defmodule Sigma.Coding.Hooks.Payload do
  @moduledoc "Builds command stdin according to the pinned Codex hook input schemas."

  alias Sigma.Coding.Hooks.{Catalog, Matcher}

  @names Map.new(Catalog.events(), &{&1.event, &1.name})
  @no_permission [
    :session_end,
    :pre_compact,
    :post_compact,
    :pre_model_request,
    :post_model_request
  ]

  def build(event, ctx, data \\ %{}) do
    base = %{
      "session_id" => ctx[:session_id] || "",
      "transcript_path" => ctx[:transcript_path],
      "cwd" => ctx[:cwd] || "",
      "hook_event_name" => Map.fetch!(@names, event)
    }

    base = if event == :session_end, do: base, else: Map.put(base, "model", ctx[:model] || "")

    base =
      if event in @no_permission,
        do: base,
        else: Map.put(base, "permission_mode", ctx[:permission_mode] || "default")

    base =
      if event in [:session_start, :session_end],
        do: base,
        else: Map.put(base, "turn_id", ctx[:turn_id] || "")

    base
    |> subagent_fields(event, ctx, data)
    |> Map.merge(event_fields(event, data))
  end

  defp subagent_fields(base, event, ctx, data) do
    cond do
      event in [:subagent_start, :subagent_stop] ->
        base
        |> Map.put("agent_id", data[:agent_id] || ctx[:agent_id] || "")
        |> Map.put("agent_type", data[:agent_type] || ctx[:agent_type] || "")

      event in [:session_start, :session_end, :stop, :interrupt] ->
        base

      true ->
        base |> maybe_put("agent_id", ctx[:agent_id]) |> maybe_put("agent_type", ctx[:agent_type])
    end
  end

  defp event_fields(:session_start, data),
    do: %{"source" => to_string(data[:source] || "startup")}

  defp event_fields(:session_end, _data), do: %{"reason" => "other"}
  defp event_fields(:user_prompt_submit, data), do: %{"prompt" => data[:prompt] || ""}

  defp event_fields(event, data)
       when event in [:pre_tool_use, :permission_request, :post_tool_use] do
    fields = %{
      "tool_name" => Matcher.to_external_name(data[:tool_name] || ""),
      "tool_input" => data[:tool_input] || %{}
    }

    fields =
      if event == :permission_request,
        do: fields,
        else: Map.put(fields, "tool_use_id", data[:tool_use_id] || "")

    if event == :post_tool_use,
      do: Map.put(fields, "tool_response", Map.get(data, :tool_response)),
      else: fields
  end

  defp event_fields(event, data) when event in [:stop, :subagent_stop] do
    fields = %{
      "stop_hook_active" => Map.get(data, :stop_hook_active, false),
      "last_assistant_message" => data[:last_assistant_message]
    }

    if event == :subagent_stop,
      do: Map.put(fields, "agent_transcript_path", data[:agent_transcript_path]),
      else: fields
  end

  defp event_fields(event, data) when event in [:pre_compact, :post_compact],
    do: %{"trigger" => to_string(data[:trigger] || "auto")}

  defp event_fields(:post_model_request, data),
    do: %{
      "status" => to_string(data[:status] || "completed"),
      "error" => data[:error],
      "token_usage" => data[:token_usage]
    }

  defp event_fields(_event, _data), do: %{}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
