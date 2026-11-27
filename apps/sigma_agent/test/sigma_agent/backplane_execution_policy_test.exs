defmodule Sigma.Agent.BackplaneExecutionPolicyTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.{Conversation, EphemeralStore, ToolRegistry}
  alias Sigma.Agent.Backplane.{ChildHooks, ExecutionPolicy, Hooks}

  defmodule Provider do
    def stream(request, context) do
      send(context.test, {:provider, self(), request})

      Stream.resource(
        fn -> nil end,
        fn state ->
          receive do
            {:events, events} -> {events, state}
          end
        end,
        fn _ -> :ok end
      )
    end
  end

  defmodule RootTimeout do
    defdelegate tool_effect_timeout(invocation, context), to: Hooks
  end

  defmodule ChildTimeout do
    defdelegate tool_effect_timeout(invocation, context), to: ChildHooks
  end

  defmodule Backend do
    def execute(operation) do
      send(operation.backend_context.test, {:waiting, self()})
      receive do: (:finish -> {:ok, %{text: "wait completed"}})
    end
  end

  test "active provider output outlives the total effect allowance" do
    pid = start_conversation(ExecutionPolicy.provider_options(receive_timeout: 150))
    assert_receive {:provider, worker, _}

    for _ <- 1..6 do
      Process.sleep(30)
      send(worker, {:events, [%{type: :content_text_delta, delta: "progress"}]})
      assert_receive {:agent_runtime, _, %{type: :content_text_delta}}
    end

    send(worker, {:events, [done()]})
    assert_receive {:agent_runtime, _, %{type: :run_completed}}, 1_000
    assert Conversation.status(pid).run.state == :completed
  end

  test "provider inactivity remains bounded" do
    start_conversation(ExecutionPolicy.provider_options(receive_timeout: 80))
    assert_receive {:provider, _, _}
    assert_receive {:agent_runtime, _, %{type: :run_cancelled}}, 1_000
  end

  test "root and child command waits accept integer-valued JSON numbers" do
    context = %{host: %{native_tool_names: ["write_stdin"]}}

    for hooks <- [RootTimeout, ChildTimeout] do
      assert {:ok, 65_000} =
               hooks.tool_effect_timeout(
                 %{tool_name: "write_stdin", arguments: %{"yield_time_ms" => 60_000.0}},
                 context
               )

      assert :default =
               hooks.tool_effect_timeout(
                 %{tool_name: "write_stdin", arguments: %{"yield_time_ms" => 60_000.5}},
                 context
               )
    end
  end

  for hooks <- [RootTimeout, ChildTimeout], duration <- [600_000, 600_000.0] do
    @hooks hooks
    @duration duration
    test "#{hooks} allows wait #{inspect(duration)} to exceed the generic effect allowance" do
      {:ok, registry} =
        ToolRegistry.register(%ToolRegistry{}, %{
          tool_name: "wait_agent",
          tool_revision: 1,
          description: "Wait fixture",
          backend: Backend,
          backend_context: %{test: self()},
          schema: %{
            "type" => "object",
            "properties" => %{"timeout_ms" => %{"type" => "integer"}}
          },
          safety: %{read_only: true, retry_safe: true, parallel_safe: false}
        })

      pid = start_conversation(hooks: @hooks, registry: registry)
      assert_receive {:provider, worker, _}

      send(
        worker,
        {:events,
         [
           %{
             type: :tool_call_completed,
             tool_call: %{id: "wait", name: "wait_agent", arguments: %{"timeout_ms" => @duration}}
           },
           done()
         ]}
      )

      assert_receive {:waiting, waiting}, 1_000
      Process.sleep(150)
      send(waiting, :finish)
      assert_receive {:provider, next, _}, 1_000
      send(next, {:events, [done()]})
      assert_receive {:agent_runtime, _, %{type: :run_completed}}, 1_000
      assert Conversation.status(pid).run.state == :completed
    end
  end

  defp start_conversation(options) do
    {:ok, store} = EphemeralStore.new(1)
    run_id = "execution-policy-#{System.unique_integer([:positive])}"

    options =
      Keyword.merge(
        [
          run_id: run_id,
          store: EphemeralStore,
          context: store,
          provider: Provider,
          provider_context: %{test: self(), host: %{native_tool_names: ["wait_agent"]}},
          registry: %ToolRegistry{},
          subscriber: self(),
          authority: %{caller: "host", run_id: run_id, grants: ["wait_agent"], tool_revision: 1},
          run_timeout: :infinity,
          effect_timeout: 80
        ],
        options
      )

    pid = start_supervised!(Supervisor.child_spec({Conversation, options}, id: make_ref()))
    assert {:ok, _} = Conversation.prompt(pid, "work")
    pid
  end

  defp done, do: %{type: :response_completed, message: %{role: :assistant, content: "done"}}
end
