defmodule Sigma.Session.HookFeedbackDurabilityTest do
  use ExUnit.Case, async: false

  alias Sigma.Agent.Message
  alias Sigma.Session.{HookFeedback, Writer}

  @moduletag :tmp_dir

  test "a new hook receipt syncs its file before acknowledging the append", %{tmp_dir: dir} do
    writer =
      start_supervised!(
        {Writer, storage_id: Path.join(dir, "sync.jsonl"), session_id: "session", cwd: dir}
      )

    assert {:ok, anchor} = Writer.append(writer, {:message_end, Message.user("origin", "prompt")})

    origin = %{
      "run_id" => "run",
      "incarnation" => 1,
      "turn_id" => "turn",
      "step_id" => "step",
      "attempt_id" => "attempt",
      "invocation_id" => "invocation",
      "tool_call_id" => "call",
      "tool_name" => "update_plan",
      "branch_entry_id" => anchor,
      "handler_index" => 0,
      "handler_digest" => String.duplicate("a", 64)
    }

    assert {:ok, event} = HookFeedback.received("session", origin, "original context")

    # Trace the real storage boundary without replacing its filesystem calls.
    # This module is synchronous because the trace pattern is VM-global.
    :erlang.trace_pattern({:file, :sync, 1}, [{:_, [], [{:return_trace}]}], [:local])
    :erlang.trace(writer, true, [:call, {:tracer, self()}])
    on_exit(fn -> :erlang.trace_pattern({:file, :sync, 1}, false, [:local]) end)

    assert {:ok, _receipt} = Writer.append_hook_feedback(writer, event, anchor)
    delivered = :erlang.trace_delivered(writer)
    assert_receive {:trace_delivered, ^writer, ^delivered}
    assert_receive {:trace, ^writer, :call, {:file, :sync, [_io]}}
    assert_receive {:trace, ^writer, :return_from, {:file, :sync, 1}, :ok}
  end
end
