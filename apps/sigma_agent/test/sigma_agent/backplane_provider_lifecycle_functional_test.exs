defmodule Sigma.Agent.BackplaneProviderLifecycleFunctionalTest do
  use ExUnit.Case, async: false

  alias Sigma.Agent.{Runtime, Subagents}
  alias Sigma.Agent.Backplane.{ChildIO, GoalStore, Store}

  @moduletag :tmp_dir
  @session "provider-lifecycle"

  defmodule Provider do
    @behaviour Sigma.Ai.Provider
    def output_token_limit(_model, _options), do: 2_000

    def stream(request) do
      send(request.options[:test_pid], {:lifecycle_provider, self(), request})

      receive do
        {:lifecycle_response, content} ->
          reason = if Enum.any?(content, &(&1.type == :tool_call)), do: :tool_use, else: :stop

          message = %{
            role: :assistant,
            content: content,
            stop_reason: reason,
            usage: %{input: 7, output: 3, total_tokens: 10},
            model: "provider-lifecycle",
            provider: "provider-lifecycle",
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
      mode = Agent.get(control, & &1)

      rejected =
        if Path.basename(path) == "provider-lifecycle.etf" do
          %{attempts: attempts} = :erlang.binary_to_term(bytes, [:safe])

          mode == :reject_observation or
            (mode == :reject_termination and
               Enum.any?(attempts, fn {_key, entry} -> entry.status == :stopped end))
        end

      if rejected,
        do: {:error, :injected_provider_lifecycle_write_failure},
        else: Store.FileSystem.write_atomic(path, bytes)
    end
  end

  setup %{tmp_dir: dir} do
    {:ok, control} = Agent.start_link(fn -> :allow end)
    path = Path.join(dir, "root.jsonl")

    {:ok, store} =
      Store.start_link(path: path <> ".runtime", filesystem: {FaultableFileSystem, control})

    assert {:ok, handle} =
             Runtime.get_session(dir, @session,
               cwd: dir,
               transcript_path: path,
               native_tools: true,
               native_memory_root: Path.join(dir, "memories"),
               backplane_store: store,
               provider: Provider,
               model: %{
                 id: "provider-lifecycle",
                 provider: "provider-lifecycle",
                 api: "openai-responses"
               },
               tools: [],
               hook_specs: [],
               options: [test_pid: self()]
             )

    assert :ok = Sigma.Agent.subscribe(handle.agent)

    on_exit(fn ->
      if Process.alive?(control), do: Agent.update(control, fn _ -> :allow end)

      case Runtime.lookup(dir, :supervisor) do
        nil -> :ok
        pid -> DynamicSupervisor.terminate_child(Sigma.Agent.DynamicSupervisor, pid)
      end

      GoalStore.retire(Path.join(path <> ".subagents", "goal"))
      if Process.alive?(store), do: Store.retire(store)
      if Process.alive?(control), do: Agent.stop(control)
    end)

    %{
      dir: dir,
      path: path,
      store: store,
      control: control,
      agent: handle.agent,
      host: Runtime.lookup(dir, @session, :subagents)
    }
  end

  test "actual root attempts retain exact worker exits across turns, generations and Store reopen",
       c do
    first = prompt!(c)
    first_identity = active!(c.store, first)
    assert_observing!(c.store, first_identity)

    send_call(first, "update_plan", %{"plan" => [%{"step" => "observe", "status" => "completed"}]})

    second = provider!(@session)
    second_identity = active!(c.store, second)
    assert first_identity != second_identity
    assert first_identity.run_id == second_identity.run_id
    assert_stopped!(c.store, first_identity)
    finish!(second)
    assert_stopped!(c.store, second_identity)
    assert {:ok, %{status: :confirmed}} = Subagents.close(c.host)

    third = prompt!(c)
    third_identity = active!(c.store, third)
    assert third_identity.run_id != first_identity.run_id
    finish!(third)
    assert_stopped!(c.store, third_identity)
    original_runtime = runtime_bytes(c.path)
    assert {:ok, ledger} = Store.provider_lifecycle(c.store, :all)
    assert map_size(ledger.attempts) == 3
    assert :ok = Store.flush_provider_lifecycle(c.store)
    assert runtime_bytes(c.path) === original_runtime
    assert {:ok, %{status: :confirmed}} = Sigma.Agent.retire_host(c.agent)
    stop_repository!(c)
    assert :ok = Store.retire(c.store)
    frozen = File.read!(receipt_path(c.path))
    mtime = File.stat!(receipt_path(c.path), time: :posix).mtime
    reopened = start_supervised!({Store, path: c.path <> ".runtime"}, id: :reopened)
    assert {:ok, ^ledger} = Store.provider_lifecycle(reopened, :all)
    assert File.read!(receipt_path(c.path)) === frozen
    assert File.stat!(receipt_path(c.path), time: :posix).mtime == mtime
    assert runtime_bytes(c.path) === original_runtime
    refute_receive {:lifecycle_provider, _, _}, 50
  end

  test "managed child and followup observe their actual worker in their own Store", c do
    root = prompt!(c)

    send_call(root, "spawn_agent", %{
      "task_name" => "contributor",
      "message" => "Respond",
      "fork_turns" => "none"
    })

    child = provider!(:child)
    root = provider!(@session)
    assert {:ok, sources} = Subagents.archive_sources(c.host)
    [source] = sources.children
    assert {:ok, store} = ChildIO.store(source.io)
    first = active!(store, child, source.identity.run_id)
    assert_observing!(store, first)
    respond!(child)
    assert_stopped!(store, first)
    finish!(root)

    root = prompt!(c)

    send_call(root, "followup_task", %{
      "target" => "/root/contributor",
      "message" => "Respond again"
    })

    child = provider!(:child)
    root = provider!(@session)
    assert {:ok, metadata} = ChildIO.metadata(source.io)
    second = active!(store, child, metadata.identity.run_id)
    assert second.run_id != first.run_id
    assert child.request.session_id == source.identity.child_session_id
    respond!(child)
    assert_stopped!(store, second)
    finish!(root)
    assert {:ok, ledger} = Store.provider_lifecycle(store, :all)
    assert map_size(ledger.attempts) == 2
    assert {:ok, root_ledger} = Store.provider_lifecycle(c.store, :all)

    assert Enum.all?(root_ledger.attempts, fn {identity, _} ->
             identity.run_id not in [first.run_id, second.run_id]
           end)
  end

  test "failed observation persistence prevents a new Provider request", c do
    Agent.update(c.control, fn _ -> :reject_observation end)
    assert {:accepted, _} = Sigma.Agent.prompt(c.agent, "Do not dispatch without the observation")
    assert_receive {:agent_end, _}, 8_000
    refute_receive {:lifecycle_provider, _, _}, 50
    assert {:ok, %{attempts: attempts}} = Store.provider_lifecycle(c.store, :all)
    assert attempts == %{}
  end

  test "failed child DOWN persistence retains its owner until an exact close retry", c do
    root = prompt!(c)

    send_call(root, "spawn_agent", %{
      "task_name" => "contributor",
      "message" => "Respond",
      "fork_turns" => "none"
    })

    child = provider!(:child)
    root = provider!(@session)
    assert {:ok, %{children: [source]}} = Subagents.archive_sources(c.host)
    assert {:ok, store} = ChildIO.store(source.io)
    assert {:ok, metadata} = ChildIO.metadata(source.io)
    identity = active!(store, child, metadata.identity.run_id)
    receipt = Path.join(metadata.backplane_store_path, "provider-lifecycle.etf")
    backup = receipt <> ".saved"
    File.rename!(receipt, backup)
    File.mkdir!(receipt)

    try do
      respond!(child)
      finish!(root)
      assert {:error, %{cause: :eisdir}} = Store.provider_lifecycle(store, identity)
      assert {:error, error} = Subagents.close(c.host)
      assert inspect(error) =~ "eisdir"
      assert Process.alive?(source.io)
      assert Process.alive?(store)
    after
      File.rmdir!(receipt)
      File.rename!(backup, receipt)
    end

    assert {:ok, %{status: :confirmed}} = Subagents.close(c.host)
    refute Process.alive?(source.io)
    refute Process.alive?(store)

    reopened =
      start_supervised!({Store, path: metadata.backplane_store_path}, id: :child_reopened)

    assert_stopped!(reopened, identity)
    refute_receive {:lifecycle_provider, _, _}, 50
  end

  test "a failed DOWN receipt retains its cause and retries only persistence", c do
    provider = prompt!(c)
    identity = active!(c.store, provider)
    Agent.update(c.control, fn _ -> :reject_termination end)
    finish!(provider)

    assert {:error, %{cause: :injected_provider_lifecycle_write_failure}} =
             Store.provider_lifecycle(c.store, identity)

    assert {:error, %{cause: :injected_provider_lifecycle_write_failure}} = Store.retire(c.store)
    assert Process.alive?(c.store)
    original_runtime = runtime_bytes(c.path)
    Agent.update(c.control, fn _ -> :allow end)
    assert :ok = Store.flush_provider_lifecycle(c.store)
    assert_stopped!(c.store, identity)
    frozen = File.read!(receipt_path(c.path))
    mtime = File.stat!(receipt_path(c.path), time: :posix).mtime
    assert :ok = Store.flush_provider_lifecycle(c.store)
    assert File.read!(receipt_path(c.path)) === frozen
    assert File.stat!(receipt_path(c.path), time: :posix).mtime == mtime
    assert runtime_bytes(c.path) === original_runtime
    refute_receive {:lifecycle_provider, _, _}, 50
  end

  test "Store replacement preserves an unobserved termination as incomplete", c do
    provider = prompt!(c)
    identity = active!(c.store, provider)
    assert_observing!(c.store, identity)
    assert {:error, %{class: :unknown_outcome}} = Store.retire(c.store)
    assert Process.alive?(provider.pid)
    assert :ok = GenServer.stop(c.store, :normal)
    frozen = File.read!(receipt_path(c.path))
    reopened = start_supervised!({Store, path: c.path <> ".runtime"}, id: :reopened)
    assert_observing!(reopened, identity)
    assert Process.alive?(provider.pid)
    stop_repository!(c)
    refute Process.alive?(provider.pid)
    assert_observing!(reopened, identity)
    assert File.read!(receipt_path(c.path)) === frozen
    refute_receive {:lifecycle_provider, _, _}, 50
  end

  defp prompt!(c) do
    assert {:accepted, _} = Sigma.Agent.prompt(c.agent, "Perform actual Provider work")
    provider!(@session)
  end

  defp provider!(session) do
    receive do
      {:lifecycle_provider, pid, %{session_id: "child_" <> _} = request} when session == :child ->
        %{pid: pid, request: request}

      {:lifecycle_provider, pid, %{session_id: ^session} = request} ->
        %{pid: pid, request: request}
    after
      8_000 -> flunk("actual Provider did not start")
    end
  end

  defp active!(store, provider), do: active!(store, provider, provider.request.turn_id)

  defp active!(store, _provider, runtime_run) do
    assert {:ok, %{run: %{active_provider: identity}}} =
             Store.load(store, runtime_run)

    assert is_map(identity)
    assert identity.run_id == runtime_run
    identity
  end

  defp assert_observing!(store, identity),
    do:
      assert(
        {:ok, %{identity: ^identity, status: :observing}} =
          Store.provider_lifecycle(store, identity)
      )

  defp assert_stopped!(store, identity) do
    assert eventually(fn ->
             match?({:ok, %{status: :stopped}}, Store.provider_lifecycle(store, identity))
           end)

    assert {:ok, %{identity: ^identity, status: :stopped}} =
             Store.provider_lifecycle(store, identity)
  end

  defp respond!(provider) do
    monitor = Process.monitor(provider.pid)
    send(provider.pid, {:lifecycle_response, [%{type: :text, text: "Finished"}]})
    assert_receive {:DOWN, ^monitor, :process, _, _}, 8_000
  end

  defp finish!(provider) do
    respond!(provider)
    assert_receive {:agent_end, _}, 8_000
  end

  defp send_call(provider, name, arguments) do
    send(
      provider.pid,
      {:lifecycle_response,
       [
         %{
           type: :tool_call,
           name: name,
           id: "lifecycle-#{System.unique_integer([:positive])}",
           input_kind: :function,
           arguments: arguments
         }
       ]}
    )
  end

  defp stop_repository!(c) do
    assert :ok =
             DynamicSupervisor.terminate_child(
               Sigma.Agent.DynamicSupervisor,
               Runtime.lookup(c.dir, :supervisor)
             )
  end

  defp receipt_path(path), do: Path.join(path <> ".runtime", "provider-lifecycle.etf")

  defp runtime_bytes(path),
    do: Map.new(Path.wildcard(path <> ".runtime/*.runtime"), &{&1, File.read!(&1)})

  defp eventually(fun, left \\ 300)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, left) do
    if fun.(),
      do: true,
      else:
        (
          Process.sleep(10)
          eventually(fun, left - 1)
        )
  end
end
