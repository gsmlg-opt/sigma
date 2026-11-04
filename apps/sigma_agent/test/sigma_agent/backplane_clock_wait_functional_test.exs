defmodule Sigma.Agent.BackplaneClockWaitFunctionalTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.ToolEffects
  alias Backplane.AgentRuntime.Codex.{ResourceRegistry, Session}
  alias Backplane.AgentRuntime.Codex.Reconciliation.Evidence
  alias Sigma.Agent.Backplane.{ChildIO, CodexResources, Store}
  alias Sigma.Agent.{Runtime, Subagents}
  alias Sigma.Coding.Hooks.Spec
  alias Sigma.Coding.Hooks.Spec.Command
  alias Sigma.Session.{Log, Writer}

  @moduletag :tmp_dir
  @moduletag :codex_alignment_functional
  @moduletag timeout: 30_000
  @root "clock-wait"

  defmodule Provider do
    @behaviour Sigma.Ai.Provider
    def output_token_limit(_, _), do: 2_000

    def stream(params) do
      send(params.options[:test_pid], {:clock_provider, self(), params})

      receive do
        {:clock_response, content} ->
          reason = if Enum.any?(content, &(&1.type == :tool_call)), do: :tool_use, else: :stop

          message = %{
            role: :assistant,
            content: content,
            stop_reason: reason,
            usage: %{input: 1, output: 1, total_tokens: 2},
            model: "clock-wait",
            provider: "clock-wait",
            api: "openai-responses",
            timestamp: System.system_time(:millisecond)
          }

          [{:start, %{message | content: []}}, {:done, reason, message}]
      end
    end
  end

  setup %{tmp_dir: dir} do
    path = Path.join(dir, "root.jsonl")
    hook_log = Path.join(dir, "post-hooks.jsonl")

    on_exit(fn ->
      case Runtime.lookup(dir, :supervisor) do
        nil -> :ok
        pid -> DynamicSupervisor.terminate_child(Sigma.Agent.DynamicSupervisor, pid)
      end
    end)

    assert {:ok, handle} =
             Runtime.get_session(dir, @root,
               cwd: dir,
               transcript_path: path,
               native_tools: true,
               native_memory_root: Path.join(dir, "memories"),
               provider: Provider,
               model: %{id: "clock-wait", provider: "clock-wait", api: "openai-responses"},
               tools: [],
               hook_specs: [
                 %Spec{
                   event: :post_tool_use,
                   matcher: :any,
                   dialect: :codex,
                   origin: {:user, dir},
                   trusted?: true,
                   handler: %Command{
                     cmd: "cat >> '#{hook_log}'; printf '\\n' >> '#{hook_log}'",
                     timeout_ms: 5_000
                   }
                 }
               ],
               options: [test_pid: self()]
             )

    :ok = Sigma.Agent.subscribe(handle.agent)
    assert {:accepted, _} = Sigma.Agent.prompt(handle.agent, "Exercise native clock retirement")

    %{
      agent: handle.agent,
      host: Runtime.lookup(dir, @root, :subagents),
      writer: Runtime.lookup(dir, @root, :writer),
      root: provider!(@root),
      path: path,
      dir: dir,
      hook_log: hook_log
    }
  end

  test "immediate root clock cancellation with PostToolUse retains exact proof and permits full retirement",
       c do
    {root, effect} = patch_once!(c.root, c)
    native = native!(c.host)
    monitor = Process.monitor(native.session)
    assert {:ok, store} = Store.open(path: c.path <> ".runtime")
    hooks = File.read!(c.hook_log)
    send_sleep(root, :direct)
    assert_receive {:tool_execution_start, call_id, "clock::sleep", arguments}, 5_000
    assert {:cancelling, _} = Sigma.Agent.cancel(c.agent)
    assert_receive {:turn_cancelled}, 8_000
    assert_receive {:agent_end, _}, 5_000
    assert Sigma.Agent.status(c.agent).phase == :cancelled
    assert %{phase: :closed} = Session.status(native.session)

    assert {:ok, original} = Store.load(store, native.binding.run_id)
    assert original.run.state == :cancelled
    assert original.run.outcome["cleanup"]["certainty"] == "confirmed"

    assert [%{operation: operation}] =
             original.run.execution_intents
             |> Map.values()
             |> Enum.filter(fn intent ->
               intent.type == :tool and intent.operation.tool_call_id == call_id
             end)

    assert operation.tool_name == "clock::sleep"
    assert operation.arguments == arguments
    assert operation.run_id == native.binding.run_id
    assert operation.incarnation == native.binding.run_incarnation
    refute Map.has_key?(original.run.tool_results, operation.invocation_id)

    assert [proof] =
             original.run.outcome
             |> records()
             |> Enum.filter(&(&1["record_type"] == "native_clock_wait_retirement"))
             |> Enum.uniq()

    # Validate the authoritative invocation against the independently captured
    # native binding, without observing or gating startup before cancellation.
    operation =
      Map.put(
        operation,
        :session_binding_identity,
        Map.take(native.binding, [:run_id, :owner_id, :incarnation, :run_incarnation])
      )

    assert {:ok, ^proof} = ToolEffects.validate_retirement_record(proof, operation)
    history = history!(c.writer, c.path)
    assert_no_sleep_result!(history.messages, :direct)
    assert File.read!(c.hook_log) == hooks

    assert {:accepted, _} =
             Sigma.Agent.prompt(c.agent, "Read the clock after immediate cancellation")

    next = provider!(@root)
    refute next.params.turn_id == root.params.turn_id
    assert_receive {:DOWN, ^monitor, :process, _, _}, 5_000
    replacement = native!(c.host)
    refute replacement.session == native.session
    refute replacement.binding.resource_registry == native.binding.resource_registry
    next = current_time!(next, :direct)
    finish_root!(next, c.agent)
    assert {:ok, %{status: :confirmed}} = Sigma.Agent.retire_host(c.agent)
    assert {:ok, after_run} = Store.load(store, native.binding.run_id)
    assert after_run.run == original.run
    assert_history_prefix!(history!(c.writer, c.path), history)
    assert String.starts_with?(File.read!(c.hook_log), hooks)
    assert_effect_once!(effect, c)
  end

  for mode <- [:direct, :deno] do
    @tag clock_mode: mode
    test "root #{mode} clock cancellation preserves its exact proof through a fresh turn and retirement",
         c do
      {root, effect} = patch_once!(c.root, c)
      native = native!(c.host)
      monitor = Process.monitor(native.session)
      assert {:ok, store} = Store.open(path: c.path <> ".runtime")
      send_sleep(root, c.clock_mode)
      wait = clock_allocation!(native.binding)
      waiter_monitor = Process.monitor(wait.waiter)

      assert {:cancelling, _} = Sigma.Agent.cancel(c.agent)
      assert_receive {:turn_cancelled}, 8_000
      assert_receive {:agent_end, _}, 5_000
      assert Sigma.Agent.status(c.agent).phase == :cancelled
      assert %{phase: :closed} = Session.status(native.session)
      assert_receive {:DOWN, ^waiter_monitor, :process, _, _}, 5_000
      original = cancelled!(store, wait, native.binding, c.clock_mode)
      history = history!(c.writer, c.path)
      assert_no_sleep_result!(history.messages, c.clock_mode)

      assert {:accepted, _} =
               Sigma.Agent.prompt(c.agent, "Read the clock after actual cancellation")

      next = provider!(@root)
      refute next.params.turn_id == root.params.turn_id
      assert_receive {:DOWN, ^monitor, :process, _, _}, 5_000
      refute native!(c.host).session == native.session
      next = current_time!(next, c.clock_mode)
      finish_root!(next, c.agent)
      assert {:ok, %{status: :confirmed}} = Sigma.Agent.retire_host(c.agent)
      assert_preserved!(store, wait, original, c.writer, c.path, history, effect, c)
    end

    @tag clock_mode: mode
    test "managed child #{mode} clock interruption preserves its exact proof through same-child followup and retirement",
         c do
      send_call(c.root, "spawn_agent", %{
        "task_name" => "clock_child",
        "message" => "Exercise the native clock",
        "fork_turns" => "none"
      })

      child = provider!(:child)
      root = provider!(@root)
      refute result!(root, "spawn_agent").is_error
      {child, effect} = patch_once!(child, c)

      assert {:ok, %{children: [%{io: io, identity: identity}]}} =
               Subagents.archive_sources(c.host)

      assert identity.child_session_id == child.params.session_id
      assert {:ok, store} = ChildIO.store(io)
      assert {:ok, source} = ChildIO.archive_source(io)
      assert {:ok, metadata} = ChildIO.metadata(io)
      native = native!(io)
      monitor = Process.monitor(native.session)
      send_sleep(child, c.clock_mode)
      wait = clock_allocation!(native.binding)
      waiter_monitor = Process.monitor(wait.waiter)
      assert wait.identity.run_id == identity.run_id

      root = call!(root, "interrupt_agent", %{"target" => "/root/clock_child"})
      refute result!(root, "interrupt_agent").is_error
      assert %{phase: :closed} = Session.status(native.session)
      assert_receive {:DOWN, ^waiter_monitor, :process, _, _}, 5_000
      original = cancelled!(store, wait, native.binding, c.clock_mode)
      history = history!(source.writer, source.transcript_path)
      assert_no_sleep_result!(history.messages, c.clock_mode)

      send_call(root, "followup_task", %{
        "target" => "/root/clock_child",
        "message" => "Read a fresh clock on the same child"
      })

      next = provider!(child.params.session_id)
      root = provider!(@root)
      refute result!(root, "followup_task").is_error
      refute next.params.turn_id == child.params.turn_id
      assert_receive {:DOWN, ^monitor, :process, _, _}, 5_000
      refute native!(io).session == native.session

      assert {:ok, %{children: [%{io: ^io, identity: next_identity}]}} =
               Subagents.archive_sources(c.host)

      assert next_identity.agent_id == identity.agent_id
      assert next_identity.child_session_id == identity.child_session_id
      refute next_identity.run_id == identity.run_id
      next = current_time!(next, c.clock_mode)
      respond(next, "Child clock completed")
      root = call!(root, "wait_agent", %{"timeout_ms" => 10_000})
      refute result!(root, "wait_agent").is_error
      finish_root!(root, c.agent)
      assert {:ok, %{status: :confirmed}} = Sigma.Agent.retire_host(c.agent)

      # Full host retirement stops child Store/Writer owners. Read the original
      # durable records through fresh public readers rather than retaining them.
      refute Process.alive?(store)
      reopened = start_supervised!({Store, path: metadata.backplane_store_path})
      assert {:ok, after_history} = Log.snapshot(source.transcript_path)
      assert_preserved_run!(reopened, wait, original)
      assert_history_prefix!(after_history, history)
      assert_effect_once!(effect, c)
    end
  end

  defp native!(owner) do
    # Observe only Sigma's host-owned resource reference; all lifetime inspection
    # and clock identities below come from the public resource APIs.
    resources = :sys.get_state(owner).codex_resources
    %{binding: binding, session: session} = CodexResources.retirement_context(resources)
    assert is_map(binding)
    %{session: session, binding: binding}
  end

  defp clock_allocation!(binding, attempts \\ 500)
  defp clock_allocation!(_binding, 0), do: flunk("Native clock resource was not allocated")

  defp clock_allocation!(binding, attempts) do
    assert {:ok, entries} =
             ResourceRegistry.owner_status(binding.resource_registry, binding.owner_id)

    clock =
      Enum.find_value(entries, fn
        %{kind: :resource, status: :active, id: id} ->
          handle = %{
            resource_id: id,
            owner_id: binding.owner_id,
            incarnation: binding.incarnation
          }

          case ResourceRegistry.fetch(binding.resource_registry, handle, binding.owner_id) do
            {:ok, %{identity: %{tool_name: "clock::sleep"}} = value} -> value
            _ -> nil
          end

        _ ->
          nil
      end)

    if clock do
      assert clock.identity.run_id == binding.run_id
      assert Process.alive?(clock.waiter)
      clock
    else
      Process.sleep(10)
      clock_allocation!(binding, attempts - 1)
    end
  end

  defp cancelled!(store, wait, binding, mode) do
    assert {:ok, original} = Store.load(store, wait.identity.run_id)
    assert original.run.state == :cancelled
    assert original.run.outcome["cleanup"]["certainty"] == "confirmed"
    records = records(original.run.outcome) |> Enum.uniq()
    assert [clock] = Enum.filter(records, &(&1["record_type"] == "native_clock_wait_retirement"))
    assert {:ok, identity} = Evidence.public(wait.identity)
    assert clock["identity"] == identity

    assert identity["session_binding_identity"] == %{
             "owner_id" => binding.owner_id,
             "incarnation" => binding.incarnation,
             "run_id" => binding.run_id,
             "run_incarnation" => identity["incarnation"]
           }

    assert clock["provenance"]["session_binding_identity"] == identity["session_binding_identity"]
    assert clock["executor_down"] == true
    assert clock["resources"] == "confirmed"
    assert clock["local_cleanup"] == "confirmed"
    assert clock["outcome"] == "unknown"
    cancellation = clock["cancellation"]
    assert cancellation["record_type"] == "native_clock_cancellation"
    assert cancellation["registration_id"] == wait.registration
    assert cancellation["wait_generation"] == wait.generation
    assert cancellation["stop_generation"] == clock["stop_generation"]
    assert cancellation["completion_gate"] == "closed"
    assert cancellation["timer_retired"] == true
    assert cancellation["waiter_down"] == true
    assert cancellation["local_cleanup"] == "confirmed"

    if mode == :deno do
      assert [outer] = Enum.filter(records, &(&1["record_type"] == "code_mode_retirement"))
      assert outer["identity"]["tool_name"] == "exec"
      assert identity["enclosing_invocation_id"] == outer["identity"]["invocation_id"]
      assert outer["identity"]["run_id"] == identity["run_id"]
      assert outer["identity"]["session_binding_identity"] == identity["session_binding_identity"]
      assert outer["executor_down"] == true
      assert outer["resources"] == "confirmed"
      assert [nested] = outer["nested"]
      assert nested["kind"] == "native_clock_wait_retirement"
      assert nested["identity"] == identity
      assert nested["evidence_digest"] == clock["retirement_digest"]
    end

    original
  end

  defp records(%{"record_type" => _} = record), do: [record]
  defp records(map) when is_map(map), do: map |> Map.values() |> Enum.flat_map(&records/1)
  defp records(list) when is_list(list), do: Enum.flat_map(list, &records/1)
  defp records(_), do: []

  defp patch_once!(provider, c) do
    path = Path.join(c.dir, "clock-once.txt")
    patch = "*** Begin Patch\n*** Add File: clock-once.txt\n+once 汉字\n*** End Patch"
    provider = call!(provider, "apply_patch", patch)
    refute result!(provider, "apply_patch").is_error
    assert File.read!(path) == "once 汉字\n"
    {provider, %{path: path, bytes: File.read!(path), stat: effect_stat(path)}}
  end

  defp assert_preserved!(store, wait, original, writer, path, history, effect, c) do
    assert_preserved_run!(store, wait, original)
    assert_history_prefix!(history!(writer, path), history)
    assert_effect_once!(effect, c)
  end

  defp assert_preserved_run!(store, wait, original) do
    assert {:ok, after_run} = Store.load(store, wait.identity.run_id)
    assert after_run.run == original.run
  end

  defp history!(writer, path) do
    assert {:ok, _} = Writer.flush(writer)
    assert {:ok, history} = Log.snapshot(path)
    history
  end

  defp assert_history_prefix!(after_history, before_history) do
    assert Enum.take(after_history.messages, length(before_history.messages)) ==
             before_history.messages
  end

  defp assert_effect_once!(effect, c) do
    assert File.read!(effect.path) == effect.bytes
    assert effect_stat(effect.path) == effect.stat

    hooks =
      c.hook_log |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

    assert Enum.count(hooks, &(&1["tool_name"] == "apply_patch")) == 1
    refute Enum.any?(hooks, &(&1["tool_name"] == "clock::sleep"))
    refute_receive {:clock_provider, _, _}, 0
  end

  defp effect_stat(path),
    do: path |> File.stat!(time: :posix) |> Map.take([:size, :mtime, :inode])

  defp assert_no_sleep_result!(messages, mode) do
    name = if mode == :deno, do: "exec", else: "clock::sleep"
    refute Enum.any?(messages, &(Map.get(&1, :tool_name) == name))
  end

  defp send_sleep(provider, :direct),
    do: send_call(provider, "clock::sleep", %{"duration_ms" => 60_000})

  defp send_sleep(provider, :deno) do
    assert is_binary(System.find_executable("deno"))
    send_call(provider, "exec", "return await tools.clock__sleep({duration_ms:60000});")
  end

  defp current_time!(provider, mode) do
    {name, args} =
      if mode == :deno,
        do: {"exec", "return await tools.clock__curr_time({});"},
        else: {"clock::curr_time", %{}}

    next = call!(provider, name, args)
    result = result!(next, name)
    refute result.is_error
    assert [%{type: :text, text: json}] = result.content
    value = Jason.decode!(json)
    value = if mode == :deno, do: value["value"], else: value
    assert value["current_time"] =~ ~r/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} UTC$/
    next
  end

  defp provider!(session) do
    receive do
      {:clock_provider, pid, %{session_id: "child_" <> _} = params} when session == :child ->
        %{pid: pid, params: params}

      {:clock_provider, pid, %{session_id: ^session} = params} ->
        %{pid: pid, params: params}

      {:turn_error, error} ->
        flunk("Clock turn failed: #{inspect(error)}")
    after
      8_000 -> flunk("Clock Provider did not start for #{session}")
    end
  end

  defp send_call(provider, name, arguments) do
    id = "clock-#{System.unique_integer([:positive])}"

    send(
      provider.pid,
      {:clock_response,
       [
         %{
           type: :tool_call,
           id: id,
           name: name,
           arguments: arguments,
           input_kind: if(is_binary(arguments), do: :custom, else: :function)
         }
       ]}
    )
  end

  defp call!(provider, name, arguments) do
    send_call(provider, name, arguments)
    provider!(provider.params.session_id)
  end

  defp result!(provider, name) do
    Enum.find(Enum.reverse(provider.params.context.messages), &(Map.get(&1, :tool_name) == name)) ||
      flunk("Missing #{name} result")
  end

  defp respond(provider, text),
    do: send(provider.pid, {:clock_response, [%{type: :text, text: text}]})

  defp finish_root!(provider, agent) do
    turn_id = Sigma.Agent.status(agent).turn_id
    respond(provider, "Clock completed")
    assert_receive {:turn_completed, ^turn_id}, 5_000
    assert_receive {:agent_end, _}, 5_000
    assert Sigma.Agent.status(agent).phase == :completed
  end
end
