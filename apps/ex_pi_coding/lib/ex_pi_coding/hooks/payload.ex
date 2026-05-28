defmodule PiCoding.Hooks.Payload do
  @moduledoc """
  Builds the stdin JSON payload sent to hook commands.

  All functions are pure and return JSON-encodable maps. The caller is
  responsible for encoding via `Jason.encode!/1`.

  Common fields (FR-P1):
    session_id, transcript_path, cwd, hook_event_name, permission_mode

  Event-specific fields (FR-P2) are merged on top.
  """

  alias PiCoding.Hooks.Matcher

  @doc """
  Build the JSON payload map for a hook event.

  `ctx` is the session/turn context with at minimum:
    - `:session_id`
    - `:cwd`
    - `:transcript_path`
    - `:permission_mode` (default "default")
    - `:model` (required on SessionStart; optional elsewhere)
    - `:turn_id` (optional)

  `event_data` carries event-specific fields.
  """
  @spec build(atom(), map(), map()) :: map()
  def build(event, ctx, event_data \\ %{}) do
    base = %{
      "session_id" => ctx[:session_id] || "",
      "transcript_path" => ctx[:transcript_path] || "",
      "cwd" => ctx[:cwd] || "",
      "hook_event_name" => event_name(event),
      "permission_mode" => ctx[:permission_mode] || "default"
    }

    base
    |> maybe_put("turn_id", ctx[:turn_id])
    |> Map.merge(event_specific(event, ctx, event_data))
  end

  # ---------------------------------------------------------------------------
  # Event-specific fields
  # ---------------------------------------------------------------------------

  defp event_specific(:session_start, ctx, data) do
    %{
      "source" => to_string(Map.get(data, :source, "startup")),
      "model" => ctx[:model] || ""
    }
  end

  defp event_specific(:user_prompt_submit, _ctx, data) do
    %{"prompt" => Map.get(data, :prompt, "")}
  end

  defp event_specific(event, _ctx, data)
       when event in [:pre_tool_use, :permission_request] do
    %{
      "tool_name" => Matcher.to_external_name(Map.get(data, :tool_name, "")),
      "tool_use_id" => Map.get(data, :tool_use_id, ""),
      "tool_input" => Map.get(data, :tool_input, %{})
    }
  end

  defp event_specific(:post_tool_use, _ctx, data) do
    %{
      "tool_name" => Matcher.to_external_name(Map.get(data, :tool_name, "")),
      "tool_use_id" => Map.get(data, :tool_use_id, ""),
      "tool_input" => Map.get(data, :tool_input, %{}),
      "tool_response" => Map.get(data, :tool_response, "")
    }
  end

  defp event_specific(:stop, _ctx, data) do
    %{
      "stop_hook_active" => Map.get(data, :stop_hook_active, false),
      "last_assistant_message" => Map.get(data, :last_assistant_message, "")
    }
  end

  defp event_specific(:session_end, _ctx, data) do
    %{
      "reason" => to_string(Map.get(data, :reason, "user_close")),
      "last_activity_at" => Map.get(data, :last_activity_at, "")
    }
  end

  defp event_specific(:pre_compact, _ctx, data) do
    %{
      "trigger" => to_string(Map.get(data, :trigger, "auto")),
      "summary" => Map.get(data, :summary, "")
    }
  end

  defp event_specific(_, _, _), do: %{}

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp event_name(:pre_tool_use), do: "PreToolUse"
  defp event_name(:permission_request), do: "PermissionRequest"
  defp event_name(:post_tool_use), do: "PostToolUse"
  defp event_name(:user_prompt_submit), do: "UserPromptSubmit"
  defp event_name(:stop), do: "Stop"
  defp event_name(:session_start), do: "SessionStart"
  defp event_name(:session_end), do: "SessionEnd"
  defp event_name(:pre_compact), do: "PreCompact"
  defp event_name(event), do: to_string(event)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
