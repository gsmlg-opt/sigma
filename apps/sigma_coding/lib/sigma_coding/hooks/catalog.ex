defmodule Sigma.Coding.Hooks.Catalog do
  @moduledoc "Hook declarations from openai/codex at the pinned reference commit."

  @reference_commit "7a152fbcf9ecd32d9fb4b45edf80127ee4c8499e"
  @declarations [
    {"PreModelRequest", :pre_model_request, "Before each model request (observation only).", nil},
    {"PostModelRequest", :post_model_request,
     "After each model request completes, fails, or is cancelled (observation only).", nil},
    {"PreToolUse", :pre_tool_use, "Before a tool runs.", "Bash|apply_patch"},
    {"PermissionRequest", :permission_request, "When a tool requests permission.",
     "Bash|apply_patch"},
    {"PostToolUse", :post_tool_use, "After a tool finishes.", "Bash|apply_patch"},
    {"PreCompact", :pre_compact, "Before conversation context is compacted.", "manual|auto"},
    {"PostCompact", :post_compact, "After conversation context is compacted.", "manual|auto"},
    {"SessionStart", :session_start,
     "When a session starts, resumes, clears, compacts, or forks.",
     "startup|resume|clear|compact|fork"},
    {"SessionEnd", :session_end, "When a session shuts down.", "other"},
    {"UserPromptSubmit", :user_prompt_submit, "Before a submitted prompt is processed.", nil},
    {"SubagentStart", :subagent_start, "When a subagent starts.", "explorer|worker"},
    {"SubagentStop", :subagent_stop, "When a subagent finishes its turn.", "explorer|worker"},
    {"Stop", :stop, "When the agent finishes its turn.", nil},
    {"Interrupt", :interrupt, "When the current turn is interrupted (observation only).", nil}
  ]
  @events Enum.map(@declarations, fn {name, event, description, matcher} ->
            bounded? = event in [:session_end, :interrupt]

            %{
              name: name,
              event: event,
              description: description,
              matcher: matcher,
              default_timeout: if(bounded?, do: 1, else: 600),
              max_timeout: if(bounded?, do: 3, else: nil),
              available?: true,
              limitation: nil
            }
          end)

  def events, do: @events
  def reference_commit, do: @reference_commit
end
