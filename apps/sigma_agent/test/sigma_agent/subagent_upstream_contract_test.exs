defmodule Sigma.Agent.SubagentUpstreamContractTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.{
    Codex,
    Conversation,
    EphemeralStore,
    Error,
    ToolEffects,
    ToolRegistry
  }

  alias Backplane.AgentRuntime.Codex.{MultiAgent, Session}

  defmodule Provider do
    def stream(request, context) do
      send(context.test, {:provider, request.run_id, request, self()})

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

  test "pre-reservation capacity refusal proves exact non-dispatch without a birth receipt" do
    runtime =
      start_runtime(
        max_concurrent_threads_per_session: 1,
        admission_receipt: receipt_observer()
      )

    operation = operation(runtime, "spawn_agent", %{"task_name" => "excess", "message" => "work"})
    assert {:ok, before_rejection} = MultiAgent.snapshot(runtime)
    assert_rejection(operation, :resource_conflict)
    assert {:ok, ^before_rejection} = MultiAgent.snapshot(runtime)
    assert_no_admission()
    assert {:ok, %{agents: [], admissions: []}} = MultiAgent.snapshot(runtime)
  end

  test "duplicate task refusal leaves the admitted child and its reservation intact" do
    runtime = start_runtime(admission_receipt: receipt_observer())
    arguments = %{"task_name" => "worker", "message" => "work"}
    assert {:ok, _} = MultiAgent.call(operation(runtime, "spawn_agent", arguments))
    assert_receive {:child_options, run_id, _}, 5_000
    assert_receive {:admission_receipt, %{status: :created, run_id: ^run_id}}, 5_000
    assert_receive {:provider, ^run_id, _, provider}, 5_000
    assert {:ok, before_rejection} = MultiAgent.snapshot(runtime)

    assert_rejection(operation(runtime, "spawn_agent", arguments), :validation)

    assert {:ok, ^before_rejection} = MultiAgent.snapshot(runtime)
    assert Process.alive?(provider)
    assert_no_admission()
  end

  for {tool, arguments} <- [
        {"send_message", %{"target" => "missing", "message" => "hello"}},
        {"followup_task", %{"target" => "missing", "message" => "continue"}},
        {"interrupt_agent", %{"target" => "missing"}}
      ] do
    test "#{tool} missing-target refusal proves exact non-dispatch" do
      runtime = start_runtime(admission_receipt: receipt_observer())
      assert {:ok, before_rejection} = MultiAgent.snapshot(runtime)

      assert_rejection(
        operation(runtime, unquote(tool), unquote(Macro.escape(arguments))),
        :not_found
      )

      assert {:ok, ^before_rejection} = MultiAgent.snapshot(runtime)
      assert_no_admission()
    end
  end

  test "completed child followup at capacity refuses before replacement preparation" do
    runtime =
      start_runtime(
        max_concurrent_threads_per_session: 2,
        admission_receipt: receipt_observer()
      )

    assert {:ok, _} = MultiAgent.subscribe(runtime)
    assert {:ok, _} = spawn_agent(runtime, "completed")
    assert_receive {:child_options, completed_run, _}, 5_000
    assert_receive {:admission_receipt, %{status: :created, run_id: ^completed_run}}, 5_000
    assert_receive {:provider, ^completed_run, _, completed_provider}, 5_000
    finish(completed_provider)

    assert_receive {:codex_collaboration, %{type: :settled, agent: %{run_id: ^completed_run}}},
                   5_000

    assert {:ok, _} = spawn_agent(runtime, "running")
    assert_receive {:child_options, running_run, _}, 5_000
    assert_receive {:admission_receipt, %{status: :created, run_id: ^running_run}}, 5_000
    assert_receive {:provider, ^running_run, _, running_provider}, 5_000
    assert {:ok, before_rejection} = MultiAgent.snapshot(runtime)

    assert_rejection(
      operation(runtime, "followup_task", %{"target" => "completed", "message" => "continue"}),
      :resource_conflict
    )

    assert {:ok, ^before_rejection} = MultiAgent.snapshot(runtime)
    assert Process.alive?(running_provider)
    assert_no_admission()
  end

  test "legacy refusals without full invocation identity remain uncertain" do
    runtime =
      start_runtime(
        max_concurrent_threads_per_session: 1,
        admission_receipt: receipt_observer()
      )

    for {tool, arguments, error_class} <- [
          {"spawn_agent", %{"task_name" => "excess", "message" => "work"}, :resource_conflict},
          {"send_message", %{"target" => "missing", "message" => "hello"}, :not_found}
        ] do
      assert {:error, %Error{class: ^error_class}} = result = call(runtime, tool, arguments)
      assert ToolEffects.settlement(result, %{read_only: false}) == :uncertain
    end

    assert_no_admission()
  end

  for error_class <- [:execution_failure, :resource_conflict] do
    test "#{error_class} after reservation remains uncertain despite full invocation identity" do
      runtime =
        start_runtime(
          prepare: fn _child, _options ->
            {:error, Error.new(unquote(error_class), "preparation failed after reservation")}
          end,
          admission_receipt: receipt_observer()
        )

      assert {:error, %Error{class: unquote(error_class)}} =
               result =
               MultiAgent.call(
                 operation(runtime, "spawn_agent", %{"task_name" => "worker", "message" => "work"})
               )

      assert ToolEffects.settlement(result, %{read_only: false}) == :uncertain
      assert_receive {:child_options, run_id, %{child: intent}}, 5_000
      assert_receive {:admission_receipt, %{status: :rejected, run_id: ^run_id} = receipt}, 5_000
      assert receipt.attempt_id == intent.attempt_id
      refute receipt.process_started

      assert {:ok, %{agents: [], admissions: [%{status: :rejected}]}} =
               MultiAgent.snapshot(runtime)

      refute_receive {:provider, _, _, _}, 20
    end
  end

  @tag :tmp_dir
  test "persisted birth intent and created receipt gate child prompt dispatch", %{
    tmp_dir: tmp_dir
  } do
    test_pid = self()
    intent_path = Path.join(tmp_dir, "intent.json")
    receipt_path = Path.join(tmp_dir, "receipt.json")

    runtime =
      start_runtime(
        prepare: fn child, options ->
          send(test_pid, {:intent_waiting, child, self()})

          receive do
            :persist_intent -> persist(intent_path, child)
          end

          {:ok, options}
        end,
        admission_receipt: fn receipt ->
          send(test_pid, {:receipt_waiting, receipt, self()})

          receive do
            :persist_receipt -> persist(receipt_path, receipt)
          end
        end
      )

    spawn = Task.async(fn -> spawn_agent(runtime, "worker") end)
    assert_receive {:intent_waiting, intent, manager}, 5_000
    assert is_binary(intent[:attempt_id])
    assert is_binary(Jason.encode!(intent))
    refute File.exists?(intent_path)
    refute_receive {:provider, _, _, _}, 20

    send(manager, :persist_intent)
    assert_receive {:receipt_waiting, %{status: :created} = receipt, ^manager}, 5_000
    assert receipt.attempt_id == intent.attempt_id
    assert receipt.agent_id == intent.agent_id
    assert receipt.run_id == intent.run_id
    assert receipt.process_started
    assert Jason.decode!(File.read!(intent_path))["attempt_id"] == intent.attempt_id
    refute File.exists?(receipt_path)
    refute_receive {:provider, _, _, _}, 20

    send(manager, :persist_receipt)
    assert {:ok, %{task_name: "/root/worker"}} = Task.await(spawn, 5_000)
    assert_receive {:provider, run_id, _, _}, 5_000
    assert run_id == intent.run_id
    assert Jason.decode!(File.read!(receipt_path))["attempt_id"] == intent.attempt_id
    assert {:ok, %{admissions: [record], agents: [agent]}} = MultiAgent.snapshot(runtime)
    assert record.status == :created
    assert record.receipt_acknowledged
    assert agent.agent_id == intent.agent_id
    assert agent.run_id == intent.run_id
  end

  test "prepared rejections retain correlated receipts and consume unique reservations" do
    runtime = start_runtime(reject_first_metadata: true, admission_receipt: receipt_observer())
    assert {:ok, %{agents: [], admissions: [], revision: 0}} = MultiAgent.subscribe(runtime)

    assert {:error, %Error{class: :validation} = error} = spawn_agent(runtime, "worker")
    assert_receive {:child_options, rejected_run, %{child: rejected}}, 5_000
    assert_receive {:admission_receipt, %{status: :rejected} = rejection}, 5_000
    assert rejection.attempt_id == rejected.attempt_id
    assert rejection.agent_id == rejected.agent_id
    assert rejection.run_id == rejected_run
    assert error.details.attempt_id == rejected.attempt_id
    refute rejection.process_started
    assert {:ok, %{agents: [], admissions: [%{status: :rejected}]}} = MultiAgent.snapshot(runtime)
    refute_receive {:provider, _, _, _}, 20

    assert {:ok, %{task_name: "/root/worker"}} = spawn_agent(runtime, "worker")
    assert_receive {:child_options, accepted_run, %{child: accepted}}, 5_000
    assert accepted_run != rejected_run
    assert accepted.agent_id != rejected.agent_id
    assert accepted.attempt_id != rejected.attempt_id
    assert_receive {:admission_receipt, %{status: :created} = created}, 5_000
    assert created.attempt_id == accepted.attempt_id
    assert_receive {:provider, ^accepted_run, _, _}, 5_000

    assert {:ok, %{admissions: [rejected_record, created_record]}} = MultiAgent.snapshot(runtime)
    assert rejected_record.attempt_id == rejected.attempt_id
    assert created_record.attempt_id == accepted.attempt_id
    assert rejected_record.receipt_acknowledged
    assert created_record.receipt_acknowledged
    assert is_binary(Jason.encode!([rejected_record, created_record]))
  end

  @tag :capture_log
  test "startup failure retains a correlated failed receipt without provider execution" do
    runtime =
      start_runtime(
        prepare: fn _child, options -> {:ok, Keyword.put(options, :work, 0)} end,
        admission_receipt: receipt_observer()
      )

    assert {:ok, _} = MultiAgent.subscribe(runtime)
    assert {:error, %Error{} = error} = spawn_agent(runtime, "worker")
    assert_receive {:child_options, run_id, %{child: intent}}, 5_000
    assert_receive {:admission_receipt, %{status: :failed} = receipt}, 5_000
    assert receipt.attempt_id == intent.attempt_id
    assert receipt.run_id == run_id
    assert error.details.attempt_id == intent.attempt_id
    refute receipt.process_started
    refute_receive {:provider, _, _, _}, 20

    assert {:ok, %{admissions: [%{status: :failed, receipt_acknowledged: true}]}} =
             MultiAgent.snapshot(runtime)
  end

  for failure <- [:refused, :raised] do
    test "created receipt acknowledgement #{failure} prevents dispatch and records failure" do
      test_pid = self()
      failure = unquote(failure)

      runtime =
        start_runtime(
          admission_receipt: fn receipt ->
            send(test_pid, {:admission_receipt, receipt})

            if receipt.status == :created do
              receipt_failure(failure)
            else
              :ok
            end
          end
        )

      assert {:ok, _} = MultiAgent.subscribe(runtime)

      assert {:error, %Error{class: :execution_failure} = error} =
               result =
               MultiAgent.call(
                 operation(runtime, "spawn_agent", %{"task_name" => "worker", "message" => "work"})
               )

      assert ToolEffects.settlement(result, %{read_only: false}) == :uncertain
      assert_receive {:child_options, run_id, %{child: intent}}, 5_000
      assert_receive {:admission_receipt, %{status: :created} = created}, 5_000
      assert_receive {:admission_receipt, %{status: :failed} = failed}, 5_000
      assert created.attempt_id == intent.attempt_id
      assert failed.attempt_id == intent.attempt_id
      assert failed.run_id == run_id
      assert failed.process_started
      assert error.details.attempt_id == intent.attempt_id
      refute_receive {:provider, _, _, _}, 20

      assert_receive {:codex_collaboration,
                      %{type: :admission_created, admission: %{receipt_acknowledged: false}}},
                     5_000

      assert {:ok, %{admissions: [record], agents: [agent]}} = MultiAgent.snapshot(runtime)
      assert record.status == :failed
      assert record.process_started
      assert record.receipt_acknowledged
      assert agent.status == :errored
      assert agent.cleanup == :confirmed
    end
  end

  test "snapshot watermark and stable identity survive a completed run and explicit followup" do
    runtime = start_runtime(max_concurrent_threads_per_session: 2)
    assert {:ok, initial} = MultiAgent.subscribe(runtime)
    assert {:ok, _} = spawn_agent(runtime, "worker")
    assert_receive {:provider, run_id, _, provider}, 5_000
    assert_receive {:codex_collaboration, %{type: :created} = created}, 5_000
    assert_receive {:codex_collaboration, %{type: :started} = started}, 5_000
    assert created.manager_id == initial.manager_id
    assert created.revision == initial.revision + 2
    assert started.revision == created.revision + 2
    assert {:ok, snapshot} = MultiAgent.snapshot(runtime)
    assert snapshot.revision == started.revision
    assert is_binary(Jason.encode!(snapshot))

    finish(provider)
    assert_receive {:codex_collaboration, %{type: :settled, agent: %{run_id: ^run_id}}}, 5_000

    assert {:ok, %{accepted: true}} =
             call(runtime, "followup_task", %{"target" => "worker", "message" => "continue"})

    assert_receive {:provider, next_run, _, _}, 5_000
    assert next_run != run_id
    assert {:ok, %{agents: [agent]}} = MultiAgent.snapshot(runtime)
    assert agent.agent_id == created.agent.agent_id
    assert agent.incarnation == 2
  end

  test "completed V2 identities release execution capacity while history remains" do
    runtime = start_runtime(max_concurrent_threads_per_session: 2)
    assert {:ok, _} = MultiAgent.subscribe(runtime)
    assert {:ok, _} = spawn_agent(runtime, "a")
    assert_receive {:provider, run_id, _, provider}, 5_000
    finish(provider)
    assert_receive {:codex_collaboration, %{type: :settled, agent: %{run_id: ^run_id}}}, 5_000
    assert {:ok, _} = spawn_agent(runtime, "b")
    assert_receive {:provider, _, _, _}, 5_000
    assert {:ok, %{agents: agents}} = MultiAgent.snapshot(runtime)
    assert Enum.map(agents, & &1.status) == [:completed, :running]
  end

  test "V2 interrupt affects the target while nested and sibling children keep running" do
    runtime = start_runtime()
    assert {:ok, _} = spawn_agent(runtime, "a")
    assert_receive {:provider, parent_run, _, _}, 5_000
    assert {:ok, _} = spawn_agent(runtime, "nested", parent_run)
    assert_receive {:provider, _, _, _}, 5_000
    assert {:ok, _} = spawn_agent(runtime, "sibling")
    assert_receive {:provider, _, _, _}, 5_000

    assert {:error, %Error{class: :resource_conflict}} = spawn_agent(runtime, "overflow")
    assert {:ok, %{agents: before_interrupt}} = MultiAgent.snapshot(runtime)
    assert length(before_interrupt) == 3

    assert {:ok, %{status: :interrupted}} =
             call(runtime, "interrupt_agent", %{"target" => "a"})

    assert {:ok, %{agents: agents}} = MultiAgent.snapshot(runtime)
    statuses = Map.new(agents, &{&1.name, &1.status})
    assert statuses["/root/a"] == :interrupted
    assert statuses["/root/a/nested"] == :running
    assert statuses["/root/sibling"] == :running
  end

  test "idle mailbox queues without activation and is consumed by explicit followup" do
    runtime = start_runtime()
    assert {:ok, _} = MultiAgent.subscribe(runtime)
    assert {:ok, _} = spawn_agent(runtime, "worker")
    assert_receive {:provider, run_id, _, provider}, 5_000
    finish(provider)
    assert_receive {:codex_collaboration, %{type: :settled, agent: %{run_id: ^run_id}}}, 5_000

    assert {:ok, %{accepted: true, acceptance: :process_local}} =
             call(runtime, "send_message", %{"target" => "worker", "message" => "queued report"})

    refute_receive {:provider, _, _, _}, 20

    assert {:ok, %{accepted: true}} =
             call(runtime, "followup_task", %{"target" => "worker", "message" => "continue"})

    assert_receive {:provider, next_run, request, _}, 5_000
    assert next_run != run_id

    queued =
      Enum.find(request.messages, &(&1[:collaboration] && &1.collaboration.kind == :message))

    assert queued.content =~ "queued report"
    assert queued.collaboration.source_name == "/root"
  end

  test "V2 wait timeout leaves independently running child intact" do
    runtime = start_runtime(min_wait_timeout_ms: 0)
    assert {:ok, _} = spawn_agent(runtime, "worker")
    assert_receive {:provider, _, _, provider}, 5_000
    assert {:ok, %{timed_out: true}} = call(runtime, "wait_agent", %{"timeout_ms" => 1})
    assert Process.alive?(provider)
    assert {:ok, %{agents: [%{status: :running}]}} = MultiAgent.snapshot(runtime)
  end

  test "child results reach root mailbox and a new root steer wakes wait" do
    runtime = start_runtime()
    assert {:ok, _} = MultiAgent.subscribe(runtime)
    assert {:ok, _} = spawn_agent(runtime, "worker")
    assert_receive {:provider, run_id, _, provider}, 5_000
    root = attach_root(runtime)
    assert {:ok, _} = Conversation.prompt(root.pid, "coordinate")
    assert_receive {:provider, "root", _, _}, 5_000

    wait =
      Task.async(fn ->
        MultiAgent.call(%{
          backend_context: %{
            runtime: runtime,
            profile: :v2,
            resource_owner: Map.take(root.binding, [:owner_id, :incarnation])
          },
          run_id: "root",
          incarnation: root.binding.run_incarnation,
          tool_name: "wait_agent",
          arguments: %{"timeout_ms" => 30_000}
        })
      end)

    assert {:ok, _} = Conversation.steer(root.pid, "new direction")

    assert {:ok, %{message: "Wait interrupted by new input.", timed_out: false}} =
             Task.await(wait, 5_000)

    assert {:ok, %{accepted: true}} =
             call(
               runtime,
               "send_message",
               %{"target" => "/root", "message" => "child report"},
               run_id
             )

    report =
      Enum.find(
        Conversation.status(root.pid).conversation.mailbox,
        &(&1.collaboration.kind == :message)
      )

    assert report.collaboration.source_run_id == run_id
    assert report.content =~ "child report"

    finish(provider)
    assert_receive {:codex_collaboration, %{type: :settled, agent: %{run_id: ^run_id}}}, 5_000

    assert_receive {:codex_collaboration, %{type: :result_delivered, agent: %{run_id: ^run_id}}},
                   5_000

    assert {:ok, %{agents: [agent]}} = MultiAgent.snapshot(runtime)

    result =
      Enum.find(
        Conversation.status(root.pid).conversation.mailbox,
        &(&1.collaboration.kind == :result)
      )

    assert result.collaboration.source_agent_id == agent.agent_id
    assert result.collaboration.source_run_id == run_id
    assert is_binary(result.collaboration.result_id)
  end

  defp attach_root(runtime) do
    tools = MultiAgent.contracts(:v2, runtime) |> Enum.map(& &1.name)
    authority = %{caller: "host", run_id: "root", grants: tools, tool_revision: 1}
    session = start_supervised!({Session, owner_pid: self()})
    assert {:ok, binding} = Session.bind(session, authority, incarnation: 1)

    assert {:ok, catalog} =
             Codex.profile(
               :collaboration_v2,
               %{collaboration_runtime: runtime, session_binding: binding},
               authority,
               tools: tools
             )

    {:ok, store} = EphemeralStore.new(1)

    pid =
      start_supervised!(
        {Conversation,
         run_id: "root",
         incarnation: binding.run_incarnation,
         session_binding: binding,
         store: EphemeralStore,
         context: store,
         provider: Provider,
         provider_context: %{test: self()},
         registry: catalog.registry,
         tools: catalog.tools,
         authority: catalog.authority,
         schema_admission: :strict,
         run_timeout: :infinity}
      )

    %{pid: pid, binding: binding}
  end

  defp start_runtime(opts \\ []) do
    test_pid = self()
    attempts = :atomics.new(1, [])

    start_supervised!(
      {MultiAgent,
       parent_run_id: "root",
       parent_name: "/root",
       parent_authority: %{caller: "host", run_id: "root", grants: []},
       subscriber: Keyword.get(opts, :subscriber),
       admission_receipt: Keyword.get(opts, :admission_receipt),
       min_wait_timeout_ms: Keyword.get(opts, :min_wait_timeout_ms, 10_000),
       max_concurrent_threads_per_session:
         Keyword.get(opts, :max_concurrent_threads_per_session, 4),
       child_options: fn _request, run_id, parent ->
         attempt = :atomics.add_get(attempts, 1, 1)
         send(test_pid, {:child_options, run_id, parent})
         {:ok, context} = EphemeralStore.new(1)

         metadata =
           if Keyword.get(opts, :reject_first_metadata, false) and attempt == 1,
             do: %{invalid_process_handle: self()},
             else: %{}

         options = [
           run_id: run_id,
           store: EphemeralStore,
           context: context,
           provider: Provider,
           provider_context: %{test: test_pid},
           registry: %ToolRegistry{},
           tools: [],
           authority: %{caller: "host", run_id: run_id, grants: [], tool_revision: 1},
           host_metadata: metadata,
           schema_admission: :strict,
           work: 10,
           run_timeout: :infinity
         ]

         case Keyword.get(opts, :prepare) do
           nil -> {:ok, options}
           prepare -> prepare.(parent.child, options)
         end
       end}
    )
  end

  defp receipt_failure(:refused),
    do: {:error, Error.new(:execution_failure, "receipt persistence refused")}

  defp receipt_failure(:raised), do: raise("receipt persistence failed")

  defp persist(path, record) do
    {:ok, file} = File.open(path, [:write, :binary, :sync])
    :ok = IO.binwrite(file, Jason.encode!(record))
    File.close(file)
  end

  defp receipt_observer do
    test_pid = self()

    fn receipt ->
      send(test_pid, {:admission_receipt, receipt})
      :ok
    end
  end

  defp spawn_agent(runtime, name, caller_run \\ "root") do
    call(runtime, "spawn_agent", %{"task_name" => name, "message" => "work"}, caller_run)
  end

  defp operation(runtime, tool, arguments) do
    identity = Integer.to_string(System.unique_integer([:positive]))

    %{
      backend_context: %{runtime: runtime, profile: :v2},
      run_id: "root",
      incarnation: 1,
      step_id: "step-" <> identity,
      attempt_id: "attempt-" <> identity,
      invocation_id: "invocation-" <> identity,
      tool_name: tool,
      tool_revision: 1,
      catalog_revision: 1,
      tool_call_id: "call-" <> identity,
      turn_id: "turn-" <> identity,
      arguments: arguments
    }
  end

  defp assert_rejection(operation, error_class) do
    assert {:rejected, %ToolEffects.Rejection{} = proof} = MultiAgent.call(operation)

    assert {:ok, %{is_error: true, error: %Error{class: ^error_class}}} =
             result = ToolEffects.validate_rejection(proof, operation)

    assert ToolEffects.settlement(result, %{read_only: false}) == :settled

    for {field, replacement} <- [
          run_id: "other-run",
          incarnation: 2,
          step_id: "other-step",
          attempt_id: "other-attempt",
          invocation_id: "other-invocation",
          tool_name: "other-tool",
          tool_revision: 2,
          catalog_revision: 2,
          tool_call_id: "other-call",
          turn_id: "other-turn",
          arguments: Map.put(operation.arguments, "different", true)
        ] do
      assert {:error, %Error{class: :unknown_outcome}} =
               result =
               ToolEffects.validate_rejection(proof, Map.put(operation, field, replacement))

      assert ToolEffects.settlement(result, %{read_only: false}) == :uncertain
    end
  end

  defp assert_no_admission do
    refute_receive {:child_options, _, _}, 20
    refute_receive {:admission_receipt, _}, 20
    refute_receive {:provider, _, _, _}, 20
  end

  defp call(runtime, tool, arguments, caller_run \\ "root") do
    MultiAgent.call(%{
      backend_context: %{runtime: runtime, profile: :v2},
      run_id: caller_run,
      tool_name: tool,
      arguments: arguments
    })
  end

  defp finish(provider) do
    send(provider, {
      :events,
      [%{type: :response_completed, message: %{role: :assistant, content: "done"}}]
    })
  end
end
