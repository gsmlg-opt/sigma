defmodule Sigma.Agent.BackplaneCommandHandleFunctionalTest do
  use ExUnit.Case, async: false

  alias Sigma.Agent.{Runtime, Subagents}
  alias Sigma.Agent.Backplane.{ChildIO, Store}
  alias Sigma.Session.Log

  @moduletag :tmp_dir

  defmodule Provider do
    @behaviour Sigma.Ai.Provider

    def stream(params) do
      send(params.options[:test_pid], {:command_handle_provider, self(), params})

      receive do
        {:command_handle_response, content} ->
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

  setup %{tmp_dir: dir} do
    on_exit(fn ->
      case Runtime.lookup(dir, :supervisor) do
        nil -> :ok
        pid -> DynamicSupervisor.terminate_child(Sigma.Agent.DynamicSupervisor, pid)
      end
    end)

    path = Path.join(dir, "command-handles.jsonl")

    assert {:ok, handle} =
             Runtime.get_session(dir, "command-handles",
               cwd: dir,
               transcript_path: path,
               provider: Provider,
               model: %{id: "test", provider: "test", api: "openai-responses"},
               native_tools: true,
               native_memory_root: Path.join(dir, "memories"),
               tools: [],
               hook_specs: [],
               options: [test_pid: self()]
             )

    :ok = Sigma.Agent.subscribe(handle.agent)
    assert {:accepted, _} = Sigma.Agent.prompt(handle.agent, "Finish a retained command")
    %{agent: handle.agent, path: path, dir: dir, provider: provider!()}
  end

  test "a completed command handle returns a model error and the same turn can run another command",
       c do
    {provider, handle} = completed_handle!(c.provider)
    provider = call!(provider, "write_stdin", %{"session_id" => handle, "chars" => "unused\n"})
    error = result!(provider, "write_stdin")
    assert error.is_error
    assert value!(error)["error"]["class"] == "not_found"

    provider = call!(provider, "exec_command", %{"cmd" => "printf 'after-expiry'"})
    next = result!(provider, "exec_command")
    refute next.is_error
    assert value!(next)["output"] == "after-expiry"
    finish!(provider)
    assert_receive {:agent_end, _}, 10_000
    assert Sigma.Agent.status(c.agent).phase == :completed

    assert {:ok, snapshot} = Log.snapshot(c.path)
    errors = Enum.filter(snapshot.messages, &(&1.role == :tool_result and &1.is_error))
    assert length(errors) == 1
    assert hd(errors).metadata["structured_result"]["error"]["class"] == "not_found"
  end

  # Published Backplane 1.10.42 serializes settled native errors for Code Mode.
  # Keep the actual error and successful continuation in this consumer regression.
  @tag timeout: 60_000
  test "real Deno can observe a completed handle error and continue with a native command", c do
    assert is_binary(System.find_executable("deno"))
    {provider, handle} = completed_handle!(c.provider)

    code = """
    const expired = await Promise.allSettled([
      tools.write_stdin({session_id: #{handle}, chars: "unused\\n"})
    ]);
    const next = await tools.exec_command({cmd: "printf 'nested-after-expiry'"});
    return {expired, output: next.output};
    """

    provider = call!(provider, "exec", code)
    result = result!(provider, "exec")
    refute result.is_error
    value = value!(result)
    assert value["status"] == "completed"
    assert value["value"]["output"] == "nested-after-expiry"

    assert [
             %{
               "status" => "fulfilled",
               "value" => %{"is_error" => true, "error" => %{"class" => "not_found"}}
             }
           ] = value["value"]["expired"]

    finish!(provider)
    assert_receive {:agent_end, _}, 10_000
    assert Sigma.Agent.status(c.agent).phase == :completed
  end

  test "a real child continues after direct and Deno completed-handle errors", c do
    assert is_binary(System.find_executable("deno"))

    send_call(c.provider, "spawn_agent", %{
      "task_name" => "completed_handle_child",
      "message" => "Complete a command and continue after its handle expires",
      "fork_turns" => "none"
    })

    child = provider!(:child)
    root = provider!(c.provider.params.session_id)
    refute result!(root, "spawn_agent").is_error
    {child, handle} = completed_handle!(child)
    child = call!(child, "write_stdin", %{"session_id" => handle, "chars" => "unused\n"})
    direct = result!(child, "write_stdin")
    assert direct.is_error
    assert value!(direct)["error"]["class"] == "not_found"

    child =
      call!(child, "exec", """
      const expired = await tools.write_stdin({session_id: #{handle}, chars: "unused\\n"});
      const next = await tools.exec_command({cmd: "printf 'child-after-expiry'"});
      return {expired, output: next.output};
      """)

    nested = result!(child, "exec")
    refute nested.is_error

    assert %{
             "status" => "completed",
             "value" => %{
               "expired" => %{"is_error" => true, "error" => %{"class" => "not_found"}},
               "output" => "child-after-expiry"
             }
           } = value!(nested)

    finish!(child)
    host = Runtime.lookup(c.dir, "command-handles", :subagents)

    assert eventually(fn ->
             case Subagents.snapshot(host) do
               {:ok, %{subagents: %{agents: [row]}}} -> row.status == :completed
               _ -> false
             end
           end)

    assert {:ok, sources} = Subagents.archive_sources(host)
    [source] = sources.children
    assert source.identity.child_session_id == child.params.session_id
    assert {:ok, store} = ChildIO.store(source.io)
    assert {:ok, %{run: %{state: :completed}}} = Store.load(store, source.identity.run_id)

    child_path = Path.join([c.path <> ".subagents", child.params.session_id, "session.jsonl"])
    assert {:ok, saved} = Log.snapshot(child_path)

    for result <- [direct, nested] do
      persisted =
        Enum.find(
          saved.messages,
          &(&1.role == :tool_result and &1.tool_call_id == result.tool_call_id)
        )

      assert persisted
      assert persisted.is_error == result.is_error
      assert persisted.metadata["structured_result"] == value!(result)
    end

    finish!(root)
    assert_receive {:agent_end, _}, 10_000
    assert Sigma.Agent.status(c.agent).phase == :completed
  end

  defp completed_handle!(provider) do
    provider =
      call!(provider, "exec_command", %{
        "cmd" => "read line; printf '%s' \"$line\"",
        "yield_time_ms" => 20
      })

    started = result!(provider, "exec_command")
    refute started.is_error
    assert %{"status" => "running", "session_id" => handle} = value!(started)

    provider =
      call!(provider, "write_stdin", %{
        "session_id" => handle,
        "chars" => "finished\n",
        "yield_time_ms" => 1_000
      })

    completed = result!(provider, "write_stdin")
    refute completed.is_error
    assert %{"exit_code" => 0, "output" => output} = value!(completed)
    assert output =~ "finished"
    {provider, handle}
  end

  defp call!(provider, name, args) do
    send_call(provider, name, args)
    provider!(provider.params.session_id)
  end

  defp send_call(provider, name, args) do
    send(provider.pid, {
      :command_handle_response,
      [
        %{
          type: :tool_call,
          id: "command-handle-#{System.unique_integer([:positive])}",
          name: name,
          arguments: args,
          input_kind: if(is_binary(args), do: :custom, else: :function)
        }
      ]
    })
  end

  defp provider!(session \\ :any) do
    receive do
      {:command_handle_provider, pid, params} when session == :any ->
        %{pid: pid, params: params}

      {:command_handle_provider, pid, %{session_id: "child_" <> _} = params}
      when session == :child ->
        %{pid: pid, params: params}

      {:command_handle_provider, pid, %{session_id: ^session} = params} ->
        %{pid: pid, params: params}

      {:turn_error, error} ->
        flunk("command turn failed: #{inspect(error)}")
    after
      10_000 -> flunk("command Provider did not start")
    end
  end

  defp result!(provider, name),
    do:
      Enum.find(
        Enum.reverse(provider.params.context.messages),
        &(Map.get(&1, :tool_name) == name)
      )

  defp value!(message) do
    assert [%{type: :text, text: json}] = message.content
    Jason.decode!(json)
  end

  defp finish!(provider),
    do: send(provider.pid, {:command_handle_response, [%{type: :text, text: "done"}]})

  defp eventually(fun, attempts \\ 150)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    if fun.(),
      do: true,
      else:
        (
          Process.sleep(20)
          eventually(fun, attempts - 1)
        )
  end
end
