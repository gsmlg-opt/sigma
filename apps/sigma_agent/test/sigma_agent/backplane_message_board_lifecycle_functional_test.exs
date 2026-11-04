defmodule Sigma.Agent.BackplaneMessageBoardLifecycleFunctionalTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.Error
  alias Sigma.Agent.Backplane.{MessageBoardStore, Store.FileSystem}
  alias Sigma.Agent.Runtime
  alias Sigma.Session.{Log, SessionFiles}

  @moduletag :tmp_dir

  defmodule EmptyProvider do
    @behaviour Sigma.Ai.Provider
    def stream(_params), do: []
  end

  defmodule BlockingFileSystem do
    def ensure_dir(_test, path), do: FileSystem.ensure_dir(path)
    def read(_test, path), do: FileSystem.read(path)

    def write_atomic(test, path, bytes) do
      send(test, {:board_commit_waiting, self()})

      receive do
        :continue_board_commit -> FileSystem.write_atomic(path, bytes)
      after
        5_000 -> {:error, :board_commit_fixture_timeout}
      end
    end
  end

  defmodule FailedRetirement do
    use GenServer, restart: :temporary

    def start_link(path) do
      GenServer.start_link(__MODULE__, nil,
        name: {:via, Registry, {Sigma.Agent.RepositoryRegistry, {:message_board_store, path}}}
      )
    end

    def init(state), do: {:ok, state}
    def handle_call(:retire, _from, state), do: {:stop, :injected_retirement_failure, state}
  end

  setup %{tmp_dir: dir} do
    repo = Path.join(dir, "repo")
    sessions = Path.join(repo, "sessions")
    File.mkdir_p!(sessions)
    source = Path.join(sessions, "source.jsonl")
    :ok = SessionFiles.create(sessions, "source", %{"cwd" => repo}, repo)
    assert {:ok, snapshot} = Log.snapshot(source)

    assert {:ok, _handle} =
             Runtime.get_session(repo, "source",
               cwd: repo,
               transcript_path: source,
               provider: EmptyProvider,
               model: %{id: "mock", provider: "mock", api: "mock"},
               tools: [],
               hook_specs: [],
               permission_config: %{default: :allow, rules: %{}},
               idle_timeout_ms: 30_000
             )

    paths = [
      source,
      Path.join(sessions, "renamed.jsonl"),
      Path.join(sessions, "fork.jsonl"),
      Path.join([dir, "adopted", "sessions", "source.jsonl"])
    ]

    on_exit(fn ->
      case Runtime.lookup(repo, :supervisor) do
        nil -> :ok
        pid -> DynamicSupervisor.terminate_child(Sigma.Agent.DynamicSupervisor, pid)
      end

      for path <- paths do
        case Registry.lookup(Sigma.Agent.RepositoryRegistry, {:message_board_store, path}) do
          [{pid, _}] ->
            DynamicSupervisor.terminate_child(Sigma.Agent.DynamicSupervisor, pid)

          [] ->
            :ok
        end
      end
    end)

    %{dir: dir, repo: repo, sessions: sessions, source: source, root_id: snapshot.session_id}
  end

  test "Runtime rename retires the old writer, preserves the board and permits a new root at its old path",
       c do
    writer = open!(c.source, c.root_id)
    assert {:ok, posted, []} = post(writer, c.root_id, "original", 1)
    bytes = File.read!(board_path(c.source))

    assert {:ok, %{session_id: "renamed"}} =
             Runtime.rename_session(c.repo, "source", "renamed", c.sessions)

    refute Process.alive?(writer)
    assert [] == Registry.lookup(Sigma.Agent.RepositoryRegistry, {:message_board_store, c.source})
    renamed = Path.join(c.sessions, "renamed.jsonl")
    assert {:ok, snapshot} = Log.snapshot(renamed)
    assert snapshot.session_id == c.root_id
    assert File.read!(board_path(renamed)) == bytes
    moved = open!(renamed, snapshot.session_id)
    assert {:ok, ^posted, []} = post(moved, c.root_id, "original", 1)
    assert read_text(moved, c.root_id, posted["message_id"]) == "original"
    assert_new_root(c, moved, posted)
  end

  test "Runtime adopt moves board bytes with the unchanged header and releases the source path",
       c do
    writer = open!(c.source, c.root_id)
    assert {:ok, posted, []} = post(writer, c.root_id, "adopted", 1)
    before = File.read!(c.source)
    board_bytes = File.read!(board_path(c.source))
    replacement = Path.join(c.dir, "adopted")
    target_sessions = Path.join(replacement, "sessions")
    File.mkdir_p!(replacement)

    assert {:ok, %{session_id: "source", cwd: ^replacement}} =
             Runtime.adopt_session(
               c.repo,
               "source",
               c.sessions,
               target_sessions,
               replacement
             )

    refute Process.alive?(writer)
    adopted = Path.join(target_sessions, "source.jsonl")
    assert File.read!(adopted) == before
    assert File.read!(board_path(adopted)) == board_bytes
    assert {:ok, snapshot} = Log.snapshot(adopted)
    assert snapshot.session_id == c.root_id
    moved = open!(adopted, snapshot.session_id)
    assert {:ok, ^posted, []} = post(moved, c.root_id, "adopted", 1)
    assert_new_root(c, moved, posted)
  end

  test "Runtime delete confirms writer exit and permits same-name recreation without old content",
       c do
    writer = open!(c.source, c.root_id)
    assert {:ok, _, []} = post(writer, c.root_id, "deleted", 1)
    assert {:ok, %{deleted: true}} = Runtime.delete_session(c.repo, "source", c.sessions)
    refute Process.alive?(writer)
    refute File.exists?(c.source)
    refute File.exists?(c.source <> ".subagents")
    assert :ok = MessageBoardStore.retire(c.source)

    {fresh, new_root_id} = recreate_source(c)
    assert {:ok, page, []} = call(fresh, new_root_id, "search_posts", %{}, 2)
    assert page["results"] == []
    assert {:ok, _, []} = post(fresh, new_root_id, "new board", 3)
    assert {:ok, %{deleted: true}} = Runtime.delete_session(c.repo, "source", c.sessions)
    refute Process.alive?(fresh)
    assert {:ok, %{deleted: true}} = Runtime.delete_session(c.repo, "source", c.sessions)
    refute File.exists?(c.source <> ".subagents")
  end

  test "Runtime fork keeps the source writer and gives the fork a fresh independent board", c do
    writer = open!(c.source, c.root_id)
    assert {:ok, posted, []} = post(writer, c.root_id, "source", 1)
    before = File.read!(board_path(c.source))
    assert {:ok, checkpoint} = Log.snapshot(c.source)

    opts = [
      operation_id: "board-fork",
      expected_source_leaf: checkpoint.active_leaf_id,
      expected_source_revision: length(checkpoint.branch_entry_ids) + 1
    ]

    assert {:ok, %{session_id: "fork"}} =
             Runtime.fork_session(c.repo, "source", "fork", c.sessions, :all, opts)

    assert Process.alive?(writer)
    assert {:ok, ^writer} = MessageBoardStore.open(root_transcript: c.source, root_id: c.root_id)
    assert File.read!(board_path(c.source)) == before
    fork_path = Path.join(c.sessions, "fork.jsonl")
    assert {:ok, forked} = Log.snapshot(fork_path)
    refute forked.session_id == c.root_id
    assert forked.parent_session_id == c.root_id
    refute File.exists?(fork_path <> ".subagents")
    independent = open!(fork_path, forked.session_id)
    assert {:ok, page, []} = call(independent, forked.session_id, "search_posts", %{}, 2)
    assert page["results"] == []
    refute File.exists?(fork_path <> ".subagents")
    assert {:ok, fork_post, []} = post(independent, forked.session_id, "fork only", 3)
    assert read_text(independent, forked.session_id, fork_post["message_id"]) == "fork only"
    assert read_text(writer, c.root_id, posted["message_id"]) == "source"
    assert File.read!(board_path(c.source)) == before
  end

  test "a failed Runtime file operation retires the writer without losing bytes or accepted-call receipts",
       c do
    writer = open!(c.source, c.root_id)
    assert {:ok, posted, []} = post(writer, c.root_id, "keep me", 1)
    before = File.read!(board_path(c.source))
    File.write!(Path.join(c.sessions, "renamed.jsonl"), "occupied")

    assert {:error, :already_exists} =
             Runtime.rename_session(c.repo, "source", "renamed", c.sessions)

    refute Process.alive?(writer)
    assert File.read!(board_path(c.source)) == before
    assert File.read!(Path.join(c.sessions, "renamed.jsonl")) == "occupied"
    assert {:ok, snapshot} = Log.snapshot(c.source)
    assert snapshot.session_id == c.root_id
    reopened = open!(c.source, snapshot.session_id)
    assert {:ok, ^posted, []} = post(reopened, c.root_id, "keep me", 1)
    assert File.read!(board_path(c.source)) == before

    assert {:ok, _, []} =
             call(
               reopened,
               c.root_id,
               "post",
               %{"channel_name" => "build", "text" => "continued"},
               2
             )
  end

  test "Runtime rename waits for an accepted board commit before moving its subtree", c do
    writer = open!(c.source, c.root_id, filesystem: {BlockingFileSystem, self()})
    write = Task.async(fn -> post(writer, c.root_id, "accepted before rename", 1) end)
    assert_receive {:board_commit_waiting, ^writer}, 1_000

    mutation =
      Task.async(fn -> Runtime.rename_session(c.repo, "source", "renamed", c.sessions) end)

    assert Task.yield(mutation, 100) == nil
    assert File.exists?(c.source)
    send(writer, :continue_board_commit)
    assert {:ok, posted, []} = Task.await(write, 5_000)
    assert {:ok, %{session_id: "renamed"}} = Task.await(mutation, 5_000)
    refute Process.alive?(writer)
    renamed = Path.join(c.sessions, "renamed.jsonl")
    moved = open!(renamed, c.root_id)
    assert read_text(moved, c.root_id, posted["message_id"]) == "accepted before rename"
    refute File.exists?(c.source <> ".subagents")
  end

  @tag :capture_log
  test "an abnormal retirement preserves its actual error and stops Runtime file mutation", c do
    writer = open!(c.source, c.root_id)
    assert {:ok, _, []} = post(writer, c.root_id, "preserve", 1)
    before = File.read!(board_path(c.source))
    assert :ok = MessageBoardStore.retire(c.source)
    start_supervised!({FailedRetirement, c.source})

    assert {:error,
            %Error{
              class: :unknown_outcome,
              cause:
                {:injected_retirement_failure, {GenServer, :call, [_pid, :retire, :infinity]}}
            }} =
             Runtime.rename_session(c.repo, "source", "renamed", c.sessions)

    assert File.exists?(c.source)
    refute File.exists?(Path.join(c.sessions, "renamed.jsonl"))
    assert File.read!(board_path(c.source)) == before
  end

  defp open!(path, root_id, opts \\ []) do
    assert {:ok, writer} =
             MessageBoardStore.open([root_transcript: path, root_id: root_id] ++ opts)

    writer
  end

  defp recreate_source(c) do
    :ok = SessionFiles.create(c.sessions, "source", %{"cwd" => c.repo}, c.repo)
    assert {:ok, snapshot} = Log.snapshot(c.source)
    refute snapshot.session_id == c.root_id
    {open!(c.source, snapshot.session_id), snapshot.session_id}
  end

  defp assert_new_root(c, moved, original) do
    {fresh, new_root_id} = recreate_source(c)
    assert {:ok, page, []} = call(fresh, new_root_id, "search_posts", %{}, 2)
    assert page["results"] == []
    assert {:ok, fresh_post, []} = post(fresh, new_root_id, "new rollout", 3)
    assert read_text(fresh, new_root_id, fresh_post["message_id"]) == "new rollout"
    assert read_text(moved, c.root_id, original["message_id"]) != "new rollout"
  end

  defp post(writer, root_id, text, n),
    do: call(writer, root_id, "post", %{"new_channel_name" => "build", "text" => text}, n)

  defp read_text(writer, root_id, message_id) do
    assert {:ok, result, []} =
             call(writer, root_id, "read_post", %{"message_id" => message_id}, 100)

    result["text"]
  end

  defp call(writer, root_id, name, arguments, n) do
    host = %{
      root_id: root_id,
      agent_id: "root",
      agent_path: "/root",
      agents: %{"/root" => "root"},
      timestamp: "2026-10-26T00:00:00Z",
      invocation_id: "call-#{n}",
      message_id: "00000000-0000-4000-8000-" <> String.pad_leading(Integer.to_string(n), 12, "0")
    }

    MessageBoardStore.execute(writer, %{name: name, arguments: arguments}, host)
  end

  defp board_path(path), do: Path.join(path <> ".subagents", "message_board.json")
end
