defmodule PiCoding.Hooks.Matcher do
  @moduledoc """
  Evaluates whether a `HookSpec` matches a given event context.

  Matching is event-specific:
  - PreToolUse / PostToolUse / PermissionRequest: matches the external tool_name
  - SessionStart: matches the source (startup|resume|clear|compact)
  - PreCompact: matches the trigger (manual|auto)
  - UserPromptSubmit / Stop: matcher is ignored; always fires

  External tool-name mapping (internal → external):
    bash → Bash, read → Read, write → Write, edit → Edit,
    grep → Grep, glob → Glob, ls → LS,
    url_fetch → WebFetch (canonical; UrlFetch accepted as alias),
    ask_user_question → AskUserQuestion
  MCP tools keep the mcp__<server>__<tool> form unchanged.
  """

  alias PiCoding.Hooks.Spec

  @tool_name_map %{
    "bash" => "Bash",
    "read" => "Read",
    "write" => "Write",
    "edit" => "Edit",
    "grep" => "Grep",
    "glob" => "Glob",
    "ls" => "LS",
    "url_fetch" => "WebFetch",
    "ask_user_question" => "AskUserQuestion"
  }

  # Reverse map: accept both forms from the config side
  @reverse_alias %{"UrlFetch" => "WebFetch"}

  @doc """
  Convert an internal tool name to its external (PascalCase) name.
  MCP tool names (starting with mcp__) are returned unchanged.
  """
  @spec to_external_name(String.t()) :: String.t()
  def to_external_name("mcp__" <> _ = name), do: name

  def to_external_name(name) when is_binary(name) do
    Map.get(@tool_name_map, name, name)
  end

  @doc """
  Returns true if `spec` matches the given event context.

  `context` is a map with fields relevant to the event:
  - `:tool_name` (internal name) for tool events
  - `:source` for SessionStart
  - `:trigger` for PreCompact
  """
  @spec match?(Spec.t(), map()) :: boolean()
  def match?(%Spec{event: :user_prompt_submit}, _context), do: true
  def match?(%Spec{event: :stop}, _context), do: true

  def match?(%Spec{event: event, matcher: matcher}, context)
      when event in [:pre_tool_use, :post_tool_use, :permission_request] do
    external_name =
      context
      |> Map.get(:tool_name, "")
      |> to_external_name()

    eval_matcher(matcher, external_name)
  end

  def match?(%Spec{event: :session_start, matcher: matcher}, context) do
    source = Map.get(context, :source, "")
    eval_matcher(matcher, to_string(source))
  end

  def match?(%Spec{event: :pre_compact, matcher: matcher}, context) do
    trigger = Map.get(context, :trigger, "")
    eval_matcher(matcher, to_string(trigger))
  end

  def match?(_spec, _context), do: false

  # ---------------------------------------------------------------------------
  # Matcher evaluation rules (Claude spec)
  # ---------------------------------------------------------------------------

  defp eval_matcher(:any, _value), do: true
  defp eval_matcher(nil, _value), do: true

  defp eval_matcher(matcher, value) when is_binary(matcher) do
    # Exact or |-separated list
    matcher
    |> String.split("|")
    |> Enum.any?(fn candidate ->
      # Normalize aliases on the matcher side too
      canonical = Map.get(@reverse_alias, candidate, candidate)
      canonical == value
    end)
  end

  defp eval_matcher(%Regex{} = re, value) do
    Regex.match?(re, value)
  end
end
