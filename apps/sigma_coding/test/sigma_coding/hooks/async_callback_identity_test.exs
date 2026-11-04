defmodule Sigma.Coding.Hooks.AsyncCallbackIdentityTest do
  use ExUnit.Case, async: true

  alias Sigma.Coding.Hooks.{Runner, Spec}
  alias Sigma.Coding.Hooks.Spec.Command

  @moduletag :tmp_dir

  defmodule QueueProbe do
    use GenServer

    def start_link(owner), do: GenServer.start_link(__MODULE__, owner)
    def init(owner), do: {:ok, owner}

    def handle_call({:schedule, fun}, _from, owner) do
      send(owner, {:queued, fun})
      {:reply, :ok, owner}
    end

    def handle_call({:track_command, _worker}, _from, owner), do: {:reply, :ok, owner}
  end

  setup %{tmp_dir: directory} do
    supervisor = start_supervised!({Task.Supervisor, []})
    queue = start_supervised!({QueueProbe, self()})

    %{
      ctx: %{
        cwd: directory,
        session_id: "session-1",
        turn_id: "turn-1",
        model: "model",
        hook_shell: "/bin/sh",
        hook_task_supervisor: supervisor,
        hook_async_runtime: queue
      }
    }
  end

  test "factory sees original unfiltered indices and separates identical handlers before queueing",
       %{
         ctx: ctx
       } do
    test_pid = self()
    spec = async_spec()

    factory = fn index, selected ->
      send(test_pid, {:factory, index, selected, self()})
      fn text, warnings -> send(test_pid, {:completed, index, text, warnings}) end
    end

    specs = [
      %{spec | event: :stop},
      %{spec | matcher: "Read"},
      %{spec | unsupported_reason: "not supported"},
      %{spec | trusted?: nil},
      %{spec | handler: %Command{cmd: "true", timeout_ms: 1_000, async: false}},
      spec,
      spec
    ]

    assert {:proceed, warnings} =
             Runner.run(
               :post_tool_use,
               specs,
               Map.put(ctx, :hook_async_callback_factory, factory),
               %{
                 tool_name: "exec_command"
               }
             )

    assert length(warnings) == 2
    assert_receive {:factory, 5, ^spec, ^test_pid}
    assert_receive {:queued, first}
    assert_receive {:factory, 6, ^spec, ^test_pid}
    assert_receive {:queued, second}
    refute_receive {:factory, _, _, _}
    refute_receive {:completed, _, _, _}
    first.()
    second.()
    assert_receive {:completed, 5, "中文原文", []}
    assert_receive {:completed, 6, "中文原文", []}
    refute_receive {:queued, _}
  end

  test "legacy callback still receives async output when no factory is supplied", %{ctx: ctx} do
    test_pid = self()
    callback = fn text, warnings -> send(test_pid, {:legacy, text, warnings}) end

    assert {:proceed, []} =
             Runner.run(
               :post_tool_use,
               [async_spec()],
               Map.put(ctx, :hook_async_callback, callback)
             )

    assert_receive {:queued, fun}
    fun.()
    assert_receive {:legacy, "中文原文", []}
  end

  test "factory takes precedence over a legacy callback", %{ctx: ctx} do
    test_pid = self()

    ctx =
      Map.merge(ctx, %{
        hook_async_callback: fn _, _ -> send(test_pid, :legacy_called) end,
        hook_async_callback_factory: fn index, _spec ->
          fn text, warnings -> send(test_pid, {:factory_result, index, text, warnings}) end
        end
      })

    assert {:proceed, []} = Runner.run(:post_tool_use, [async_spec()], ctx)
    assert_receive {:queued, fun}
    fun.()
    assert_receive {:factory_result, 0, "中文原文", []}
    refute_receive :legacy_called
  end

  test "factory failure rejects the hook before queue admission without legacy fallback", %{
    ctx: ctx,
    tmp_dir: directory
  } do
    test_pid = self()

    spec = %{
      async_spec()
      | handler: %Command{cmd: "touch executed", timeout_ms: 1_000, async: true}
    }

    failures = [
      fn _, _ -> nil end,
      fn _, _ -> fn _ -> :wrong_arity end end,
      fn _, _ -> raise "factory unavailable" end,
      fn _, _ -> throw(:factory_unavailable) end,
      fn _, _ -> exit(:factory_unavailable) end,
      :invalid_factory
    ]

    for factory <- failures do
      context =
        Map.merge(ctx, %{
          hook_async_callback_factory: factory,
          hook_async_callback: fn _, _ -> send(test_pid, :legacy_called) end
        })

      assert {:proceed, warnings} = Runner.run(:post_tool_use, [spec], context)
      assert Enum.any?(warnings, &String.contains?(&1, "async hook"))
      assert Enum.any?(warnings, &String.contains?(&1, "callback"))
      refute_receive {:queued, _}
      refute_receive :legacy_called
      refute File.exists?(Path.join(directory, "executed"))
    end
  end

  defp async_spec do
    %Spec{
      event: :post_tool_use,
      handler: %Command{
        cmd:
          ~S(printf '%s' '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"中文原文"}}'),
        timeout_ms: 1_000,
        async: true
      },
      matcher: :any,
      origin: {:user, "/user"},
      dialect: :codex,
      trusted?: true
    }
  end
end
