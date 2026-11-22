defmodule Sigma.Agent.BackplaneLifetimeContinuationTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.Codex.Reconciliation.Evidence
  alias Backplane.AgentRuntime.Error

  alias Sigma.Agent.Backplane.{
    CodexResources,
    LifetimeEvidence,
    LifetimeRecovery,
    RootRetirement,
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
      send(observer, {:original_read, content})
      {:error, Sigma.Coding.ToolError.new(:unknown_outcome, "tool completion was lost")}
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
  test "an actual stopped read with a lost completion prepares one continuation and keeps the unknown run",
       %{tmp_dir: dir} do
    {path, handle, run_id} = failed_read!(dir)
    state = :sys.get_state(handle.agent)
    host = :sys.get_state(state.subagents)
    writer = host.lifetime_recovery
    header = LifetimeRecovery.scope(writer)
    identity = %{thread_id: header, run_id: run_id, incarnation: 1}
    assert :ok = LifetimeRecovery.retire_executor(writer, identity)
    assert {:ok, %{status: :confirmed}} = native = CodexResources.close(host.codex_resources)
    assert :ok = LifetimeEvidence.finalize(writer, host.manager)

    assert :ok =
             LifetimeEvidence.capture_for_continuation(
               CodexResources.retirement_context(host.codex_resources)
             )

    evidence_path = Path.join(path <> ".subagents", "lifetime-recovery.etf")
    evidence_bytes = File.read!(evidence_path)

    assert {:error, %Error{class: :unknown_outcome}} =
             LifetimeEvidence.prepare_continuation(path, identity, "continue-first")

    assert File.read!(evidence_path) == evidence_bytes

    facts = RootRetirement.close(state, %{native: native}, :normal)
    assert {:ok, %{status: :confirmed}} = facts.result
    assert {:ok, original} = Store.load(state.backplane_store, run_id)
    assert original.run.state == :unknown_outcome
    journal = File.read!(path)
    assert_incomplete_ownership_rejected(dir, path, identity)

    assert {:ok, decision} =
             LifetimeEvidence.prepare_continuation(path, identity, "continue-first")

    assert [%{"tool_call_id" => "lost-call", "tool_name" => "lost_read"}] =
             decision["unresolved_tools"]

    assert decision["historical_outcome"]["state"] == "unknown_outcome"

    assert {:ok, ^decision} =
             LifetimeEvidence.prepare_continuation(path, identity, "continue-first")

    assert {:ok, ^decision} = LifetimeEvidence.read_continuation(path, identity)
    accepted_evidence = File.read!(evidence_path)
    assert :ok = LifetimeEvidence.refresh(path, header)
    assert File.read!(evidence_path) == accepted_evidence

    assert {:error, %Error{class: :resource_conflict}} =
             LifetimeEvidence.prepare_continuation(path, identity, "different-click")

    assert {:ok, ^original} = Store.load(state.backplane_store, run_id)
    assert File.read!(path) == journal
    refute_receive {:original_read, _}, 0
    refute_receive {:continuation_provider, _, _}, 0
  end

  @tag capture_log: true
  test "orderly shutdown after a lost completion preserves real closure before the first Continue",
       %{tmp_dir: dir} do
    marker = Path.join(dir, "session-end.log")

    hook = %Sigma.Coding.Hooks.Spec{
      event: :session_end,
      matcher: :any,
      handler: %Sigma.Coding.Hooks.Spec.Command{
        cmd: "printf 'once\\n' >> '#{marker}'",
        timeout_ms: 5_000
      },
      origin: {:user, dir},
      trusted?: true,
      dialect: :codex
    }

    {path, handle, source} = failed_read!(dir, [hook])
    state = :sys.get_state(handle.agent)
    assert {:ok, original} = Store.load(state.backplane_store, source)
    assert {:ok, _} = Sigma.Session.Writer.flush(state.writer)
    journal = File.read!(path)

    assert :ok =
             DynamicSupervisor.terminate_child(
               Sigma.Agent.DynamicSupervisor,
               Runtime.lookup(dir, :supervisor)
             )

    assert File.read!(marker) == "once\n"

    evidence =
      Path.join(path <> ".subagents", "lifetime-recovery.etf")
      |> File.read!()
      |> :erlang.binary_to_term([:safe])

    assert evidence.continuations == %{}

    refute Enum.any?(evidence.evidence, fn {key, _} ->
             String.starts_with?(key, "continuation-request:")
           end)

    hosts =
      Path.join(path <> ".runtime", "host-retirement.etf")
      |> File.read!()
      |> :erlang.binary_to_term([:safe])

    assert [host] = Map.values(hosts.hosts)
    assert host.async_hooks == %{status: :confirmed}
    assert %{status: :confirmed, dispatch: :completed} = host.session_end
    assert File.read!(path) == journal

    assert {:ok, reopened} =
             Runtime.get_session(dir, "source", session_options(dir, path, [hook]))

    :ok = Sigma.Agent.subscribe(reopened.agent)
    assert {:ok, ^original} = Store.load(:sys.get_state(reopened.agent).backplane_store, source)

    assert {:accepted, %{turn_id: target}} =
             Sigma.Agent.prompt(reopened.agent, "fresh work", continuation_source: source)

    assert target != source
    assert_receive {:continuation_provider, provider, request}, 5_000
    assert request.turn_id == target
    send(provider, {:respond, [%{type: :text, text: "fresh reply"}]})
    assert_receive {:agent_end, _}, 5_000
    assert {:ok, ^original} = Store.load(:sys.get_state(reopened.agent).backplane_store, source)
    refute_receive {:original_read, _}, 0
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

  defp failed_read!(dir, hooks \\ []) do
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

    assert_receive {:original_read, "original data"}, 5_000
    assert_receive {:agent_end, _}, 5_000
    {path, handle, run_id}
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

      bytes = :erlang.term_to_binary(%{original | manifests: manifests})
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
end
