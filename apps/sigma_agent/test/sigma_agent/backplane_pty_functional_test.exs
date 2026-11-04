defmodule Sigma.Agent.BackplanePtyFunctionalTest do
  use ExUnit.Case, async: false

  alias Sigma.Agent.{Runtime, Subagents}
  alias Sigma.Session.Log

  @moduletag :tmp_dir

  defmodule Provider do
    @behaviour Sigma.Ai.Provider

    def stream(params) do
      send(params.options[:test_pid], {:pty_provider, self(), params})

      receive do
        {:pty_response, content} ->
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

    path = Path.join(dir, "pty-root.jsonl")

    assert {:ok, handle} =
             Runtime.get_session(dir, "pty-root",
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
    %{agent: handle.agent, path: path}
  end

  test "a root PTY retains real terminal dimensions and Unicode stdin across successful turns",
       c do
    provider = prompt!(c.agent)
    provider = call!(provider, "exec_command", retained_command())
    started = result!(provider, "exec_command")
    assert started["status"] == "running"
    assert started["output"] == "24 120\r\npty-ready\r\n"
    assert is_integer(started["session_id"])
    finish_root!(c.agent, provider)

    provider = prompt!(c.agent)
    assert result!(provider, "exec_command") == started

    provider =
      call!(provider, "write_stdin", %{
        "session_id" => started["session_id"],
        "chars" => "  中文 stdin  \n",
        "yield_time_ms" => 2_000
      })

    completed = result!(provider, "write_stdin")
    assert completed["output"] == "got:  中文 stdin  \r\n"
    assert completed["exit_code"] == 7
    assert completed["status"] == "completed"
    assert completed["cleanup_status"] == "confirmed"
    refute Map.has_key?(completed, "session_id")
    finish_root!(c.agent, provider)

    assert {:ok, saved} = Log.snapshot(c.path)
    assert saved_result(saved.messages, "exec_command") == started
    assert saved_result(saved.messages, "write_stdin") == completed
  end

  @tag timeout: 60_000
  test "real Deno receives a complete native PTY result including a nonzero command exit", c do
    assert is_binary(System.find_executable("deno"))
    provider = prompt!(c.agent)

    args = %{
      "cmd" => "[ -t 0 ] && [ -t 1 ] || exit 41; printf 'nested 中文\\n'; exit 3",
      "shell" => "/bin/sh",
      "login" => false,
      "tty" => true,
      "yield_time_ms" => 2_000
    }

    provider = call!(provider, "exec", "return await tools.exec_command(#{Jason.encode!(args)});")
    nested = result!(provider, "exec")
    assert nested["status"] == "completed"
    assert nested["value"]["output"] == "nested 中文\r\n"
    assert nested["value"]["exit_code"] == 3
    assert nested["value"]["cleanup_status"] == "confirmed"
    finish_root!(c.agent, provider)
    assert {:ok, saved} = Log.snapshot(c.path)
    assert saved_result(saved.messages, "exec") == nested
  end

  @tag timeout: 60_000
  test "a managed child resumes its retained PTY through real Deno in a later followup", c do
    assert is_binary(System.find_executable("deno"))
    root = prompt!(c.agent)
    host = Runtime.lookup(c.tmp_dir, "pty-root", :subagents)

    send_call(root, "spawn_agent", %{
      "task_name" => "pty_worker",
      "message" => "Keep a terminal for the requested followup",
      "fork_turns" => "none"
    })

    child = provider!(:child)
    root = provider!("pty-root")
    _spawned = result!(root, "spawn_agent")
    child = call!(child, "exec_command", retained_command())
    started = result!(child, "exec_command")
    assert started["status"] == "running"
    assert started["output"] == "24 120\r\npty-ready\r\n"
    finish!(child)
    assert eventually(fn -> roster(host).counts.stopped == 1 end)

    send_call(root, "followup_task", %{
      "target" => "/root/pty_worker",
      "message" => "Finish stdin"
    })

    child = provider!(child.params.session_id)
    root = provider!("pty-root")
    _followup = result!(root, "followup_task")

    args = %{
      "session_id" => started["session_id"],
      "chars" => "child 中文\n",
      "yield_time_ms" => 2_000
    }

    child = call!(child, "exec", "return await tools.write_stdin(#{Jason.encode!(args)});")
    nested = result!(child, "exec")
    assert nested["status"] == "completed"
    assert nested["value"]["output"] == "got:child 中文\r\n"
    assert nested["value"]["exit_code"] == 7
    assert nested["value"]["cleanup_status"] == "confirmed"
    finish!(child)
    assert eventually(fn -> roster(host).counts.stopped == 1 end)
    [row] = roster(host).agents
    path = Path.join([c.path <> ".subagents", row.child_session_id, "session.jsonl"])
    assert {:ok, saved} = Log.snapshot(path)
    assert saved_result(saved.messages, "exec_command") == started
    assert saved_result(saved.messages, "exec") == nested
    finish_root!(c.agent, root)
  end

  defp retained_command do
    stty = System.find_executable("stty")
    assert is_binary(stty)
    stty = "'" <> String.replace(stty, "'", "'\\''") <> "'"

    %{
      "cmd" =>
        "[ -t 0 ] && [ -t 1 ] || exit 41; #{stty} -echo; #{stty} size; " <>
          "printf 'pty-ready\\n'; IFS= read -r line; printf 'got:%s\\n' \"$line\"; exit 7",
      "shell" => "/bin/sh",
      "login" => false,
      "tty" => true,
      "yield_time_ms" => 1_000
    }
  end

  defp prompt!(agent) do
    assert {:accepted, _} = Sigma.Agent.prompt(agent, "Exercise the requested PTY command")
    provider!("pty-root")
  end

  defp provider!(session) do
    receive do
      {:pty_provider, pid, %{session_id: "child_" <> _} = params} when session == :child ->
        %{pid: pid, params: params}

      {:pty_provider, pid, %{session_id: id} = params} when session == id ->
        %{pid: pid, params: params}

      {:turn_error, error} ->
        flunk("PTY turn failed: #{inspect(error)}")
    after
      10_000 -> flunk("PTY Provider did not start for #{session}")
    end
  end

  defp call!(provider, name, args) do
    send_call(provider, name, args)
    provider!(provider.params.session_id)
  end

  defp send_call(provider, name, args) do
    send(
      provider.pid,
      {:pty_response,
       [
         %{
           type: :tool_call,
           id: "pty-#{System.unique_integer([:positive])}",
           name: name,
           arguments: args,
           input_kind: if(is_binary(args), do: :custom, else: :function)
         }
       ]}
    )
  end

  defp result!(provider, name) do
    result =
      Enum.find(
        Enum.reverse(provider.params.context.messages),
        &(Map.get(&1, :tool_name) == name)
      )

    assert result, "missing #{name} in next Provider input"
    refute result.is_error
    assert [%{type: :text, text: json}] = result.content
    Jason.decode!(json)
  end

  defp saved_result(messages, name) do
    result = Enum.find(Enum.reverse(messages), &(Map.get(&1, :tool_name) == name))
    assert result
    result.metadata["structured_result"]
  end

  defp finish!(provider), do: send(provider.pid, {:pty_response, [%{type: :text, text: "done"}]})

  defp finish_root!(agent, provider) do
    finish!(provider)
    assert_receive {:agent_end, _}, 10_000
    assert Sigma.Agent.status(agent).phase == :completed
  end

  defp roster(host) do
    assert {:ok, %{available: true, subagents: roster}} = Subagents.snapshot(host)
    roster
  end

  defp eventually(fun, attempts \\ 200)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    if fun.(),
      do: true,
      else:
        (
          Process.sleep(10)
          eventually(fun, attempts - 1)
        )
  end
end
