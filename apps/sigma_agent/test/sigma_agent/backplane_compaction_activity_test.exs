defmodule Sigma.Agent.BackplaneCompactionActivityTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.{Conversation, EphemeralStore, ToolRegistry}
  alias Sigma.Agent.Compaction
  alias Sigma.Ai.ProviderEvent

  setup_all do
    unless Process.whereis(Sigma.Ai.ProviderTaskSupervisor) do
      start_supervised!({Task.Supervisor, name: Sigma.Ai.ProviderTaskSupervisor})
    end

    :ok
  end

  defmodule SummaryProvider do
    def stream_normalized(request) do
      Stream.resource(
        fn ->
          send(request.options[:test], {:summary, self()})
          nil
        end,
        fn state ->
          receive do
            {:events, events} -> {events, state}
          end
        end,
        fn _ -> :ok end
      )
    end
  end

  defmodule Provider do
    def stream(_request, context) do
      state = %{
        provider: SummaryProvider,
        model: %{id: "summary"},
        provider_options: [test: context.test],
        session_id: "compaction-activity",
        log_session_id: nil,
        turn_id: "compaction-activity",
        context_window: 65_536,
        cancelled?: fn -> false end,
        emit: fn _, _, _ -> :ok end
      }

      result =
        Compaction.summarize([%{role: :user, content: "Summarize this session"}], state,
          on_activity: fn -> context.provider_emit.(%{type: :response_activity}) end
        )

      send(context.test, {:summary_result, result})
      [%{type: :response_completed, message: %{role: :assistant, content: "done"}}]
    end
  end

  test "real summary activity renews the outer provider idle allowance" do
    pid = start_conversation()
    assert_receive {:summary, worker}

    for _ <- 1..6 do
      Process.sleep(30)
      send(worker, {:events, [%ProviderEvent{type: :response_activity}]})
    end

    send(worker, {:events, [completed()]})
    assert_receive {:summary_result, {:ok, "summary", [_]}}, 1_000
    assert_receive {:agent_runtime, _, %{type: :run_completed}}, 1_000
    assert Conversation.status(pid).run.state == :completed
  end

  test "a silent summary still expires the outer provider idle allowance" do
    start_conversation()
    assert_receive {:summary, _worker}
    assert_receive {:agent_runtime, _, %{type: :run_cancelled}}, 1_000
    refute_receive {:summary_result, {:ok, _, _}}, 100
  end

  test "rejected activity cannot release a successful summary" do
    owner = self()

    task =
      Task.async(fn ->
        Provider.stream(nil, %{
          test: owner,
          provider_emit: fn _ -> {:error, :stale_run} end
        })
      end)

    assert_receive {:summary, worker}
    send(worker, {:events, [%ProviderEvent{type: :response_activity}, completed()]})
    assert_receive {:summary_result, {:error, _, [_]}}, 1_000
    Task.await(task)
  end

  test "the provider adapter supplies its public activity emitter to context preparation" do
    owner = self()
    error = Sigma.Ai.ProviderError.from_reason(:summary_failure)

    host = %{
      context_window: fn -> 4096 end,
      build_context: fn [], 4096, [], on_activity ->
        assert :ok = on_activity.()
        %{messages: []}
      end,
      context_error: fn _ -> error end
    }

    request = %{messages: [], tools: [], catalog_revision: 1}

    assert [%{type: :response_failed, error: ^error}] =
             Sigma.Agent.Backplane.Provider.stream(request, %{
               host: host,
               owner: owner,
               provider_emit: fn event ->
                 send(owner, {:context_activity, event})
                 :ok
               end
             })

    assert_received {:context_activity, %{type: :response_activity}}
  end

  defp start_conversation do
    {:ok, store} = EphemeralStore.new(1)
    run_id = "compaction-activity-#{System.unique_integer([:positive])}"

    options = [
      run_id: run_id,
      store: EphemeralStore,
      context: store,
      provider: Provider,
      provider_context: %{test: self()},
      registry: %ToolRegistry{},
      subscriber: self(),
      authority: %{caller: "host", run_id: run_id, grants: [], tool_revision: 1},
      run_timeout: :infinity,
      effect_timeout: 80,
      provider_idle_timeout: 100
    ]

    pid = start_supervised!(Supervisor.child_spec({Conversation, options}, id: make_ref()))
    assert {:ok, _} = Conversation.prompt(pid, "work")
    pid
  end

  defp completed,
    do: %ProviderEvent{type: :response_completed, message: %{content: "summary"}}
end
