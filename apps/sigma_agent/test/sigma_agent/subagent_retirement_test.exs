defmodule Sigma.Agent.SubagentRetirementTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.Error
  alias Sigma.Agent.{RepositoryProcess, Runtime}

  defmodule OperationAgent do
    use GenServer
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
    def init(opts), do: {:ok, opts}
    def handle_call(:begin_session_operation, _from, state), do: {:reply, :ok, state}
    def handle_call(:end_session_operation, _from, state), do: {:reply, :ok, state}
  end

  defmodule WriterProbe do
    use GenServer
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
    def init(opts), do: {:ok, Map.new(opts)}

    def handle_call(:flush, _from, state) do
      send(state.test_pid, {:writer_flushed, File.read!(state.source_path)})
      {:reply, {:ok, %{}}, state}
    end
  end

  defmodule HostProbe do
    use GenServer
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: opts[:name])
    def init(opts), do: {:ok, Map.new(opts)}

    def handle_call(:close, _from, state) do
      send(
        state.test_pid,
        {:host_closed, Process.alive?(state.writer), File.exists?(state.source_path)}
      )

      if match?({:ok, %{status: :confirmed}}, state.result) do
        File.write!(state.source_path, "closed root\n", [:append])
        File.write!(Path.join(state.children, "child/session.jsonl"), "closed child\n", [:append])
      end

      {:reply, state.result, state}
    end
  end

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    repo = Path.join(dir, "repo")
    File.mkdir_p!(repo)
    source_path = Path.join(repo, "source.jsonl")
    children = source_path <> ".subagents"
    File.mkdir_p!(Path.join(children, "child/runtime"))
    File.write!(source_path, "root\n")
    File.write!(Path.join(children, "child/session.jsonl"), "child\n")
    File.write!(Path.join(children, "child/runtime/run.runtime"), "runtime")
    agent = start_supervised!(OperationAgent)
    writer = start_supervised!({WriterProbe, test_pid: self(), source_path: source_path})
    repository = start_supervised!({RepositoryProcess, repo_path: repo})

    :sys.replace_state(repository, fn state ->
      %{
        state
        | sessions: %{
            "source" => %{session: agent, agent: agent, writer: writer, session_supervisor: nil}
          }
      }
    end)

    %{
      repo: repo,
      source_path: source_path,
      children: children,
      writer: writer,
      repository: repository
    }
  end

  test "rename confirms host closure and flushes before moving retained artifacts", ctx do
    host = start_host(ctx, {:ok, %{status: :confirmed}})

    assert {:ok, %{session_id: "renamed"}} =
             RepositoryProcess.session_operation(
               ctx.repository,
               "source",
               {:rename, "renamed", ctx.repo, []}
             )

    assert_receive {:host_closed, true, true}
    assert_receive {:writer_flushed, "root\nclosed root\n"}
    assert Process.alive?(host)
    assert File.read!(Path.join(ctx.repo, "renamed.jsonl")) == "root\nclosed root\n"

    assert File.read!(Path.join(ctx.repo, "renamed.jsonl.subagents/child/session.jsonl")) ==
             "child\nclosed child\n"

    refute File.exists?(ctx.children)
  end

  test "unknown closure prevents rename adoption and delete without flushing or moving evidence",
       ctx do
    error = Error.new(:unknown_outcome, "closure unconfirmed")
    start_host(ctx, {:error, error})

    operations = [
      {:rename, "renamed", ctx.repo, []},
      {:adopt, ctx.repo, Path.join(ctx.repo, "adopted"), ctx.repo, []},
      {:delete, ctx.repo, []}
    ]

    for operation <- operations do
      assert {:error, ^error} =
               RepositoryProcess.session_operation(ctx.repository, "source", operation)

      assert_receive {:host_closed, true, true}
      assert File.read!(ctx.source_path) == "root\n"
      assert File.read!(Path.join(ctx.children, "child/session.jsonl")) == "child\n"
    end

    refute_receive {:writer_flushed, _}
    refute File.exists?(Path.join(ctx.repo, "renamed.jsonl"))
    refute File.exists?(Path.join(ctx.repo, "adopted"))
  end

  test "an unconfirmed close acknowledgement blocks deletion", ctx do
    start_host(ctx, {:ok, %{status: :unknown}})

    assert {:error, %Error{class: :unknown_outcome}} =
             RepositoryProcess.session_operation(
               ctx.repository,
               "source",
               {:delete, ctx.repo, []}
             )

    assert File.exists?(ctx.source_path)
    assert File.exists?(ctx.children)
    refute_receive {:writer_flushed, _}
  end

  defp start_host(ctx, result) do
    start_supervised!(
      {HostProbe,
       test_pid: self(),
       result: result,
       writer: ctx.writer,
       source_path: ctx.source_path,
       children: ctx.children,
       name: Runtime.via(ctx.repo, "source", :subagents)}
    )
  end
end
