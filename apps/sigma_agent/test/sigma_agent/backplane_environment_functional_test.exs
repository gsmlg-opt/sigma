defmodule Sigma.Agent.BackplaneEnvironmentFunctionalTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.Codex.Control
  alias Backplane.AgentRuntime.{Command, Error}
  alias Sigma.Agent.{Runtime, Subagents}
  alias Sigma.Agent.Backplane.{CodexResources, PlainCommand}
  alias Sigma.Session.Log

  @moduletag :tmp_dir
  @moduletag :codex_alignment_functional

  defmodule Provider do
    @behaviour Sigma.Ai.Provider

    def output_token_limit(_model, _options), do: 2_000

    def stream(params) do
      send(params.options[:test_pid], {:environment_provider, self(), params})

      receive do
        {:environment_response, content} ->
          reason = if Enum.any?(content, &(&1.type == :tool_call)), do: :tool_use, else: :stop

          message = %{
            role: :assistant,
            content: content,
            stop_reason: reason,
            usage: %{input: 1, output: 1, total_tokens: 2},
            model: "environment",
            provider: "environment",
            api: "openai-responses",
            timestamp: System.system_time(:millisecond)
          }

          [{:start, %{message | content: []}}, {:done, reason, message}]
      end
    end
  end

  # Hold the real command startup acknowledgement at the resource-owner mailbox.
  # The initializer and every state/call handler remain the production callbacks;
  # the fixture neither fabricates readiness nor substitutes a command backend.
  defmodule StartupGate do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    def init(opts) do
      Process.put(:startup_test, Keyword.fetch!(opts, :test_pid))
      CodexResources.init(Keyword.delete(opts, :test_pid))
    end

    def handle_info({:plain_command_startup, _server, _result} = message, state) do
      send(Process.get(:startup_test), {:command_boot_completed, self()})
      {:noreply, Map.put(state, :held_startup, message)}
    end

    def handle_info(message, state), do: CodexResources.handle_info(message, state)

    def handle_call(:release_startup, _from, state) do
      {message, state} = Map.pop!(state, :held_startup)
      {:noreply, state} = CodexResources.handle_info(message, state)
      {:reply, :ok, state}
    end

    def handle_call(message, from, state), do: CodexResources.handle_call(message, from, state)
    def terminate(reason, state), do: CodexResources.terminate(reason, state)
  end

  setup %{tmp_dir: dir} do
    on_exit(fn ->
      case Runtime.lookup(dir, :supervisor) do
        nil -> :ok
        pid -> DynamicSupervisor.terminate_child(Sigma.Agent.DynamicSupervisor, pid)
      end
    end)

    :ok
  end

  test "the public wait polls starting until the owner accepts the actual command bootstrap", %{
    tmp_dir: dir
  } do
    resources =
      start_supervised!(
        {StartupGate,
         workspace: dir,
         owner_pid: self(),
         memory_root: Path.join(dir, "memories"),
         test_pid: self()}
      )

    authority = %{caller: "environment-root", run_id: "bootstrap", grants: [], tool_revision: 1}
    assert {:ok, binding} = CodexResources.bind(resources, authority)
    assert {:ok, context} = CodexResources.context(resources, binding)
    assert_receive {:command_boot_completed, ^resources}, 2_000
    starting = CodexResources.environment(context)
    assert starting.status == "starting"
    refute starting.ready
    assert starting.cwd == dir
    command_pid = context.command.server
    local_pid = GenServer.call(command_pid, :local)
    assert Process.alive?(local_pid)

    wait =
      Task.async(fn ->
        Control.call(%{
          tool_name: "wait_for_environment",
          arguments: %{"environment_id" => starting.environment_id},
          backend_context: %{context: Map.put(context, :environment_wait_timeout, 2_000)}
        })
      end)

    assert Task.yield(wait, 40) == nil
    assert :ok = GenServer.call(resources, :release_startup)
    assert {:ok, result} = Task.await(wait, 3_000)
    assert result.environment_id == starting.environment_id
    assert result.status == "ready"
    assert result.environment == CodexResources.environment(context)
    assert result.environment.ready
    assert GenServer.call(command_pid, :local) == local_pid
    assert {:ok, %{status: :confirmed}} = CodexResources.close(resources)
    refute Process.alive?(command_pid)
    refute Process.alive?(local_pid)
  end

  test "root Engine publishes the real environment, waits directly and through Deno, and renews only after closure",
       %{tmp_dir: dir} do
    {agent, path} = session!(dir)
    first = prompt!(agent)
    assert "wait_for_environment" in names(first)
    assert Enum.any?(first.params.context.system, &(&1.text == "Custom root policy"))
    environment = environment!(first)
    assert environment["kind"] == "local-command-runtime"
    assert environment["cwd"] == dir
    assert is_binary(environment["environment_id"])

    ready =
      call!(first, "wait_for_environment", %{"environment_id" => environment["environment_id"]})

    waited = result!(ready, "wait_for_environment")
    assert waited["status"] == "ready"
    assert waited["environment_id"] == environment["environment_id"]
    assert waited["environment"]["ready"]
    assert environment!(ready) == waited["environment"]

    command =
      call!(ready, "exec_command", %{
        "cmd" => "printf '%s' \"$PWD\"; printf 'environment effect\\n' > environment-effect.txt",
        "shell" => "/bin/sh",
        "login" => false,
        "yield_time_ms" => 1_000
      })

    assert result!(command, "exec_command")["output"] == dir
    effect = Path.join(dir, "environment-effect.txt")
    before = file_snapshot(effect)
    budget = call!(command, "get_context_remaining", %{})
    assert is_integer(result!(budget, "get_context_remaining")["tokens_left"])
    finish_root!(agent, budget)

    second = prompt!(agent)
    assert environment!(second)["environment_id"] == environment["environment_id"]

    nested =
      call!(
        second,
        "exec",
        "return await tools.wait_for_environment(#{Jason.encode!(%{environment_id: environment["environment_id"]})});"
      )

    result = result!(nested, "exec")
    assert result["status"] == "completed"
    assert result["value"]["environment_id"] == environment["environment_id"]
    assert result["value"]["environment"]["ready"]
    finish_root!(agent, nested)

    assert {:ok, %{status: :confirmed}} = Runtime.close_subagents(dir, "environment-root")
    third = prompt!(agent)
    refute environment!(third)["environment_id"] == environment["environment_id"]
    assert file_snapshot(effect) == before
    finish_root!(agent, third)
    assert {:ok, saved} = Log.snapshot(path)
    assert saved_result(saved.messages, "wait_for_environment") == waited
    assert saved_result(saved.messages, "exec") == result
    assert file_snapshot(effect) == before
  end

  test "asynchronous command startup preserves an actual invalid-timeout failure", %{tmp_dir: dir} do
    command_pid =
      start_supervised!(
        {PlainCommand, owner_pid: self(), async_start: true, local: [cleanup_timeout: 0]}
      )

    assert_receive {:plain_command_startup, ^command_pid,
                    {:error, %Error{class: :validation} = error}},
                   2_000

    assert error.message =~ "cleanup_timeout"
    assert {:ok, command} = PlainCommand.command(command_pid)

    assert {:error, ^error} =
             Command.reserve(command, %{owner_run_id: "failed-startup", workspace: dir})

    assert :ok = PlainCommand.stop(command_pid)
    refute Process.alive?(command_pid)
  end

  test "closing before the startup acknowledgement returns the public unavailable result",
       %{tmp_dir: dir} do
    resources =
      start_supervised!(
        {StartupGate,
         workspace: dir,
         owner_pid: self(),
         memory_root: Path.join(dir, "memories"),
         test_pid: self()}
      )

    authority = %{
      caller: "environment-root",
      run_id: "closing-bootstrap",
      grants: [],
      tool_revision: 1
    }

    assert {:ok, binding} = CodexResources.bind(resources, authority)
    assert {:ok, context} = CodexResources.context(resources, binding)
    assert_receive {:command_boot_completed, ^resources}, 2_000
    environment = CodexResources.environment(context)
    assert environment.status == "starting"
    assert {:ok, %{status: :confirmed}} = CodexResources.close(resources)
    assert :ok = GenServer.call(resources, :release_startup)
    refute context.environment_provider.(environment.environment_id).ready

    assert {:ok, %{is_error: true, error: error}} =
             Control.call(%{
               tool_name: "wait_for_environment",
               arguments: %{"environment_id" => environment.environment_id},
               backend_context: %{context: Map.put(context, :environment_wait_timeout, 20)}
             })

    assert error["class"] == "not_found"

    assert error["details"] == %{
             "environment_id" => environment.environment_id,
             "status" => "unavailable"
           }

    refute Process.alive?(context.command.server)
  end

  @tag timeout: 60_000
  test "managed children use their own environment and retain it through a real Deno followup", %{
    tmp_dir: dir
  } do
    {agent, path} = session!(dir)
    root = prompt!(agent)
    root_environment = environment!(root)
    host = Runtime.lookup(dir, "environment-root", :subagents)

    send_call(root, "spawn_agent", %{
      "task_name" => "environment_worker",
      "message" => "Use the local command environment",
      "fork_turns" => "none"
    })

    child = provider!(:child)
    root = provider!("environment-root")
    _spawned = result!(root, "spawn_agent")
    assert "wait_for_environment" in names(child)
    child_environment = environment!(child)
    refute child_environment["environment_id"] == root_environment["environment_id"]

    child =
      call!(child, "wait_for_environment", %{
        "environment_id" => child_environment["environment_id"]
      })

    direct = result!(child, "wait_for_environment")
    assert direct["environment"]["ready"]
    finish!(child)
    assert eventually(fn -> roster(host).counts.stopped == 1 end)

    send_call(root, "followup_task", %{
      "target" => "/root/environment_worker",
      "message" => "Wait through Code Mode"
    })

    child = provider!(child.params.session_id)
    root = provider!("environment-root")
    _followup = result!(root, "followup_task")
    assert environment!(child)["environment_id"] == child_environment["environment_id"]

    child =
      call!(
        child,
        "exec",
        "return await tools.wait_for_environment(#{Jason.encode!(%{environment_id: child_environment["environment_id"]})});"
      )

    nested = result!(child, "exec")
    assert nested["status"] == "completed"
    assert nested["value"]["environment_id"] == child_environment["environment_id"]
    assert nested["value"]["environment"]["ready"]
    finish!(child)
    assert eventually(fn -> roster(host).counts.stopped == 1 end)
    [row] = roster(host).agents
    child_path = Path.join([path <> ".subagents", row.child_session_id, "session.jsonl"])
    assert {:ok, saved} = Log.snapshot(child_path)
    assert saved_result(saved.messages, "wait_for_environment") == direct
    assert saved_result(saved.messages, "exec") == nested
    finish_root!(agent, root)
  end

  defp session!(dir) do
    path = Path.join(dir, "environment-root.jsonl")

    assert {:ok, handle} =
             Runtime.get_session(dir, "environment-root",
               cwd: dir,
               transcript_path: path,
               provider: Provider,
               model: %{
                 id: "environment",
                 provider: "environment",
                 api: "openai-responses",
                 context_window: 100_000
               },
               system_prompt: "Custom root policy",
               native_tools: true,
               native_memory_root: Path.join(dir, "memories"),
               tools: [],
               hook_specs: [],
               options: [test_pid: self()]
             )

    :ok = Sigma.Agent.subscribe(handle.agent)
    {handle.agent, path}
  end

  defp prompt!(agent) do
    assert {:accepted, _} = Sigma.Agent.prompt(agent, "Use the execution environment")
    provider!("environment-root")
  end

  defp provider!(session) do
    receive do
      {:environment_provider, pid, %{session_id: "child_" <> _} = params}
      when session == :child ->
        %{pid: pid, params: params}

      {:environment_provider, pid, %{session_id: id} = params} when session == id ->
        %{pid: pid, params: params}

      {:turn_error, error} ->
        flunk("environment turn failed: #{inspect(error)}")
    after
      10_000 -> flunk("environment Provider did not start for #{inspect(session)}")
    end
  end

  defp call!(provider, name, args) do
    send_call(provider, name, args)
    provider!(provider.params.session_id)
  end

  defp send_call(provider, name, args) do
    send(
      provider.pid,
      {:environment_response,
       [
         %{
           type: :tool_call,
           id: "environment-#{System.unique_integer([:positive])}",
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

  defp environment!(provider) do
    text = Enum.map_join(provider.params.context.system, "\n", & &1.text)
    assert [_, json] = Regex.run(~r/<environment_context>\n(.*?)\n<\/environment_context>/s, text)
    Jason.decode!(json)
  end

  defp names(provider), do: Enum.map(provider.params.context.tools, & &1.name)

  defp finish!(provider),
    do: send(provider.pid, {:environment_response, [%{type: :text, text: "done"}]})

  defp finish_root!(agent, provider) do
    finish!(provider)
    assert_receive {:agent_end, _}, 10_000
    assert Sigma.Agent.status(agent).phase == :completed
  end

  defp roster(host) do
    assert {:ok, %{available: true, subagents: roster}} = Subagents.snapshot(host)
    roster
  end

  defp file_snapshot(path), do: {File.read!(path), File.stat!(path).mtime}
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
