defmodule Sigma.Agent.BackplaneGoalHost51FunctionalTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.Error
  alias Sigma.Agent.Backplane.{GoalCoordinator, GoalIntegration, GoalRuns, GoalStore, Store}
  alias Sigma.Agent.Runtime
  alias Sigma.Coding.Hooks.{AsyncRuntime, Runner, Spec}
  alias Sigma.Coding.Hooks.Spec.{Command, McpTool}
  alias Sigma.Session.Writer

  @moduletag :tmp_dir
  @moduletag :codex_alignment_functional

  defmodule Provider do
    @behaviour Sigma.Ai.Provider

    def stream(params) do
      send(params.options[:test_pid], {:host51_provider, self(), params})

      receive do
        :finish_host51 ->
          message = %{
            role: :assistant,
            content: [%{type: :text, text: "Completed fresh work"}],
            stop_reason: :stop,
            usage: %{input: 1, output: 1, total_tokens: 2},
            model: "host51",
            provider: "host51",
            api: "openai-responses",
            timestamp: System.system_time(:millisecond)
          }

          [{:start, %{message | content: []}}, {:done, :stop, message}]
      end
    end
  end

  defmodule FaultableFileSystem do
    def ensure_dir(_faults, path), do: Store.FileSystem.ensure_dir(path)
    def read(_faults, path), do: Store.FileSystem.read(path)

    def write_atomic(faults, path, bytes) do
      fail? =
        case Agent.get(faults, & &1) do
          :public_goal -> String.ends_with?(path, ".goal")
          other -> other
        end

      if fail?,
        do: {:error, :host51_settlement_write_failed},
        else: Store.FileSystem.write_atomic(path, bytes)
    end
  end

  test "SessionStart and async hook results retain completion order and allow fresh same-Goal work",
       %{tmp_dir: dir} do
    capture = Path.join(dir, "effects")
    File.write!(capture, "")
    flag = Path.join(dir, "veto")
    File.write!(flag, "once")

    specs = [
      command(:session_start, "printf S >> '#{capture}'; printf 'implicit session context'"),
      command(
        :user_prompt_submit,
        "printf A >> '#{capture}'; touch '#{dir}/async-done'; printf '%s' '{\"continue\":false,\"stopReason\":\"async control ignored\"}'",
        true
      ),
      command(:user_prompt_submit, """
      while [ ! -e '#{dir}/async-done' ]; do sleep 0.01; done
      printf B >> '#{capture}'
      if [ -e '#{flag}' ]; then
        printf '%s' '{"continue":false,"stopReason":"preserved actual veto"}'
      fi
      """)
    ]

    c = session!(dir, specs)
    goal = set_goal!(c.agent)
    assert_receive {:turn_blocked, "preserved actual veto"}, 5_000
    assert_receive {:agent_end, _}, 5_000
    refute_receive {:host51_provider, _, _}, 30

    record = record!(c, goal.thread_id)
    [{token, receipt}] = Map.to_list(record.admission_settlements)
    assert receipt.reason == :host_stopped
    assert receipt.admission.reservation_token == token
    effects = receipt.attestation.effects
    assert effects.cleanup == :confirmed
    assert effects.result == %{"status" => "blocked", "reason" => "preserved actual veto"}

    assert [
             %{effect_id: "session_start:0", kind: "SessionStart", result: session},
             %{effect_id: "user_prompt_submit:1", kind: "UserPromptSubmit", result: async},
             %{effect_id: "user_prompt_submit:2", kind: "UserPromptSubmit", result: veto}
           ] = effects.records

    assert session == %{
             "exit_status" => 0,
             "outcome" => %{"control" => %{"decision" => "proceed"}}
           }

    assert async == session

    assert veto["outcome"]["control"] == %{
             "decision" => "halt",
             "value" => "preserved actual veto"
           }

    refute inspect(effects) =~ "implicit session context"
    assert File.read!(capture) == "SAB"
    assert {:ok, []} = GoalRuns.list(c.goal_root, goal.thread_id)
    assert {:ok, store} = Store.open(path: c.path <> ".runtime")
    assert {:error, %Error{class: :not_found}} = Store.load(store, receipt.admission.run_id)

    File.rm!(flag)
    assert {:accepted, %{turn_id: real_run}} = Sigma.Agent.prompt(c.agent, "Continue real work")
    assert_receive {:host51_provider, provider, %{turn_id: ^real_run}}, 5_000
    send(provider, :finish_host51)
    assert_receive {:agent_end, _}, 5_000
    assert_receive {:host51_provider, automatic, %{turn_id: next_run}}, 5_000
    refute next_run in [real_run, receipt.admission.run_id]
    complete_goal!(c.agent)
    send(automatic, :finish_host51)
    assert_receive {:agent_end, messages}, 5_000

    assert Enum.any?(
             messages,
             &((Map.get(&1.metadata || %{}, :goal_instruction) == true or
                  Map.get(&1.metadata || %{}, "goal_instruction") == true) and
                 Sigma.Agent.Hooks.message_text(&1) == "Complete this actual Goal")
           )

    assert capture |> File.read!() |> String.graphemes() |> Enum.frequencies() ==
             %{"S" => 1, "A" => 3, "B" => 3}

    assert record!(c, goal.thread_id).admission_settlements == record.admission_settlements
    assert record!(c, goal.thread_id).goal.goal_id == record.goal.goal_id
    assert {:ok, %{status: :confirmed}} = Sigma.Agent.retire_host(c.agent)
  end

  test "cancelling an actual pre-Runtime hook joins its cleanup and durably defers the Goal",
       %{tmp_dir: dir} do
    c =
      session!(dir, [
        command(:user_prompt_submit, "printf '%s' \"$$\" > '#{dir}/shell'; sleep 30")
      ])

    goal = set_goal!(c.agent)
    await!(fn -> File.exists?(Path.join(dir, "shell")) end)
    goal_id = record!(c, goal.thread_id).goal.goal_id
    shell = dir |> Path.join("shell") |> File.read!() |> String.to_integer()
    assert {:cancelling, stopped_run} = Sigma.Agent.cancel(c.agent)
    assert_receive {:agent_end, _}, 8_000
    refute process_running?(shell)
    refute_receive {:host51_provider, _, _}, 30
    record = record!(c, goal.thread_id)
    [receipt] = Map.values(record.admission_settlements)
    assert receipt.reason == :cancelled
    assert receipt.admission.run_id == stopped_run
    assert receipt.attestation.effects.result == %{"status" => "cancelled"}
    assert receipt.attestation.effects.cleanup == :confirmed

    assert [%{result: %{"status" => "failed", "reason" => "Hook cancelled."}}] =
             receipt.attestation.effects.records

    assert record.continuation_deferral.reason == :cancelled
    assert record.goal.goal_id == goal_id
    assert record.goal.status == :active
    assert {:ok, %{status: :confirmed}} = Sigma.Agent.retire_host(c.agent)
  end

  test "an automatic Goal index failure retains actual hooks until confirmed pre-Runtime settlement",
       %{tmp_dir: dir} do
    capture = Path.join(dir, "preparation-effects")
    c = session!(dir, [command(:user_prompt_submit, "printf H >> '#{capture}'; printf '{}' ")])
    writer = Runtime.lookup(dir, "host51", :writer)
    host = Runtime.lookup(dir, "host51", :subagents)
    assert {:ok, selected} = Writer.selected_journal(writer)
    header = Enum.find(selected.entries, &(&1["type"] == "session"))
    thread = header["id"]
    index_name = :crypto.hash(:sha256, thread) |> Base.url_encode64(padding: false)
    index_path = Path.join(c.goal_root, index_name <> ".goal-runs")
    File.mkdir!(index_path)

    goal = set_goal!(c.agent)
    assert goal.thread_id == thread
    original_goal_id = record!(c, thread).goal.goal_id
    assert_receive {:turn_error, error}, 8_000
    assert error.message =~ "goal run index read failed"
    assert error.message =~ "eisdir"
    assert_receive {:turn_failed, failed_run}, 8_000
    assert_receive {:agent_end, messages}, 8_000
    refute_receive {:host51_provider, _, _}, 0
    assert File.read!(capture) == "H"

    assert {:ok, failed_tree} =
             Sigma.Agent.Subagents.message_board_context(host, "/root", %{
               run_id: failed_run,
               incarnation: 1
             })

    failed_session = failed_tree.root_binding.session
    assert is_pid(failed_session)
    refute Process.alive?(failed_session)
    assert {:ok, %{status: :confirmed}} = Sigma.Agent.Subagents.close(host)
    assert {:ok, store} = Store.open(path: c.path <> ".runtime")
    assert {:error, %Error{class: :not_found}} = Store.load(store, failed_run)
    record = record!(c, thread)
    [receipt] = Map.values(record.admission_settlements)
    assert receipt.admission.run_id == failed_run
    assert receipt.reason == :host_stopped
    assert receipt.attestation.effects.cleanup == :confirmed

    assert receipt.attestation.effects.result == %{
             "status" => "failed",
             "reason" => error.message
           }

    assert [
             %{
               effect_id: "user_prompt_submit:0",
               kind: "UserPromptSubmit",
               result: %{
                 "exit_status" => 0,
                 "outcome" => %{"control" => %{"decision" => "proceed"}}
               }
             }
           ] = receipt.attestation.effects.records

    assert record.goal.goal_id == original_goal_id
    assert record.goal.status == :active

    assert Enum.count(messages, &(Sigma.Agent.Hooks.message_text(&1) == "Continue this Goal")) ==
             1

    File.rmdir!(index_path)
    assert {:ok, []} = GoalRuns.list(c.goal_root, thread)

    assert {:accepted, %{turn_id: real_run}} =
             Sigma.Agent.prompt(c.agent, "Continue after restoring the actual index")

    assert_receive {:host51_provider, provider, %{turn_id: ^real_run}}, 8_000
    refute real_run == failed_run
    send(provider, :finish_host51)
    assert_receive {:agent_end, _}, 8_000
    assert_receive {:host51_provider, automatic, %{turn_id: automatic_run}}, 8_000
    refute automatic_run in [failed_run, real_run]
    assert File.read!(capture) == "HHH"
    complete_goal!(c.agent)
    send(automatic, :finish_host51)
    assert_receive {:agent_end, final_messages}, 8_000
    assert record!(c, thread).admission_settlements == record.admission_settlements
    assert record!(c, thread).goal.goal_id == original_goal_id

    assert Enum.count(
             final_messages,
             &(Sigma.Agent.Hooks.message_text(&1) == "Continue this Goal")
           ) == 1

    assert {:ok, %{status: :confirmed}} = Sigma.Agent.retire_host(c.agent)
    assert File.read!(capture) == "HHH"
    refute_receive {:host51_provider, _, _}, 0
  end

  test "cancellation while preparing the actual Session fences Goal binding before Runtime",
       %{tmp_dir: dir} do
    capture = Path.join(dir, "cancel-preparation-effects")
    release = Path.join(dir, "release-preparation-hook")

    c =
      session!(dir, [
        command(:user_prompt_submit, """
        printf H >> '#{capture}'
        while [ ! -e '#{release}' ]; do sleep 0.01; done
        printf '{}'
        """)
      ])

    host = Runtime.lookup(dir, "host51", :subagents)
    goal = set_goal!(c.agent)
    await!(fn -> File.exists?(capture) end)
    assert :ok = :sys.suspend(host)

    stopped_run =
      try do
        File.write!(release, "continue")

        await!(fn ->
          {:messages, messages} = Process.info(host, :messages)

          Enum.any?(messages, fn
            {:"$gen_call", _from, {:prepare_root, _context}} -> true
            _ -> false
          end)
        end)

        assert {:cancelling, run} = Sigma.Agent.cancel(c.agent)
        run
      after
        :ok = :sys.resume(host)
      end

    assert_receive {:turn_cancelled}, 8_000
    assert_receive {:agent_end, _}, 8_000
    refute_receive {:host51_provider, _, _}, 0
    assert File.read!(capture) == "H"
    record = record!(c, goal.thread_id)
    [receipt] = Map.values(record.admission_settlements)
    assert receipt.admission.run_id == stopped_run
    assert receipt.reason == :cancelled
    assert receipt.attestation.effects.result == %{"status" => "cancelled"}
    assert receipt.attestation.effects.cleanup == :confirmed
    assert [%{effect_id: "user_prompt_submit:0"}] = receipt.attestation.effects.records
    assert record.continuation_deferral.reason == :cancelled
    assert {:ok, []} = GoalRuns.list(c.goal_root, goal.thread_id)
    assert {:ok, store} = Store.open(path: c.path <> ".runtime")
    assert {:error, %Error{class: :not_found}} = Store.load(store, stopped_run)

    assert {:ok, tree} =
             Sigma.Agent.Subagents.message_board_context(host, "/root", %{
               run_id: stopped_run,
               incarnation: 1
             })

    refute Process.alive?(tree.root_binding.session)
    assert {:ok, %{status: :confirmed}} = Sigma.Agent.retire_host(c.agent)
    assert File.read!(capture) == "H"
  end

  test "a real connected MCP hook retains its stop result and the same client remains usable",
       %{tmp_dir: dir} do
    fixture = Path.join(dir, "hooks.py")
    log = Path.join(dir, "mcp.jsonl")
    python = System.find_executable("python3")
    assert is_binary(python)
    flag = Path.join(dir, "veto")
    File.write!(flag, "once")

    File.write!(fixture, """
    import json, sys, os
    for line in sys.stdin:
        request = json.loads(line)
        with open(sys.argv[1], "a") as log:
            log.write(json.dumps(request) + "\\n")
        method = request.get("method")
        if "id" not in request:
            continue
        if method == "server/discover":
            print(json.dumps({"jsonrpc": "2.0", "id": request["id"], "error": {"code": -32601, "message": "legacy fixture"}}), flush=True)
            continue
        if method == "initialize":
            result = {"protocolVersion": "2025-11-25", "capabilities": {"tools": {}}, "serverInfo": {"name": "host51", "version": "1"}}
        elif method == "tools/list":
            result = {"tools": [{"name": "veto", "description": "Actual hook", "inputSchema": {"type": "object", "properties": {}}}]}
        elif method == "tools/call":
            output = {"continue": False, "stopReason": "actual MCP veto"} if os.path.exists(sys.argv[2]) else {}
            result = {"content": [{"type": "text", "text": json.dumps(output)}]}
        else:
            result = {}
        print(json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": result}), flush=True)
    """)

    spec = %Spec{
      event: :user_prompt_submit,
      matcher: :any,
      dialect: :codex,
      origin: {:user, "/functional"},
      trusted?: true,
      handler: %McpTool{server: "hooks", tool: "veto", timeout_ms: 5_000}
    }

    c =
      session!(dir, [spec],
        mcp_servers: %{
          "hooks" => %{
            "type" => "stdio",
            "command" => python,
            "args" => ["-u", fixture, log, flag]
          }
        }
      )

    goal = set_goal!(c.agent)
    assert_receive {:turn_blocked, "actual MCP veto"}, 5_000
    assert_receive {:agent_end, _}, 5_000
    [receipt] = Map.values(record!(c, goal.thread_id).admission_settlements)
    assert receipt.reason == :host_stopped
    assert receipt.attestation.effects.cleanup == :confirmed

    assert [
             %{
               kind: "UserPromptSubmit",
               result: %{
                 "exit_status" => 0,
                 "outcome" => %{
                   "control" => %{"decision" => "halt", "value" => "actual MCP veto"}
                 }
               }
             }
           ] =
             receipt.attestation.effects.records

    assert {:ok, clients} = GenServer.call(c.agent, :native_child_mcp_clients)

    executor = Sigma.Coding.MCP.hook_executor(%{clients: clients})
    assert {:ok, %{exit: 0}} = executor.("hooks", "veto", %{}, 5_000)
    requests = log |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    assert Enum.count(requests, &(&1["method"] == "initialize")) == 1
    calls = Enum.filter(requests, &(&1["method"] == "tools/call"))
    assert length(calls) == 2
    assert length(Enum.uniq_by(calls, & &1["id"])) == 2
    refute_receive {:host51_provider, _, _}, 0
    File.rm!(flag)

    assert {:accepted, %{turn_id: real_run}} =
             Sigma.Agent.prompt(c.agent, "Continue using this connection")

    assert_receive {:host51_provider, provider, %{turn_id: ^real_run}}, 5_000
    complete_goal!(c.agent)
    send(provider, :finish_host51)
    assert_receive {:agent_end, _}, 5_000
    assert {:ok, %{status: :confirmed}} = Sigma.Agent.retire_host(c.agent)
  end

  test "a veto seals queued async starts and joins all eight actual command workers", %{
    tmp_dir: dir
  } do
    async =
      for n <- 1..10 do
        command(:user_prompt_submit, "printf '%s' \"$$\" > '#{dir}/started-#{n}'; sleep 30", true)
      end

    wait =
      Enum.map_join(1..8, "\n", fn n ->
        "while [ ! -e '#{dir}/started-#{n}' ]; do sleep 0.01; done"
      end)

    veto =
      command(
        :user_prompt_submit,
        wait <> "\nprintf '%s' '{\"continue\":false,\"stopReason\":\"stop queued work\"}'"
      )

    c = session!(dir, async ++ [veto])
    goal = set_goal!(c.agent)
    assert_receive {:turn_blocked, "stop queued work"}, 5_000
    assert_receive {:agent_end, _}, 5_000
    [receipt] = Map.values(record!(c, goal.thread_id).admission_settlements)
    assert receipt.reason == :host_stopped
    assert receipt.attestation.effects.cleanup == :confirmed
    assert length(receipt.attestation.effects.records) == 9

    assert Enum.sort(Enum.map(receipt.attestation.effects.records, & &1.effect_id)) ==
             Enum.sort(Enum.map(Enum.to_list(0..7) ++ [10], &"user_prompt_submit:#{&1}"))

    for n <- 1..8 do
      pid = dir |> Path.join("started-#{n}") |> File.read!() |> String.to_integer()
      refute process_running?(pid)
    end

    refute File.exists?(Path.join(dir, "started-9"))
    refute File.exists?(Path.join(dir, "started-10"))
    refute_receive {:host51_provider, _, _}, 30
    assert {:ok, %{status: :confirmed}} = Sigma.Agent.retire_host(c.agent)
  end

  test "a detached helper keeps host cleanup and its reservation explicitly unconfirmed", %{
    tmp_dir: dir
  } do
    script =
      "sleep 30 </dev/null >/dev/null 2>&1 & printf '%s' \"$!\" > '#{dir}/helper'; printf '%s' '{\"continue\":false,\"stopReason\":\"actual unfinished helper\"}'"

    c = session!(dir, [command(:user_prompt_submit, script)])
    goal = set_goal!(c.agent)
    assert_receive {:turn_blocked, "actual unfinished helper"}, 5_000
    assert_receive {:turn_error, %Error{class: :unknown_outcome} = actual}, 5_000
    assert_receive {:agent_end, _}, 5_000
    helper = dir |> Path.join("helper") |> File.read!() |> String.to_integer()

    on_exit(fn ->
      System.cmd("kill", ["-KILL", "--", Integer.to_string(helper)], stderr_to_stdout: true)
    end)

    assert process_running?(helper)
    assert inspect(actual) =~ "command_processes_still_active"
    assert record!(c, goal.thread_id).admission_settlements == %{}
    assert {:error, error} = Sigma.Agent.retire_host(c.agent)
    assert inspect(error) =~ "command_processes_still_active"
    refute_receive {:host51_provider, _, _}, 0
  end

  test "failed host settlement retains the seal and retries only persistence after actual DOWN",
       %{tmp_dir: dir} do
    owner = self()
    tasks = start_supervised!(Task.Supervisor)
    faults = start_supervised!({Agent, fn -> false end})
    root = Path.join(dir, "goals")
    store = start_supervised!({GoalStore, path: root, filesystem: {FaultableFileSystem, faults}})
    runtime_store = start_supervised!({Store, path: Path.join(dir, "runtime")})

    writer =
      start_supervised!(
        {Writer, storage_id: Path.join(dir, "root.jsonl"), session_id: "host51", cwd: dir}
      )

    {:ok, async} = AsyncRuntime.start(owner)
    on_exit(fn -> AsyncRuntime.shutdown(async) end)
    capture = Path.join(dir, "effect")

    host = %{
      record_instruction: fn _thread, instruction ->
        message = Sigma.Agent.Message.user("goal-user", instruction.text)
        with {:ok, _} <- Writer.append(writer, {:message_end, message}), do: :ok
      end,
      reserve_turn: fn _thread, request ->
        {:ok,
         {:started,
          %{
            run_id: "host51-run-#{request.host_generation}",
            turn_id: "host51-turn-#{request.host_generation}",
            incarnation: 1
          }}}
      end,
      release_turn: fn _thread, admission ->
        coordinator = self()
        control = :atomics.new(1, [])

        {:ok, executor} =
          Task.Supervisor.start_child(tasks, fn ->
            handle = %{coordinator: coordinator}

            GoalIntegration.execute_admission(handle, admission, fn -> {:ok, :prepared} end, fn ->
              {:ok, scope} = GoalIntegration.open_host_hooks(handle, admission, async)

              assert {:error, %Error{class: :resource_conflict}} =
                       GoalIntegration.open_host_hooks(handle, admission, async)

              assert {{:halt, "actual host stop"}, []} =
                       Runner.run(
                         :user_prompt_submit,
                         [
                           command(
                             :user_prompt_submit,
                             "printf X >> '#{capture}'; printf '%s' '{\"continue\":false,\"stopReason\":\"actual host stop\"}'"
                           )
                         ],
                         %{cwd: dir, hook_execution: scope, hook_async_runtime: async}
                       )

              :ok =
                GoalIntegration.stop_host_executor(handle, admission, %{
                  "status" => "blocked",
                  "reason" => "actual host stop"
                })

              send(owner, {:host51_sealed, self(), admission})
              receive do: (:finish_host51_executor -> :ok)
            end)
          end)

        send(owner, {:host51_executor, executor, control, admission})
        {:ok, %{executor: executor, control: control}}
      end
    }

    opts = [
      writer: writer,
      cwd: dir,
      root: root,
      runtime_store: runtime_store,
      owner_pid: owner,
      host_context: host
    ]

    coordinator = start_supervised!({GoalCoordinator, opts}, restart: :temporary)

    assert {:ok, %{goal: goal}} =
             GoalCoordinator.set(coordinator, %{objective: "Keep actual effects"}, %{
               text: "Continue"
             })

    assert {:ok, original} = GoalStore.load(store, goal.thread_id)
    assert {:ok, {:started, admission}} = GoalCoordinator.idle(coordinator, 1)
    assert_receive {:host51_executor, executor, control, ^admission}, 5_000
    assert_receive {:host51_sealed, ^executor, ^admission}, 5_000
    assert :atomics.get(control, 1) == 4
    assert Process.alive?(executor)
    assert {:ok, ^original} = GoalStore.load(store, goal.thread_id)
    refute_receive {:goal_executor_settled, _, _, _, _, _}, 30
    Agent.update(faults, fn _ -> true end)
    ref = Process.monitor(executor)
    send(executor, :finish_host51_executor)
    assert_receive {:DOWN, ^ref, :process, ^executor, :normal}, 5_000

    assert_receive {:goal_executor_settled, ^coordinator, ^executor, ^control, ^admission,
                    {:error, actual}},
                   5_000

    assert inspect(actual) =~ "host51_settlement_write_failed"
    assert {:ok, ^original} = GoalStore.load(store, goal.thread_id)
    assert File.read!(capture) == "X"
    assert {:error, ^actual} = GoalCoordinator.prepare_admission(coordinator)
    assert File.read!(capture) == "X"
    Agent.update(faults, fn _ -> false end)
    assert {:ok, %{status: :ready}} = GoalCoordinator.prepare_admission(coordinator)

    assert_receive {:goal_executor_settled, ^coordinator, ^executor, ^control, ^admission,
                    {:ok, {:settled, :host_stopped}}},
                   5_000

    assert {:ok, settled} = GoalStore.load(store, goal.thread_id)

    assert settled.admission_settlements[admission.reservation_token].attestation.effects.result ==
             %{"status" => "blocked", "reason" => "actual host stop"}

    assert File.read!(capture) == "X"
    assert {:ok, %{status: :ready}} = GoalCoordinator.prepare_admission(coordinator)
    assert {:ok, ^settled} = GoalStore.load(store, goal.thread_id)
    assert :ok = GenServer.stop(coordinator)
    reopened = start_supervised!({GoalCoordinator, opts}, id: :reopened, restart: :temporary)
    assert {:ok, %{status: :ready}} = GoalCoordinator.prepare_admission(reopened)
    assert {:ok, ^settled} = GoalStore.load(store, goal.thread_id)
    assert File.read!(capture) == "X"

    # This admission commits its exact host observations but loses the public
    # ACK before its Goal owner exits. A replacement must preserve that gate,
    # rather than infer an unsaved reservation or start the hook again.
    assert {:ok, {:started, fresh}} = GoalCoordinator.idle(reopened, 2)
    assert fresh.run_id != admission.run_id
    assert_receive {:host51_executor, next_executor, next_control, ^fresh}, 5_000
    assert_receive {:host51_sealed, ^next_executor, ^fresh}, 5_000
    Agent.update(faults, fn _ -> :public_goal end)
    send(next_executor, :finish_host51_executor)

    assert_receive {:goal_executor_settled, ^reopened, ^next_executor, ^next_control, ^fresh,
                    {:error, failed_ack}},
                   5_000

    assert inspect(failed_ack) =~ "host51_settlement_write_failed"
    assert {:ok, entries} = GoalStore.host_admissions(store, goal.thread_id)
    assert entries[fresh.reservation_token].stage == :sealed
    assert File.read!(capture) == "XX"
    assert :ok = GenServer.stop(reopened)
    Agent.update(faults, fn _ -> false end)

    uncertain =
      start_supervised!({GoalCoordinator, opts}, id: :uncertain_reopen, restart: :temporary)

    assert {:error, %Error{class: :unknown_outcome} = gate} =
             GoalCoordinator.prepare_admission(uncertain)

    assert gate.details.admission.run_id == fresh.run_id
    assert {:error, ^gate} = GoalCoordinator.recover(uncertain)
    assert {:error, _} = GoalCoordinator.idle(uncertain, 3)
    assert {:ok, ^settled} = GoalStore.load(store, goal.thread_id)
    assert {:ok, ^entries} = GoalStore.host_admissions(store, goal.thread_id)
    assert File.read!(capture) == "XX"
    refute_receive {:host51_executor, _, _, _}, 30
  end

  defp session!(dir, specs, opts \\ []) do
    path = Path.join(dir, "root.jsonl")
    goal_root = path <> ".subagents/goal"

    assert {:ok, handle} =
             Runtime.get_session(
               dir,
               "host51",
               Keyword.merge(
                 [
                   cwd: dir,
                   transcript_path: path,
                   native_tools: true,
                   native_memory_root: Path.join(dir, "memories"),
                   provider: Provider,
                   model: %{id: "host51", provider: "host51", api: "openai-responses"},
                   tools: [],
                   hook_specs: specs,
                   options: [test_pid: self()]
                 ],
                 opts
               )
             )

    :ok = Sigma.Agent.subscribe(handle.agent)

    on_exit(fn ->
      case Runtime.lookup(dir, :supervisor) do
        nil -> :ok
        pid -> DynamicSupervisor.terminate_child(Sigma.Agent.DynamicSupervisor, pid)
      end

      assert :ok = GoalStore.retire(goal_root)
    end)

    %{agent: handle.agent, path: path, goal_root: goal_root}
  end

  defp set_goal!(agent) do
    assert {:ok, %{goal: goal}} =
             Sigma.Agent.set_goal(agent, %{objective: "Finish the requested actual work"}, %{
               text: "Continue this Goal"
             })

    goal
  end

  defp complete_goal!(agent),
    do:
      assert(
        {:ok, %{goal: %{status: :complete}}} =
          Sigma.Agent.set_goal(agent, %{status: :complete}, %{text: "Complete this actual Goal"})
      )

  defp record!(c, thread) do
    assert {:ok, store} = GoalStore.open(path: c.goal_root)
    assert {:ok, record} = GoalStore.load(store, thread)
    record
  end

  defp command(event, script, async \\ false),
    do: %Spec{
      event: event,
      matcher: :any,
      dialect: :codex,
      origin: {:user, "/functional"},
      trusted?: true,
      handler: %Command{cmd: script, timeout_ms: 10_000, async: async}
    }

  defp process_running?(pid) do
    case File.read("/proc/#{pid}/stat") do
      {:ok, stat} ->
        [_, state] = Regex.run(~r/\A[0-9]+ \(.*\) ([A-Za-z]) /s, stat)
        state not in ["Z", "X"]

      {:error, :enoent} ->
        false
    end
  end

  defp await!(fun, attempts \\ 400)
  defp await!(_fun, 0), do: flunk("actual host hook did not become observable")

  defp await!(fun, attempts) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(5)
          await!(fun, attempts - 1)
        )
  end
end
