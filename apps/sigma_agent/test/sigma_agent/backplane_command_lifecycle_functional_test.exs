defmodule Sigma.Agent.BackplaneCommandLifecycleFunctionalTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.{Codex, Conversation, EphemeralStore}
  alias Backplane.AgentRuntime.Codex.{ResourceRegistry, Session}
  alias Sigma.Agent.Backplane.CodexResources

  @moduletag :tmp_dir
  @session_count 32

  defmodule CommandProvider do
    def stream(request, %{command: command}) do
      if Enum.any?(request.messages, &(&1.role == :tool)) do
        [response("Command retained")]
      else
        [
          %{
            type: :tool_call_completed,
            tool_call: %{
              id: "retained-command",
              name: "exec_command",
              arguments: %{
                "cmd" => command,
                "shell" => "/bin/sh",
                "login" => false,
                "yield_time_ms" => 0
              }
            }
          },
          response("Start command")
        ]
      end
    end

    defp response(text),
      do: %{type: :response_completed, message: %{role: :assistant, content: text}}
  end

  test "32 independent Sessions concurrently confirm close and cancellation of retained stdin commands",
       %{tmp_dir: dir} do
    runs = Enum.map(1..@session_count, &prepare_run!(dir, &1))

    for key <- [:owner, :resources, :session, :command_server, :owner_id] do
      assert runs |> Enum.map(&Map.fetch!(&1, key)) |> Enum.uniq() |> length() == @session_count
    end

    # Launch every independent Conversation before waiting for any completion.
    for run <- runs do
      assert {:ok, _} = Conversation.prompt(run.conversation, "Retain a command waiting on stdin")
    end

    runs = Enum.map(runs, &completed_run!/1)
    pids = recorded_pids!(runs)
    assert length(Enum.uniq(pids)) == @session_count

    runs =
      runs
      |> Enum.zip(pids)
      |> Enum.map(fn {run, os_pid} ->
        assert File.exists?("/proc/#{os_pid}"), "retained command #{os_pid} exited before cleanup"

        # A completed model turn is distinct from process exit and resource
        # release. Its running-command result remains an actual settled fact.
        assert run.command_result.status == :running
        assert run.command_result.cleanup_status == :not_started
        assert run.command_result.termination_status == :not_requested
        assert Map.get(run.command_result, :exit_code) == nil
        assert is_integer(run.command_result.session_id)

        assert {:ok, %{job: job}} =
                 ResourceRegistry.fetch_session(
                   run.context.session_registry,
                   run.command_result.session_id,
                   run.binding.owner_id,
                   run.binding.incarnation
                 )

        assert is_map(job)
        assert :ok = stop_supervised({:launch, run.index})
        assert File.exists?("/proc/#{os_pid}")
        run = Map.put(run, :os_pid, os_pid)

        if rem(run.index, 2) == 0, do: prepare_cancellation!(run), else: run
      end)

    test_pid = self()

    tasks =
      Enum.map(runs, fn run ->
        Task.async(fn ->
          send(test_pid, {:cleanup_ready, self()})
          receive do: (:cleanup_now -> cleanup(run))
        end)
      end)

    for task <- tasks do
      task_pid = task.pid
      assert_receive {:cleanup_ready, ^task_pid}, 5_000
    end

    Enum.each(tasks, &send(&1.pid, :cleanup_now))
    results = Task.await_many(tasks)

    assert Enum.frequencies_by(results, & &1.kind) == %{close: 16, cancel: 16}

    # Cancellation acknowledgement starts an asynchronous transition. Observe
    # its terminal event before sampling either Conversation or Session status.
    results =
      runs
      |> Enum.zip(results)
      |> Enum.map(fn
        {run, %{kind: :cancel} = result} ->
          assert result.cancellation == :ok
          cancelled_id = run.cancel_binding.run_id
          assert_receive {:agent_runtime, ^cancelled_id, %{type: :run_cancelled}}, 5_000

          assert %{phase: :terminal, resource_cleanup: :confirmed, run: %{state: :cancelled}} =
                   conversation_status = Conversation.status(run.cancel_conversation)

          assert %{phase: :closed, cleanup: {:ok, %{status: :confirmed}}} =
                   session_status = Session.status(run.session)

          Map.merge(result, %{
            conversation_status: conversation_status,
            session_status: session_status
          })

        {_run, result} ->
          result
      end)

    cancelled_close_tasks =
      for {run, %{kind: :cancel}} <- Enum.zip(runs, results) do
        Task.async(fn -> {run.index, CodexResources.close(run.resources)} end)
      end

    cancelled_closures = cancelled_close_tasks |> Task.await_many() |> Map.new()

    for {run, result} <- Enum.zip(runs, results) do
      resources_cleanup =
        if result.kind == :cancel,
          do: Map.fetch!(cancelled_closures, run.index),
          else: result.resources_cleanup

      assert {:ok, %{status: :confirmed, owner_id: owner_id}} = resources_cleanup
      assert owner_id == run.owner_id

      if result.kind == :cancel do
        assert result.cancellation == :ok

        assert %{phase: :terminal, resource_cleanup: :confirmed, run: %{state: :cancelled}} =
                 result.conversation_status

        assert %{phase: :closed, cleanup: {:ok, %{status: :confirmed}}} = result.session_status
      end

      refute File.exists?("/proc/#{run.os_pid}"),
             "cleanup claimed confirmation while command #{run.os_pid} remained present"

      refute Process.alive?(run.command_server)
      refute Process.alive?(run.context.plan)
      refute Process.alive?(run.session)

      # Cleanup does not rewrite the earlier result into a successful command
      # exit, even though its owning Session has now confirmed process closure.
      assert {:ok, %{run: saved}} = EphemeralStore.load(run.store, run.id)
      assert saved.state == :completed
      assert saved.tool_results[run.invocation_id] == run.command_result
    end
  end

  defp prepare_run!(dir, index) do
    workspace = Path.join(dir, "session-#{index}")
    File.mkdir!(workspace)
    pid_path = Path.join(workspace, "command.pid")
    owner = spawn(fn -> receive do: (:stop -> :ok) end)

    on_exit(fn ->
      monitor = Process.monitor(owner)
      send(owner, :stop)
      assert_receive {:DOWN, ^monitor, :process, ^owner, _}, 5_000
    end)

    resources =
      start_supervised!(
        {CodexResources,
         workspace: workspace, owner_pid: owner, memory_root: Path.join(dir, "memories")},
        id: {:resources, index}
      )

    id = "command-lifecycle-#{index}"
    assert {:ok, binding} = CodexResources.bind(resources, authority(id, ["exec_command"]))
    assert {:ok, context} = CodexResources.context(resources, binding)

    # The shell records its own real OS PID before blocking on retained stdin.
    # No sleep process, background job or inherited user resource is involved.
    command = "printf '%s\\n' \"$$\" > " <> shell_quote(pid_path) <> "; IFS= read -r line"

    {conversation, store} =
      conversation!(context, binding, ["exec_command"], %{command: command}, {:launch, index})

    %{
      index: index,
      id: id,
      owner: owner,
      owner_id: binding.owner_id,
      resources: resources,
      session: binding.session,
      command_server: context.command.server,
      binding: binding,
      context: context,
      conversation: conversation,
      store: store,
      pid_path: pid_path
    }
  end

  defp completed_run!(run) do
    id = run.id
    assert_receive {:agent_runtime, ^id, %{type: :run_completed}}, 5_000

    assert %{phase: :terminal, run: %{state: :completed}, messages: messages} =
             Conversation.status(run.conversation)

    assert [%{result: %{is_error: false} = result, invocation_id: invocation_id}] =
             Enum.filter(messages, &(&1.role == :tool))

    assert {:ok, %{run: saved}} = EphemeralStore.load(run.store, run.id)
    assert saved.tool_results[invocation_id] == result
    Map.merge(run, %{command_result: result, invocation_id: invocation_id})
  end

  defp prepare_cancellation!(run) do
    id = "cancel-#{run.index}"
    assert {:ok, binding} = CodexResources.bind(run.resources, authority(id, []))
    assert {:ok, context} = CodexResources.context(run.resources, binding)
    assert binding.owner_id == run.binding.owner_id
    assert binding.session == run.session

    {conversation, _store} =
      conversation!(context, binding, [], %{}, {:cancellation, run.index})

    Map.merge(run, %{cancel_binding: binding, cancel_conversation: conversation})
  end

  defp conversation!(context, binding, tools, provider_context, supervisor_id) do
    assert {:ok, profile} =
             Codex.profile(:pinned_local, context, authority(binding.run_id, tools), tools: tools)

    assert {:ok, store} = EphemeralStore.new(1)

    conversation =
      start_supervised!(
        {Conversation,
         run_id: binding.run_id,
         store: EphemeralStore,
         context: store,
         provider: CommandProvider,
         provider_context: provider_context,
         registry: profile.registry,
         tools: profile.tools,
         authority: profile.authority,
         session_binding: binding,
         subscriber: self(),
         effect_timeout: 5_000},
        id: supervisor_id
      )

    {conversation, store}
  end

  defp cleanup(%{cancel_conversation: conversation}) do
    %{kind: :cancel, cancellation: Conversation.cancel(conversation)}
  end

  defp cleanup(run), do: %{kind: :close, resources_cleanup: CodexResources.close(run.resources)}

  defp recorded_pids!(runs, attempts \\ 500)
  defp recorded_pids!(_runs, 0), do: flunk("retained commands did not record their OS PIDs")

  defp recorded_pids!(runs, attempts) do
    reads = Enum.map(runs, &File.read(&1.pid_path))

    if Enum.all?(reads, fn
         {:ok, text} -> String.trim(text) != ""
         {:error, :enoent} -> false
         {:error, reason} -> flunk("command PID could not be read: #{inspect(reason)}")
       end) do
      Enum.map(reads, fn {:ok, text} ->
        assert {pid, ""} = text |> String.trim() |> Integer.parse()
        assert pid > 0
        pid
      end)
    else
      Process.sleep(10)
      recorded_pids!(runs, attempts - 1)
    end
  end

  defp authority(id, tools),
    do: %{caller: "command-lifecycle", run_id: id, grants: tools, tool_revision: 1}

  defp shell_quote(text), do: "'" <> String.replace(text, "'", "'\\''") <> "'"
end
