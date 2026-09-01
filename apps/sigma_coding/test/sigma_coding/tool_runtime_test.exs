defmodule Sigma.Coding.ToolRuntimeTest do
  use ExUnit.Case, async: true

  alias Sigma.Coding.{Dispatcher, PermissionPolicy, Tool, ToolError, ToolMetadata, ToolUpdate}

  defmodule SharedProbe do
    @behaviour Sigma.Coding.Tool

    @impl true
    def name, do: "shared_probe"
    @impl true
    def description, do: "shared probe"
    @impl true
    def schema, do: %{}
    @impl true
    def metadata, do: %{effect: :read, concurrency: :shared, default_deadline_ms: 1_000}

    @impl true
    def execute(id, params, opts) do
      owner = Keyword.fetch!(opts, :test_pid)
      send(owner, {:started, id, self(), Map.get(params, "path")})

      case Map.get(params, "action", "block") do
        "block" ->
          receive do
            {:release, ^id} -> {:ok, %{content: [%{type: :text, text: id}], details: %{}}}
          end

        "partial" ->
          update = Keyword.fetch!(opts, :on_update)
          update.(%{content: [%{type: :text, text: "one"}], details: %{}})
          update.(%{content: [%{type: :text, text: "two"}], details: %{}})
          {:ok, %{content: [%{type: :text, text: "done"}], details: %{}}}

        "crash" ->
          raise "probe crash"

        "malformed" ->
          {:ok, %{unexpected: true}}

        "sleep" ->
          Process.sleep(Map.fetch!(params, "ms"))
          {:ok, %{content: [%{type: :text, text: "late"}], details: %{}}}
      end
    end
  end

  defmodule WriteProbe do
    @behaviour Sigma.Coding.Tool

    @impl true
    def name, do: "write_probe"
    @impl true
    def description, do: "write probe"
    @impl true
    def schema, do: %{}
    @impl true
    def metadata,
      do: %{
        effect: :write,
        concurrency: :sequential,
        interruptible: false,
        default_deadline_ms: 1_000
      }

    @impl true
    def execute(id, params, opts) do
      owner = Keyword.fetch!(opts, :test_pid)
      send(owner, {:started, id, self(), Map.fetch!(params, "path")})

      receive do
        {:release, ^id} -> {:ok, %{content: [%{type: :text, text: id}], details: %{}}}
      end
    end
  end

  defmodule NeverExecute do
    @behaviour Sigma.Coding.Tool

    @impl true
    def name, do: "never_execute"
    @impl true
    def description, do: "must remain denied"
    @impl true
    def schema, do: %{}
    @impl true
    def execute(_id, _params, opts) do
      send(Keyword.fetch!(opts, :test_pid), :executed)
      {:ok, %{content: [%{type: :text, text: "bad"}], details: %{}}}
    end
  end

  setup do
    task_supervisor = start_supervised!({Task.Supervisor, name: unique_name()})
    {:ok, task_supervisor: task_supervisor}
  end

  test "derives explicit built-in metadata and conservative MCP defaults" do
    assert %ToolMetadata{
             effect: :write,
             concurrency: :sequential,
             interruptible: false,
             discoverable: true
           } = Tool.metadata(Sigma.Coding.Tools.Write, %{arguments: %{"path" => "file"}}, cwd: File.cwd!())

    mcp_tool = %Sigma.Coding.MCP.Tool{name: "mcp__server__unknown", schema: %{}}

    assert %ToolMetadata{
             effect: :network,
             concurrency: :sequential,
             approval_tier: :guarded,
             discoverable: true
           } = Tool.metadata(mcp_tool, %{arguments: %{}}, cwd: File.cwd!())
  end

  test "parallel shared work respects max_parallel and stable result order", %{task_supervisor: ts} do
    calls = for id <- ~w(one two three), do: call(id, "shared_probe", %{"path" => id})
    test_pid = self()

    batch =
      Task.async(fn ->
        Dispatcher.dispatch_batch(calls, [SharedProbe],
          task_supervisor: ts,
          test_pid: test_pid,
          max_parallel: 2
        )
      end)

    started = receive_started(2, [])
    refute_receive {:started, "three", _pid, _path}, 50
    Enum.each(started, fn {id, pid} -> send(pid, {:release, id}) end)

    assert_receive {:started, "three", third_pid, "three"}
    send(third_pid, {:release, "three"})

    results = Task.await(batch)
    assert Enum.map(results, fn {tool_call, _result} -> tool_call.id end) == ~w(one two three)
    assert Enum.all?(results, fn {_tool_call, result} -> match?({:ok, _}, result) end)
  end

  @tag :tmp_dir
  test "writes resolving to the same canonical path never overlap", %{
    task_supervisor: ts,
    tmp_dir: tmp_dir
  } do
    real_path = Path.join(tmp_dir, "real.txt")
    link_path = Path.join(tmp_dir, "link.txt")
    File.write!(real_path, "content")
    File.ln_s!(real_path, link_path)

    calls = [
      call("real", "write_probe", %{"path" => real_path}),
      call("link", "write_probe", %{"path" => link_path})
    ]
    test_pid = self()

    batch =
      Task.async(fn ->
        Dispatcher.dispatch_batch(calls, [WriteProbe],
          task_supervisor: ts,
          test_pid: test_pid,
          cwd: tmp_dir,
          max_parallel: 2
        )
      end)

    assert_receive {:started, "real", first_pid, ^real_path}
    refute_receive {:started, "link", _pid, _path}, 50
    send(first_pid, {:release, "real"})
    assert_receive {:started, "link", second_pid, ^link_path}
    send(second_pid, {:release, "link"})
    assert [_first, _second] = Task.await(batch)
  end

  @tag :tmp_dir
  test "sequential writes do not overlap even with independent resources", %{task_supervisor: ts, tmp_dir: tmp_dir} do
    first_path = Path.join(tmp_dir, "first")
    second_path = Path.join(tmp_dir, "second")

    calls = [
      call("first", "write_probe", %{"path" => first_path}),
      call("second", "write_probe", %{"path" => second_path})
    ]
    test_pid = self()

    batch =
      Task.async(fn ->
        Dispatcher.dispatch_batch(calls, [WriteProbe],
          task_supervisor: ts,
          test_pid: test_pid,
          cwd: tmp_dir,
          max_parallel: 2
        )
      end)

    assert_receive {:started, "first", first_pid, ^first_path}
    refute_receive {:started, "second", _pid, _path}, 50
    send(first_pid, {:release, "first"})
    assert_receive {:started, "second", second_pid, ^second_path}
    send(second_pid, {:release, "second"})
    assert [_first, _second] = Task.await(batch)
  end

  test "deadlines terminate interruptible work and return a typed timeout", %{task_supervisor: ts} do
    [{_call, result}] =
      Dispatcher.dispatch_batch(
        [call("slow", "shared_probe", %{"action" => "sleep", "ms" => 500})],
        [SharedProbe],
        task_supervisor: ts,
        test_pid: self(),
        deadline_ms: 30
      )

    assert {:error, %ToolError{kind: :timeout, retryable: true}} = result
  end

  @tag :tmp_dir
  test "indeterminate non-interruptible work retains its resource lock until exit", %{
    task_supervisor: ts,
    tmp_dir: tmp_dir
  } do
    path = Path.join(tmp_dir, "resource")
    test_pid = self()

    first =
      Task.async(fn ->
        Dispatcher.dispatch_batch(
          [call("first", "write_probe", %{"path" => path})],
          [WriteProbe],
          task_supervisor: ts,
          test_pid: test_pid,
          deadline_ms: 10,
          shutdown_budget_ms: 10
        )
      end)

    assert_receive {:started, "first", first_pid, ^path}
    assert [{_call, {:error, %ToolError{kind: :indeterminate}}}] = Task.await(first)

    second =
      Task.async(fn ->
        Dispatcher.dispatch_batch(
          [call("second", "write_probe", %{"path" => path})],
          [WriteProbe],
          task_supervisor: ts,
          test_pid: test_pid
        )
      end)

    refute_receive {:started, "second", _pid, ^path}, 50
    send(first_pid, {:release, "first"})
    assert_receive {:started, "second", second_pid, ^path}, 1_000
    send(second_pid, {:release, "second"})
    assert [{_call, {:ok, _result}}] = Task.await(second)
  end

  @tag :tmp_dir
  test "batch cancellation terminates Bash and returns one cancelled result", %{
    task_supervisor: ts,
    tmp_dir: tmp_dir
  } do
    target = Path.join(tmp_dir, "late")
    signal = make_ref()
    test_pid = self()
    handler_id = {__MODULE__, self(), :cancellation_trace}

    :telemetry.attach(
      handler_id,
      [:sigma, :tool, :call, :start],
      fn _event, _measurements, _metadata, _config ->
        send(test_pid, {:tool_task_started, self()})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    batch =
      Task.async(fn ->
        Dispatcher.dispatch_batch(
          [call("bash", "bash", %{"command" => "sleep 1; touch #{target}"})],
          [Sigma.Coding.Tools.Bash],
          task_supervisor: ts,
          cwd: tmp_dir,
          signal: signal
        )
      end)

    assert_receive {:tool_task_started, _tool_task}
    send(batch.pid, {:abort, signal})

    assert [{_call, {:error, %ToolError{kind: :cancelled}}}] = Task.await(batch)
    Process.sleep(1_100)
    refute File.exists?(target)
  end

  @tag :capture_log
  test "crashes and malformed results fail closed without crashing the caller", %{task_supervisor: ts} do
    calls = [
      call("crash", "shared_probe", %{"action" => "crash"}),
      call("malformed", "shared_probe", %{"action" => "malformed"})
    ]

    assert [
             {_crash, {:error, %ToolError{kind: :crash}}},
             {_malformed, {:error, %ToolError{kind: :malformed_result}}}
           ] =
             Dispatcher.dispatch_batch(calls, [SharedProbe],
               task_supervisor: ts,
               test_pid: self()
             )
  end

  test "partial updates reach the normalized callback in order", %{task_supervisor: ts} do
    test_pid = self()

    assert [{_call, {:ok, _result}}] =
             Dispatcher.dispatch_batch(
               [call("partial", "shared_probe", %{"action" => "partial"})],
               [SharedProbe],
               task_supervisor: ts,
               test_pid: self(),
               on_tool_update: fn update -> send(test_pid, {:update, update}) end
             )

    assert_receive {:update, %ToolUpdate{tool_call_id: "partial", sequence: 1, content: content1}}
    assert_receive {:update, %ToolUpdate{tool_call_id: "partial", sequence: 2, content: content2}}
    assert [%{text: "one"}] = content1
    assert [%{text: "two"}] = content2
  end

  test "permission denial happens before scheduler execution", %{task_supervisor: ts} do
    {:ok, policy} = PermissionPolicy.start_link(default: :allow)
    PermissionPolicy.deny_tool(policy, "never_execute")

    assert [{_call, {:error, %ToolError{kind: :permission_denied}}}] =
             Dispatcher.dispatch_batch(
               [call("denied", "never_execute", %{})],
               [NeverExecute],
               task_supervisor: ts,
               test_pid: self(),
               permission_policy: policy
             )

    refute_receive :executed
  end

  defp call(id, name, arguments), do: %{id: id, name: name, arguments: arguments}

  defp receive_started(0, acc), do: acc

  defp receive_started(remaining, acc) do
    receive do
      {:started, id, pid, _path} -> receive_started(remaining - 1, [{id, pid} | acc])
    after
      1_000 -> flunk("expected #{remaining} more tool(s) to start")
    end
  end

  defp unique_name do
    Module.concat(__MODULE__, "Tasks#{System.unique_integer([:positive])}")
  end
end
