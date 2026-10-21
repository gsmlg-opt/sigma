defmodule Sigma.Coding.Hooks.RunnerTest do
  use ExUnit.Case, async: true

  alias Sigma.Coding.Hooks.{AsyncRuntime, Outcome, Runner, Spec}
  alias Sigma.Coding.Hooks.Spec.{Command, McpTool}

  @moduletag :tmp_dir

  setup %{tmp_dir: directory} do
    supervisor = start_supervised!({Task.Supervisor, []})

    %{
      ctx: %{
        cwd: directory,
        session_id: "s",
        turn_id: "t",
        model: "model",
        hook_task_supervisor: supervisor
      }
    }
  end

  test "stdin reaches EOF and event-data matcher selection uses the canonical tool", %{
    ctx: ctx,
    tmp_dir: directory
  } do
    command =
      ~S(cat > payload.json; printf '%s' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"read stdin"}}')

    spec = %{command(:pre_tool_use, command) | matcher: "Bash"}

    assert {{:context, "read stdin"}, []} =
             Runner.run(:pre_tool_use, [spec], ctx, %{
               tool_name: "exec_command",
               tool_input: %{"command" => "true"}
             })

    payload = Jason.decode!(File.read!(Path.join(directory, "payload.json")))
    assert payload["tool_name"] == "Bash"
    assert payload["turn_id"] == "t"
  end

  test "stderr is separate and exit two wins over conflicting JSON stdout", %{ctx: ctx} do
    command = ~S(printf '%s' '{"continue":false}'; printf '%s' 'policy denied' >&2; exit 2)

    assert {{:block, "policy denied"}, []} =
             Runner.run(:pre_tool_use, [command(:pre_tool_use, command)], ctx)
  end

  test "configured identical commands each execute once", %{ctx: ctx, tmp_dir: directory} do
    spec = command(:stop, "printf x >> executions")
    assert {:proceed, []} = Runner.run(:stop, [spec, spec], ctx)
    assert File.read!(Path.join(directory, "executions")) == "xx"
  end

  test "collected command exit statuses preserve intentionally detached helpers", %{
    ctx: ctx,
    tmp_dir: directory
  } do
    for exit <- [0, 1] do
      marker = "detached-#{exit}"
      script = "(sleep 0.2; touch #{marker}) </dev/null >/dev/null 2>&1 & exit #{exit}"

      assert {:proceed, warnings} =
               Runner.run(:stop, [command(:stop, script)], Map.put(ctx, :hook_shell, "/bin/sh"))

      assert length(warnings) == exit
      await_file(Path.join(directory, marker), 200)
    end
  end

  test "continuous output does not extend the absolute timeout and descendants are stopped", %{
    ctx: ctx,
    tmp_dir: directory
  } do
    script = "(sleep 0.4; touch escaped) & while :; do printf x; done"
    spec = command(:stop, script, timeout_ms: 80)
    started = System.monotonic_time(:millisecond)
    assert {:proceed, warnings} = Runner.run(:stop, [spec], ctx)
    assert Enum.any?(warnings, &String.contains?(&1, "timed out"))
    assert System.monotonic_time(:millisecond) - started < 1_500
    Process.sleep(500)
    refute File.exists?(Path.join(directory, "escaped"))
  end

  test "async commands return immediately and cannot apply control effects", %{ctx: ctx} do
    test_pid = self()

    script =
      ~S(sleep 0.2; printf '%s' '{"decision":"block","reason":"ignored","hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"later"}}')

    spec = command(:user_prompt_submit, script, async: true)

    ctx =
      Map.put(ctx, :hook_async_callback, fn text, warnings ->
        send(test_pid, {:async, text, warnings})
      end)

    started = System.monotonic_time(:millisecond)
    assert {:proceed, []} = Runner.run(:user_prompt_submit, [spec], ctx)
    assert System.monotonic_time(:millisecond) - started < 150
    assert_receive {:async, "later", []}, 1_500
  end

  test "async unsupported control fields preserve valid additional context", %{ctx: ctx} do
    test_pid = self()

    script =
      ~S(printf '%s' '{"continue":false,"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"retained"}}')

    ctx = Map.put(ctx, :hook_async_callback, &send(test_pid, {:async, &1, &2}))

    assert {:proceed, []} =
             Runner.run(:pre_tool_use, [command(:pre_tool_use, script, async: true)], ctx)

    assert_receive {:async, "retained", []}, 1_000
  end

  test "session owner death cancels running async shell process groups", %{
    ctx: ctx,
    tmp_dir: directory
  } do
    owner = spawn(fn -> receive do: (:stop -> :ok) end)

    runtime =
      start_supervised!({AsyncRuntime, {owner, task_supervisor: ctx.hook_task_supervisor}})

    ctx = Map.put(ctx, :hook_async_runtime, runtime)
    script = "touch started; (sleep 0.4; touch escaped) & wait"
    assert {:proceed, []} = Runner.run(:stop, [command(:stop, script, async: true)], ctx)
    await_file(Path.join(directory, "started"), 200)
    Process.exit(owner, :kill)
    Process.sleep(500)
    refute File.exists?(Path.join(directory, "escaped"))
  end

  test "owner death preserves helpers released by a completed async hook", %{
    ctx: ctx,
    tmp_dir: directory
  } do
    owner = spawn(fn -> receive do: (:stop -> :ok) end)

    runtime =
      start_supervised!({AsyncRuntime, {owner, task_supervisor: ctx.hook_task_supervisor}})

    test_pid = self()

    ctx =
      Map.merge(ctx, %{
        hook_async_runtime: runtime,
        hook_shell: "/bin/sh",
        hook_async_callback: fn _, _ -> send(test_pid, :completed) end
      })

    script = "(sleep 0.3; touch detached) </dev/null >/dev/null 2>&1 &"
    assert {:proceed, []} = Runner.run(:stop, [command(:stop, script, async: true)], ctx)
    assert_receive :completed, 1_000
    Process.exit(owner, :kill)
    await_file(Path.join(directory, "detached"), 200)
  end

  test "cancelling the dispatch owner cleans up its command process group", %{
    ctx: ctx,
    tmp_dir: directory
  } do
    started = Path.join(directory, "started")
    escaped = Path.join(directory, "escaped")
    spec = command(:stop, "touch started; (sleep 0.4; touch escaped) & wait")
    task = Task.async(fn -> Runner.run(:stop, [spec], ctx) end)
    await_file(started, 200)
    Task.shutdown(task, :brutal_kill)
    Process.sleep(500)
    refute File.exists?(escaped)
  end

  test "cancellation during startup cannot release an unowned command or background child", %{
    ctx: ctx,
    tmp_dir: directory
  } do
    try do
      for index <- 1..30 do
        script =
          "printf '%s' \"$$\" > startup-pid-#{index}; (sleep 0.3; touch startup-escaped-#{index}) & wait"

        spec = command(:stop, script)

        task =
          Task.async(fn -> Runner.run(:stop, [spec], Map.put(ctx, :hook_shell, "/bin/sh")) end)

        # Do not wait for the command to publish its own started marker. This
        # exercises cancellation before and during subprocess initialization.
        Process.sleep(rem(index, 4))
        Task.shutdown(task, :brutal_kill)
      end

      Process.sleep(500)
      assert Path.wildcard(Path.join(directory, "startup-escaped-*")) == []
    after
      for path <- Path.wildcard(Path.join(directory, "startup-pid-*")),
          {:ok, text} <- [File.read(path)],
          {pid, ""} <- [Integer.parse(text)],
          pid > 0 do
        System.cmd("kill", ["-KILL", "--", "-#{pid}"], stderr_to_stdout: true)
      end
    end
  end

  test "MCP templates preserve exact JSON types and interpolate embedded values", %{ctx: ctx} do
    test_pid = self()

    handler = %McpTool{
      server: "server",
      tool: "tool",
      timeout_ms: 500,
      input: %{
        "number" => "${tool_input.count}",
        "nested" => ["${tool_input.items}"],
        "text" => "count=${tool_input.count}; items=${tool_input.items}"
      }
    }

    spec = spec(:pre_tool_use, handler)

    executor = fn server, tool, input, timeout ->
      send(test_pid, {:called, server, tool, input, timeout})

      {:ok,
       %{
         exit: 0,
         stdout:
           ~S({"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"MCP context"}}),
         stderr: ""
       }}
    end

    assert {{:context, "MCP context"}, []} =
             Runner.run(:pre_tool_use, [spec], Map.put(ctx, :mcp_hook_executor, executor), %{
               tool_input: %{"count" => 3, "items" => [true, 2]}
             })

    assert_receive {:called, "server", "tool",
                    %{
                      "number" => 3,
                      "nested" => [[true, 2]],
                      "text" => "count=3; items=[true,2]"
                    }, 500}
  end

  test "missing MCP fields fail without calling the server", %{ctx: ctx} do
    test_pid = self()

    handler = %McpTool{
      server: "server",
      tool: "tool",
      timeout_ms: 100,
      input: %{"value" => "${missing.field}"}
    }

    executor = fn _, _, _, _ ->
      send(test_pid, :unexpected)
      {:ok, %{exit: 0, stdout: "", stderr: ""}}
    end

    assert {:proceed, [warning]} =
             Runner.run(:stop, [spec(:stop, handler)], Map.put(ctx, :mcp_hook_executor, executor))

    assert warning =~ "was not found"
    refute_receive :unexpected
  end

  test "MCP executor failures and timeouts remain diagnostics", %{ctx: ctx} do
    handler = %McpTool{server: "server", tool: "tool", timeout_ms: 30}

    executor = fn _, _, _, _ ->
      Process.sleep(500)
      {:ok, %{exit: 0, stdout: "", stderr: ""}}
    end

    assert {:proceed, [warning]} =
             Runner.run(:stop, [spec(:stop, handler)], Map.put(ctx, :mcp_hook_executor, executor))

    assert warning =~ "timed out"
    executor = fn _, _, _, _ -> raise "failed server" end

    assert {:proceed, [_]} =
             Runner.run(:stop, [spec(:stop, handler)], Map.put(ctx, :mcp_hook_executor, executor))
  end

  test "cancelling the dispatch owner stops its blocked MCP executor", %{ctx: ctx} do
    test_pid = self()
    handler = %McpTool{server: "server", tool: "tool", timeout_ms: 10_000}

    executor = fn _, _, _, _ ->
      send(test_pid, {:mcp_started, self()})
      receive do: (:release -> {:ok, %{exit: 0, stdout: "", stderr: ""}})
    end

    task =
      Task.async(fn ->
        Runner.run(:stop, [spec(:stop, handler)], Map.put(ctx, :mcp_hook_executor, executor))
      end)

    assert_receive {:mcp_started, executor_pid}
    ref = Process.monitor(executor_pid)
    Task.shutdown(task, :brutal_kill)
    assert_receive {:DOWN, ^ref, :process, ^executor_pid, _reason}
  end

  test "last completed full input replacement wins without merging fields", %{ctx: ctx} do
    first =
      ~S(sleep 0.08; printf '%s' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","updatedInput":{"last":2},"additionalContext":"later"}}')

    second =
      ~S(printf '%s' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","updatedInput":{"first":1}}}')

    {outcome, []} =
      Runner.run(
        :pre_tool_use,
        [command(:pre_tool_use, first), command(:pre_tool_use, second)],
        ctx
      )

    assert Outcome.control(outcome) == {:replace_input, %{"last" => 2}}
    assert Outcome.context(outcome) == "later"
  end

  defp command(event, cmd, options \\ []) do
    handler = struct!(Command, Keyword.merge([cmd: cmd, timeout_ms: 1_000], options))
    spec(event, handler)
  end

  defp spec(event, handler),
    do: %Spec{
      event: event,
      handler: handler,
      matcher: :any,
      origin: {:user, "/user"},
      dialect: :pi,
      trusted?: true
    }

  defp await_file(_path, 0), do: flunk("Hook did not start")

  defp await_file(path, remaining) do
    if File.exists?(path) do
      :ok
    else
      Process.sleep(5)
      await_file(path, remaining - 1)
    end
  end
end
