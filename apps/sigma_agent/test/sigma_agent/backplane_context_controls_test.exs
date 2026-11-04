defmodule Sigma.Agent.BackplaneContextControlsTest do
  use ExUnit.Case, async: false

  alias Sigma.Agent.{Runtime, SessionContext}
  alias Sigma.Agent.Backplane.ContextControls
  alias Sigma.Session.{Log, Writer}
  alias Sigma.Session.Storage.JsonlFile

  @moduletag :tmp_dir
  @gate :sigma_context_window_storage_gate

  defmodule Provider do
    @behaviour Sigma.Ai.Provider

    @impl true
    def output_token_limit(_model, options),
      do: if(options[:unknown_reserve], do: nil, else: 2_000)

    @impl true
    def stream(params) do
      send(params.options[:test_pid], {:context_provider, self(), params})

      receive do
        {:respond, content} ->
          reason = if Enum.any?(content, &(&1.type == :tool_call)), do: :tool_use, else: :stop

          message = %{
            role: :assistant,
            content: content,
            stop_reason: reason,
            usage: %{input: 1, output: 1, total_tokens: 2, cost: %{total: 0.0}},
            model: "context",
            provider: "context",
            api: "openai-responses",
            timestamp: 1
          }

          [{:start, %{message | content: []}}, {:done, reason, message}]
      end
    end
  end

  defmodule GateStorage do
    @behaviour Sigma.Session.Storage
    defdelegate read(path), to: JsonlFile

    def read_with_diagnostics(path) do
      case :ets.lookup(:sigma_context_window_storage_gate, :read_plan) do
        [{:read_plan, [next | rest]}] ->
          :ets.insert(:sigma_context_window_storage_gate, {:read_plan, rest})

          if next == :error,
            do: {:error, :unavailable},
            else: JsonlFile.read_with_diagnostics(path)

        _ ->
          read_without_plan(path)
      end
    end

    defp read_without_plan(path) do
      case :ets.lookup(:sigma_context_window_storage_gate, :read_failure) do
        [{:read_failure, true}] -> {:error, :unavailable}
        [] -> JsonlFile.read_with_diagnostics(path)
      end
    end

    def append(path, %{"type" => "context_window"} = entry) do
      [{:gate, test, mode}] = :ets.lookup(:sigma_context_window_storage_gate, :gate)
      send(test, {:context_boundary_append, self(), entry})

      case mode do
        :fail ->
          {:error, :disk_full}

        :hold ->
          receive do
            :release_context_boundary -> JsonlFile.append(path, entry)
          end
      end
    end

    def append(path, entry), do: JsonlFile.append(path, entry)
  end

  setup %{tmp_dir: dir} do
    :ets.new(@gate, [:named_table, :public])

    on_exit(fn ->
      case Runtime.lookup(dir, :supervisor) do
        nil -> :ok
        pid -> DynamicSupervisor.terminate_child(Sigma.Agent.DynamicSupervisor, pid)
      end
    end)

    :ok
  end

  test "remaining budget is refreshed from real current Runtime messages", %{tmp_dir: dir} do
    agent = session!(dir)
    prompt!(agent, "Count this conversation")
    {provider, _params} = provider!()
    provider = call!(provider, "get_context_remaining", %{})
    first = last_result(agent).metadata.structured_result["tokens_left"]
    assert is_integer(first) and first > 0

    provider =
      call!(provider, "update_plan", %{
        "explanation" => String.duplicate("More context for the current plan. ", 120),
        "plan" => [%{"step" => "Read", "status" => "pending"}]
      })

    provider = call!(provider, "get_context_remaining", %{})
    second = last_result(agent).metadata.structured_result["tokens_left"]
    assert is_integer(second) and second < first
    finish!(provider)
  end

  test "unknown actual Provider output cap returns null", %{tmp_dir: dir} do
    agent = session!(dir, options: [test_pid: self(), unknown_reserve: true])
    prompt!(agent, "Unknown output cap")
    {provider, _} = provider!()
    provider = call!(provider, "get_context_remaining", %{})
    assert last_result(agent).metadata.structured_result["tokens_left"] == nil
    finish!(provider)
  end

  test "reset rehydrates instructions, keeps display history and survives later turns and restart",
       %{
         tmp_dir: dir
       } do
    agent = session!(dir)
    prompt!(agent, "PRIVATE_OLD_PROMPT")
    {provider, _} = provider!()
    send_call(provider, "new_context", %{})
    {provider, params} = provider!()
    assert_base(params)
    refute inspect(params.context.messages) =~ "PRIVATE_OLD_PROMPT"
    refute inspect(params.context.messages) =~ "new_context"

    assert {:ok, snapshot} = Log.snapshot(path(dir))
    assert snapshot.context_messages == []
    assert Enum.any?(snapshot.messages, &(&1.content == "PRIVATE_OLD_PROMPT"))
    assert List.last(snapshot.messages).tool_name == "new_context"
    assert snapshot.context_window.window == 2
    assert snapshot.compaction == nil
    refute Enum.any?(snapshot.messages, &(get_in(&1.metadata, [:source]) == :context_window))
    finish!(provider)

    prompt!(agent, "NEXT_TURN")
    {provider, params} = provider!()
    assert_base(params)
    assert inspect(params.context.messages) =~ "NEXT_TURN"
    refute inspect(params.context.messages) =~ "PRIVATE_OLD_PROMPT"
    finish!(provider)

    assert {:ok, snapshot} = Log.snapshot(path(dir))
    stop_session!(dir)

    agent =
      session!(dir,
        messages: snapshot.messages,
        context_messages: snapshot.context_messages,
        context_window: snapshot.context_window
      )

    prompt!(agent, "AFTER_RESTART")
    {provider, params} = provider!()
    assert_base(params)
    assert inspect(params.context.messages) =~ "NEXT_TURN"
    assert inspect(params.context.messages) =~ "AFTER_RESTART"
    refute inspect(params.context.messages) =~ "PRIVATE_OLD_PROMPT"
    assert Enum.any?(:sys.get_state(agent).messages, &(&1.content == "PRIVATE_OLD_PROMPT"))
    finish!(provider)
  end

  test "Provider dispatch waits for durable boundary acknowledgement", %{tmp_dir: dir} do
    :ets.insert(@gate, {:gate, self(), :hold})
    agent = session!(dir, storage_mod: GateStorage)
    prompt!(agent, "Old history")
    {provider, _} = provider!()
    send_call(provider, "new_context", %{})
    assert_receive {:context_boundary_append, writer, entry}, 5_000
    refute_receive {:context_provider, _, _}, 150
    assert {:ok, before} = Log.snapshot(path(dir))
    assert before.context_window == nil
    send(writer, :release_context_boundary)
    {provider, _} = provider!()
    assert {:ok, after_commit} = Log.snapshot(path(dir))
    assert after_commit.context_window.window == entry["window"]
    assert after_commit.context_messages == []
    assert {:ok, %{active_leaf_id: id}} = Writer.flush(writer)
    assert id == entry["id"]
    finish!(provider)
  end

  test "storage failure prevents a new request and keeps the old context", %{tmp_dir: dir} do
    :ets.insert(@gate, {:gate, self(), :fail})
    agent = session!(dir, storage_mod: GateStorage)
    prompt!(agent, "Keep old history")
    {provider, _} = provider!()
    send_call(provider, "new_context", %{})
    assert_receive {:context_boundary_append, _, _}, 5_000
    assert_receive {:turn_failed, _}, 5_000
    assert_receive {:turn_error, {:event_persistence_failed, :context_window, _}}, 5_000
    refute_receive {:context_provider, _, _}, 150
    assert {:ok, snapshot} = Log.snapshot(path(dir))
    assert snapshot.context_window == nil
    assert Enum.any?(snapshot.context_messages, &(&1.content == "Keep old history"))
  end

  test "cancellation before boundary acknowledgement prevents the late Provider dispatch", %{
    tmp_dir: dir
  } do
    :ets.insert(@gate, {:gate, self(), :hold})
    agent = session!(dir, storage_mod: GateStorage)
    prompt!(agent, "Cancel reset")
    {provider, _} = provider!()
    send_call(provider, "new_context", %{})
    assert_receive {:context_boundary_append, writer, _}, 5_000
    assert {:cancelling, _} = Sigma.Agent.cancel(agent)
    send(writer, :release_context_boundary)
    assert_receive {:agent_end, _}, 5_000
    refute_receive {:context_provider, _, _}, 150
  end

  test "a boundary committed after the Engine exits still fences the next turn", %{tmp_dir: dir} do
    :ets.insert(@gate, {:gate, self(), :hold})
    agent = session!(dir, storage_mod: GateStorage)
    prompt!(agent, "PRIVATE_BEFORE_LATE_BOUNDARY")
    {provider, _} = provider!()
    engine = :sys.get_state(agent).current_turn_task.pid
    monitor = Process.monitor(engine)
    send_call(provider, "new_context", %{})
    assert_receive {:context_boundary_append, writer, entry}, 5_000

    # The append already belongs to the Writer even when its caller dies.
    Process.exit(engine, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^engine, :killed}, 5_000
    send(writer, :release_context_boundary)
    assert_receive {:turn_failed, _}, 5_000
    assert {:ok, _} = Writer.flush(writer)
    assert {:ok, snapshot} = Log.snapshot(path(dir))
    assert snapshot.context_window.window == entry["window"]
    assert snapshot.context_messages == []

    prompt!(agent, "AFTER_LATE_BOUNDARY")
    {provider, params} = provider!()
    refute inspect(params.context.messages) =~ "PRIVATE_BEFORE_LATE_BOUNDARY"
    assert inspect(params.context.messages) =~ "AFTER_LATE_BOUNDARY"
    assert_base(params)

    assert Enum.any?(
             :sys.get_state(agent).messages,
             &(&1.content == "PRIVATE_BEFORE_LATE_BOUNDARY")
           )

    finish!(provider)
  end

  test "an unavailable durable recovery cannot dispatch the next Provider request", %{
    tmp_dir: dir
  } do
    :ets.insert(@gate, {:gate, self(), :hold})
    agent = session!(dir, storage_mod: GateStorage)
    prompt!(agent, "PRIVATE_BEFORE_UNREADABLE_BOUNDARY")
    {provider, _} = provider!()
    engine = :sys.get_state(agent).current_turn_task.pid
    monitor = Process.monitor(engine)
    send_call(provider, "new_context", %{})
    assert_receive {:context_boundary_append, writer, _}, 5_000
    Process.exit(engine, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^engine, :killed}, 5_000
    send(writer, :release_context_boundary)
    assert_receive {:turn_failed, _}, 5_000

    :ets.insert(@gate, {:read_failure, true})
    prompt!(agent, "MUST_NOT_DISPATCH")
    assert_receive {:turn_failed, _}, 5_000

    assert_receive {:turn_error,
                    {:event_persistence_failed, :context_recovery, {:error, :unavailable}}},
                   5_000

    refute_receive {:context_provider, _, _}, 150
    :ets.delete(@gate, :read_failure)

    prompt!(agent, "RECOVERED_READ")
    {provider, params} = provider!()
    refute inspect(params.context.messages) =~ "PRIVATE_BEFORE_UNREADABLE_BOUNDARY"
    refute inspect(params.context.messages) =~ "MUST_NOT_DISPATCH"
    assert inspect(params.context.messages) =~ "RECOVERED_READ"
    finish!(provider)
  end

  test "retry recovery failure rejects admission promptly and restores the selected leaf", %{
    tmp_dir: dir
  } do
    :ets.insert(@gate, {:gate, self(), :hold})
    agent = session!(dir, storage_mod: GateStorage)
    prompt!(agent, "RETRY_BEFORE_LATE_BOUNDARY")
    {provider, _} = provider!()
    original_id = user_id(agent, "RETRY_BEFORE_LATE_BOUNDARY")
    engine = :sys.get_state(agent).current_turn_task.pid
    monitor = Process.monitor(engine)
    send_call(provider, "new_context", %{})
    assert_receive {:context_boundary_append, writer, _}, 5_000
    Process.exit(engine, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^engine, :killed}, 5_000
    send(writer, :release_context_boundary)
    assert_receive {:turn_failed, _}, 5_000
    assert {:ok, source} = Writer.flush(writer)
    opts = mutation_opts(dir, "retry-unreadable-window")

    # Checkout succeeds, recovery fails, then rollback can read the source branch.
    :ets.insert(@gate, {:read_plan, [:ok, :error, :ok]})
    task = Task.async(fn -> Runtime.retry_turn(dir, "context", dir, original_id, opts) end)

    try do
      assert {:ok,
              {:error,
               {:retry_rejected,
                {:event_persistence_failed, :context_recovery, {:error, :unavailable}}}}} =
               Task.yield(task, 2_000)
    after
      Task.shutdown(task, :brutal_kill)
    end

    assert {:ok, restored} = Writer.flush(writer)
    assert restored.active_leaf_id == source.active_leaf_id
    refute_receive {:context_provider, _, _}, 150
    assert {:ok, projection} = Writer.context_snapshot(writer)
    assert projection.context_window.window == 2
    assert projection.context_messages == []
  end

  test "actual retry restores the chosen pre-reset or post-reset branch projection", %{
    tmp_dir: dir
  } do
    agent = session!(dir)
    prompt!(agent, "BEFORE_RESET_RETRY")
    {provider, _} = provider!()
    before_id = user_id(agent, "BEFORE_RESET_RETRY")
    provider = call!(provider, "new_context", %{})
    finish!(provider)
    prompt!(agent, "AFTER_RESET_RETRY")
    {provider, _} = provider!()
    after_id = user_id(agent, "AFTER_RESET_RETRY")
    finish!(provider)
    prompt!(agent, "SIBLING_RESET_PRIVATE")
    {provider, _} = provider!()
    provider = call!(provider, "new_context", %{})
    finish!(provider)

    assert {:ok, _} =
             Runtime.retry_turn(dir, "context", dir, after_id, mutation_opts(dir, "retry-after"))

    {provider, params} = provider!()
    assert inspect(params.context.messages) =~ "AFTER_RESET_RETRY"
    refute inspect(params.context.messages) =~ "BEFORE_RESET_RETRY"
    refute inspect(params.context.messages) =~ "SIBLING_RESET_PRIVATE"
    assert_base(params)
    finish!(provider)

    assert {:ok, _} =
             Runtime.retry_turn(
               dir,
               "context",
               dir,
               before_id,
               mutation_opts(dir, "retry-before")
             )

    {provider, params} = provider!()
    assert inspect(params.context.messages) =~ "BEFORE_RESET_RETRY"
    refute inspect(params.context.messages) =~ "AFTER_RESET_RETRY"
    assert :sys.get_state(agent).context_window == nil
    finish!(provider)
  end

  test "an actual fork preserves the active Provider window independently", %{tmp_dir: dir} do
    agent = session!(dir)
    prompt!(agent, "BEFORE_FORK_RESET_PRIVATE")
    {provider, _} = provider!()
    provider = call!(provider, "new_context", %{})
    finish!(provider)
    prompt!(agent, "AFTER_FORK_RESET")
    {provider, _} = provider!()
    finish!(provider)

    assert {:ok, _} =
             Runtime.fork_session(
               dir,
               "context",
               "fork",
               dir,
               :all,
               mutation_opts(dir, "fork-window")
             )

    fork_path = Path.join(dir, "fork.jsonl")
    assert {:ok, snapshot} = Log.snapshot(fork_path)
    assert snapshot.context_window.window == 2

    fork =
      session!(dir,
        session_id: "fork",
        transcript_path: fork_path,
        messages: snapshot.messages,
        context_messages: snapshot.context_messages,
        context_window: snapshot.context_window
      )

    prompt!(fork, "FORK_ONLY_PROMPT")
    {provider, params} = provider!()
    assert inspect(params.context.messages) =~ "AFTER_FORK_RESET"
    refute inspect(params.context.messages) =~ "BEFORE_FORK_RESET_PRIVATE"
    assert_base(params)
    finish!(provider)
    assert {:ok, original} = Log.snapshot(path(dir))
    refute Enum.any?(original.messages, &(&1.content == "FORK_ONLY_PROMPT"))
  end

  test "stale run callbacks and canonical acknowledgements cannot access or mutate a live turn",
       %{tmp_dir: dir} do
    agent = session!(dir)
    prompt!(agent, "Current turn")
    {provider, _} = provider!()
    live = :sys.get_state(agent)
    owner = live.current_turn_task.pid
    assert ContextControls.request(owner, :remaining, "stale-run") == nil
    assert is_integer(ContextControls.request(owner, :remaining, live.turn_state.turn_id))

    send(
      agent,
      {:canonical_context, "stale-run", [], %{run_id: "stale-run", incarnation: 1, window: 2},
       MapSet.new()}
    )

    assert :sys.get_state(agent).messages == live.messages
    finish!(provider)
  end

  test "a remaining callback whose host has exited returns unknown" do
    host =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    monitor = Process.monitor(host)
    send(host, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^host, _}
    assert ContextControls.request(host, :remaining, "stale") == nil
  end

  defp session!(dir, opts \\ []) do
    {session_id, opts} = Keyword.pop(opts, :session_id, "context")

    defaults = [
      cwd: dir,
      transcript_path: path(dir),
      provider: Provider,
      model: %{
        id: "context",
        provider: "context",
        api: "openai-responses",
        context_window: 100_000
      },
      system_prompt: "Stable system instructions",
      native_tools: true,
      tools: [],
      hook_specs: [],
      session_context:
        SessionContext.new(
          agents_context: "BASE_AGENTS",
          hooks: "BASE_HOOKS",
          skills: [%{name: "base-skill", description: "BASE_SKILLS"}]
        ),
      options: [test_pid: self()]
    ]

    assert {:ok, handle} = Runtime.get_session(dir, session_id, Keyword.merge(defaults, opts))
    :ok = Sigma.Agent.subscribe(handle.agent)
    handle.agent
  end

  defp stop_session!(dir) do
    supervisor = Runtime.lookup(dir, "context", :supervisor)
    assert :ok = DynamicSupervisor.terminate_child(Runtime.lookup(dir, :sessions), supervisor)
  end

  defp mutation_opts(dir, operation_id) do
    assert {:ok, snapshot} = Log.snapshot(path(dir))

    [
      operation_id: operation_id,
      expected_source_revision: length(snapshot.branch_entry_ids) + 1,
      expected_source_leaf: snapshot.active_leaf_id
    ]
  end

  defp user_id(agent, content),
    do:
      Enum.find(:sys.get_state(agent).messages, &(&1.role == :user and &1.content == content)).id

  defp path(dir), do: Path.join(dir, "context.jsonl")
  defp prompt!(agent, text), do: assert({:accepted, _} = Sigma.Agent.prompt(agent, text))

  defp provider! do
    assert_receive {:context_provider, pid, params}, 8_000
    {pid, params}
  end

  defp send_call(provider, name, arguments) do
    send(
      provider,
      {:respond,
       [
         %{
           type: :tool_call,
           id: "context-#{System.unique_integer([:positive])}",
           name: name,
           arguments: arguments,
           input_kind: :function
         }
       ]}
    )
  end

  defp call!(provider, name, arguments) do
    send_call(provider, name, arguments)
    {provider, _} = provider!()
    provider
  end

  defp last_result(agent),
    do: :sys.get_state(agent).messages |> Enum.reverse() |> Enum.find(&(&1.role == :tool_result))

  defp finish!(provider) do
    send(provider, {:respond, [%{type: :text, text: "done"}]})
    assert_receive {:agent_end, _}, 5_000
  end

  defp assert_base(params) do
    text = inspect(params.context.messages)
    assert text =~ "BASE_AGENTS"
    assert text =~ "BASE_HOOKS"
    assert text =~ "base-skill"
    assert String.starts_with?(params.context.system_prompt, "Stable system instructions\n\n")
    assert params.context.system_prompt =~ "memories::add_ad_hoc_note"
  end
end
