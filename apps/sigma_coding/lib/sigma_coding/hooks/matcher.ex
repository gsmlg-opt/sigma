defmodule Sigma.Coding.Hooks.Matcher do
  @moduledoc "Codex canonical hook tool identities and event-specific matcher selection."

  alias Sigma.Coding.Hooks.Spec

  @shell_tools ~w(bash exec_command write_stdin shell shell_command)

  def to_external_name(name) when name in @shell_tools, do: "Bash"
  def to_external_name(name) when is_binary(name), do: name

  def match?(%Spec{event: event}, _context)
      when event in [
             :pre_model_request,
             :post_model_request,
             :user_prompt_submit,
             :stop,
             :interrupt
           ],
      do: true

  def match?(%Spec{event: event, matcher: matcher}, context)
      when event in [:pre_tool_use, :post_tool_use, :permission_request] do
    canonical = to_external_name(Map.get(context, :tool_name, ""))

    aliases =
      case canonical do
        "apply_patch" -> ["Write", "Edit"]
        "spawn_agent" -> ["Agent"]
        _ -> []
      end

    Enum.any?(
      [canonical | aliases ++ Map.get(context, :matcher_aliases, [])],
      &eval_matcher(matcher, &1)
    )
  end

  def match?(%Spec{event: :session_start, matcher: matcher}, context),
    do: eval_matcher(matcher, string_value(context[:source], "startup"))

  def match?(%Spec{event: :session_end, matcher: matcher}, _context),
    do: eval_matcher(matcher, "other")

  def match?(%Spec{event: event, matcher: matcher}, context)
      when event in [:subagent_start, :subagent_stop],
      do: eval_matcher(matcher, string_value(context[:agent_type], ""))

  def match?(%Spec{event: event, matcher: matcher}, context)
      when event in [:pre_compact, :post_compact],
      do: eval_matcher(matcher, string_value(context[:trigger], "auto"))

  def match?(_spec, _context), do: false

  defp eval_matcher(matcher, _value) when matcher in [:any, nil, "", "*"], do: true
  defp eval_matcher(%Regex{} = regex, value), do: Regex.match?(regex, value)

  defp eval_matcher(matcher, value) when is_binary(matcher),
    do: value in String.split(matcher, "|")

  defp eval_matcher(_, _), do: false

  defp string_value(value, _default) when is_binary(value), do: value

  defp string_value(value, _default) when is_atom(value) and not is_nil(value),
    do: Atom.to_string(value)

  defp string_value(_, default), do: default
end
