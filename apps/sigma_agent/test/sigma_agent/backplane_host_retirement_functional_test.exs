defmodule Sigma.Agent.BackplaneHostRetirementFunctionalTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.{Conversation, Error}
  alias Backplane.AgentRuntime.Codex.Session
  alias Backplane.AgentRuntime.Store, as: RuntimeStore
  alias Sigma.Agent.Backplane.{ChildIO, CodexResources, HostRetirement, Store}
  alias Sigma.Coding.Hooks.AsyncRuntime
  alias Sigma.Session.Writer

  @moduletag :tmp_dir
  @moduletag :host_retirement_functional

  defmodule Provider do
    @behaviour Sigma.Ai.Provider

    def output_token_limit(_model, _options), do: 2_000

    def stream(request) do
      send(request.options[:test_pid], {:retirement_provider, self(), request})

      receive do
        {:retirement_response, content} ->
          reason = if Enum.any?(content, &(&1.type == :tool_call)), do: :tool_use, else: :stop

          message = %{
            role: :assistant,
            content: content,
            stop_reason: reason,
            usage: %{input: 7, output: 3},
            timestamp: System.system_time(:millisecond)
          }

          [{:start, %{message | content: []}}, {:done, reason, message}]
      end
    end
  end

  defmodule FileSystem do
    def ensure_dir(_control, path), do: Store.FileSystem.ensure_dir(path)
    def read(_control, path), do: Store.FileSystem.read(path)

    def write_atomic(control, path, bytes) do
      fail? =
        Agent.get_and_update(control, fn state ->
          {state.fail?, %{state | writes: state.writes + 1}}
        end)

      if fail?,
        do: {:error, :injected_retirement_write},
        else: Store.FileSystem.write_atomic(path, bytes)
    end
  end

  test "private receipt retries preserve all memberships and exact Runtime snapshots", %{
    tmp_dir: dir
  } do
    control = start_supervised!({Agent, fn -> %{fail?: false, writes: 0} end})
    path = Path.join(dir, "runtime")

    store =
      start_supervised!({Store, path: path, filesystem: {FileSystem, control}},
        restart: :temporary
      )

    base = host_identity("first-host")
    first = membership(base, "run-1", "native-1", 1)
    second = membership(base, "run-2", "native-1", 1)
    third = membership(base, "run-3", "native-2", 2)
    reopened_host = membership(host_identity("second-host"), "run-4", "native-3", 3)

    run = %{
      run_id: "ordinary-run",
      incarnation: 1,
      expected_revision: 0,
      state: :queued,
      deadline: nil,
      outcome: nil,
      children: []
    }

    assert {:ok, _} =
             RuntimeStore.store(Store, store, run, %{command: {:admit, 1, %{state: :running}}})

    assert {:ok, runtime} = Store.load(store, run.run_id)
    [runtime_path] = Path.wildcard(Path.join(path, "*.runtime"))
    runtime_bytes = File.read!(runtime_path)

    for binding <- [first, second, third, reopened_host],
        do: assert(:ok == Store.register_host_binding(store, binding))

    for binding <- [first, third, reopened_host] do
      assert :ok =
               Store.record_host_retirement(store, native_identity(binding), :native, %{
                 status: :confirmed,
                 owner_id: binding.native_owner_id
               })
    end

    assert :ok = Store.record_host_retirement(store, base, :async_hooks, %{status: :confirmed})
    assert {:ok, %{status: :confirmed}} = Store.host_retirement(store, first)
    assert {:ok, %{status: :confirmed}} = Store.host_retirement(store, second)
    assert {:ok, %{status: :confirmed}} = Store.host_retirement(store, third)

    assert {:ok, %{status: :unconfirmed, async_hooks: nil}} =
             Store.host_retirement(store, reopened_host)

    writes = Agent.get(control, & &1.writes)
    assert :ok = Store.register_host_binding(store, first)
    assert :ok = Store.record_host_retirement(store, base, :async_hooks, %{status: :confirmed})
    assert Agent.get(control, & &1.writes) == writes
    assert File.read!(runtime_path) === runtime_bytes
    assert {:ok, ^runtime} = Store.load(store, run.run_id)
    assert {:ok, ledger} = Store.host_retirement(store, :all)
    assert ledger.version == 2
    assert map_size(ledger.hosts) == 2
    assert map_size(ledger.hosts[base.host_lifetime_id].bindings) == 3

    assert :ok = Store.retire(store)
    store = start_supervised!({Store, path: path}, id: :reopened_store)
    assert {:ok, ^ledger} = Store.host_retirement(store, :all)
    assert {:ok, ^runtime} = Store.load(store, run.run_id)
  end

  test "version one receipts decode without rewriting or inventing root SessionEnd", %{
    tmp_dir: dir
  } do
    identity = host_identity("legacy-host")
    member = membership(identity, "legacy-run", "legacy-native", 1)
    assert {:ok, ledger, :changed} = HostRetirement.register(HostRetirement.new(), member)

    legacy = %{
      version: 1,
      hosts: Map.new(ledger.hosts, fn {id, host} -> {id, Map.delete(host, :session_end)} end)
    }

    path = Path.join(dir, "runtime")
    File.mkdir_p!(path)
    receipt = Path.join(path, "host-retirement.etf")
    bytes = :erlang.term_to_binary(legacy)
    File.write!(receipt, bytes)
    before = File.stat!(receipt, time: :posix)
    store = start_supervised!({Store, path: path})
    assert {:ok, %{version: 2, hosts: hosts}} = Store.host_retirement(store, :all)
    assert hosts[identity.host_lifetime_id].session_end == nil
    assert {:ok, %{session_end: nil, status: :unconfirmed}} = Store.host_retirement(store, member)
    assert File.read!(receipt) === bytes
    assert File.stat!(receipt, time: :posix).mtime == before.mtime
  end

  test "root SessionEnd completion stays independent of native and async-hook close", %{
    tmp_dir: dir
  } do
    store = start_supervised!({Store, path: Path.join(dir, "runtime")})

    root = %{
      host_identity("root-host")
      | child_session_id: nil,
        transcript_header_id: "root-header"
    }

    member = membership(root, "root-run", "root-native", 1)
    assert :ok = Store.register_host_binding(store, member)
    assert :ok = Store.record_host_retirement(store, root, :async_hooks, %{status: :confirmed})

    completion = %{
      status: :confirmed,
      dispatch: :completed,
      outcome: :proceed,
      warnings: ["Hook exited with code 1."]
    }

    assert :ok = Store.record_host_retirement(store, root, :session_end, completion)

    assert {:ok,
            %{
              native: nil,
              async_hooks: %{status: :confirmed},
              session_end: ^completion,
              status: :unconfirmed
            }} =
             Store.host_retirement(store, member)

    assert :ok = Store.record_host_retirement(store, root, :session_end, completion)
  end

  test "actual native close remains retryable after its receipt write is rejected", %{
    tmp_dir: dir
  } do
    control = start_supervised!({Agent, fn -> %{fail?: false, writes: 0} end})

    store =
      start_supervised!(
        {Store, path: Path.join(dir, "runtime"), filesystem: {FileSystem, control}}
      )

    identity = host_identity("native-close-host")

    resources =
      start_supervised!(
        {CodexResources,
         workspace: dir,
         owner_pid: self(),
         memory_root: Path.join(dir, "memories"),
         host_retirement: %{store: store, identity: identity}}
      )

    assert {:ok, binding} = CodexResources.bind(resources, authority("native-close"))
    member = membership(identity, binding.run_id, binding.owner_id, binding.incarnation)
    assert {:ok, %{native: nil, async_hooks: nil}} = Store.host_retirement(store, member)
    Agent.update(control, &%{&1 | fail?: true})

    assert {:error, %Error{cause: :injected_retirement_write}} = CodexResources.close(resources)
    refute Process.alive?(binding.session)
    assert {:ok, %{native: nil, status: :unconfirmed}} = Store.host_retirement(store, member)

    Agent.update(control, &%{&1 | fail?: false})
    assert {:ok, %{status: :confirmed, owner_id: owner}} = CodexResources.close(resources)
    assert owner == binding.owner_id

    assert {:ok, %{native: %{owner_id: ^owner}, async_hooks: nil, status: :unconfirmed}} =
             Store.host_retirement(store, member)
  end

  test "a rejected binding-index write prevents admission and remains recoverable on close", %{
    tmp_dir: dir
  } do
    control = start_supervised!({Agent, fn -> %{fail?: true, writes: 0} end})

    store =
      start_supervised!(
        {Store, path: Path.join(dir, "runtime"), filesystem: {FileSystem, control}}
      )

    identity = host_identity("rejected-bind-host")

    resources =
      start_supervised!(
        {CodexResources,
         workspace: dir,
         owner_pid: self(),
         memory_root: Path.join(dir, "memories"),
         host_retirement: %{store: store, identity: identity}}
      )

    session = CodexResources.session(resources)
    native = Session.status(session)

    assert {:error, %Error{cause: :injected_retirement_write}} =
             CodexResources.bind(resources, authority("rejected-bind"))

    assert %{phase: :closed} = Session.status(session)
    assert {:ok, %{hosts: hosts}} = Store.host_retirement(store, :all)
    assert hosts == %{}

    Agent.update(control, &%{&1 | fail?: false})
    assert {:ok, %{status: :confirmed}} = CodexResources.close(resources)
    member = membership(identity, "rejected-bind", native.owner_id, native.incarnation)

    assert {:ok, %{native: %{status: :confirmed}, async_hooks: nil}} =
             Store.host_retirement(store, member)

    assert Path.wildcard(Path.join(dir, "runtime/*.runtime")) == []
  end

  test "a rejected followup binding retains its existing extension until confirmed close", %{
    tmp_dir: dir
  } do
    control = start_supervised!({Agent, fn -> %{fail?: false, writes: 0} end})

    store =
      start_supervised!(
        {Store, path: Path.join(dir, "runtime"), filesystem: {FileSystem, control}}
      )

    identity = host_identity("rejected-followup-host")

    resources =
      start_supervised!(
        {CodexResources,
         workspace: dir,
         owner_pid: self(),
         memory_root: Path.join(dir, "memories"),
         host_retirement: %{store: store, identity: identity}}
      )

    first_authority = authority("first-bind")
    assert {:ok, first} = CodexResources.bind(resources, first_authority)
    assert {:ok, context} = CodexResources.context(resources, first)
    extension = context.extension_runtime
    extension_monitor = Process.monitor(extension)
    assert Process.alive?(extension)

    assert :ok =
             Session.attach(first, %{
               authority: first_authority,
               registry: %Backplane.AgentRuntime.ToolRegistry{}
             })

    assert :ok = Session.prepare_detach(first)
    assert {:ok, %{status: :retained}} = Session.detach(first)

    first_member = membership(identity, first.run_id, first.owner_id, first.incarnation)
    second_member = membership(identity, "rejected-followup", first.owner_id, first.incarnation)
    Agent.update(control, &%{&1 | fail?: true})

    assert {:error, %Error{cause: :injected_retirement_write}} =
             CodexResources.bind(resources, authority("rejected-followup"))

    assert Process.alive?(extension)
    refute_receive {:DOWN, ^extension_monitor, :process, ^extension, _}, 0
    assert {:ok, %{native: nil}} = Store.host_retirement(store, first_member)
    assert {:error, %Error{class: :not_found}} = Store.host_retirement(store, second_member)

    Agent.update(control, &%{&1 | fail?: false})
    assert {:ok, %{status: :confirmed, owner_id: owner}} = CodexResources.close(resources)
    assert owner == first.owner_id
    refute Process.alive?(extension)
    assert_receive {:DOWN, ^extension_monitor, :process, ^extension, :normal}

    for member <- [first_member, second_member] do
      assert {:ok, %{native: %{status: :confirmed, owner_id: ^owner}, async_hooks: nil}} =
               Store.host_retirement(store, member)
    end

    assert {:ok, %{hosts: hosts}} = Store.host_retirement(store, :all)
    assert map_size(hosts[identity.host_lifetime_id].bindings) == 2
  end

  test "child retirement covers detached runs, rotated native generations and cold reopen", %{
    tmp_dir: dir
  } do
    c = child!(dir)
    {first, first_run} = run_child!(c, "first-run", true)

    assert %{result: %{is_error: false}} =
             Enum.find(first_run.run.context.conversation.messages, fn message ->
               message[:role] == :tool and message[:tool_call_id] == "retained-command"
             end)

    command_server =
      first.catalog.registry.tools["exec_command"].backend_context.context.command.server

    assert Process.alive?(command_server)
    {second, second_run} = run_child!(c, "second-run", false)
    first_binding = first.options[:session_binding]
    second_binding = second.options[:session_binding]
    assert first_binding.owner_id == second_binding.owner_id
    assert {:ok, metadata} = ChildIO.metadata(c.io)
    identity = metadata.host_retirement
    assert identity.root_header_id == c.root_header
    refute identity.root_header_id == c.identity.root_session_id

    first_member =
      membership(
        identity,
        first_binding.run_id,
        first_binding.owner_id,
        first_binding.incarnation
      )

    second_member =
      membership(
        identity,
        second_binding.run_id,
        second_binding.owner_id,
        second_binding.incarnation
      )

    assert {:ok, %{native: nil}} = Store.host_retirement(c.store, first_member)
    assert {:ok, %{status: :confirmed}} = ChildIO.reject_preparation(c.io, second.key)
    refute Process.alive?(command_server)

    assert {:ok, %{native: %{status: :confirmed}, async_hooks: nil}} =
             Store.host_retirement(c.store, first_member)

    third_identity = %{c.identity | run_id: "third-run", public_run_id: "third-run"}
    assert {:ok, third} = ChildIO.prepare(c.io, third_identity, c.authority, [])
    third_binding = third.options[:session_binding]
    refute third_binding.owner_id == first_binding.owner_id

    third_member =
      membership(
        identity,
        third_binding.run_id,
        third_binding.owner_id,
        third_binding.incarnation
      )

    assert {:ok, %{status: :confirmed, capture: :durable}} = ChildIO.retire(c.io)

    for member <- [first_member, second_member, third_member] do
      assert {:ok,
              %{
                status: :confirmed,
                native: %{status: :confirmed},
                async_hooks: %{status: :confirmed}
              }} =
               Store.host_retirement(c.store, member)
    end

    assert {:ok, ^first_run} = Store.load(c.store, "first-run")
    assert {:ok, ^second_run} = Store.load(c.store, "second-run")
    receipt_path = Path.join(c.runtime_path, "host-retirement.etf")
    bytes = File.read!(receipt_path)
    stat = File.stat!(receipt_path, time: :posix)
    assert {:ok, %{status: :confirmed}} = ChildIO.retire(c.io)
    assert File.read!(receipt_path) === bytes
    assert File.stat!(receipt_path, time: :posix).mtime == stat.mtime

    assert {:error, %Error{class: :resource_conflict}} =
             ChildIO.prepare(c.io, third_identity, c.authority, [])

    assert :ok = GenServer.stop(c.io, :normal)
    refute Process.alive?(c.store)

    reopened = start_supervised!({Store, path: c.runtime_path})
    assert {:ok, %{status: :confirmed}} = Store.host_retirement(reopened, first_member)
    assert {:ok, ^first_run} = Store.load(reopened, "first-run")
    assert File.read!(receipt_path) === bytes
    refute_receive {:retirement_provider, _, _}, 100
  end

  test "child preserves actual hook confirmation when a later receipt commit fails", %{
    tmp_dir: dir
  } do
    c = child!(dir)
    assert {:ok, prepared} = ChildIO.prepare(c.io, c.identity, c.authority, [])
    hooks = prepared.options[:provider_context].host.hook_context.hook_async_runtime
    monitor = Process.monitor(hooks)
    binding = prepared.options[:session_binding]
    assert {:ok, metadata} = ChildIO.metadata(c.io)

    member =
      membership(metadata.host_retirement, binding.run_id, binding.owner_id, binding.incarnation)

    receipt_path = Path.join(c.runtime_path, "host-retirement.etf")
    backup = receipt_path <> ".saved"
    File.rename!(receipt_path, backup)
    File.mkdir!(receipt_path)

    try do
      assert {:error, %Error{class: :execution_failure, cause: :eisdir}} = ChildIO.retire(c.io)
      refute Process.alive?(binding.session)
      assert_receive {:DOWN, ^monitor, :process, ^hooks, :normal}, 5_000
    after
      File.rmdir!(receipt_path)
      File.rename!(backup, receipt_path)
    end

    # Strict hook shutdown cannot be repeated on a dead runtime. The successful
    # original acknowledgement must survive the later failed persistence step.
    assert {:ok, %{status: :confirmed}} = ChildIO.retire(c.io)
    assert {:ok, %{status: :confirmed}} = Store.host_retirement(c.store, member)
  end

  test "an unavailable hook runtime cannot manufacture whole host retirement", %{tmp_dir: dir} do
    c = child!(dir)
    assert {:ok, prepared} = ChildIO.prepare(c.io, c.identity, c.authority, [])
    hooks = prepared.options[:provider_context].host.hook_context.hook_async_runtime
    assert :ok = AsyncRuntime.shutdown(hooks)
    failure = ChildIO.retire(c.io)
    assert {:error, {:async_runtime_shutdown_unconfirmed, _}} = failure
    assert ChildIO.retire(c.io) === failure
    binding = prepared.options[:session_binding]
    assert {:ok, metadata} = ChildIO.metadata(c.io)

    member =
      membership(metadata.host_retirement, binding.run_id, binding.owner_id, binding.incarnation)

    assert {:ok, %{native: %{status: :confirmed}, async_hooks: nil, status: :unconfirmed}} =
             Store.host_retirement(c.store, member)
  end

  defp child!(dir) do
    root_writer =
      start_supervised!(
        {Writer, storage_id: Path.join(dir, "root.jsonl"), session_id: "logical-root", cwd: dir}
      )

    assert {:ok, root_header} = Writer.append(root_writer, {:agent_start, dir})

    identity = %{
      agent_id: "child-id",
      child_session_id: "child-session",
      root_session_id: "logical-root",
      run_id: "child-run",
      public_run_id: "child-run",
      incarnation: 1,
      observer_incarnation: 1,
      agent_path: "/root/child",
      parent_agent_id: "root-id"
    }

    config = %{
      native_tools: true,
      native_memory_root: Path.join(dir, "memories"),
      model: %{
        id: "retirement",
        provider: "retirement",
        api: "openai-responses",
        context_window: 200_000
      },
      provider: Provider,
      provider_options: [test_pid: self()],
      cwd: dir,
      tools: [],
      dispatcher_opts: [],
      hook_specs: [],
      policy: nil
    }

    runtime_path = Path.join(dir, "child-runtime")

    io =
      start_supervised!(
        {ChildIO,
         config: config,
         identity: identity,
         root_header_id: root_header,
         transcript_path: Path.join(dir, "child.jsonl"),
         backplane_store_path: runtime_path},
        restart: :temporary
      )

    assert {:ok, store} = ChildIO.store(io)

    %{
      io: io,
      store: store,
      identity: identity,
      root_header: root_header,
      authority: authority("root-run"),
      runtime_path: runtime_path
    }
  end

  defp run_child!(c, run, command?) do
    identity = %{c.identity | run_id: run, public_run_id: run}
    assert {:ok, prepared} = ChildIO.prepare(c.io, identity, c.authority, [])

    conversation =
      start_supervised!({Conversation, prepared.options ++ [subscriber: self()]}, id: run)

    assert {:ok, _} = Conversation.prompt(conversation, "Perform child work")
    pid = provider!()

    pid =
      if command? do
        send(
          pid,
          {:retirement_response,
           [
             %{
               type: :tool_call,
               id: "retained-command",
               name: "exec_command",
               input_kind: :function,
               arguments: %{
                 "cmd" => "IFS= read -r line",
                 "shell" => "/bin/sh",
                 "login" => false,
                 "yield_time_ms" => 0
               }
             }
           ]}
        )

        provider!()
      else
        pid
      end

    send(pid, {:retirement_response, [%{type: :text, text: "Finished"}]})
    assert_receive {:agent_runtime, ^run, %{type: :run_completed}}, 8_000
    assert {:ok, snapshot} = Store.load(c.store, run)
    assert :ok = stop_supervised(run)
    {prepared, snapshot}
  end

  defp provider! do
    receive do
      {:retirement_provider, pid, _request} -> pid
    after
      8_000 -> flunk("actual child Provider did not start")
    end
  end

  defp authority(run),
    do: %{caller: "root", run_id: run, grants: ["exec_command"], tool_revision: 1}

  defp host_identity(host),
    do: %{
      root_header_id: "root-header",
      transcript_header_id: "child-header",
      child_session_id: "child-session",
      host_lifetime_id: host
    }

  defp membership(host, run, owner, session_incarnation),
    do:
      Map.merge(host, %{
        run_id: run,
        run_incarnation: 1,
        native_owner_id: owner,
        native_session_incarnation: session_incarnation
      })

  defp native_identity(binding), do: Map.drop(binding, [:run_id, :run_incarnation])
end
