defmodule PiCoding.Hooks.Discovery do
  @moduledoc """
  Parses hook configuration files into `HookSpec` structs.

  `parse/2` is pure: it takes raw JSON bytes and a dialect atom and returns
  a list of `HookSpec`s. It performs no filesystem I/O.

  `load/1` is impure: it resolves all config layer paths for a given repo cwd,
  reads each file, parses it, and accumulates specs tagged with origin and
  trust state.
  """

  alias PiCoding.Hooks.Spec
  alias PiCoding.Hooks.Spec.{Command, Http}

  # Default timeouts per the wire contract
  @default_timeout_ms 600_000
  @user_prompt_submit_timeout_ms 30_000

  # ---------------------------------------------------------------------------
  # Pure parse API
  # ---------------------------------------------------------------------------

  @doc """
  Parse raw JSON bytes from a hook config file into a list of `HookSpec`s.

  `dialect` is `:codex`, `:claude`, or `:pi`. For `:claude`, the top-level
  `"hooks"` key is extracted first.

  Returns `{:ok, [%HookSpec{}]}` or `{:error, reason}`.
  """
  @spec parse(binary(), Spec.dialect()) :: {:ok, [Spec.t()]} | {:error, term()}
  def parse(bytes, dialect) when is_binary(bytes) and dialect in [:codex, :claude, :pi] do
    case Jason.decode(bytes) do
      {:ok, data} ->
        hooks_list = extract_hooks_list(data, dialect)
        specs = parse_hooks_list(hooks_list, dialect)
        {:ok, specs}

      {:error, reason} ->
        {:error, {:json_decode, reason}}
    end
  end

  # ---------------------------------------------------------------------------
  # Impure load API
  # ---------------------------------------------------------------------------

  @doc """
  Load all hook specs for a given repo `cwd`.

  Accumulates from all config layers in precedence order, tagging each spec
  with `{origin, dialect, trusted?}`. Project-layer specs are loaded but
  marked `trusted?: false` if the repo is not trusted.

  Returns a flat list of `%HookSpec{}`.
  """
  @spec load(String.t()) :: [Spec.t()]
  def load(cwd) when is_binary(cwd) do
    home = System.user_home!()
    pi_agent_dir = agent_dir()

    # Build the set of (path, origin, dialect) triples to check
    sources = [
      # User-layer: pi agent hooks
      {Path.join(pi_agent_dir, "hooks.json"), {:user, pi_agent_dir}, :pi},
      # User-layer: Codex
      {Path.join(home, ".codex/hooks.json"), {:user, home}, :codex},
      # User-layer: Claude (settings.json with embedded hooks key)
      {Path.join(home, ".claude/settings.json"), {:user, home}, :claude},
      # Project-layer: Codex
      {Path.join(cwd, ".codex/hooks.json"), {:project, cwd}, :codex},
      # Project-layer: Claude settings.json
      {Path.join(cwd, ".claude/settings.json"), {:project, cwd}, :claude},
      # Project-layer: Claude settings.local.json
      {Path.join(cwd, ".claude/settings.local.json"), {:project, cwd}, :claude},
      # Project-layer: pi convenience file
      {Path.join(cwd, ".pi/hooks.json"), {:project, cwd}, :pi}
    ]

    repo_trusted? = repo_trusted?(cwd)

    Enum.flat_map(sources, fn {path, origin, dialect} ->
      load_file(path, origin, dialect, repo_trusted?)
    end)
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp load_file(path, origin, dialect, repo_trusted?) do
    case File.read(path) do
      {:ok, bytes} ->
        case parse(bytes, dialect) do
          {:ok, specs} ->
            {origin_type, _} = origin
            trusted? = origin_type == :user or repo_trusted?

            Enum.map(specs, fn spec ->
              %{spec | origin: origin, trusted?: trusted?}
            end)

          {:error, _} ->
            []
        end

      {:error, _} ->
        []
    end
  end

  defp extract_hooks_list(data, :claude) when is_map(data) do
    normalize_hooks_value(Map.get(data, "hooks", []))
  end

  defp extract_hooks_list(data, dialect) when dialect in [:codex, :pi] and is_list(data) do
    data
  end

  defp extract_hooks_list(data, _dialect) when is_map(data) do
    normalize_hooks_value(Map.get(data, "hooks", []))
  end

  defp extract_hooks_list(_, _), do: []

  # Claude Code settings.json uses hooks as a map keyed by event name:
  #   {"SessionStart": [matcher_groups], "PreToolUse": [matcher_groups]}
  # Normalize to the list form that parse_hook_entry expects:
  #   [%{"event" => "SessionStart", "hooks" => [...]}, ...]
  defp normalize_hooks_value(hooks) when is_map(hooks) do
    Enum.map(hooks, fn {event_name, groups} ->
      %{"event" => event_name, "hooks" => List.wrap(groups)}
    end)
  end

  defp normalize_hooks_value(hooks) when is_list(hooks), do: hooks
  defp normalize_hooks_value(_), do: []

  defp parse_hooks_list(hooks_list, dialect) when is_list(hooks_list) do
    Enum.flat_map(hooks_list, fn entry ->
      parse_hook_entry(entry, dialect)
    end)
  end

  defp parse_hooks_list(_, _), do: []

  # Each top-level entry has an event name and a list of matcher groups.
  # Format: %{"matcher" => "...", "hooks" => [...handlers]}
  # Or older format: %{"event" => "...", "hooks" => [...handlers]}
  defp parse_hook_entry(entry, dialect) when is_map(entry) do
    raw_event = Map.get(entry, "event") || Map.get(entry, "hookEvent") || Map.get(entry, "type")
    matcher_groups = Map.get(entry, "hooks", [Map.drop(entry, ["event", "hookEvent", "type"])])

    case normalize_event(raw_event) do
      nil ->
        []

      event ->
        Enum.flat_map(matcher_groups, fn group ->
          parse_matcher_group(group, event, dialect)
        end)
    end
  end

  defp parse_hook_entry(_, _), do: []

  # A matcher group has an optional "matcher" and a list of "hooks" (handlers).
  # Some formats put handlers directly in the group.
  defp parse_matcher_group(group, event, dialect) when is_map(group) do
    raw_matcher = Map.get(group, "matcher")
    handlers_raw = Map.get(group, "hooks", [group])

    matcher = parse_matcher(raw_matcher)

    handlers_raw
    |> List.wrap()
    |> Enum.map(fn handler_raw ->
      parse_handler(handler_raw, event, matcher, dialect)
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_matcher_group(_, _, _), do: []

  defp parse_handler(raw, event, matcher, dialect) when is_map(raw) do
    handler_type = detect_handler_type(raw)

    handler =
      case handler_type do
        :command ->
          cmd = Map.get(raw, "command") || Map.get(raw, "cmd") || ""
          timeout_ms = parse_timeout(raw, event)
          status_message = Map.get(raw, "statusMessage") || Map.get(raw, "status_message")
          %Command{cmd: cmd, timeout_ms: timeout_ms, status_message: status_message}

        :http ->
          url = Map.get(raw, "url") || ""
          timeout_ms = parse_timeout(raw, event)
          headers = Map.get(raw, "headers", %{})
          %Http{url: url, timeout_ms: timeout_ms, headers: headers}

        unsupported when is_atom(unsupported) ->
          {:unsupported, unsupported}
      end

    unsupported_reason =
      case handler do
        {:unsupported, type} -> "Handler type '#{type}' is not supported in v1"
        %Http{} -> "HTTP handlers are not supported in v1"
        _ -> nil
      end

    %Spec{
      event: event,
      matcher: matcher,
      handler: handler,
      origin: nil,
      dialect: dialect,
      trusted?: nil,
      unsupported_reason: unsupported_reason
    }
  end

  defp parse_handler(_, _, _, _), do: nil

  defp detect_handler_type(raw) do
    cond do
      Map.has_key?(raw, "command") or Map.has_key?(raw, "cmd") -> :command
      Map.has_key?(raw, "url") -> :http
      Map.get(raw, "type") in ["mcp_tool", "mcpTool"] -> :mcp_tool
      Map.get(raw, "type") in ["prompt"] -> :prompt
      Map.get(raw, "type") in ["agent"] -> :agent
      Map.get(raw, "async") == true -> :async
      true -> :command
    end
  end

  # Matcher rules per Claude spec:
  # nil/"*"/"" → :any
  # only letters/digits/_/| → exact or |-list (stored as plain string)
  # any other char → compiled regex
  defp parse_matcher(nil), do: :any
  defp parse_matcher(""), do: :any
  defp parse_matcher("*"), do: :any

  defp parse_matcher(s) when is_binary(s) do
    if Regex.match?(~r/^[A-Za-z0-9_|]+$/, s) do
      s
    else
      case Regex.compile(s) do
        {:ok, re} -> re
        {:error, _} -> :any
      end
    end
  end

  # Timeout: `timeout` (seconds), `timeoutSec` alias, default 600s
  # Exception: UserPromptSubmit command default is 30s
  defp parse_timeout(raw, event) do
    secs =
      Map.get(raw, "timeout") ||
        Map.get(raw, "timeoutSec") ||
        Map.get(raw, "timeout_sec")

    cond do
      is_number(secs) -> round(secs * 1000)
      event == :user_prompt_submit -> @user_prompt_submit_timeout_ms
      true -> @default_timeout_ms
    end
  end

  @event_map %{
    "PreToolUse" => :pre_tool_use,
    "pre_tool_use" => :pre_tool_use,
    "PermissionRequest" => :permission_request,
    "permission_request" => :permission_request,
    "PostToolUse" => :post_tool_use,
    "post_tool_use" => :post_tool_use,
    "UserPromptSubmit" => :user_prompt_submit,
    "user_prompt_submit" => :user_prompt_submit,
    "Stop" => :stop,
    "stop" => :stop,
    "SessionStart" => :session_start,
    "session_start" => :session_start,
    "PreCompact" => :pre_compact,
    "pre_compact" => :pre_compact
  }

  defp normalize_event(name) when is_binary(name), do: Map.get(@event_map, name)
  defp normalize_event(_), do: nil

  defp repo_trusted?(cwd) do
    cwd = Path.expand(cwd)
    repos_path = Path.join(agent_dir(), "repos.jsonl")

    with {:ok, content} <- File.read(repos_path) do
      content
      |> String.split("\n", trim: true)
      |> Enum.any?(fn line ->
        case Jason.decode(line) do
          {:ok, %{"path" => ^cwd, "trusted" => true}} -> true
          _ -> false
        end
      end)
    else
      _ -> false
    end
  end

  defp agent_dir do
    Application.get_env(:ex_pi_session, :agent_dir) ||
      Path.join([System.user_home!(), ".pi", "agent"])
  end
end
