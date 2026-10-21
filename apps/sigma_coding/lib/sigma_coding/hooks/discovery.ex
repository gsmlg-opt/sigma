defmodule Sigma.Coding.Hooks.Discovery do
  @moduledoc """
  Parses hook configuration files into `HookSpec` structs.

  `parse/2` is pure: it takes raw JSON bytes and a dialect atom and returns
  a list of `HookSpec`s. It performs no filesystem I/O.

  `load/1` is impure: it resolves all config layer paths for a given repo cwd,
  reads each file, parses it, and accumulates specs tagged with origin and
  trust state.
  """

  alias Sigma.Coding.Hooks.Spec
  alias Sigma.Coding.Hooks.Catalog
  alias Sigma.Coding.Hooks.Spec.{Command, McpTool}

  # Default timeouts per the wire contract
  @default_timeout_ms 600_000

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
        Enum.flat_map(List.wrap(matcher_groups), fn group ->
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

    case parse_matcher(raw_matcher, event) do
      {:ok, matcher} ->
        handlers_raw
        |> List.wrap()
        |> Enum.map(fn handler_raw -> parse_handler(handler_raw, event, matcher, dialect) end)
        |> Enum.reject(&is_nil/1)

      :error ->
        []
    end
  end

  defp parse_matcher_group(_, _, _), do: []

  defp parse_handler(raw, event, matcher, dialect) when is_map(raw) do
    handler_type = detect_handler_type(raw)

    handler =
      case handler_type do
        :command ->
          cmd =
            if match?({:win32, _}, :os.type()),
              do: raw["commandWindows"] || raw["command_windows"] || raw["command"] || raw["cmd"],
              else: raw["command"] || raw["cmd"]

          timeout_ms = parse_timeout(raw, event)
          status_message = Map.get(raw, "statusMessage") || Map.get(raw, "status_message")

          if is_binary(cmd) and String.trim(cmd) != "" and is_integer(timeout_ms) and
               Map.get(raw, "async", false) in [true, false] do
            %Command{
              cmd: cmd,
              timeout_ms: timeout_ms,
              status_message: status_message,
              async: raw["async"] == true and event != :session_end,
              additional_context_limit: raw["additionalContextLimit"]
            }
          else
            {:unsupported, :invalid_command}
          end

        :mcp_tool ->
          timeout_ms = parse_timeout(raw, event)
          server = raw["server"]
          tool = raw["tool"]
          input = Map.get(raw, "input", %{})

          if event != :session_end and is_binary(server) and String.trim(server) != "" and
               is_binary(tool) and String.trim(tool) != "" and is_map(input) and
               is_integer(timeout_ms) do
            %McpTool{
              server: server,
              tool: tool,
              input: input,
              timeout_ms: timeout_ms,
              status_message: raw["statusMessage"]
            }
          else
            {:unsupported, :invalid_mcp_tool}
          end

        unsupported ->
          {:unsupported, unsupported}
      end

    unsupported_reason =
      case handler do
        {:unsupported, type} -> "Handler type '#{type}' is not supported in v1"
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
    case Map.get(raw, "type") do
      "command" ->
        :command

      "mcp_tool" ->
        :mcp_tool

      "prompt" ->
        :prompt

      "agent" ->
        :agent

      nil ->
        if is_binary(raw["command"] || raw["cmd"]), do: :command, else: :unknown

      value when is_binary(value) ->
        value

      _ ->
        :unknown
    end
  end

  # Matcher rules per Claude spec:
  # nil/"*"/"" → :any
  # only letters/digits/_/| → exact or |-list (stored as plain string)
  # any other char → compiled regex
  defp parse_matcher(_matcher, event)
       when event in [
              :pre_model_request,
              :post_model_request,
              :user_prompt_submit,
              :stop,
              :interrupt
            ],
       do: {:ok, :any}

  defp parse_matcher(value, _event) when value in [nil, "", "*"], do: {:ok, :any}

  defp parse_matcher(value, _event) when is_binary(value) do
    if Regex.match?(~r/^[A-Za-z0-9_|]+$/, value) do
      {:ok, value}
    else
      case Regex.compile(value) do
        {:ok, regex} -> {:ok, regex}
        {:error, _} -> :error
      end
    end
  end

  defp parse_matcher(_, _), do: :error

  # Timeout: `timeout` (seconds), `timeoutSec` alias, default 600s
  # SessionEnd and Interrupt default to 1s and cap explicit timeouts at 3s.
  defp parse_timeout(raw, event) do
    secs =
      Map.get(raw, "timeout") ||
        Map.get(raw, "timeoutSec") ||
        Map.get(raw, "timeout_sec")

    default = if event in [:session_end, :interrupt], do: 1_000, else: @default_timeout_ms

    timeout =
      if is_nil(secs),
        do: default,
        else: if(is_integer(secs) and secs >= 0, do: max(secs, 1) * 1000)

    if is_integer(timeout) and event in [:session_end, :interrupt],
      do: min(timeout, 3_000),
      else: timeout
  end

  @event_map Map.new(
               Enum.flat_map(Catalog.events(), fn event ->
                 [{event.name, event.event}, {Atom.to_string(event.event), event.event}]
               end)
             )

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
    Application.get_env(:sigma_session, :agent_dir) ||
      Path.join([System.user_home!(), ".pi", "agent"])
  end
end
