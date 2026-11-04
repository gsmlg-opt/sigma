defmodule Sigma.Agent.BackplaneGoalLifecycleFunctionalTest do
  use ExUnit.Case, async: false

  alias Sigma.Agent.Backplane.GoalStore
  alias Sigma.Agent.Runtime
  alias Sigma.Session.{Log, Writer}

  @moduletag :tmp_dir

  defmodule Provider do
    @behaviour Sigma.Ai.Provider

    def stream(params) do
      send(params.options[:test_pid], {:lifecycle_provider, self(), params})

      receive do
        {:lifecycle_response, content} ->
          reason = if Enum.any?(content, &(&1.type == :tool_call)), do: :tool_use, else: :stop

          message = %{
            role: :assistant,
            content: content,
            timestamp: System.system_time(:millisecond),
            usage: %{input: 5, output: 2, total_tokens: 7},
            stop_reason: reason,
            api: "openai-responses",
            model: "goal-lifecycle",
            provider: "goal-lifecycle"
          }

          [{:start, %{message | content: []}}, {:done, reason, message}]
      end
    end
  end

  defmodule FailedRetirement do
    use GenServer, restart: :temporary

    def start_link(root) do
      GenServer.start_link(__MODULE__, nil,
        name: {:via, Registry, {Sigma.Agent.RepositoryRegistry, {:backplane_goal_store, root}}}
      )
    end

    def init(state), do: {:ok, state}
    def handle_call(:retire, _from, state), do: {:stop, :injected_goal_retirement_failure, state}
  end

  setup %{tmp_dir: dir} do
    repo = Path.join(dir, "repo")
    sessions = Path.join(repo, "sessions")
    path = Path.join(sessions, "source.jsonl")
    File.mkdir_p!(sessions)
    opts = session_opts(repo, path)
    assert {:ok, handle} = Runtime.get_session(repo, "source", opts)
    :ok = Sigma.Agent.subscribe(handle.agent)
    assert {:accepted, _} = Sigma.Agent.prompt(handle.agent, "Complete this durable Goal")
    root = provider!()

    root =
      call!(root, "create_goal", %{"objective" => "Persist the exact Goal across session files"})

    root = call!(root, "update_goal", %{"status" => "complete"})
    send(root, {:lifecycle_response, [%{type: :text, text: "Goal completed"}]})
    assert_receive {:agent_end, _}, 8_000
    assert {:ok, %{goal: goal}} = Sigma.Agent.goal(handle.agent)
    assert {:ok, snapshot} = Log.snapshot(path)
    assert {:ok, record} = GoalStore.load(store!(path), snapshot.session_id)

    on_exit(fn ->
      for repo_path <- [repo, Path.join(dir, "adopted")] do
        case Runtime.lookup(repo_path, :supervisor) do
          nil -> :ok
          pid -> DynamicSupervisor.terminate_child(Sigma.Agent.DynamicSupervisor, pid)
        end
      end

      Registry.select(Sigma.Agent.RepositoryRegistry, [
        {{{:backplane_goal_store, :"$1"}, :"$2", :_}, [], [{{:"$1", :"$2"}}]}
      ])
      |> Enum.each(fn {root, _pid} ->
        if String.starts_with?(root, dir), do: GoalStore.retire(root)
      end)
    end)

    %{
      dir: dir,
      repo: repo,
      sessions: sessions,
      path: path,
      handle: handle,
      goal: goal,
      record: record,
      header: snapshot.session_id
    }
  end

  test "native Runtime rename retires both owners and reopens the same durable Goal", c do
    store = store!(c.path)

    assert {:ok, %{session_id: "renamed"}} =
             Runtime.rename_session(c.repo, "source", "renamed", c.sessions)

    refute Process.alive?(store)
    refute Process.alive?(c.handle.agent)
    target = Path.join(c.sessions, "renamed.jsonl")
    agent = assert_goal!(c, "renamed", target, c.goal)
    assert_native_goal!(agent, c.goal)
    refute File.exists?(c.path <> ".subagents")
    refute File.exists?(c.path <> ".runtime")
  end

  test "native Runtime adopt preserves immutable Goal identity at the new path", c do
    store = store!(c.path)
    replacement = Path.join(c.dir, "adopted")
    target_sessions = Path.join(replacement, "sessions")
    File.mkdir_p!(replacement)

    assert {:ok, %{session_id: "source", cwd: ^replacement}} =
             Runtime.adopt_session(c.repo, "source", c.sessions, target_sessions, replacement)

    refute Process.alive?(store)
    target = Path.join(target_sessions, "source.jsonl")
    assert {:ok, moved} = Log.snapshot(target)
    assert moved.session_id == c.header
    assert {:ok, record} = GoalStore.load(store!(target), c.header)
    assert record.goal == c.record.goal

    assert {:ok, handle} =
             Runtime.get_session(replacement, "source", session_opts(replacement, target))

    assert_native_goal!(handle.agent, c.goal)
    refute File.exists?(c.path <> ".subagents")
    refute File.exists?(c.path <> ".runtime")
  end

  test "native Runtime delete drains Goal storage and same-name recreation has no Goal", c do
    store = store!(c.path)
    assert {:ok, %{deleted: true}} = Runtime.delete_session(c.repo, "source", c.sessions)
    refute Process.alive?(store)
    refute Process.alive?(c.handle.agent)
    refute File.exists?(c.path <> ".subagents")
    refute File.exists?(c.path <> ".runtime")
    assert {:ok, fresh} = Runtime.get_session(c.repo, "source", session_opts(c.repo, c.path))
    assert {:ok, %{goal: nil}} = Sigma.Agent.goal(fresh.agent)
    assert {:ok, journal} = Writer.selected_journal(Runtime.lookup(c.repo, "source", :writer))
    refute hd(journal.entries)["id"] == c.header
    refute_receive {:lifecycle_provider, _, _}, 50
  end

  test "native Runtime fork installs the public snapshot in the independent target store", c do
    target = Path.join(c.sessions, "fork.jsonl")

    assert {:ok, %{session_id: "fork"}} =
             Runtime.fork_session(c.repo, "source", "fork", c.sessions, :all, fork_opts(c.path))

    assert Process.alive?(c.handle.agent)
    assert {:ok, %{goal: source}} = Sigma.Agent.goal(c.handle.agent)
    assert source == c.goal
    assert {:ok, forked} = Log.snapshot(target)
    refute forked.session_id == c.header
    expected = %{c.goal | thread_id: forked.session_id}
    fork_agent = assert_goal!(c, "fork", target, expected)
    assert Path.wildcard(Path.join(goal_root(target), "*.goal-runs")) == []
    assert_native_goal!(fork_agent, expected)

    assert {:ok, %{goal: nil}} =
             Sigma.Agent.clear_goal(fork_agent, %{text: "Clear only this fork"})

    assert {:ok, %{goal: ^source}} = Sigma.Agent.goal(c.handle.agent)
    refute_receive {:lifecycle_provider, _, _}, 50
  end

  test "a stopped source forks its retained Goal without rerunning the Provider", c do
    stop_session!(c)
    target = Path.join(c.sessions, "fork.jsonl")

    assert {:ok, %{session_id: "fork"}} =
             Runtime.fork_session(c.repo, "source", "fork", c.sessions, :all, fork_opts(c.path))

    assert {:ok, forked} = Log.snapshot(target)
    assert_goal!(c, "fork", target, %{c.goal | thread_id: forked.session_id})
    refute_receive {:lifecycle_provider, _, _}, 50
  end

  test "a stopped native session moves its indexed Runtime snapshots with its Goal", c do
    stop_session!(c)

    runtime =
      Path.wildcard(Path.join(c.path <> ".runtime", "*"))
      |> Map.new(&{Path.basename(&1), File.read!(&1)})

    assert {:ok, %{session_id: "renamed"}} =
             Runtime.rename_session(c.repo, "source", "renamed", c.sessions)

    target = Path.join(c.sessions, "renamed.jsonl")

    moved =
      Path.wildcard(Path.join(target <> ".runtime", "*"))
      |> Map.new(&{Path.basename(&1), File.read!(&1)})

    assert moved == runtime
    refute File.exists?(c.path <> ".runtime")
    agent = assert_goal!(c, "renamed", target, c.goal)
    assert_native_goal!(agent, c.goal)
  end

  test "failed file mutation reopens the exact source Goal and preserves its records", c do
    store = store!(c.path)
    before = goal_bytes(c.path)
    target = Path.join(c.sessions, "renamed.jsonl")
    File.write!(target, "occupied")

    assert {:error, :already_exists} =
             Runtime.rename_session(c.repo, "source", "renamed", c.sessions)

    refute Process.alive?(store)
    assert File.read!(target) == "occupied"
    assert goal_bytes(c.path) == before
    assert {:ok, %{goal: actual}} = Sigma.Agent.goal(c.handle.agent)
    assert actual == c.goal
    :ok = Sigma.Agent.subscribe(c.handle.agent)
    assert {:accepted, _} = Sigma.Agent.prompt(c.handle.agent, "Read the retained Goal")
    root = call!(provider!(), "get_goal", %{})
    send(root, {:lifecycle_response, [%{type: :text, text: "Still available"}]})
    assert_receive {:agent_end, _}, 8_000
  end

  @tag :capture_log
  test "an unconfirmed Goal-store retirement stops the file operation with its actual cause", c do
    before = goal_bytes(c.path)
    :ok = Sigma.Agent.retire_goal(c.handle.agent)
    :ok = GoalStore.retire(goal_root(c.path))
    start_supervised!({FailedRetirement, goal_root(c.path)})

    assert {:error, %{class: :unknown_outcome, cause: cause}} =
             Runtime.rename_session(c.repo, "source", "renamed", c.sessions)

    assert inspect(cause) =~ "injected_goal_retirement_failure"
    assert File.exists?(c.path)
    refute File.exists?(Path.join(c.sessions, "renamed.jsonl"))
    assert goal_bytes(c.path) == before
    assert {:ok, %{goal: actual}} = Sigma.Agent.goal(c.handle.agent)
    assert actual == c.goal
  end

  defp session_opts(repo, path) do
    [
      cwd: repo,
      transcript_path: path,
      native_tools: true,
      tools: [],
      hook_specs: [],
      native_memory_root: Path.join(repo, "memories"),
      provider: Provider,
      model: %{id: "goal-lifecycle", provider: "goal-lifecycle", api: "openai-responses"},
      options: [test_pid: self()],
      permission_config: %{default: :allow, rules: %{}}
    ]
  end

  defp provider! do
    receive do
      {:lifecycle_provider, pid, params} ->
        Process.put({:lifecycle_provider, pid}, params)
        pid

      {:turn_error, error} ->
        flunk("Goal lifecycle Engine failed: #{inspect(error)}")
    after
      8_000 -> flunk("Goal lifecycle Provider did not start")
    end
  end

  defp call!(provider, name, arguments) do
    send(
      provider,
      {:lifecycle_response,
       [
         %{
           type: :tool_call,
           id: "goal-lifecycle-#{System.unique_integer([:positive])}",
           name: name,
           arguments: arguments,
           input_kind: :function
         }
       ]}
    )

    provider!()
  end

  defp store!(path) do
    assert {:ok, store} = GoalStore.open(path: goal_root(path))
    store
  end

  defp goal_root(path), do: Path.join(path <> ".subagents", "goal")

  defp goal_bytes(path) do
    Path.wildcard(Path.join(goal_root(path), "*"))
    |> Map.new(&{Path.basename(&1), File.read!(&1)})
  end

  defp assert_goal!(c, session_id, path, expected) do
    assert {:ok, handle} = Runtime.get_session(c.repo, session_id, session_opts(c.repo, path))
    assert {:ok, %{goal: actual}} = Sigma.Agent.goal(handle.agent)
    assert actual == expected
    handle.agent
  end

  defp assert_native_goal!(agent, expected) do
    :ok = Sigma.Agent.subscribe(agent)
    assert {:accepted, _} = Sigma.Agent.prompt(agent, "Read the persisted Goal")
    root = call!(provider!(), "get_goal", %{})
    params = Process.get({:lifecycle_provider, root})

    result =
      Enum.find(Enum.reverse(params.context.messages), &(Map.get(&1, :tool_name) == "get_goal"))

    assert result
    refute result.is_error
    assert [%{type: :text, text: json}] = result.content
    assert Jason.decode!(json)["goal"] == expected |> Jason.encode!() |> Jason.decode!()
    send(root, {:lifecycle_response, [%{type: :text, text: "Persisted Goal read"}]})
    assert_receive {:agent_end, _}, 8_000
  end

  defp fork_opts(path) do
    assert {:ok, snapshot} = Log.snapshot(path)

    [
      operation_id: "goal-fork-#{System.unique_integer([:positive])}",
      expected_source_leaf: snapshot.active_leaf_id,
      expected_source_revision: length(snapshot.branch_entry_ids) + 1
    ]
  end

  defp stop_session!(c) do
    sessions = Runtime.lookup(c.repo, :sessions)
    assert :ok = DynamicSupervisor.terminate_child(sessions, c.handle.session_supervisor)
    refute Process.alive?(c.handle.agent)
    assert Runtime.lookup(c.repo, "source", :agent) == nil
    assert Runtime.lookup(c.repo, "source", :writer) == nil

    assert [] ==
             Registry.lookup(
               Sigma.Agent.RepositoryRegistry,
               {:backplane_store, c.path <> ".runtime"}
             )
  end
end
