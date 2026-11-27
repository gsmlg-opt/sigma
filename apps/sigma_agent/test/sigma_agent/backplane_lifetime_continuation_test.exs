defmodule Sigma.Agent.BackplaneLifetimeContinuationTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.Codex.Reconciliation.Evidence
  alias Backplane.AgentRuntime.Error

  alias Sigma.Agent.Backplane.{
    LifetimeEvidence,
    LifetimeRecovery,
    Store
  }

  alias Sigma.Agent.Runtime

  @moduletag :tmp_dir

  defmodule LostRead do
    @behaviour Sigma.Coding.Tool
    def name, do: "lost_read"
    def description, do: "Reads a file and loses the tool completion"

    def schema do
      %{
        "type" => "object",
        "properties" => %{"path" => %{"type" => "string"}, "observer" => %{"type" => "string"}},
        "required" => ["path", "observer"]
      }
    end

    def metadata, do: %{effect: :read, concurrency: :shared, default_deadline_ms: 5_000}

    def execute(_id, params, _opts) do
      {:ok, content} = File.read(params["path"])
      observer = params["observer"] |> String.to_charlist() |> :erlang.list_to_pid()
      send(observer, {:original_read, content, self()})

      receive do
        :lose_completion ->
          {:error, Sigma.Coding.ToolError.new(:unknown_outcome, "tool completion was lost")}
      end
    end
  end

  defmodule Provider do
    @behaviour Sigma.Ai.Provider
    def output_token_limit(_model, _opts), do: 2_000

    def stream(request) do
      send(request.options[:test_pid], {:continuation_provider, self(), request})

      receive do
        {:respond, content} ->
          reason = if Enum.any?(content, &(&1.type == :tool_call)), do: :tool_use, else: :stop

          message = %{
            role: :assistant,
            content: content,
            stop_reason: reason,
            usage: %{input: 1, output: 1, total_tokens: 2},
            model: "test",
            provider: "test",
            api: "openai-responses",
            timestamp: System.system_time(:millisecond)
          }

          [{:start, %{message | content: []}}, {:done, reason, message}]
      end
    end
  end

  @tag capture_log: true
  test "a live lost completion automatically admits fresh work and preserves the unknown run",
       %{tmp_dir: dir} do
    {hook, marker, gate} = gated_session_end(dir)
    {path, handle, source} = failed_read!(dir, [hook])
    assert_receive {:recovery_started, %{source_run_id: ^source}}, 5_000
    assert eventually(fn -> File.exists?(marker) end)
    state = :sys.get_state(handle.agent)

    identity = %{
      thread_id: state.host_retirement.identity.root_header_id,
      run_id: source,
      incarnation: 1
    }

    assert Sigma.Agent.status(handle.agent).phase == :session_operation
    assert {:ok, original} = Store.load(state.backplane_store, source)
    assert original.run.state == :unknown_outcome
    assert {:ok, _} = Sigma.Session.Writer.flush(state.writer)
    journal = File.read!(path)

    try do
      assert {:error, %Error{class: :unknown_outcome}} =
               LifetimeEvidence.prepare_continuation(path, identity, "sigma-continue:" <> source)

      refute_receive {:continuation_provider, _, _}, 0
    after
      File.touch!(gate)
    end

    assert_receive {:continuation_provider, provider, request}, 5_000
    assert request.turn_id != source
    assert inspect(request.context.messages) =~ "outcome is unknown"
    assert inspect(request.context.messages) =~ "inspect the current state"
    assert {:ok, decision} = LifetimeEvidence.read_continuation(path, identity)

    assert [%{"tool_call_id" => "lost-call", "tool_name" => "lost_read"}] =
             decision["unresolved_tools"]

    assert decision["historical_outcome"]["state"] == "unknown_outcome"
    assert decision["target"]["run_id"] == request.turn_id

    assert {:ok, ^decision} =
             LifetimeEvidence.prepare_continuation(path, identity, "sigma-continue:" <> source)

    assert_incomplete_ownership_rejected(dir, path, identity)

    assert {:error, %Error{class: :resource_conflict}} =
             LifetimeEvidence.prepare_continuation(path, identity, "different-click")

    send(
      provider,
      {:respond,
       [
         %{
           type: :tool_call,
           id: "fresh",
           name: "exec_command",
           arguments: %{"cmd" => "printf recovered"}
         }
       ]}
    )

    assert_receive {:continuation_provider, provider, request}, 5_000
    result = List.last(request.context.messages)
    refute result.is_error
    assert [%{text: json}] = result.content
    assert Formata.JSON.decode!(json)["output"] == "recovered"
    send(provider, {:respond, [%{type: :text, text: "checked and continued"}]})
    assert_receive {:agent_end, _}, 5_000
    assert Sigma.Agent.status(handle.agent).phase == :completed
    assert {:ok, ^original} = Store.load(state.backplane_store, source)
    assert String.starts_with?(File.read!(path), journal)
    assert File.read!(marker) == "once\n"
    refute_receive {:original_read, _, _}, 0
    refute_receive {:continuation_provider, _, _}, 0

    incidents = incident_records(dir)
    assert Enum.any?(incidents, &(&1["kind"] == "recovery_started" and &1["run_id"] == source))

    assert Enum.any?(
             incidents,
             &(&1["kind"] == "recovery_admitted" and &1["target_run_id"] == request.turn_id)
           )
  end

  @tag capture_log: true
  test "Stop during automatic preparation retains closure and decision for an explicit cold Continue",
       %{tmp_dir: dir} do
    {hook, marker, gate} = gated_session_end(dir)
    {path, handle, source} = failed_read!(dir, [hook])
    assert eventually(fn -> File.exists?(marker) end)
    state = :sys.get_state(handle.agent)
    original_host = state.host_retirement.identity
    assert {:ok, original} = Store.load(state.backplane_store, source)
    assert {:ok, _} = Sigma.Session.Writer.flush(state.writer)
    journal = File.read!(path)

    try do
      assert {:cancelling, _} = Sigma.Agent.cancel(handle.agent)
    after
      File.touch!(gate)
    end

    assert eventually(fn -> Sigma.Agent.status(handle.agent).phase == :cancelled end)
    assert :sys.get_state(handle.agent).host_retirement.identity == original_host
    assert File.read!(marker) == "once\n"

    assert :ok =
             DynamicSupervisor.terminate_child(
               Sigma.Agent.DynamicSupervisor,
               Runtime.lookup(dir, :supervisor)
             )

    assert File.read!(path) == journal

    evidence =
      File.read!(path <> ".subagents/lifetime-recovery.etf") |> :erlang.binary_to_term([:safe])

    assert map_size(evidence.continuations) == 1

    assert {:ok, reopened} =
             Runtime.get_session(dir, "source", session_options(dir, path, [hook]))

    :ok = Sigma.Agent.subscribe(reopened.agent)
    assert {:ok, ^original} = Store.load(:sys.get_state(reopened.agent).backplane_store, source)
    refute_receive {:continuation_provider, _, _}, 100
    assert File.read!(path) == journal

    assert {:accepted, %{turn_id: target}} =
             Sigma.Agent.prompt(reopened.agent, "fresh work", continuation_source: source)

    assert target != source
    assert_receive {:continuation_provider, provider, request}, 5_000
    assert request.turn_id == target
    send(provider, {:respond, [%{type: :text, text: "fresh reply"}]})
    assert_receive {:agent_end, _}, 5_000
    assert {:ok, ^original} = Store.load(:sys.get_state(reopened.agent).backplane_store, source)
    refute_receive {:original_read, _, _}, 0

    assert Enum.any?(
             incident_records(dir),
             &(&1["kind"] == "recovery_cancelled" and is_binary(&1["continuation_id"]))
           )
  end

  @tag capture_log: true
  @tag timeout: 60_000
  test "a lost command cell keeps its unknown outcome through real shutdown and cold Continue",
       %{tmp_dir: dir} do
    Sigma.Agent.TestCodeMode.assert_available!()
    observer = self()
    path = Path.join(dir, "command.jsonl")
    launches = Path.join(dir, "launches.log")
    pid_path = Path.join(dir, "command.pid")
    {hook, session_end, end_gate} = gated_session_end(dir)

    lost = %Sigma.Coding.MCP.Tool{
      name: "mcp__fixture__lose_completion",
      description: "Lose completion after a real command has started",
      schema: %{"type" => "object", "properties" => %{}},
      server_id: "fixture",
      server_tool_name: "lose_completion",
      call_tool: fn _, _, _ ->
        send(observer, {:command_cell_waiting, self()})

        receive do
          :lose_completion ->
            {:error,
             Sigma.Coding.ToolError.new(:unknown_outcome, "command cell completion was lost")}
        end
      end
    }

    options = Keyword.put(session_options(dir, path, [hook]), :tools, [lost])

    on_exit(fn ->
      case Runtime.lookup(dir, :supervisor) do
        nil -> :ok
        supervisor -> DynamicSupervisor.terminate_child(Sigma.Agent.DynamicSupervisor, supervisor)
      end
    end)

    assert {:ok, handle} = Runtime.get_session(dir, "command", options)
    :ok = Sigma.Agent.subscribe(handle.agent)
    assert {:accepted, %{turn_id: source}} = Sigma.Agent.prompt(handle.agent, "start one command")
    assert_receive {:continuation_provider, provider, _}, 5_000

    command =
      "printf '%s\\n' \"$$\" > #{quote_shell(pid_path)}; " <>
        "printf 'launched\\n' >> #{quote_shell(launches)}; " <>
        "while IFS= read -r line; do printf '%s\\n' \"$line\"; done"

    code = """
    await tools.exec_command({cmd: #{Formata.JSON.encode!(command)}, shell: "/bin/sh", login: false, yield_time_ms: 100});
    return await tools.mcp__fixture__lose_completion({});
    """

    send(
      provider,
      {:respond,
       [
         %{
           type: :tool_call,
           id: "lost-command-cell",
           name: "exec",
           arguments: code,
           input_kind: :custom
         }
       ]}
    )

    assert_receive {:command_cell_waiting, cell}, 10_000
    assert File.read!(launches) == "launched\n"
    pid = pid_path |> File.read!() |> String.trim()
    assert {_, 0} = System.cmd("/bin/kill", ["-0", pid], stderr_to_stdout: true)
    send(cell, :lose_completion)
    assert_receive {:agent_end, _}, 10_000
    assert eventually(fn -> File.exists?(session_end) end)
    assert {:cancelling, _} = Sigma.Agent.cancel(handle.agent)
    File.touch!(end_gate)
    assert eventually(fn -> Sigma.Agent.status(handle.agent).phase == :cancelled end)

    state = :sys.get_state(handle.agent)

    identity = %{
      thread_id: state.host_retirement.identity.root_header_id,
      run_id: source,
      incarnation: 1
    }

    assert {:ok, %{run: %{state: :unknown_outcome} = run} = original} =
             Store.load(state.backplane_store, source)

    assert [{_, intent}] =
             Enum.filter(run.execution_intents, fn {_, intent} ->
               intent.type == :tool and intent.operation.tool_call_id == "lost-command-cell" and
                 not Map.has_key?(run.tool_results, intent.operation.invocation_id)
             end)

    assert intent.operation.tool_name == "exec"
    assert intent.status == :uncertain
    assert {:ok, _} = Sigma.Session.Writer.flush(state.writer)
    journal = File.read!(path)

    assert :ok =
             DynamicSupervisor.terminate_child(
               Sigma.Agent.DynamicSupervisor,
               Runtime.lookup(dir, :supervisor)
             )

    assert {_, status} = System.cmd("/bin/kill", ["-0", pid], stderr_to_stdout: true)
    refute status == 0
    assert File.read!(session_end) == "once\n"
    assert File.read!(path) == journal

    evidence =
      (path <> ".subagents/lifetime-recovery.etf")
      |> File.read!()
      |> :erlang.binary_to_term([:safe])

    assert map_size(evidence.continuations) == 1

    assert {:ok, reopened} = Runtime.get_session(dir, "command", options)
    :ok = Sigma.Agent.subscribe(reopened.agent)
    reopened_store = :sys.get_state(reopened.agent).backplane_store
    assert {:ok, ^original} = Store.load(reopened_store, source)
    assert {:ok, %{hosts: hosts}} = Store.host_retirement(reopened_store, :all)
    assert [original_host] = Map.values(hosts)
    assert original_host.async_hooks == %{status: :confirmed}
    assert %{status: :confirmed, dispatch: :completed} = original_host.session_end

    for binding <- Map.values(original_host.bindings) do
      assert {:ok, %{status: :confirmed, native: %{status: :confirmed}}} =
               Store.host_retirement(reopened_store, binding)
    end

    assert {:accepted, %{turn_id: target}} =
             Sigma.Agent.prompt(reopened.agent, "fresh command", continuation_source: source)

    assert target != source
    assert_receive {:continuation_provider, provider, request}, 10_000
    assert request.turn_id == target
    assert inspect(request.context.messages) =~ "outcome is unknown"
    assert {:ok, decision} = LifetimeEvidence.read_continuation(path, identity)
    assert decision["historical_outcome"]["state"] == "unknown_outcome"

    lost_operations =
      for {_, %{type: :tool, status: status, operation: operation}} <- run.execution_intents,
          status in [:started, :uncertain],
          not Map.has_key?(run.tool_results, operation.invocation_id) do
        {:ok, identity} =
          operation
          |> Map.take(
            ~w(run_id incarnation step_id attempt_id invocation_id tool_call_id tool_name enclosing_invocation_id)a
          )
          |> Evidence.public()

        identity
      end

    assert Enum.sort_by(decision["unresolved_tools"], & &1["invocation_id"]) ==
             Enum.sort_by(lost_operations, & &1["invocation_id"])

    assert Enum.sort(Enum.map(lost_operations, & &1["tool_name"])) ==
             ["exec", "mcp__fixture__lose_completion"]

    send(
      provider,
      {:respond,
       [
         %{
           type: :tool_call,
           id: "fresh-command",
           name: "exec_command",
           arguments: %{"cmd" => "printf fresh"}
         }
       ]}
    )

    assert_receive {:continuation_provider, provider, request}, 10_000
    result = List.last(request.context.messages)
    refute result.is_error
    assert [%{text: json}] = result.content
    assert Formata.JSON.decode!(json)["output"] == "fresh"
    send(provider, {:respond, [%{type: :text, text: "fresh reply"}]})
    assert_receive {:agent_end, _}, 5_000
    assert Sigma.Agent.status(reopened.agent).phase == :completed
    assert {:ok, ^original} = Store.load(reopened_store, source)
    assert File.read!(launches) == "launched\n"
    assert File.read!(session_end) == "once\n"
    assert String.starts_with?(File.read!(path), journal)
    refute_receive {:command_cell_waiting, _}, 0
  end

  @tag capture_log: true
  test "automatic recovery preserves a queued user prompt and ignores duplicate old terminals", %{
    tmp_dir: dir
  } do
    owner = self()
    resource = %{root: Path.join(dir, "prepared"), release: fn -> send(owner, :released) end}

    {path, handle, source} =
      failed_read!(dir, [], fn handle, _source ->
        old_task = :sys.get_state(handle.agent).current_turn_task

        assert {:queued_as_follow_up, info} =
                 Sigma.Agent.prompt(handle.agent, "keep this exact followup",
                   prepared_resources: [resource]
                 )

        send(owner, {:queued_recovery, info, old_task})
      end)

    assert_receive {:queued_recovery, _info, old_task}
    assert_receive {:continuation_provider, provider, request}, 5_000
    assert request.turn_id != source

    assert List.last(request.context.messages).content == "keep this exact followup"

    send(handle.agent, {old_task.ref, {:error, :duplicate_terminal}})
    send(handle.agent, {:DOWN, old_task.ref, :process, old_task.pid, :duplicate_terminal})
    assert Sigma.Agent.status(handle.agent).turn_id == request.turn_id
    refute_receive {:continuation_provider, _, _}, 0
    send(provider, {:respond, [%{type: :text, text: "followup completed"}]})
    assert_receive {:agent_end, _}, 5_000
    assert_receive :released, 5_000
    refute_receive :released, 0
    assert Sigma.Agent.status(handle.agent).phase == :completed
    assert Enum.count(incident_records(dir), &(&1["kind"] == "recovery_admitted")) == 1

    assert {:ok, %{run: %{state: :unknown_outcome}}} =
             Store.load(:sys.get_state(handle.agent).backplane_store, source)

    assert File.exists?(path)
  end

  @tag capture_log: true
  test "a lost preparation acknowledgement blocks visibly without recursive recovery", %{
    tmp_dir: dir
  } do
    {hook, marker, gate} = gated_session_end(dir)
    {_path, handle, source} = failed_read!(dir, [hook])
    assert_receive {:recovery_started, %{source_run_id: ^source}}, 5_000
    assert eventually(fn -> File.exists?(marker) end)
    state = :sys.get_state(handle.agent)
    assert {:ok, original} = Store.load(state.backplane_store, source)
    Process.exit(state.host_recovery_task.pid, :kill)
    File.touch!(gate)
    assert_receive {:turn_error, %Error{class: :unknown_outcome, message: message}}, 5_000
    assert message =~ "preparation stopped"
    assert eventually(fn -> Sigma.Agent.status(handle.agent).phase == :failed end)
    assert is_nil(:sys.get_state(handle.agent).pending_host_prompt)
    refute_receive {:continuation_provider, _, _}, 100
    refute_receive {:recovery_started, _}, 0
    assert {:ok, ^original} = Store.load(state.backplane_store, source)
    assert [blocked] = Enum.filter(incident_records(dir), &(&1["kind"] == "recovery_blocked"))
    assert blocked["blocked_component"] == "async_hooks.session_end"
    assert blocked["error"]["class"] == "unknown_outcome"
  end

  @tag :session_delete_lifecycle
  @tag capture_log: true
  test "delete waits for automatic preparation and prevents replacement work", %{tmp_dir: dir} do
    owner = self()
    resource = %{root: Path.join(dir, "queued"), release: fn -> send(owner, :queued_released) end}
    {hook, marker, gate} = gated_session_end(dir)

    {path, handle, source} =
      failed_read!(dir, [hook], fn handle, _source ->
        assert {:queued_as_follow_up, _} =
                 Sigma.Agent.prompt(handle.agent, "must not continue",
                   prepared_resources: [resource]
                 )
      end)

    assert_receive {:recovery_started, %{source_run_id: ^source}}, 5_000
    assert eventually(fn -> File.exists?(marker) end)
    state = :sys.get_state(handle.agent)
    assert {:ok, original} = Store.load(state.backplane_store, source)

    deletion = Task.async(fn -> Runtime.delete_session(dir, "source", dir) end)

    try do
      assert eventually(fn -> not is_nil(:sys.get_state(handle.agent).delete_operation) end)
      assert {:rejected, :session_busy} = Sigma.Agent.prompt(handle.agent, "must not race")
      assert Task.yield(deletion, 0) == nil
      assert File.exists?(path)
      assert {:ok, ^original} = Store.load(state.backplane_store, source)
      refute_receive {:continuation_provider, _, _}, 0
    after
      File.touch!(gate)
    end

    assert_receive :queued_released, 5_000
    assert {:ok, %{deleted: true}} = Task.await(deletion, 10_000)
    refute File.exists?(path)
    refute File.exists?(path <> ".runtime")
    refute File.exists?(path <> ".subagents")
    assert File.read!(marker) == "once\n"
    refute_receive :queued_released, 0
    refute_receive {:continuation_provider, _, _}, 0
    refute Enum.any?(incident_records(dir), &(&1["kind"] == "recovery_admitted"))
  end

  test "legacy evidence reads keep their bytes and concurrent decisions admit one durable record",
       %{
         tmp_dir: dir
       } do
    transcript = Path.join(dir, "root.jsonl")
    path = Path.join(transcript <> ".subagents", "lifetime-recovery.etf")
    File.mkdir_p!(Path.dirname(path))

    legacy = %{
      version: 1,
      root_header_id: "header",
      root_agent_id: "header",
      evidence: %{},
      receipts: %{},
      manifests: %{},
      stores: %{},
      executors: %{}
    }

    bytes = :erlang.term_to_binary(legacy)
    File.write!(path, bytes)
    writer = open_writer(transcript)
    assert {:ok, %{}} = LifetimeRecovery.manifests(writer)
    assert File.read!(path) == bytes

    id = "continuation-source"

    first =
      Evidence.seal(%{"continuation_id" => id, "instruction_ref" => "first"}, "decision_digest")

    second =
      Evidence.seal(%{"continuation_id" => id, "instruction_ref" => "second"}, "decision_digest")

    results =
      [first, second]
      |> Enum.map(fn decision ->
        Task.async(fn ->
          LifetimeRecovery.compare_and_create_continuation(writer, id, decision)
        end)
      end)
      |> Task.await_many()

    assert [{:ok, accepted}] = Enum.filter(results, &match?({:ok, _}, &1))

    assert [{:error, %Error{class: :resource_conflict}}] =
             Enum.filter(results, &match?({:error, _}, &1))

    assert {:ok, ^accepted} = LifetimeRecovery.load_continuation(writer, id)
    assert :ok = LifetimeRecovery.retire(writer)
    committed = File.read!(path)

    assert %{version: 2, evidence: %{}, continuations: %{^id => ^accepted}} =
             :erlang.binary_to_term(committed, [:safe])

    reopened = open_writer(transcript)
    assert {:ok, ^accepted} = LifetimeRecovery.load_continuation(reopened, id)
    assert File.read!(path) == committed
    assert :ok = LifetimeRecovery.retire(reopened)
  end

  defp failed_read!(dir, hooks, before_failure \\ fn _, _ -> :ok end) do
    path = Path.join(dir, "source.jsonl")
    input = Path.join(dir, "input.txt")
    File.write!(input, "original data")

    on_exit(fn ->
      case Runtime.lookup(dir, :supervisor) do
        nil -> :ok
        supervisor -> DynamicSupervisor.terminate_child(Sigma.Agent.DynamicSupervisor, supervisor)
      end
    end)

    assert {:ok, handle} =
             Runtime.get_session(dir, "source", session_options(dir, path, hooks))

    :ok = Sigma.Agent.subscribe(handle.agent)
    assert {:accepted, %{turn_id: run_id}} = Sigma.Agent.prompt(handle.agent, "read once")
    assert_receive {:continuation_provider, provider, _request}, 5_000

    send(
      provider,
      {:respond,
       [
         %{
           type: :tool_call,
           id: "lost-call",
           name: "lost_read",
           arguments: %{
             "path" => input,
             "observer" => self() |> :erlang.pid_to_list() |> List.to_string()
           }
         }
       ]}
    )

    assert_receive {:original_read, "original data", worker}, 5_000
    before_failure.(handle, run_id)
    send(worker, :lose_completion)
    assert_receive {:agent_end, _}, 5_000
    {path, handle, run_id}
  end

  defp gated_session_end(dir) do
    marker = Path.join(dir, "session-end.log")
    gate = Path.join(dir, "session-end.release")
    on_exit(fn -> File.touch(gate) end)

    hook = %Sigma.Coding.Hooks.Spec{
      event: :session_end,
      matcher: :any,
      handler: %Sigma.Coding.Hooks.Spec.Command{
        cmd:
          "printf 'once\\n' >> #{quote_shell(marker)}; while ! test -f #{quote_shell(gate)}; do sleep 0.01; done",
        timeout_ms: 10_000
      },
      origin: {:user, dir},
      trusted?: true,
      dialect: :codex
    }

    {hook, marker, gate}
  end

  defp incident_records(dir) do
    Path.wildcard(Path.join([dir, ".incidents", "*", "*.json"]))
    |> Enum.map(&(&1 |> File.read!() |> Formata.JSON.decode!()))
  end

  defp eventually(fun, attempts \\ 250)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    if fun.(),
      do: true,
      else:
        (
          Process.sleep(10)
          eventually(fun, attempts - 1)
        )
  end

  defp session_options(dir, path, hooks) do
    [
      cwd: dir,
      transcript_path: path,
      native_tools: true,
      native_memory_root: Path.join(dir, "memories"),
      provider: Provider,
      model: %{id: "test", provider: "test", api: "openai-responses"},
      tools: [LostRead],
      hook_specs: hooks,
      options: [test_pid: self()]
    ]
  end

  defp assert_incomplete_ownership_rejected(dir, source, identity) do
    evidence_path = Path.join(source <> ".subagents", "lifetime-recovery.etf")
    original = evidence_path |> File.read!() |> :erlang.binary_to_term([:safe])

    for missing <- ["registry_owner", "manager"] do
      target = Path.join(dir, "missing-#{missing}.jsonl")
      File.cp!(source, target)
      File.cp_r!(source <> ".runtime", target <> ".runtime")
      target_evidence = Path.join(target <> ".subagents", "lifetime-recovery.etf")
      File.mkdir_p!(Path.dirname(target_evidence))

      manifests =
        Map.new(original.manifests, fn {id, manifest} ->
          if manifest["subject"]["kind"] == "session" do
            obligations = Enum.reject(manifest["obligations"], &(&1["kind"] == missing))

            changed =
              Evidence.manifest(
                manifest["subject"],
                manifest["run_refs"],
                obligations,
                manifest["admission_fence_ref"]
              )

            {changed["manifest_id"], changed}
          else
            {id, manifest}
          end
        end)

      # Corrupt only an independent copy, before any continuation decision, to
      # verify the public ownership gate rather than an existing decision CAS.
      evidence =
        Map.reject(original.evidence, fn {key, _} ->
          String.starts_with?(key, "continuation-request:")
        end)

      bytes =
        :erlang.term_to_binary(%{
          original
          | manifests: manifests,
            continuations: %{},
            evidence: evidence
        })

      File.write!(target_evidence, bytes)

      assert {:error, %Error{class: :unknown_outcome}} =
               LifetimeEvidence.prepare_continuation(target, identity, "continue-first")

      assert File.read!(target_evidence) == bytes
    end
  end

  defp open_writer(transcript) do
    {:ok, writer} =
      LifetimeRecovery.start_link(transcript: transcript, root_header_id: "header")

    on_exit(fn ->
      if Process.alive?(writer), do: LifetimeRecovery.retire(writer)
    end)

    writer
  end

  defp quote_shell(text), do: "'" <> String.replace(text, "'", "'\\''") <> "'"
end
