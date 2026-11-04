defmodule Sigma.Agent.BackplaneCodexRuntimeApprovalTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.{Codex, Conversation, Plan}
  alias Sigma.Agent.Backplane.{CodexResources, InteractionResponder, Store}

  @moduletag :tmp_dir

  defmodule Provider do
    def stream(request, %{call: {name, arguments}}) do
      if Enum.any?(request.messages, &(&1.role == :tool)) do
        [%{type: :response_completed, message: %{role: :assistant, content: "Finished"}}]
      else
        [
          %{
            type: :tool_call_completed,
            tool_call: %{id: "approved-call", name: name, arguments: arguments}
          },
          %{type: :response_completed, message: %{role: :assistant, content: "Use tool"}}
        ]
      end
    end
  end

  defmodule Preparation do
    def prepare_tool(_operation, %{replacement: nil}), do: :allow
    def prepare_tool(_operation, %{replacement: final}), do: {:allow, final}
  end

  defmodule ObservedStore do
    defdelegate mode(), to: Store
    defdelegate capabilities(), to: Store
    def load(context, id, opts), do: Store.load(context.store, id, opts)

    def store(context, record, meta) do
      result = Store.store(context.store, record, meta)

      if match?({:ok, _}, result) do
        {:ok, persisted} = Store.load(context.store, record.run_id)
        transition = transition(meta.command)

        if transition do
          send(
            context.test,
            {:checkpoint_committed, transition, record.run_id, persisted.run, self()}
          )

          if transition in context.gates, do: receive(do: (:release_commit -> :ok))
        end
      end

      result
    end

    defp transition({:tool_invoked, _, _}), do: :invocation
    defp transition({:cleanup_settled, _, _}), do: :cleanup

    defp transition({:conversation_updated, _, %{base_conversation: before, conversation: next}}) do
      case {before.pending_interaction, next.pending_interaction} do
        {nil, %{id: _}} -> :requested
        {%{id: _}, nil} -> :resolved
        _ -> nil
      end
    end

    defp transition(_), do: nil
  end

  test "built-in approval sees prepared final input and waits for durable request and invocation acknowledgements",
       %{tmp_dir: dir} do
    test = self()
    final = plan("B")

    run =
      start_run!(dir, "native-plan", {"update_plan", plan("A")},
        replacement: final,
        gates: [:requested, :invocation],
        permission_request_fn: fn _ ->
          flunk("built-in approval is not a Sigma policy request")
        end,
        runtime_permission_request_fn: fn request, current? ->
          send(test, {:host_approval, request, current?.()})
          :approved
        end
      )

    prompt!(run)
    assert_receive {:checkpoint_committed, :requested, _, persisted, commit}, 5_000

    assert %{request: %{kind: :permission, operation: operation}} =
             persisted.context.conversation.pending_interaction

    assert operation.arguments == final
    refute_receive {:host_approval, _, _}, 0
    assert {:ok, %{revision: 1}} = Plan.read(run.context.plan)
    send(commit, :release_commit)

    assert_receive {:host_approval, %{kind: :permission, operation: approved}, true}, 5_000
    assert approved.arguments == final
    assert_receive {:checkpoint_committed, :invocation, _, persisted, commit}, 5_000
    [invocation] = Map.values(persisted.active_tools)
    assert invocation.arguments == final
    assert {:ok, %{revision: 1}} = Plan.read(run.context.plan)
    send(commit, :release_commit)

    [tool] = complete!(run)
    refute tool.result.is_error
    assert {:ok, %{revision: 2, content: content}} = Plan.read(run.context.plan)
    assert content["plan"] == final["plan"]
    assert {:ok, saved} = Store.load(run.store, run.id)
    assert saved.run.state == :completed
    assert saved.run.context.conversation.pending_interaction == nil
  end

  test "built-in approval preserves raw apply_patch input until acknowledged durable invocation",
       %{tmp_dir: dir} do
    test = self()
    patch = patch()

    run =
      start_run!(dir, "native-patch", {"apply_patch", patch},
        gates: [:invocation],
        runtime_permission_request_fn: fn request, current? ->
          send(test, {:host_approval, request, current?.()})
          :approved
        end
      )

    prompt!(run)
    assert_receive {:host_approval, %{operation: %{arguments: ^patch}}, true}, 5_000
    assert_receive {:checkpoint_committed, :invocation, _, persisted, commit}, 5_000
    [invocation] = Map.values(persisted.active_tools)
    assert invocation.arguments === patch
    refute File.exists?(Path.join(dir, "approved.txt"))
    send(commit, :release_commit)
    [tool] = complete!(run)
    refute tool.result.is_error
    assert File.read!(Path.join(dir, "approved.txt")) == "中文 {\"raw\":true}\n"
  end

  for name <- ["update_plan", "apply_patch"] do
    test "denying built-in #{name} approval produces no native invocation or effect", %{
      tmp_dir: dir
    } do
      name = unquote(name)
      input = input(name)

      run =
        start_run!(dir, "denied", {name, input},
          runtime_permission_request_fn: fn _, _ -> :denied end
        )

      prompt!(run)
      [tool] = complete!(run)
      assert tool.result.is_error
      assert_no_effect!(run)
    end
  end

  for result <- [
        :allow,
        {:allow, %{"explanation" => "edited"}},
        %{decision: :approved, resolver_id: "client-chosen"},
        {:error, :cancelled}
      ] do
    test "invalid built-in callback result #{inspect(result)} cancels instead of granting approval",
         %{tmp_dir: dir} do
      result = unquote(Macro.escape(result))

      run =
        start_run!(dir, "invalid-answer", {"update_plan", plan("A")},
          runtime_permission_request_fn: fn _, _ -> result end
        )

      prompt!(run)
      assert_cancelled!(run)
      assert_no_effect!(run)
    end
  end

  for failure <- [:raise, :normal_exit] do
    test "built-in callback #{failure} cancels its current run", %{tmp_dir: dir} do
      failure = unquote(failure)

      run =
        start_run!(dir, "callback-lost", {"update_plan", plan("A")},
          runtime_permission_request_fn: fn _, _ -> fail_handler(failure) end
        )

      prompt!(run)
      assert_cancelled!(run)
      assert_no_effect!(run)
    end
  end

  test "forged or duplicate operation events cannot replace the current approval and late answers cannot revive cancellation",
       %{tmp_dir: dir} do
    test = self()

    run =
      start_run!(dir, "fenced", {"update_plan", plan("A")},
        runtime_permission_request_fn: fn request, current? ->
          send(test, {:host_waiter, request, current?, self()})
          receive do: (:approve -> :approved)
        end
      )

    prompt!(run)
    assert_receive {:agent_runtime, _, %{type: :interaction_requested} = event}, 5_000
    assert_receive {:host_waiter, _, current?, waiter}, 5_000
    assert current?.()

    for forged <- [
          put_in(event, [:request, :operation, :arguments], plan("forged")),
          %{event | incarnation: 2},
          %{event | interaction_id: "another-interaction"},
          event
        ] do
      send(run.responder, {:agent_runtime, run.id, forged})
    end

    refute_receive {:host_waiter, _, _, _}, 100
    monitor = Process.monitor(waiter)
    assert :ok = Conversation.cancel(run.conversation)
    assert_cancelled!(run)
    assert_receive {:DOWN, ^monitor, :process, ^waiter, _}, 5_000
    refute current?.()
    send(waiter, :approve)
    assert {:error, _} = Conversation.resolve(run.conversation, event.interaction_id, :approved)
    assert_no_effect!(run)
  end

  test "built-in human wait pauses original deadlines before Runtime binds its approval", %{
    tmp_dir: dir
  } do
    test = self()

    run =
      start_run!(dir, "human-wait", {"update_plan", plan("A")},
        run_timeout: 1_500,
        effect_timeout: 1_000,
        runtime_permission_request_fn: fn _, current? ->
          send(test, {:host_waiter, current?, self()})
          receive do: (:approve -> :approved)
        end
      )

    prompt!(run)
    assert_receive {:host_waiter, current?, waiter}, 5_000
    Process.sleep(1_600)
    assert current?.()
    send(waiter, :approve)
    [tool] = complete!(run)
    refute tool.result.is_error
    assert {:ok, %{revision: 2}} = Plan.read(run.context.plan)
  end

  defp start_run!(dir, id, call, opts) do
    resources = start_supervised!({CodexResources, workspace: dir, owner_pid: self()})

    authority = %{
      caller: "runtime-approval-test",
      run_id: id,
      grants: [elem(call, 0)],
      tool_revision: 1
    }

    assert {:ok, binding} = CodexResources.bind(resources, authority)
    assert {:ok, context} = CodexResources.context(resources, binding)

    assert {:ok, profile} =
             Codex.profile(:pinned_local, context, authority, tools: authority.grants)

    # requires_approval is a public host-authored descriptor capability. Neither
    # a model request nor an approval response can change this descriptor.
    descriptor = Map.fetch!(profile.registry.tools, elem(call, 0))
    descriptor = %{descriptor | safety: Map.put(descriptor.safety, :requires_approval, true)}

    registry = %{
      profile.registry
      | tools: Map.put(profile.registry.tools, elem(call, 0), descriptor)
    }

    store = start_supervised!({Store, path: Path.join(dir, "runtime")})

    responder_opts =
      [run_id: id, incarnation: 1, owner_pid: self(), subscriber: self()] ++
        Keyword.take(opts, [:runtime_permission_request_fn, :permission_request_fn])

    responder = start_supervised!({InteractionResponder, responder_opts})

    conversation =
      start_supervised!(
        {Conversation,
         run_id: id,
         store: ObservedStore,
         context: %{store: store, test: self(), gates: opts[:gates] || []},
         provider: Provider,
         provider_context: %{call: call, replacement: opts[:replacement]},
         hooks: Preparation,
         registry: registry,
         tools: profile.tools,
         authority: profile.authority,
         session_binding: binding,
         subscriber: responder,
         run_timeout: opts[:run_timeout] || :infinity,
         effect_timeout: opts[:effect_timeout] || 5_000}
      )

    assert :ok = InteractionResponder.attach(responder, conversation)
    %{id: id, conversation: conversation, responder: responder, context: context, store: store}
  end

  defp prompt!(run), do: assert({:ok, _} = Conversation.prompt(run.conversation, "Approve tool"))

  defp complete!(run) do
    id = run.id
    assert_receive {:agent_runtime, ^id, %{type: :run_completed}}, 5_000
    Enum.filter(Conversation.status(run.conversation).messages, &(&1.role == :tool))
  end

  defp assert_cancelled!(run) do
    id = run.id
    assert_receive {:checkpoint_committed, :cleanup, ^id, persisted, _}, 5_000
    assert persisted.state == :cancelled
    assert persisted.context.conversation.pending_interaction == nil
    assert {:ok, stored} = Store.load(run.store, id)
    assert stored.run.state == :cancelled
    assert stored.run.context.conversation.pending_interaction == nil
  end

  defp assert_no_effect!(run) do
    assert {:ok, %{revision: 1}} = Plan.read(run.context.plan)
    refute File.exists?(Path.join(run.context.workspace, "approved.txt"))
    refute_receive {:checkpoint_committed, :invocation, _, _, _}, 0
    assert {:ok, persisted} = Store.load(run.store, run.id)
    assert persisted.run.active_tools == %{}

    refute Enum.any?(
             Map.keys(Map.get(persisted.run, :execution_intents, %{})),
             &String.starts_with?(&1, "tool:")
           )
  end

  defp fail_handler(:raise), do: raise("approval host failed")
  defp fail_handler(:normal_exit), do: Process.exit(self(), :normal)
  defp input("update_plan"), do: plan("A")
  defp input("apply_patch"), do: patch()
  defp plan(step), do: %{"plan" => [%{"step" => step, "status" => "completed"}]}

  defp patch,
    do: "*** Begin Patch\n*** Add File: approved.txt\n+中文 {\"raw\":true}\n*** End Patch\n"
end
