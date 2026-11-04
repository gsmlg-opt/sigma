defmodule Sigma.Agent.BackplaneChildInteractionResponderTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.{Codex, Error, ToolCatalog}
  alias Backplane.AgentRuntime.Codex.MultiAgent
  alias Sigma.Agent.Backplane.{ChildInteractionResponder, Store, UserInput}

  @moduletag :tmp_dir

  defmodule Provider do
    def stream(request, %{test: test}) do
      send(test, {:child_provider, request.run_id, request.messages, self()})

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

  defmodule Effect do
    def execute(%{backend_context: %{test: test}} = operation) do
      send(test, {:child_effect_arguments, operation.arguments})
      send(test, :child_effect)
      {:ok, %{content: "effect completed"}}
    end
  end

  defmodule JsonPermissionPreparation do
    defdelegate prepare_tool(invocation, context), to: Sigma.Agent.Backplane.ChildHooks
  end

  # Exercises the public manager messages only. Real manager/profile integration
  # remains covered below; this endpoint makes observation faults deterministic.
  defmodule ManagerEndpoint do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    def init(opts) do
      correlation = %{
        manager_id: "observed-manager",
        agent_id: "observed-child",
        run_id: "observed-run",
        incarnation: 1,
        interaction_id: "observed-question"
      }

      pending = %{
        id: correlation.interaction_id,
        correlation: correlation,
        request: %{
          "kind" => "request_user_input",
          "questions" => [
            %{
              "id" => "scope",
              "header" => "Scope",
              "question" => "Which scope?",
              "options" => [
                %{"label" => "Local", "description" => "Current project"},
                %{"label" => "All", "description" => "Every project"}
              ]
            }
          ]
        }
      }

      {:ok,
       %{
         test: Keyword.fetch!(opts, :test),
         mode: Keyword.get(opts, :mode, :ready),
         observers: [],
         snapshot: %{
           manager_id: correlation.manager_id,
           revision: 1,
           agents: [%{status: :running, pending_interaction: pending}]
         }
       }}
    end

    def handle_call({:subscribe, observer}, _, state),
      do: {:reply, {:ok, state.snapshot}, %{state | observers: [observer | state.observers]}}

    def handle_call(:snapshot, _, %{mode: :unavailable} = state),
      do: {:reply, {:error, :temporarily_unavailable}, state}

    def handle_call(:snapshot, _, %{mode: :timeout} = state), do: {:noreply, state}
    def handle_call(:snapshot, _, state), do: {:reply, {:ok, state.snapshot}, state}

    def handle_call({:mode, mode}, _, state), do: {:reply, :ok, %{state | mode: mode}}

    def handle_call(:observe, _, state) do
      snapshot = %{state.snapshot | revision: state.snapshot.revision + 1}

      for observer <- state.observers do
        send(
          observer,
          {:codex_collaboration, %{manager_id: snapshot.manager_id, revision: snapshot.revision}}
        )
      end

      {:reply, :ok, %{state | snapshot: snapshot}}
    end

    def handle_call({:resolve_interaction, correlation, answer}, from, state) do
      send(state.test, {:endpoint_resolved, correlation, answer})
      acknowledge(from, state)
    end

    def handle_call({:cancel_interaction, correlation, reason}, from, state) do
      send(state.test, {:endpoint_cancelled, correlation, reason})
      acknowledge(from, state)
    end

    defp acknowledge(from, %{mode: :lost_ack} = state) do
      # The operation was accepted, but the caller receives a lost acknowledgement.
      Process.exit(elem(from, 0), :kill)
      {:noreply, state}
    end

    defp acknowledge(_, state), do: {:reply, :ok, state}
  end

  test "checkpointed native child input reaches the host and resolves exact answers", c do
    agent = question_host!(c.tmp_dir)
    test = self()

    responder =
      responder!(fn correlation, request, current? ->
        send(test, {:native_request, correlation, request, current?.()})

        source = %{
          agent_id: correlation.agent_id,
          agent_path: "/root/worker",
          public_run_id: correlation.run_id,
          incarnation: correlation.incarnation
        }

        resolver =
          UserInput.resolver(fn question, opts ->
            send(test, {:host_ask, source, opts})
            Sigma.Agent.ask_user_question(agent, Map.put(question, :source, source), opts)
          end)

        resolver.(request, current?)
      end)

    manager = manager!(c.tmp_dir)
    assert :ok = ChildInteractionResponder.attach(responder, manager)
    {run, provider} = spawn_child!(manager)
    ask(provider)

    assert_receive {:native_request, correlation, %{kind: :request_user_input}, true}, 5_000
    assert correlation.run_id == run
    assert {:ok, %{agents: [%{pending_interaction: pending}]}} = MultiAgent.snapshot(manager)
    assert pending.correlation == correlation
    assert {:ok, store} = Store.open(path: store_path(c.tmp_dir, run))
    assert {:ok, saved} = Store.load(store, run)
    assert saved.run.context.conversation.pending_interaction.id == pending.id

    assert_receive {:host_ask, source, [timeout: :infinity]}, 5_000
    assert source.agent_id == correlation.agent_id
    assert source.public_run_id == run

    assert_receive {:ask_user_question, question_id,
                    %{question: "[Scope] Which scope?", source: ^source}},
                   5_000

    assert :ok = Sigma.Agent.answer_user_question(agent, question_id, {:ok, "原样\nLocal"})
    assert_receive {:child_provider, ^run, messages, provider}, 5_000

    assert [%{result: %{answers: %{"scope" => %{answers: ["原样\nLocal"]}}}}] =
             Enum.filter(messages, &(&1.role == :tool))

    assert {:error, _} = MultiAgent.resolve_interaction(manager, correlation, %{answers: %{}})
    finish(provider)
    assert_receive {:codex_collaboration, %{type: :settled, agent: %{run_id: ^run}}}, 5_000
    assert Sigma.Agent.pending_user_questions(agent) == []
  end

  test "native permission uses its independent handler before any effect", c do
    test = self()

    responder =
      responder!(fn correlation, %{kind: :permission, operation: operation}, current? ->
        send(test, {:approval, correlation, operation, current?, self()})
        receive do: (:approve -> :approved)
      end)

    manager = manager!(c.tmp_dir)
    assert :ok = ChildInteractionResponder.attach(responder, manager)
    {run, provider} = spawn_child!(manager)
    tool(provider, "effect", "test_effect", %{})

    assert_receive {:approval, correlation, %{"tool_name" => "test_effect"}, current?, worker},
                   5_000

    assert current?.()
    refute_receive :child_effect, 0
    send(worker, :approve)
    assert_receive :child_effect, 5_000
    assert_receive {:child_provider, ^run, _, provider}, 5_000
    refute current?.()
    assert {:error, _} = MultiAgent.resolve_interaction(manager, correlation, :approved)
    finish(provider)
  end

  test "Sigma edited permission crosses JSON and stays separate from Runtime approval", c do
    test = self()
    policy = start_supervised!({Sigma.Coding.PermissionPolicy, default: :ask})

    responder =
      responder!(fn correlation, request, _ ->
        send(test, {:separate_permission, correlation, request})

        case request do
          %{kind: :sigma_tool_permission, tool_call: %{name: "test_effect", arguments: %{}}} ->
            {:allow, %{"marker" => "edited"}}

          %{kind: :permission, operation: %{"arguments" => %{"marker" => "edited"}}} ->
            :approved
        end
      end)

    manager =
      manager!(c.tmp_dir,
        hooks: JsonPermissionPreparation,
        provider_context: %{
          host: %{
            native_tool_names: ["test_effect"],
            permission_options: fn -> {:ok, [permission_policy: policy, hook_specs: []]} end
          },
          permission_interaction: true
        }
      )

    assert :ok = ChildInteractionResponder.attach(responder, manager)
    {run, provider} = spawn_child!(manager)
    tool(provider, "effect", "test_effect", %{})

    assert_receive {:separate_permission, sigma_correlation, %{kind: :sigma_tool_permission}},
                   5_000

    assert_receive {:separate_permission, runtime_correlation, %{kind: :permission}}, 5_000
    assert sigma_correlation.interaction_id != runtime_correlation.interaction_id
    assert_receive {:child_effect_arguments, %{"marker" => "edited"}}, 5_000
    assert_receive {:child_provider, ^run, _, provider}, 5_000
    finish(provider)
  end

  test "Sigma permission denial crosses JSON without Runtime approval or backend dispatch", c do
    test = self()
    policy = start_supervised!({Sigma.Coding.PermissionPolicy, default: :ask})

    responder =
      responder!(fn _, request, _ ->
        send(test, {:denied_channel, request.kind})
        {:deny, :declined}
      end)

    manager =
      manager!(c.tmp_dir,
        hooks: JsonPermissionPreparation,
        provider_context: %{
          host: %{
            native_tool_names: ["test_effect"],
            permission_options: fn -> {:ok, [permission_policy: policy, hook_specs: []]} end
          },
          permission_interaction: true
        }
      )

    assert :ok = ChildInteractionResponder.attach(responder, manager)
    {run, provider} = spawn_child!(manager)
    tool(provider, "effect", "test_effect", %{})
    assert_receive {:denied_channel, :sigma_tool_permission}, 5_000
    assert_receive {:child_provider, ^run, messages, provider}, 5_000
    assert [%{result: %{is_error: true}}] = Enum.filter(messages, &(&1.role == :tool))
    refute_receive {:denied_channel, :permission}, 0
    refute_receive :child_effect, 0
    finish(provider)
  end

  test "attach recovers pending interaction and forged observations cannot open another waiter",
       c do
    manager = manager!(c.tmp_dir)
    {run, provider} = spawn_child!(manager)
    ask(provider)
    assert_receive {:codex_collaboration, %{type: :interaction_requested} = event}, 5_000
    test = self()

    responder =
      responder!(fn correlation, request, current? ->
        send(test, {:recovered, correlation, request, current?, self()})
        receive do: (:answer -> {:ok, %{answers: %{"scope" => %{answers: ["Local"]}}}})
      end)

    assert :ok = ChildInteractionResponder.attach(responder, manager)

    assert_receive {:recovered, correlation, %{kind: :request_user_input}, current?, worker},
                   5_000

    assert current?.()
    send(responder, {:codex_collaboration, event})
    forged = put_in(event, [:agent, :pending_interaction, :request, "questions"], [])
    send(responder, {:codex_collaboration, %{forged | revision: event.revision + 20}})
    refute_receive {:recovered, _, _, _, _}, 50
    send(worker, :answer)
    assert_receive {:child_provider, ^run, _, provider}, 5_000
    assert {:error, _} = MultiAgent.resolve_interaction(manager, correlation, %{answers: %{}})
    finish(provider)
  end

  test "external interruption stops the owned host waiter and fences old interaction replay", c do
    agent = question_host!(c.tmp_dir)
    test = self()
    user_input = UserInput.resolver(agent)

    responder =
      responder!(fn correlation, request, current? ->
        send(test, {:waiting, correlation, current?, self()})
        user_input.(request, current?)
      end)

    manager = manager!(c.tmp_dir)
    assert :ok = ChildInteractionResponder.attach(responder, manager)
    {run, provider} = spawn_child!(manager)
    ask(provider)
    assert_receive {:waiting, correlation, current?, worker}, 5_000
    assert_receive {:ask_user_question, question_id, _}, 5_000
    monitor = Process.monitor(worker)

    assert {:error,
            %Backplane.AgentRuntime.Error{
              class: :unknown_outcome,
              message: "agent has unreconciled tool effects"
            }} =
             call(manager, "interrupt_agent", %{"target" => "worker"})

    assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 5_000
    assert_receive {:ask_user_question_resolved, ^question_id}, 5_000
    refute current?.()
    assert {:error, _} = MultiAgent.resolve_interaction(manager, correlation, %{answers: %{}})
    assert Sigma.Agent.pending_user_questions(agent) == []

    assert {:ok, %{agents: [%{run_id: ^run, status: :unknown_outcome, pending_interaction: nil}]}} =
             MultiAgent.snapshot(manager)

    assert {:error, %Backplane.AgentRuntime.Error{class: :unknown_outcome}} =
             call(manager, "followup_task", %{"target" => "worker", "message" => "again"})

    refute_receive {:child_provider, _, _, _}, 50
  end

  test "cancelled native user input fences the checkpoint and preserves uncertain effects", c do
    responder = responder!(fn _, _, _ -> {:error, :cancelled} end)
    manager = manager!(c.tmp_dir)
    assert :ok = ChildInteractionResponder.attach(responder, manager)
    {run, provider} = spawn_child!(manager)
    ask(provider)

    assert_receive {:child_interaction_error, correlation,
                    {:error, %Error{class: :unknown_outcome}}},
                   5_000

    assert correlation.run_id == run

    assert {:ok, %{agents: [%{status: :unknown_outcome, pending_interaction: nil}]}} =
             MultiAgent.snapshot(manager)

    assert {:ok, store} = Store.open(path: store_path(c.tmp_dir, run))
    assert {:ok, saved} = Store.load(store, run)
    assert saved.run.state == :unknown_outcome
    assert saved.run.context.conversation.pending_interaction == nil

    assert {:error, %Error{class: :resource_conflict}} =
             MultiAgent.cancel_interaction(manager, correlation, "Do not retry")

    assert {:error, %Error{class: :unknown_outcome}} =
             call(manager, "followup_task", %{"target" => "worker", "message" => "again"})

    refute_receive {:child_provider, _, _, _}, 50
  end

  for invalid <- [:invalid_utf8, :oversized] do
    test "#{invalid} native answer cancels the actual child without leaving a live question", c do
      test = self()
      text = invalid_answer_text(unquote(invalid))
      answer = %{answers: %{"scope" => %{answers: [text]}}}
      assert {:error, _} = Backplane.AgentRuntime.Conversation.public_interaction(answer)

      responder =
        responder!(fn correlation, _, _ ->
          send(test, {:invalid_host_answer, correlation})
          {:ok, answer}
        end)

      manager = manager!(c.tmp_dir)
      assert :ok = ChildInteractionResponder.attach(responder, manager)
      {run, provider} = spawn_child!(manager)
      ask(provider)
      assert_receive {:invalid_host_answer, correlation}, 5_000
      assert correlation.run_id == run

      assert_receive {:child_interaction_error, ^correlation,
                      {:error, %Error{class: :unknown_outcome}}},
                     5_000

      assert {:ok, %{agents: [%{status: :unknown_outcome, pending_interaction: nil}]}} =
               MultiAgent.snapshot(manager)

      assert {:ok, store} = Store.open(path: store_path(c.tmp_dir, run))
      assert {:ok, saved} = Store.load(store, run)
      assert saved.run.state == :unknown_outcome
      assert saved.run.context.conversation.pending_interaction == nil

      assert {:error, %Error{class: :unknown_outcome}} =
               call(manager, "followup_task", %{"target" => "worker", "message" => "again"})

      refute_receive {:invalid_host_answer, _}, 50
      refute_receive {:child_provider, _, _, _}, 0
      refute_receive {:child_interaction_error, _, _}, 0
    end

    test "#{invalid} answer is rejected before resolve submission and cancellation is never replayed" do
      test = self()
      text = invalid_answer_text(unquote(invalid))

      responder =
        responder!(fn correlation, _, _ ->
          send(test, {:invalid_host_answer, correlation})
          {:ok, %{answers: %{"scope" => %{answers: [text]}}}}
        end)

      manager = start_supervised!({ManagerEndpoint, test: test})
      assert :ok = ChildInteractionResponder.attach(responder, manager)
      assert_receive {:invalid_host_answer, correlation}, 5_000
      assert_receive {:endpoint_cancelled, ^correlation, _}, 5_000
      refute_receive {:endpoint_resolved, _, _}, 0
      assert :ok = GenServer.call(manager, :observe)
      refute_receive {:invalid_host_answer, _}, 50
      refute_receive {:endpoint_cancelled, _, _}, 0
      refute_receive {:child_interaction_error, _, _}, 0
    end
  end

  for failure <- [:cancelled, :raised, :normal_exit, :invalid_answer] do
    @failure failure
    test "native permission #{@failure} cancels durably before effect dispatch", c do
      failure = @failure
      responder = responder!(fn _, _, _ -> handler_failure(failure) end)
      manager = manager!(c.tmp_dir)
      assert :ok = ChildInteractionResponder.attach(responder, manager)
      {run, provider} = spawn_child!(manager)
      tool(provider, "effect", "test_effect", %{})

      assert_receive {:codex_collaboration,
                      %{
                        type: :interrupted,
                        interaction_id: interaction_id,
                        reason: reason,
                        agent: %{run_id: ^run, cleanup: :confirmed, pending_interaction: nil}
                      }},
                     5_000

      assert is_binary(reason) and byte_size(reason) <= 1024
      assert is_binary(interaction_id)
      assert {:ok, store} = Store.open(path: store_path(c.tmp_dir, run))
      assert {:ok, saved} = Store.load(store, run)
      assert saved.run.state == :cancelled
      assert saved.run.context.conversation.pending_interaction == nil
      refute_receive :child_effect, 0
      refute_receive {:child_interaction_error, _, _}, 50
    end
  end

  test "exact cancellation rejects every stale identity and cannot stop a replacement", c do
    test = self()

    responder =
      responder!(fn correlation, _, _ ->
        send(test, {:cancel_waiter, correlation, self()})
        receive do: (:cancel -> {:error, :cancelled})
      end)

    manager = manager!(c.tmp_dir)
    assert :ok = ChildInteractionResponder.attach(responder, manager)
    {run, provider} = spawn_child!(manager)
    tool(provider, "effect", "test_effect", %{})
    assert_receive {:cancel_waiter, correlation, worker}, 5_000

    for {key, value} <- correlation do
      invalid = if is_integer(value), do: value + 1, else: value <> "-stale"

      assert {:error, %Error{}} =
               MultiAgent.cancel_interaction(manager, Map.put(correlation, key, invalid), "Stale")
    end

    assert {:ok, %{agents: [%{status: :running, pending_interaction: pending}]}} =
             MultiAgent.snapshot(manager)

    assert pending.correlation == correlation
    send(worker, :cancel)
    assert_receive {:codex_collaboration, %{type: :interrupted, agent: %{run_id: ^run}}}, 5_000

    assert {:ok, _} =
             call(manager, "followup_task", %{"target" => "worker", "message" => "again"})

    assert_receive {:child_provider, next_run, _, next_provider}, 5_000
    assert next_run != run
    tool(next_provider, "effect-next", "test_effect", %{})
    assert_receive {:cancel_waiter, next_correlation, next_worker}, 5_000

    assert {:error, %Error{class: :resource_conflict}} =
             MultiAgent.cancel_interaction(manager, correlation, "Historical cancellation")

    assert {:ok,
            %{agents: [%{run_id: ^next_run, status: :running, pending_interaction: next_pending}]}} =
             MultiAgent.snapshot(manager)

    assert next_pending.correlation == next_correlation
    send(next_worker, :cancel)

    assert_receive {:codex_collaboration, %{type: :interrupted, agent: %{run_id: ^next_run}}},
                   5_000

    refute_receive :child_effect, 0
  end

  for action <- [:cancel, :answer] do
    @action action
    test "lost #{@action} acknowledgement is reported once and never replayed" do
      action = @action
      test = self()

      responder =
        responder!(fn correlation, _, _ ->
          send(test, {:ack_waiter, correlation, self()})

          receive do
            :submit ->
              interaction_reply(action)
          end
        end)

      manager = start_supervised!({ManagerEndpoint, test: test})
      assert :ok = ChildInteractionResponder.attach(responder, manager)
      assert_receive {:ack_waiter, correlation, worker}, 5_000
      assert :ok = GenServer.call(manager, {:mode, :lost_ack})
      send(worker, :submit)
      event = acknowledgement_event(action)
      assert_receive {^event, ^correlation, _}, 5_000

      assert_receive {:child_interaction_error, ^correlation,
                      {:error, %Error{class: :unknown_outcome}}},
                     5_000

      assert :ok = GenServer.call(manager, {:mode, :ready})
      assert :ok = GenServer.call(manager, :observe)
      refute_receive {:ack_waiter, _, _}, 50
      refute_receive {:endpoint_cancelled, _, _}, 0
      refute_receive {:endpoint_resolved, _, _}, 0
      refute_receive {:child_interaction_error, _, _}, 0
    end
  end

  for lost <- [:owner, :manager] do
    @lost lost
    test "#{@lost} loss stops the local waiter and removes the host question", c do
      test = self()
      owner = spawn(fn -> receive do: (:stop -> :ok) end)
      on_exit(fn -> send(owner, :stop) end)
      agent = question_host!(c.tmp_dir)
      input = UserInput.resolver(agent)

      responder =
        start_supervised!(
          {ChildInteractionResponder,
           owner_pid: owner,
           subscriber: test,
           request_fn: fn _, request, current? ->
             send(test, {:lifecycle_waiter, self()})
             input.(request, current?)
           end}
        )

      manager = manager!(c.tmp_dir)
      assert :ok = ChildInteractionResponder.attach(responder, manager)
      {_run, provider} = spawn_child!(manager)
      ask(provider)
      assert_receive {:lifecycle_waiter, worker}, 5_000
      assert_receive {:ask_user_question, question_id, _}, 5_000
      worker_monitor = Process.monitor(worker)
      responder_monitor = Process.monitor(responder)
      lose_endpoint(@lost, owner, manager)
      assert_receive {:DOWN, ^responder_monitor, :process, ^responder, :normal}, 5_000
      assert_receive {:DOWN, ^worker_monitor, :process, ^worker, _}, 5_000
      assert_receive {:ask_user_question_resolved, ^question_id}, 5_000
      assert Sigma.Agent.pending_user_questions(agent) == []
      send(owner, :stop)
    end
  end

  test "public target interruption accepts a historical run ID and interrupts its replacement",
       c do
    manager = manager!(c.tmp_dir)
    {run, provider} = spawn_child!(manager)
    finish(provider)
    assert_receive {:codex_collaboration, %{type: :settled, agent: %{run_id: ^run}}}, 5_000

    assert {:ok, _} =
             call(manager, "followup_task", %{"target" => "worker", "message" => "again"})

    assert_receive {:child_provider, next_run, _, _}, 5_000
    assert next_run != run
    assert {:ok, _} = call(manager, "interrupt_agent", %{"target" => run})

    assert {:ok, %{agents: [%{run_id: ^next_run, status: :interrupted}]}} =
             MultiAgent.snapshot(manager)
  end

  test "a snapshot timeout preserves the waiting worker and a later observation recovers it" do
    test = self()

    responder =
      responder!(fn correlation, _, current? ->
        send(test, {:fault_waiter, correlation, self(), current?})
        receive do: (:answer -> {:ok, %{answers: %{"scope" => %{answers: ["Local"]}}}})
      end)

    manager = start_supervised!({ManagerEndpoint, test: test})
    assert :ok = ChildInteractionResponder.attach(responder, manager)
    assert_receive {:fault_waiter, correlation, worker, current?}, 5_000
    monitor = Process.monitor(worker)
    assert :ok = GenServer.call(manager, {:mode, :timeout})
    assert :ok = GenServer.call(manager, :observe)

    assert_receive {:child_interaction_error, %{manager_id: "observed-manager"},
                    {:observation_unavailable, :manager_unavailable}},
                   6_000

    refute_receive {:DOWN, ^monitor, :process, ^worker, _}, 0
    assert Process.alive?(worker)
    assert :ok = GenServer.call(manager, {:mode, :ready})
    assert :ok = GenServer.call(manager, :observe)
    assert current?.()
    send(worker, :answer)

    assert_receive {:endpoint_resolved, ^correlation,
                    %{answers: %{"scope" => %{answers: ["Local"]}}}},
                   5_000

    refute_receive {:fault_waiter, _, _, _}, 50
  end

  test "an unavailable final guard reports uncertainty and never replays an answered handler" do
    test = self()

    responder =
      responder!(fn correlation, _, _ ->
        send(test, {:fault_waiter, correlation, self()})
        receive do: (:answer -> {:ok, %{answers: %{"scope" => %{answers: ["Local"]}}}})
      end)

    manager = start_supervised!({ManagerEndpoint, test: test})
    assert :ok = ChildInteractionResponder.attach(responder, manager)
    assert_receive {:fault_waiter, correlation, worker}, 5_000
    assert :ok = GenServer.call(manager, {:mode, :unavailable})
    send(worker, :answer)

    assert_receive {:child_interaction_error, ^correlation,
                    {:observation_unavailable, :temporarily_unavailable}},
                   5_000

    refute_receive {:endpoint_resolved, _, _}, 0
    assert :ok = GenServer.call(manager, {:mode, :ready})
    assert :ok = GenServer.call(manager, :observe)
    refute_receive {:fault_waiter, _, _}, 50
    refute_receive {:endpoint_resolved, _, _}, 0
  end

  test "a never-started handler can recover only after a fresh authenticated snapshot" do
    test = self()

    responder =
      responder!(fn correlation, _, _ ->
        send(test, {:recovered_handler, correlation})
        {:ok, %{answers: %{"scope" => %{answers: ["Local"]}}}}
      end)

    manager = start_supervised!({ManagerEndpoint, test: test, mode: :unavailable})
    assert :ok = ChildInteractionResponder.attach(responder, manager)

    assert_receive {:child_interaction_error, correlation,
                    {:observation_unavailable, :temporarily_unavailable}},
                   5_000

    refute_receive {:recovered_handler, _}, 0
    assert :ok = GenServer.call(manager, {:mode, :ready})
    assert :ok = GenServer.call(manager, :observe)
    assert_receive {:recovered_handler, ^correlation}, 5_000
    assert_receive {:endpoint_resolved, ^correlation, _}, 5_000
    assert :ok = GenServer.call(manager, :observe)
    refute_receive {:recovered_handler, _}, 50
  end

  defp handler_failure(:cancelled), do: {:error, :cancelled}
  defp handler_failure(:raised), do: raise("handler failed")
  defp handler_failure(:normal_exit), do: Process.exit(self(), :normal)
  defp handler_failure(:invalid_answer), do: :unexpected

  defp invalid_answer_text(:invalid_utf8), do: <<255>>
  defp invalid_answer_text(:oversized), do: String.duplicate("x", 262_145)

  defp interaction_reply(:cancel), do: {:error, :cancelled}
  defp interaction_reply(:answer), do: {:ok, %{answers: %{"scope" => %{answers: ["Local"]}}}}

  defp acknowledgement_event(:cancel), do: :endpoint_cancelled
  defp acknowledgement_event(:answer), do: :endpoint_resolved

  defp lose_endpoint(:owner, owner, _manager), do: send(owner, :stop)
  defp lose_endpoint(:manager, _owner, manager), do: GenServer.stop(manager)

  defp responder!(request) do
    start_supervised!(
      {ChildInteractionResponder, owner_pid: self(), subscriber: self(), request_fn: request}
    )
  end

  defp question_host!(dir) do
    agent =
      start_supervised!(
        {Sigma.Agent,
         cwd: dir, tools: [], hook_specs: [], backplane_runtime_path: Path.join(dir, "host")}
      )

    assert :ok = Sigma.Agent.subscribe(agent)
    agent
  end

  defp manager!(dir, extra_options \\ []) do
    test = self()
    store = start_supervised!({Store, path: store_path(dir, "")})

    manager =
      start_supervised!(
        {MultiAgent,
         parent_run_id: "root",
         parent_name: "/root",
         subscriber: test,
         parent_authority: %{
           caller: "host",
           run_id: "root",
           grants: ["request_user_input", "test_effect"]
         },
         child_options: fn _, run, _ ->
           authority = %{
             caller: "child",
             run_id: run,
             grants: ["request_user_input", "test_effect"],
             tool_revision: 1
           }

           {:ok, profile} =
             Codex.profile(
               :interactive,
               %{root?: true},
               %{authority | grants: ["request_user_input"]},
               tools: ["request_user_input"]
             )

           descriptor = %{
             tool_name: "test_effect",
             description: "Observed test effect",
             tool_revision: 1,
             backend: Effect,
             backend_context: %{test: test},
             schema: %{"type" => "object", "properties" => %{}},
             safety: %{
               read_only: false,
               retry_safe: false,
               parallel_safe: false,
               requires_approval: true
             }
           }

           {:ok, catalog} =
             ToolCatalog.admit_batch(Map.values(profile.registry.tools) ++ [descriptor],
               authority: authority,
               run_id: run,
               mode: :strict
             )

           {:ok,
            [
              run_id: run,
              store: Store,
              context: store,
              provider: Provider,
              provider_context:
                Map.merge(%{test: test}, Keyword.get(extra_options, :provider_context, %{})),
              registry: catalog.registry,
              tools: catalog.tools,
              authority: catalog.authority,
              run_timeout: :infinity
            ] ++ Keyword.take(extra_options, [:hooks])}
         end}
      )

    on_exit(fn -> if Process.alive?(manager), do: MultiAgent.close_session(manager) end)
    manager
  end

  defp store_path(dir, _run), do: Path.join(dir, "runtime")

  defp spawn_child!(manager) do
    assert {:ok, _} =
             call(manager, "spawn_agent", %{"task_name" => "worker", "message" => "work"})

    assert_receive {:child_provider, run, _, provider}, 5_000
    {run, provider}
  end

  defp call(manager, tool, args) do
    MultiAgent.call(%{
      backend_context: %{runtime: manager, profile: :v2},
      run_id: "root",
      tool_name: tool,
      arguments: args
    })
  end

  defp ask(provider),
    do: tool(provider, "question", "request_user_input", %{"questions" => [question()]})

  defp tool(provider, id, name, arguments) do
    send(
      provider,
      {:events,
       [
         %{type: :tool_call_completed, tool_call: %{id: id, name: name, arguments: arguments}},
         %{type: :response_completed, message: %{role: :assistant, content: "Use tool"}}
       ]}
    )
  end

  defp finish(provider),
    do:
      send(
        provider,
        {:events,
         [
           %{type: :response_completed, message: %{role: :assistant, content: "done"}}
         ]}
      )

  defp question do
    %{
      "id" => "scope",
      "header" => "Scope",
      "question" => "Which scope?",
      "options" => [
        %{"label" => "Local", "description" => "Current project"},
        %{"label" => "All", "description" => "Every project"}
      ]
    }
  end
end
