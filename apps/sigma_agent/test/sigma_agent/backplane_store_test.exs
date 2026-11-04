defmodule Sigma.Agent.Backplane.StoreTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.Error
  alias Backplane.AgentRuntime.Store, as: RuntimeStore
  alias Backplane.AgentRuntime.StoreConformance
  alias Backplane.AgentRuntime.{Codex, Conversation}
  alias Sigma.Agent.Backplane.Store
  alias Sigma.Agent.Message
  alias Sigma.Ai.ProviderUsage

  defmodule CompletedProvider do
    def stream(request, _context) do
      if Enum.any?(request.messages, &(&1.role == :tool)) do
        [%{type: :response_completed, message: %{role: :assistant, content: "Done"}}]
      else
        [
          %{
            type: :tool_call_completed,
            tool_call: %{
              id: "cold-question",
              name: "request_user_input_async",
              arguments: %{"questions" => [%{"title" => "Continue?"}]}
            }
          },
          %{type: :response_completed, message: %{role: :assistant, content: "Issued"}}
        ]
      end
    end
  end

  defmodule FaultableFileSystem do
    def start_link, do: Agent.start_link(fn -> false end)
    def fail_next(agent), do: Agent.update(agent, fn _ -> true end)

    def ensure_dir(_agent, path), do: Store.FileSystem.ensure_dir(path)
    def read(_agent, path), do: Store.FileSystem.read(path)

    def write_atomic(agent, path, bytes) do
      if Agent.get_and_update(agent, fn fail? -> {fail?, false} end) do
        {:error, :injected_commit_failure}
      else
        Store.FileSystem.write_atomic(path, bytes)
      end
    end
  end

  setup context do
    root =
      Path.join([
        System.tmp_dir!(),
        "sigma-backplane-store-test",
        "#{context.test}-#{System.unique_integer([:positive])}"
      ])

    File.rm_rf!(root)
    File.mkdir_p!(root)
    {:ok, faults} = FaultableFileSystem.start_link()

    on_exit(fn -> File.rm_rf!(root) end)

    {:ok, root: root, faults: faults}
  end

  test "opens one local writer for an absolute runtime directory", %{root: root} do
    assert {:ok, first} = Store.open(path: root)
    assert {:ok, second} = Store.open(path: root)
    assert first == second

    assert {:error, %Error{class: :validation, message: "runtime store path must be absolute"}} =
             Store.open(path: "relative/runtime")

    assert {:error, %Error{class: :validation}} = Store.new(1)
  end

  test "passes the durable store contract using the file-backed adapter", %{
    root: root,
    faults: faults
  } do
    assert {:ok, context} = open(root, faults)

    assert {:ok,
            %{
              mode: :durable,
              checks: checks
            }} =
             StoreConformance.run(Store, context,
               run_id: "disk-#{System.unique_integer([:positive])}",
               restart: fn current -> Store.reload(current) end,
               fail_next_commit: fn _current -> FaultableFileSystem.fail_next(faults) end,
               dependent_effect_count: fn _current, _run_id -> 0 end
             )

    assert :atomic_commit in checks
    assert :terminal_reconstruction in checks
    assert :uncertain_effect_fencing in checks
  end

  test "reconstructs the exact acknowledged snapshot after a real stop and reopen", %{
    root: root,
    faults: faults
  } do
    assert {:ok, context} = open(root, faults)
    run = base_run("restart")
    outbox = [%{id: "admitted", type: :run_admitted}]

    assert {:ok, %{revision: 1, outbox: ^outbox}} =
             RuntimeStore.store(Store, context, run, %{
               command: {:admit, 10, %{state: :running}},
               outbox: outbox
             })

    assert {:ok, before_restart} = Store.load(context, run.run_id, [])
    assert {:ok, %{mode: 0o040700}} = File.stat(root)

    [record_path] = Path.wildcard(Path.join(root, "*.runtime"))
    assert {:ok, %{mode: 0o100600}} = File.stat(record_path)

    GenServer.stop(context)
    assert {:ok, reopened} = open(root, faults)
    assert {:ok, ^before_restart} = Store.load(reopened, run.run_id, [])
  end

  test "rejects a stale incarnation even when it copies the fenced revision", %{
    root: root,
    faults: faults
  } do
    assert {:ok, context} = open(root, faults)
    run = base_run("stale-incarnation")

    assert {:ok, %{revision: 1}} =
             RuntimeStore.store(Store, context, run, %{
               command: {:admit, 10, %{state: :running}}
             })

    assert {:ok, %{run: pre_fence}} = Store.load(context, run.run_id, [])

    assert {:ok, %{revision: 2, run: %{incarnation: 2}}} =
             RuntimeStore.fence(Store, context, run.run_id, 1, 1, 2)

    stale = %{pre_fence | expected_revision: 2}

    assert {:error, %Error{class: :resource_conflict}} =
             RuntimeStore.store(Store, context, stale, %{
               command:
                 {:conversation_updated, 11,
                  %{
                    run_id: stale.run_id,
                    incarnation: stale.incarnation,
                    step_id: "stale",
                    attempt_id: "stale",
                    conversation: %{messages: []}
                  }}
             })

    assert {:ok, %{revision: 2, run: %{incarnation: 2}}} =
             Store.load(context, run.run_id, [])
  end

  test "a fresh BEAM reconstructs an actual completed Conversation without starting applications",
       %{root: root, faults: faults} do
    assert {:ok, context} = open(root, faults)
    run_id = "cold-completed"
    names = ["request_user_input_async"]

    authority = %{
      caller: "root",
      run_id: run_id,
      grants: names,
      tool_revisions: Map.new(names, &{&1, 1})
    }

    assert {:ok, profile} = Codex.profile(:interactive, %{root?: true}, authority, tools: names)

    conversation =
      start_supervised!(
        {Conversation,
         run_id: run_id,
         store: Store,
         context: context,
         provider: CompletedProvider,
         provider_context: %{},
         subscriber: self(),
         registry: profile.registry,
         tools: profile.tools,
         authority: profile.authority,
         schema_admission: :strict,
         run_timeout: 30_000,
         effect_timeout: 10_000}
      )

    assert {:ok, _} = Conversation.prompt(conversation, "Ask")
    assert_receive {:agent_runtime, ^run_id, %{type: :run_completed}}, 5_000
    assert {:ok, %{run: %{state: :completed}} = expected} = Store.load(context, run_id)
    refute expected.run.execution_intents == %{}
    before = runtime_files(root)

    {output, status, result_path} = cold_reader(root, run_id, "complete")
    assert status == 0, output
    assert output =~ "COLD_STORE_OK"
    assert :erlang.binary_to_term(File.read!(result_path), [:safe]) == expected
    assert runtime_files(root) == before
  end

  test "fresh BEAM decoding refuses an atom outside the installed application vocabulary", %{
    root: root,
    faults: faults
  } do
    assert {:ok, context} = open(root, faults)
    run = base_run("cold-unknown-atom")
    unknown_name = "sigma_runtime_unknown_#{System.unique_integer([:positive])}"
    unknown = String.to_atom(unknown_name)

    assert {:ok, _} =
             RuntimeStore.store(Store, context, run, %{
               command: {:admit, 10, %{state: :running}},
               outbox: [%{diagnostic: unknown}]
             })

    before = runtime_files(root)
    {output, status, _result_path} = cold_reader(root, run.run_id, unknown_name)
    assert status == 0, output
    assert output =~ "COLD_STORE_REJECTED_UNKNOWN_ATOM"
    assert runtime_files(root) == before
  end

  test "returns an explicit error for a malformed trusted record", %{root: root, faults: faults} do
    assert {:ok, context} = open(root, faults)
    run = base_run("malformed")

    assert {:ok, %{revision: 1}} =
             RuntimeStore.store(Store, context, run, %{
               command: {:admit, 10, %{state: :running}}
             })

    [record_path] = Path.wildcard(Path.join(root, "*.runtime"))
    File.write!(record_path, "not an external term")

    assert {:error, %Error{class: :malformed_result, message: "malformed runtime record"}} =
             Store.load(context, run.run_id, [])
  end

  test "rejects runtime handles before acknowledging a snapshot", %{root: root, faults: faults} do
    assert {:ok, context} = open(root, faults)
    run = base_run("runtime-handle")

    assert {:error, %Error{class: :validation, message: "runtime record is not serializable"}} =
             RuntimeStore.store(Store, context, run, %{
               command: {:admit, 10, %{state: :running}},
               outbox: [%{{:nested, self()} => %{callback: fn -> :unsafe end}}]
             })

    assert {:error, %Error{class: :not_found}} = Store.load(context, run.run_id, [])
  end

  test "persists nested Sigma structs and still rejects handles in struct fields", %{
    root: root,
    faults: faults
  } do
    assert {:ok, context} = open(root, faults)

    usage = %ProviderUsage{
      input_tokens: 3,
      output_tokens: 2,
      total_tokens: 5,
      usage_status: :reported
    }

    message = %Message{
      id: "message-1",
      role: :assistant,
      content: "persisted",
      timestamp: 1,
      usage: usage,
      metadata: %{projection: %{revision: 7}}
    }

    valid_run = base_run("sigma-structs")
    outbox = [%{message: message, usage: usage}]

    assert {:ok, %{revision: 1, outbox: ^outbox}} =
             RuntimeStore.store(Store, context, valid_run, %{
               command: {:admit, 10, %{state: :running}},
               outbox: outbox
             })

    assert {:ok, %{outbox: ^outbox}} = Store.load(context, valid_run.run_id, [])

    unsafe_message = %{message | metadata: %{owner: self()}}
    unsafe_run = base_run("sigma-struct-with-handle")

    assert {:error, %Error{class: :validation, message: "runtime record is not serializable"}} =
             RuntimeStore.store(Store, context, unsafe_run, %{
               command: {:admit, 11, %{state: :running}},
               outbox: [%{message: unsafe_message}]
             })

    assert {:error, %Error{class: :not_found}} = Store.load(context, unsafe_run.run_id, [])
  end

  test "direct fence calls require a strictly increasing incarnation", %{
    root: root,
    faults: faults
  } do
    assert {:ok, context} = open(root, faults)
    run = base_run("invalid-fence")

    assert {:ok, %{revision: 1}} =
             RuntimeStore.store(Store, context, run, %{
               command: {:admit, 10, %{state: :running}}
             })

    assert {:error, %Error{class: :validation}} = Store.fence(context, run.run_id, 1, 1, 1)
    assert {:error, %Error{class: :validation}} = Store.fence(context, run.run_id, -1, 1, 2)
    assert {:ok, %{revision: 1, run: %{incarnation: 1}}} = Store.load(context, run.run_id, [])
  end

  test "serializes concurrent compare-and-set writes", %{root: root, faults: faults} do
    assert {:ok, context} = open(root, faults)
    run = base_run("concurrent")

    results =
      1..2
      |> Task.async_stream(
        fn sequence ->
          RuntimeStore.store(Store, context, run, %{
            command: {:admit, sequence, %{state: :running}}
          })
        end,
        ordered: false
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert 1 == Enum.count(results, &match?({:ok, %{revision: 1}}, &1))
    assert 1 == Enum.count(results, &match?({:error, %Error{class: :resource_conflict}}, &1))
    assert {:ok, %{revision: 1}} = Store.load(context, run.run_id, [])
  end

  defp open(root, faults) do
    Store.open(path: root, filesystem: {FaultableFileSystem, faults})
  end

  defp runtime_files(root) do
    root |> Path.join("*.runtime") |> Path.wildcard() |> Map.new(&{&1, File.read!(&1)})
  end

  defp cold_reader(root, run_id, mode) do
    script = Path.join(root, "cold-reader.exs")
    result_path = Path.join(root, "cold-reader.result")

    File.write!(script, ~S'''
    [root, run_id, result_path, mode] = System.argv()
    if mode == "complete" do
      if :code.is_loaded(Backplane.AgentRuntime.Kernel), do: raise("reader preloaded Runtime")
      try do
        String.to_existing_atom("settled_children")
        raise "reader preloaded Runtime vocabulary"
      rescue
        ArgumentError -> :ok
      end
    end
    {:ok, _registry} = Registry.start_link(keys: :unique, name: Sigma.Agent.RepositoryRegistry)
    {:ok, store} = Sigma.Agent.Backplane.Store.open(path: root)

    if mode == "complete" do
      {:ok, record} = Sigma.Agent.Backplane.Store.load(store, run_id)
      File.write!(result_path, :erlang.term_to_binary(record))
      IO.puts("COLD_STORE_OK")
    else
      absent = fn ->
        try do
          String.to_existing_atom(mode)
          raise "unknown atom was admitted"
        rescue
          ArgumentError -> :ok
        end
      end

      absent.()
      {:error, %{class: :malformed_result}} = Sigma.Agent.Backplane.Store.load(store, run_id)
      absent.()
      IO.puts("COLD_STORE_REJECTED_UNKNOWN_ATOM")
    end

    for name <- [Sigma.Agent.Supervisor, Sigma.Coding.Supervisor] do
      if Process.whereis(name), do: raise("Store decoding started an application")
    end
    ''')

    paths = Enum.flat_map(:code.get_path(), &["-pa", List.to_string(&1)])

    executable =
      System.find_executable("elixir") || raise "Elixir is required for cold Store tests"

    {output, status} =
      System.cmd(
        executable,
        ["--erl", "+S 2:2"] ++ paths ++ [script, root, run_id, result_path, mode],
        stderr_to_stdout: true
      )

    {output, status, result_path}
  end

  defp base_run(run_id) do
    %{
      run_id: run_id,
      incarnation: 1,
      expected_revision: 0,
      state: :queued,
      deadline: nil,
      outcome: nil,
      children: []
    }
  end
end
