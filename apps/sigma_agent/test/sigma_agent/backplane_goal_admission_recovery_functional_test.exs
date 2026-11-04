defmodule Sigma.Agent.BackplaneGoalAdmissionRecoveryFunctionalTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.Error
  alias Sigma.Agent.Runtime
  alias Sigma.Agent.Backplane.{GoalCoordinator, GoalIntegration, GoalRuns, GoalStore, Store}
  alias Sigma.Session.{Log, Writer}

  @moduletag :tmp_dir
  @moduletag :codex_alignment_functional
  @session "goal-admission-recovery"
  @model %{
    id: "admission-recovery",
    provider: "admission-recovery",
    api: "openai-responses",
    context_window: 200_000
  }

  defmodule Provider do
    @behaviour Sigma.Ai.Provider

    def output_token_limit(_model, _options), do: 2_000

    def stream(params) do
      send(params.options[:test_pid], {:admission_provider, self(), params})

      receive do
        {:admission_response, content} ->
          reason = if Enum.any?(content, &(&1.type == :tool_call)), do: :tool_use, else: :stop

          message = %{
            role: :assistant,
            content: content,
            stop_reason: reason,
            usage: %{input: 15, cache_read: 5, output: 3, total_tokens: 18},
            model: "admission-recovery",
            provider: "admission-recovery",
            api: "openai-responses",
            timestamp: System.system_time(:millisecond)
          }

          [{:start, %{message | content: []}}, {:done, reason, message}]
      end
    end
  end

  defmodule FaultableFileSystem do
    def ensure_dir(_control, path), do: Store.FileSystem.ensure_dir(path)
    def read(_control, path), do: Store.FileSystem.read(path)

    def write_atomic(control, path, bytes) do
      record = :erlang.binary_to_term(bytes, [:safe])
      %{fail?: fail?, owner: owner} = Agent.get(control, & &1)

      if fail? and map_size(record.admission_settlements) > 0 do
        send(owner, {:admission_settlement_write_rejected, record.admission_settlements})
        {:error, :injected_admission_settlement_write_failure}
      else
        Store.FileSystem.write_atomic(path, bytes)
      end
    end
  end

  setup %{tmp_dir: dir} do
    path = Path.join(dir, "root.jsonl")
    goal_root = Path.join(path <> ".subagents", "goal")
    owner = self()
    control = start_supervised!({Agent, fn -> %{fail?: false, owner: owner} end})

    goal_store =
      start_supervised!({GoalStore, path: goal_root, filesystem: {FaultableFileSystem, control}})

    assert {:ok, handle} =
             Runtime.get_session(dir, @session,
               cwd: dir,
               transcript_path: path,
               native_tools: true,
               native_memory_root: Path.join(dir, "memories"),
               provider: Provider,
               model: @model,
               tools: [],
               hook_specs: [],
               permission_config: %{default: :allow, rules: %{}},
               options: [test_pid: self()]
             )

    assert :ok = Sigma.Agent.subscribe(handle.agent)
    assert {:ok, store} = Store.open(path: path <> ".runtime")

    on_exit(fn ->
      case Runtime.lookup(dir, :supervisor) do
        nil -> :ok
        pid -> DynamicSupervisor.terminate_child(Sigma.Agent.DynamicSupervisor, pid)
      end

      GoalStore.retire(goal_root)
    end)

    %{
      dir: dir,
      path: path,
      goal_root: goal_root,
      goal_store: goal_store,
      store: store,
      control: control,
      agent: handle.agent,
      writer: Runtime.lookup(dir, @session, :writer)
    }
  end

  test "the next real prompt retries only the sealed settlement before new execution", c do
    {thread, failed_run, actual} = failed_settlement!(c)
    assert {:ok, before_record} = GoalStore.load(c.goal_store, thread)
    assert {:ok, before_hosts} = Store.host_retirement(c.store, :all)
    assert {:ok, before_runs} = GoalRuns.list(c.goal_root, thread)
    before_users = users!(c)

    # With storage still broken, admission must surface that original write
    # failure before a new Session, canonical user or Provider can start.
    assert {:accepted, %{turn_id: rejected_run}} =
             Sigma.Agent.prompt(c.agent, "Do not execute while settlement storage is broken")

    assert_receive {:admission_settlement_write_rejected, _}, 8_000
    assert_receive {:turn_error, ^actual}, 8_000
    assert_receive {:turn_failed, ^rejected_run}, 8_000
    assert {:ok, ^before_record} = GoalStore.load(c.goal_store, thread)
    assert {:ok, ^before_hosts} = Store.host_retirement(c.store, :all)
    assert {:ok, ^before_runs} = GoalRuns.list(c.goal_root, thread)
    assert users!(c) == before_users
    assert {:error, %Error{class: :not_found}} = Store.load(c.store, rejected_run)
    refute_receive {:admission_provider, _, _}, 0

    allow_settlement!(c)
    root = prompt!(c.agent, "Continue the same Goal after repairing settlement storage")
    refute root.params.turn_id in [failed_run, rejected_run]
    receipt = receipt!(c, thread, failed_run)
    assert Enum.count(root.params.context.messages, &(&1.role == :user)) == 2
    finish_completed!(root, c)
    assert receipt!(c, thread, failed_run) == receipt
    assert {:error, %Error{class: :not_found}} = Store.load(c.store, failed_run)
    assert {:error, %Error{class: :not_found}} = Store.load(c.store, rejected_run)
    assert {:ok, %{goal: %{status: :complete, thread_id: ^thread}}} = Sigma.Agent.goal(c.agent)
    refute_receive {:admission_provider, _, _}, 30
  end

  test "explicit Goal mutation retries persistence before recording instructions or continuing",
       c do
    {thread, failed_run, actual} = failed_settlement!(c)
    before_users = users!(c)
    instruction = %{text: "Continue after repairing the original settlement"}

    assert {:error, ^actual} = Sigma.Agent.set_goal(c.agent, %{status: :active}, instruction)
    assert_receive {:admission_settlement_write_rejected, _}, 8_000
    assert users!(c) == before_users
    refute_receive {:admission_provider, _, _}, 0

    allow_settlement!(c)

    assert {:ok, %{goal: %{status: :active, thread_id: ^thread}}} =
             Sigma.Agent.set_goal(c.agent, %{status: :active}, instruction)

    root = provider!()
    refute root.params.turn_id == failed_run
    receipt = receipt!(c, thread, failed_run)
    assert Enum.count(users!(c), &(&1.content == instruction.text)) == 1
    finish_completed!(root, c)
    assert receipt!(c, thread, failed_run) == receipt
    refute_receive {:admission_provider, _, _}, 30
  end

  test "explicit clear settles the sealed admission before removing its Goal", c do
    {thread, failed_run, actual} = failed_settlement!(c)
    instruction = %{text: "Clear this Goal after recording its failed preparation"}
    before_users = users!(c)
    assert {:error, ^actual} = Sigma.Agent.clear_goal(c.agent, instruction)
    assert_receive {:admission_settlement_write_rejected, _}, 8_000
    assert users!(c) == before_users

    allow_settlement!(c)
    assert {:ok, %{goal: nil}} = Sigma.Agent.clear_goal(c.agent, instruction)
    receipt!(c, thread, failed_run)
    assert {:ok, %{goal: nil}} = Sigma.Agent.goal(c.agent)
    assert Enum.count(users!(c), &(&1.content == instruction.text)) == 1
    refute_receive {:admission_provider, _, _}, 30
  end

  test "fork settles the source admission before creating an independent Goal snapshot", c do
    {thread, failed_run, actual} = failed_settlement!(c)
    target = Path.join(c.dir, "fork.jsonl")

    writer =
      start_supervised!(
        {Writer, storage_id: target, session_id: "fork", cwd: c.dir},
        id: :fork_writer
      )

    assert {:ok, handle} = GenServer.call(c.agent, :goal_handle)
    assert {:error, ^actual} = GoalIntegration.fork(handle, writer, c.dir, target)
    assert_receive {:admission_settlement_write_rejected, _}, 8_000
    refute File.exists?(target <> ".subagents")

    allow_settlement!(c)

    assert {:ok, %{thread_id: target_thread, snapshot: snapshot}} =
             GoalIntegration.fork(handle, writer, c.dir, target)

    receipt!(c, thread, failed_run)
    assert snapshot.admission_settlements == %{}
    assert snapshot.runtime_receipt_counts == %{}
    assert target_thread != thread
    assert snapshot.goal.thread_id == target_thread
    assert {:ok, target_store} = GoalStore.open(path: Path.join(target <> ".subagents", "goal"))
    assert {:ok, ^snapshot} = GoalStore.load(target_store, target_thread)
    assert :ok = GoalStore.retire(Path.join(target <> ".subagents", "goal"))
    assert {:error, %Error{class: :not_found}} = Store.load(c.store, failed_run)
    refute_receive {:admission_provider, _, _}, 30
  end

  test "admission preparation cannot reconcile an indexed run or clear its recovery error", c do
    target = Path.join(c.dir, "indexed.jsonl")
    root = Path.join(target <> ".subagents", "goal")

    writer =
      start_supervised!(
        {Writer, storage_id: target, session_id: "indexed", cwd: c.dir},
        id: :indexed_writer
      )

    assert {:ok, _} = Writer.append(writer, {:agent_start, c.dir})
    assert {:ok, %{entries: [%{"id" => thread}]}} = Writer.selected_journal(writer)
    start_supervised!({GoalStore, path: root}, id: :indexed_goal_store)

    assert :ok =
             GoalRuns.record(root, thread, %{
               thread_id: thread,
               run_id: "missing-indexed-run",
               incarnation: 1,
               mode: :execution,
               usage_authoritative: true,
               goal_id: nil
             })

    coordinator =
      start_supervised!(
        {GoalCoordinator,
         writer: writer,
         cwd: c.dir,
         root: root,
         transcript_path: target,
         runtime_store: c.store,
         host_context: %{}}
      )

    assert {:ok, before_index} = GoalRuns.list(root, thread)
    assert {:ok, before_state} = GoalCoordinator.identity(coordinator)
    assert before_state.status == :recovery_required

    assert {:error, %Error{class: :resource_conflict}} =
             GoalCoordinator.prepare_admission(coordinator)

    assert {:ok, ^before_state} = GoalCoordinator.identity(coordinator)
    assert {:ok, ^before_index} = GoalRuns.list(root, thread)
    assert {:error, %Error{class: :not_found} = actual} = GoalCoordinator.recover(coordinator)
    assert {:error, ^actual} = GoalCoordinator.prepare_admission(coordinator)

    assert {:ok, %{status: :recovery_required, recovery_error: ^actual}} =
             GoalCoordinator.identity(coordinator)

    assert {:ok, ^before_index} = GoalRuns.list(root, thread)
    refute_receive {:admission_provider, _, _}, 0
  end

  defp failed_settlement!(c) do
    root = prompt!(c.agent, "Create a Goal and keep working")
    root = call!(root, "create_goal", %{"objective" => "Finish the requested recovery work"})
    assert {:ok, %{goal: %{thread_id: thread}}} = Sigma.Agent.goal(c.agent)
    Agent.update(c.control, &%{&1 | fail?: true})

    assert :ok =
             Sigma.Agent.set_provider(c.agent, Provider, @model,
               test_pid: self(),
               hosted_web_search: %{supported: true, enabled: true}
             )

    send(root.pid, {:admission_response, [%{type: :text, text: "Continue the Goal"}]})
    assert_receive {:agent_end, _}, 8_000
    assert_receive {:turn_failed, failed_run}, 8_000
    assert_receive {:turn_error, %Error{} = preparation_error}, 8_000
    assert preparation_error.message =~ "provider-hosted"
    assert_receive {:admission_settlement_write_rejected, _}, 8_000

    assert_receive {:turn_error,
                    %Error{
                      class: :execution_failure,
                      cause: :injected_admission_settlement_write_failure
                    } = actual},
                   8_000

    assert_receive {:agent_end, _}, 8_000
    assert {:error, %Error{class: :not_found}} = Store.load(c.store, failed_run)
    assert {:ok, %{admission_settlements: settlements}} = GoalStore.load(c.goal_store, thread)
    assert settlements == %{}
    refute_receive {:admission_provider, _, _}, 0
    assert :ok = Sigma.Agent.set_provider(c.agent, Provider, @model, test_pid: self())
    {thread, failed_run, actual}
  end

  defp allow_settlement!(c), do: Agent.update(c.control, &%{&1 | fail?: false})

  defp receipt!(c, thread, run) do
    assert {:ok, record} = GoalStore.load(c.goal_store, thread)
    [receipt] = Map.values(record.admission_settlements)
    assert receipt.admission.run_id == run
    assert receipt.reason == :preparation_failed
    assert receipt.response == {:settled, :preparation_failed}
    assert receipt.attestation.executor == :confirmed_down
    assert receipt.attestation.runtime_admission == :never_started
    assert receipt.attestation.future_start == :fenced
    assert receipt.attestation.effects == :none_dispatched
    receipt
  end

  defp users!(c) do
    assert {:ok, _} = Writer.flush(c.writer)
    assert {:ok, snapshot} = Log.snapshot(c.path)
    Enum.filter(snapshot.messages, &(&1.role == :user))
  end

  defp prompt!(agent, content) do
    assert {:accepted, _} = Sigma.Agent.prompt(agent, content)
    provider!()
  end

  defp provider! do
    receive do
      {:admission_provider, pid, params} -> %{pid: pid, params: params}
      {:turn_error, error} -> flunk("Goal admission failed: #{inspect(error)}")
    after
      8_000 -> flunk("Goal Provider did not start")
    end
  end

  defp call!(root, name, args) do
    send(
      root.pid,
      {:admission_response,
       [
         %{
           type: :tool_call,
           id: "admission-#{System.unique_integer([:positive])}",
           name: name,
           arguments: args,
           input_kind: :function
         }
       ]}
    )

    next = provider!()
    result = Enum.find(Enum.reverse(next.params.context.messages), &(&1[:tool_name] == name))
    assert result
    refute result.is_error
    next
  end

  defp finish_completed!(root, c) do
    root = call!(root, "update_goal", %{"status" => "complete"})
    send(root.pid, {:admission_response, [%{type: :text, text: "Recovery work complete"}]})
    assert_receive {:agent_end, _}, 8_000
    assert {:ok, _} = Writer.flush(c.writer)
  end
end
