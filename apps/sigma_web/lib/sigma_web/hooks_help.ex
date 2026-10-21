defmodule Sigma.Web.HooksHelp do
  @moduledoc "Event help for the Codex hook contract implemented by Sigma."

  alias Sigma.Coding.Hooks.{Catalog, Payload}

  @events Map.new(Catalog.events(), &{&1.event, &1.name})
  @observers [:pre_model_request, :post_model_request, :session_end]
  @context_events [
    :session_start,
    :subagent_start,
    :user_prompt_submit,
    :pre_tool_use,
    :post_tool_use
  ]
  @sample_context %{
    session_id: "example-session",
    turn_id: "example-turn",
    cwd: "/example/project",
    transcript_path: nil,
    model: "example-model",
    permission_mode: "default"
  }
  @sample_data %{
    source: "startup",
    prompt: "Explain this example project.",
    tool_name: "exec_command",
    tool_input: %{"command" => "printf hello"},
    tool_use_id: "example-tool-call",
    tool_response: "hello",
    trigger: "manual",
    stop_hook_active: false,
    last_assistant_message: "The example task is complete.",
    agent_id: "example-agent",
    agent_type: "worker",
    agent_transcript_path: nil,
    status: "completed",
    error: nil,
    token_usage: nil
  }
  @fields [
    {"session_id", "string", "Session identifier."},
    {"turn_id", "string", "Current turn identifier; may be empty before a turn exists."},
    {"transcript_path", "string | null",
     "Transcript path, or null when unavailable; always present."},
    {"cwd", "string", "Absolute working directory."},
    {"hook_event_name", "string",
     "Exact event name; supported hookSpecificOutput objects repeat it as hookEventName."},
    {"model", "string", "Current model identifier; may be empty when unavailable."},
    {"permission_mode", "string", "Current permission mode; Sigma currently supplies default."},
    {"agent_id", "string", "Subagent identifier."},
    {"agent_type", "string", "Subagent type used for matching SubagentStart and SubagentStop."},
    {"source", "string",
     "Accepted sources: startup, resume, clear, compact, fork. Sigma automatically supplies startup/resume; others require an explicit host source."},
    {"reason", "string", "Session shutdown reason; Sigma supplies other."},
    {"prompt", "string", "Submitted user prompt text."},
    {"tool_name", "string", "Canonical tool name, such as Bash, apply_patch, or spawn_agent."},
    {"tool_input", "JSON value", "Tool arguments; Sigma tools supply a JSON object."},
    {"tool_use_id", "string", "Tool call identifier shared by PreToolUse and PostToolUse."},
    {"tool_response", "JSON value | null", "Tool result; may be null when unavailable."},
    {"trigger", "string", "Compaction trigger: manual or auto."},
    {"stop_hook_active", "boolean", "Whether a stop hook already requested continuation."},
    {"last_assistant_message", "string | null", "Last assistant text, or null when unavailable."},
    {"agent_transcript_path", "string | null",
     "Child transcript path, or null when unavailable."},
    {"status", "string", "Model request status: completed, failed, or cancelled."},
    {"error", "string | null", "Request error, or null when none is available; always present."},
    {"token_usage", "object | null",
     "Integer counters: input_tokens, cached_input_tokens, output_tokens, reasoning_output_tokens, total_tokens. Null when unknown; always present."}
  ]

  def for_event(event) do
    example = Payload.build(event, @sample_context, @sample_data)

    child_example =
      Payload.build(
        event,
        Map.merge(@sample_context, %{agent_id: "example-agent", agent_type: "worker"}),
        @sample_data
      )

    %{
      input_fields:
        for {name, type, description} <- @fields, Map.has_key?(child_example, name) do
          optional? = not Map.has_key?(example, name)

          description =
            if event == :subagent_stop and name == "transcript_path",
              do: "Parent transcript path, or null when unavailable; always present.",
              else: description

          %{
            name: name,
            type: if(optional?, do: type <> " (optional)", else: type),
            description:
              if(optional?,
                do: description <> " Included only when running inside a subagent.",
                else: description
              )
          }
        end,
      input_example: example,
      output_rules: rules(event),
      output_examples: examples(event),
      exit_codes: exit_codes(event),
      async_note: async_note(event)
    }
  end

  defp rules(event) when event in @observers,
    do: [
      "Observation only: stdout is ignored, including JSON control fields and systemMessage.",
      "Nonzero exits report diagnostics and cannot steer execution. Exit 0 does not surface stderr."
    ]

  defp rules(:interrupt),
    do: [
      "Write one complete JSON object with systemMessage for a diagnostic; do not mix JSON with logs.",
      "Control, context, and unknown fields are invalid and produce diagnostics without control. Plain stdout is diagnostic, not context.",
      "Exit status takes precedence over stdout. Exit 0 does not surface stderr; use systemMessage."
    ]

  defp rules(event) do
    [
      "For JSON output, write one complete object to stdout without mixed log lines. Empty stdout proceeds; invalid JSON or unsupported/unknown fields report diagnostics without applying control.",
      "Exit status takes precedence over stdout. Exit 0 does not surface stderr; use systemMessage for a diagnostic."
      | event_rules(event)
    ]
  end

  defp event_rules(:pre_tool_use),
    do: [
      "decision:block requires a non-empty reason and blocks the tool.",
      "hookSpecificOutput supports additionalContext, or permissionDecision:deny with a non-empty permissionDecisionReason.",
      "permissionDecision:allow requires updatedInput as a complete JSON object replacement; the last completed replacement wins. Rewritten input still passes permission policy; allow does not bypass approval.",
      "permissionDecision:ask, continue:false, stopReason, and suppressOutput:true are unsupported. Plain stdout is ignored."
    ]

  defp event_rules(:permission_request),
    do: [
      "hookSpecificOutput.decision.behavior may be allow or deny; deny may include a message. Any deny wins over allow.",
      "No decision leaves the normal approval flow in place. Input or permission updates, interrupt:true, and universal stop controls are unsupported.",
      "No additional context is supported; plain stdout reports a diagnostic."
    ]

  defp event_rules(:post_tool_use),
    do: [
      "decision:block requires a non-empty reason; Sigma replaces the tool result with that feedback.",
      "hookSpecificOutput.additionalContext appends context to the tool result. Tool output replacement fields are unsupported.",
      "continue:false does not stop the turn in Sigma; the tool result is preserved. reason without decision is invalid unless continue:false.",
      "Plain stdout reports a diagnostic."
    ]

  defp event_rules(:session_start),
    do:
      context_rules() ++
        [
          "continue:false with optional stopReason stops the pending turn; context from that halted result is not retained."
        ]

  defp event_rules(:subagent_start),
    do:
      context_rules() ++
        ["continue:false does not prevent subagent creation; no blocking decision is supported."]

  defp event_rules(:user_prompt_submit),
    do:
      context_rules() ++
        [
          "decision:block requires a non-empty reason and blocks the submitted turn.",
          "continue:false with optional stopReason stops the turn; context from that halted result is not retained."
        ]

  defp event_rules(event) when event in [:stop, :subagent_stop],
    do: [
      "decision:block requires a non-empty reason and asks the agent to continue instead of stopping.",
      "continue:false with optional stopReason finishes the turn. Additional context is unsupported; plain stdout reports a diagnostic."
    ]

  defp event_rules(:pre_compact),
    do: [
      "continue:false with optional stopReason prevents compaction.",
      "No decision or additional context is supported. Plain stdout is ignored."
    ]

  defp event_rules(:post_compact),
    do: [
      "continue:false with optional stopReason stops further work after saved compaction; it cannot undo that compaction.",
      "No decision or additional context is supported. Plain stdout is ignored."
    ]

  defp context_rules,
    do: [
      "Plain stdout or hookSpecificOutput.additionalContext supplies model context. hookSpecificOutput must include the exact hookEventName."
    ]

  defp examples(event) when event in @observers, do: []

  defp examples(:interrupt),
    do: [example("Diagnostic", %{"systemMessage" => "Example diagnostic"})]

  defp examples(:pre_tool_use),
    do: [
      block_example(),
      example(
        "Replace complete input",
        specific(:pre_tool_use, %{
          "permissionDecision" => "allow",
          "updatedInput" => %{"command" => "printf hello"}
        })
      ),
      context_example(:pre_tool_use)
    ]

  defp examples(:permission_request),
    do:
      for(
        behavior <- ["allow", "deny"],
        do:
          example(
            String.capitalize(behavior),
            specific(:permission_request, %{
              "decision" => %{"behavior" => behavior, "message" => "Example policy"}
            })
          )
      )

  defp examples(:post_tool_use), do: [block_example(), context_example(:post_tool_use)]

  defp examples(:session_start),
    do: [
      context_example(:session_start),
      example("Plain context", "Example project context"),
      halt_example()
    ]

  defp examples(:subagent_start),
    do: [context_example(:subagent_start), example("Plain context", "Example subagent context")]

  defp examples(:user_prompt_submit),
    do: [
      block_example(),
      context_example(:user_prompt_submit),
      example("Plain context", "Example prompt context")
    ]

  defp examples(event) when event in [:stop, :subagent_stop],
    do: [
      example("Request continuation", %{
        "decision" => "block",
        "reason" => "Complete the example check first"
      }),
      halt_example()
    ]

  defp examples(event) when event in [:pre_compact, :post_compact],
    do: [example("Continue", %{}), halt_example()]

  defp block_example,
    do:
      example("Blocking feedback", %{"decision" => "block", "reason" => "Example policy reason"})

  defp halt_example,
    do: example("Halt request", %{"continue" => false, "stopReason" => "Example pause"})

  defp context_example(event),
    do:
      example(
        "Additional context",
        specific(event, %{"additionalContext" => "Example project context"})
      )

  defp specific(event, fields),
    do: %{"hookSpecificOutput" => Map.put(fields, "hookEventName", Map.fetch!(@events, event))}

  defp example(label, output), do: %{label: label, output: output}

  defp exit_codes(event) do
    [
      %{
        code: "0",
        description:
          if(event in @observers,
            do: "Successful observation; stdout is ignored.",
            else: "Parse supported stdout; empty stdout proceeds."
          )
      },
      %{code: "2", description: exit_two(event)},
      %{code: "Other nonzero", description: "Non-blocking failure diagnostic; stdout is ignored."}
    ]
  end

  defp exit_two(:pre_tool_use),
    do: "Blocks the tool using non-empty stderr as the reason; empty stderr is diagnostic."

  defp exit_two(:permission_request),
    do: "Denies approval using non-empty stderr; empty stderr is diagnostic."

  defp exit_two(:post_tool_use),
    do:
      "Uses non-empty stderr as blocking feedback; Sigma replaces the tool result. Empty stderr is diagnostic."

  defp exit_two(:user_prompt_submit),
    do: "Blocks the submitted turn using non-empty stderr; empty stderr is diagnostic."

  defp exit_two(event) when event in [:stop, :subagent_stop],
    do: "Requests continuation using non-empty stderr; empty stderr is diagnostic."

  defp exit_two(_event), do: "Non-blocking failure diagnostic; stdout is ignored."

  defp async_note(:session_end),
    do: "SessionEnd command hooks always run synchronously; async:true is ignored."

  defp async_note(event) do
    context =
      if event in @context_events,
        do: " Valid additional context may reach later model requests.",
        else: " This event does not supply model context."

    "async:true queues command hooks in the background, with at most eight running per session. Control effects are ignored; failures remain diagnostic." <>
      context <> " Session shutdown cancels outstanding hooks."
  end
end
