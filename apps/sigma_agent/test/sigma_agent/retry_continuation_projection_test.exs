defmodule Sigma.Agent.RetryContinuationProjectionTest do
  use ExUnit.Case, async: false

  alias Sigma.Agent.{ContextBuilder, Message, Runtime}
  alias Sigma.Session.Log

  defmodule Provider do
    def stream(params) do
      send(params.options[:observer], {:retry_context, params.context.messages})

      message = %{
        role: :assistant,
        content: [%{type: :text, text: "Outcome remains unknown."}],
        model: "fixture",
        provider: "fixture",
        stop_reason: :stop,
        usage: %{input: 1, output: 1, total_tokens: 2},
        timestamp: System.system_time(:millisecond)
      }

      [{:start, %{message | content: []}}, {:done, :stop, message}]
    end
  end

  @tag :tmp_dir
  test "retry keeps the continuation projection when replacing its user prompt", %{tmp_dir: dir} do
    sessions = Path.join(dir, "sessions")
    File.mkdir_p!(sessions)
    path = Path.join(sessions, "source.jsonl")
    notice = "The earlier operation outcome is unknown."
    missing = [%{"run_id" => "old", "attempt_id" => "lost", "tool_call_id" => "missing"}]

    old_assistant = %{
      Message.assistant("msg_assistant_lost", %{
        content: [%{type: :tool_call, id: "missing", name: "read", arguments: %{}}]
      })
      | metadata: %{turn_id: "old"}
    }

    continued = %{
      Message.user("continue-user", "Continue")
      | metadata: %{
          turn_id: "continued",
          continuation_notice: notice,
          continuation_tools: missing
        }
    }

    :ok = Log.persist_event(path, {:agent_start, dir})

    for message <- [Message.user("old-user", "Read"), old_assistant, continued],
        do: :ok = Log.persist_event(path, {:message_end, message})

    {:ok, before} = Log.snapshot(path)

    {:ok, handle} =
      Runtime.get_session(dir, "source",
        cwd: dir,
        transcript_path: path,
        messages: before.messages,
        model: %{id: "fixture", api: "mock-api", provider: "fixture"},
        provider: Provider,
        options: [observer: self()],
        idle_timeout_ms: 30_000
      )

    on_exit(fn ->
      if supervisor = Runtime.lookup(dir, :supervisor),
        do: DynamicSupervisor.terminate_child(Sigma.Agent.DynamicSupervisor, supervisor)
    end)

    :ok = Sigma.Agent.subscribe(handle.agent)

    assert {:ok, result} =
             Runtime.retry_turn(dir, "source", sessions, "continue-user",
               operation_id: "retry-continuation",
               expected_source_revision: length(before.branch_entry_ids) + 1,
               expected_source_leaf: before.active_leaf_id
             )

    assert_receive {:retry_context, context}, 5_000
    assert Enum.count(context, &(&1.content == notice)) == 1

    refute Enum.any?(context, fn message ->
             message.role == :tool_result or
               Enum.any?(
                 List.wrap(message.content),
                 &match?(%{type: :tool_call, id: "missing"}, &1)
               )
           end)

    assert_receive {:turn_completed, _}, 5_000
    {:ok, after_retry} = Log.snapshot(path)
    user = Enum.find(after_retry.messages, &(&1.id == result.message_id))
    assert user.metadata["continuation_notice"] == notice
    assert user.metadata["continuation_tools"] == missing
    assert user.metadata["retry_of_turn_id"] == "continued"
    assert Enum.any?(after_retry.messages, &(&1.id == old_assistant.id))

    cold = ContextBuilder.build_messages(after_retry.messages, %Sigma.Agent.SessionContext{})
    assert Enum.count(cold, &(&1.content == notice)) == 1
    refute Enum.any?(cold, &(&1.role == :tool_result))
  end
end
