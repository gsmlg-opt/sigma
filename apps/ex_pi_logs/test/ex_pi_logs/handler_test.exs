defmodule PiLogs.HandlerTest do
  use ExUnit.Case, async: false

  setup do
    session_id = "handler_test_#{System.unique_integer([:positive])}"
    {:ok, _} = PiLogs.Buffer.start_link(session_id: session_id)
    PiLogs.Handler.attach_all()
    on_exit(fn -> :telemetry.detach("ex_pi_logs") end)
    %{session_id: session_id}
  end

  test "LLM request_start is stored in buffer", %{session_id: sid} do
    :telemetry.execute(
      [:ex_pi, :llm, :request, :start],
      %{system_time: System.system_time()},
      %{session_id: sid, model: "claude-3", request_body: %{}}
    )

    [entry] = PiLogs.Buffer.all(sid)
    assert entry.category == :llm
    assert entry.event == :request_start
    assert entry.metadata[:model] == "claude-3"
  end

  test "tool call_stop is stored with correct category", %{session_id: sid} do
    :telemetry.execute(
      [:ex_pi, :tool, :call, :stop],
      %{duration: 42},
      %{session_id: sid, tool_name: "bash", result: {:ok, "output"}}
    )

    [entry] = PiLogs.Buffer.all(sid)
    assert entry.category == :tool
    assert entry.event == :call_stop
  end

  test "events without session_id are silently dropped", %{session_id: sid} do
    :telemetry.execute(
      [:ex_pi, :llm, :request, :start],
      %{system_time: System.system_time()},
      %{model: "claude-3"}
    )

    assert PiLogs.Buffer.all(sid) == []
  end
end
