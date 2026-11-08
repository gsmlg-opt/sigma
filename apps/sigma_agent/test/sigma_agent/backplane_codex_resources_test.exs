defmodule Sigma.Agent.BackplaneCodexResourcesTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.{Command, Conversation, EphemeralStore, Error, Plan}
  alias Backplane.AgentRuntime.Codex
  alias Backplane.AgentRuntime.Codex.{ResourceRegistry, Session}
  alias Sigma.Agent.Backplane.CodexResources

  @moduletag :tmp_dir

  defmodule ScriptedProvider do
    def stream(request, %{calls: calls}) do
      completed = Enum.count(request.messages, &(&1.role == :tool))

      case Enum.at(calls, completed) do
        nil ->
          [response("Finished")]

        {name, arguments} ->
          [
            %{
              type: :tool_call_completed,
              tool_call: %{id: "call-#{completed}", name: name, arguments: arguments}
            },
            response("Running tool")
          ]
      end
    end

    defp response(text),
      do: %{type: :response_completed, message: %{role: :assistant, content: text}}
  end

  test "native command sessions survive distinct runs alongside patch and plan", %{tmp_dir: dir} do
    resources = resources!(dir)

    {first_binding, first_context, first_messages} =
      run!(resources, "first", [
        {"exec_command",
         %{
           "cmd" => "IFS= read -r line; printf '%s' \"$line\"",
           "shell" => "/bin/sh",
           "login" => false,
           "yield_time_ms" => 0
         }}
      ])

    assert %{session_id: session_id, status: :running} = result!(first_messages, "exec_command")
    assert is_integer(session_id)
    assert first_context.command.allowed_environment == %{}

    # PTY support follows the host: Sigma's terminal helper on Linux or macOS.
    if :os.type() in [{:unix, :linux}, {:unix, :darwin}] and
         match?({:ok, %{real_pty: true}}, Sigma.Coding.Terminal.Native.capabilities()) do
      assert {:ok, %{columns: 120, rows: 24}} = Command.terminal(first_context.command)
    else
      assert {:error, %Error{class: :unsupported_capability}} =
               Command.terminal(first_context.command)
    end

    patch = "*** Begin Patch\n*** Add File: result.txt\n+patched\n*** End Patch\n"

    {second_binding, second_context, second_messages} =
      run!(resources, "second", [
        {"write_stdin",
         %{"session_id" => session_id, "chars" => "hello\n", "yield_time_ms" => 500}},
        {"apply_patch", patch},
        {"update_plan", %{"plan" => [%{"step" => "Verify resources", "status" => "completed"}]}}
      ])

    assert second_binding.run_id != first_binding.run_id
    assert second_binding.owner_id == first_binding.owner_id
    assert second_context.session_registry == first_context.session_registry

    assert %{output: "hello", exit_code: 0} =
             stdin_result =
             result!(second_messages, "write_stdin")

    assert %{status: :applied} = result!(second_messages, "apply_patch")
    assert File.read!(Path.join(dir, "result.txt")) == "patched\n"

    assert {:ok, %{revision: 2, content: %{"plan" => [%{"status" => "completed"}]}}} =
             Plan.read(second_context.plan)

    assert {:error, %Error{class: :forbidden}} = CodexResources.context(resources, first_binding)

    assert {:error, %Error{class: :forbidden}} =
             Session.validate(first_binding, %{run_id: "first", incarnation: 1})

    retained =
      ResourceRegistry.fetch_session(
        second_context.session_registry,
        session_id,
        second_binding.owner_id,
        second_binding.incarnation
      )

    # An exit code can precede cleanup acknowledgement. Only the confirmed
    # result withdraws the handle; pending cleanup must remain addressable.
    case stdin_result.cleanup_status do
      :confirmed -> assert {:error, %Error{class: :not_found}} = retained
      :pending -> assert {:ok, _session} = retained
    end

    assert {:ok, %{status: :confirmed}} = CodexResources.close(resources)
    refute Process.alive?(second_context.command.server)
    refute Process.alive?(second_context.plan)

    assert {:error, %Error{class: :resource_conflict}} =
             CodexResources.bind(resources, authority("third", []))
  end

  test "owned session close cancels a retained command and withdraws its handle", %{tmp_dir: dir} do
    resources = resources!(dir)
    {binding, context, messages} = run!(resources, "retained", [waiting_command()])
    %{session_id: session_id} = result!(messages, "exec_command")

    assert {:ok, %{status: :confirmed}} = CodexResources.close(resources),
           cleanup_diagnostic(context, binding, session_id)

    refute Process.alive?(context.command.server)
    refute Process.alive?(binding.session)
    assert is_integer(session_id)
    assert {:ok, %{status: :confirmed}} = CodexResources.close(resources)
  end

  test "partial child shutdown can be retried after the owned Session has stopped", %{
    tmp_dir: dir
  } do
    resources = resources!(dir)
    assert {:ok, binding} = CodexResources.bind(resources, authority("partial-close", []))
    assert {:ok, context} = CodexResources.context(resources, binding)
    monitor = Process.monitor(context.plan)

    # Suspend execution itself so even the public GenServer stop request must
    # wait. Only the host-owned PID is used; no Runtime internals are inspected.
    assert :erlang.suspend_process(context.plan)

    try do
      assert {:error, %Error{class: :unknown_outcome}} = CodexResources.close(resources)
      assert Process.alive?(resources)
      refute Process.alive?(binding.session)

      assert {:error, %Error{class: :resource_conflict}} =
               CodexResources.bind(resources, authority("during-partial-close", []))

      assert {:error, %Error{class: :forbidden}} = CodexResources.context(resources, binding)
    after
      :erlang.resume_process(context.plan)
    end

    assert_receive {:DOWN, ^monitor, :process, _, :normal}, 5_000
    assert {:ok, %{status: :confirmed}} = CodexResources.close(resources)
    assert {:ok, %{status: :confirmed}} = CodexResources.close(resources)

    assert {:error, %Error{class: :resource_conflict}} =
             CodexResources.bind(resources, authority("after-partial-close", []))

    assert {:error, %Error{class: :forbidden}} = CodexResources.context(resources, binding)
  end

  test "cancellation closes native resources before a replacement run can bind", %{tmp_dir: dir} do
    resources = resources!(dir)
    {binding, context, messages} = run!(resources, "before-cancel", [waiting_command()])
    %{session_id: session_id} = result!(messages, "exec_command")

    assert {:ok, %{job: job}} =
             ResourceRegistry.fetch_session(
               context.session_registry,
               session_id,
               binding.owner_id,
               binding.incarnation
             )

    assert {:ok, next_binding} = CodexResources.bind(resources, authority("cancelled", []))
    assert {:ok, next_context} = CodexResources.context(resources, next_binding)
    conversation = conversation!(next_context, next_binding, [], :empty)

    assert :ok = Conversation.cancel(conversation)
    assert_receive {:agent_runtime, "cancelled", %{type: :run_cancelled}}, 5_000

    status = Session.status(binding.session)

    assert match?(%{phase: :closed, cleanup: {:ok, %{status: :confirmed}}}, status),
           inspect(status) <> "\n" <> cleanup_diagnostic(context, binding, session_id, job)

    assert {:error, %Error{class: :resource_conflict}} =
             CodexResources.bind(resources, authority("after-cancel", []))

    assert {:ok, %{status: :confirmed}} = CodexResources.close(resources)
    refute Process.alive?(context.command.server)
  end

  test "borrowed session keeps its ownership and refuses competing bindings", %{tmp_dir: dir} do
    {:ok, session} = Session.start_link(owner_pid: self())
    resources = resources!(dir, session: session)
    first_authority = authority("borrowed", [])
    assert {:ok, binding} = CodexResources.bind(resources, first_authority)
    assert binding.session == session

    assert {:error, %Error{class: :resource_conflict}} =
             CodexResources.bind(resources, authority("competing", []))

    assert {:ok, context} = CodexResources.context(resources, binding)

    assert {:error, %Error{class: :forbidden}} =
             CodexResources.context(resources, %{binding | token: make_ref()})

    assert {:error, %Error{class: :resource_conflict}} = CodexResources.close(resources)
    assert Process.alive?(session)
    assert Process.alive?(context.command.server)

    assert {:ok, %{status: :confirmed}} = Session.close(session)
    assert {:ok, %{status: :confirmed}} = CodexResources.close(resources)
    assert Process.alive?(session)
    refute Process.alive?(context.command.server)
    GenServer.stop(session)
  end

  test "supervised resources stop with their host without restarting", %{tmp_dir: dir} do
    owner = spawn(fn -> receive do: (:stop -> :ok) end)
    on_exit(fn -> if Process.alive?(owner), do: send(owner, :stop) end)
    opts = [workspace: dir, owner_pid: owner]
    assert %{restart: :temporary, shutdown: 10_000} = CodexResources.child_spec(opts)
    resources = start_supervised!({CodexResources, opts})
    {binding, context, _messages} = run!(resources, "host-shutdown", [waiting_command()])
    pids = [resources, binding.session, context.command.server, context.plan]
    monitors = Enum.map(pids, &{&1, Process.monitor(&1)})

    send(owner, :stop)

    for {pid, ref} <- monitors do
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 10_000
    end

    {:ok, supervisor} = ExUnit.fetch_test_supervisor()
    refute List.keymember?(Supervisor.which_children(supervisor), CodexResources, 0)
  end

  test "shutdown still stops local children after its owned session has stopped", %{tmp_dir: dir} do
    resources = resources!(dir)
    assert {:ok, binding} = CodexResources.bind(resources, authority("dead-session", []))
    assert {:ok, context} = CodexResources.context(resources, binding)
    assert {:ok, %{status: :confirmed}} = Session.close(binding.session)
    GenServer.stop(binding.session)

    assert {:error, %Error{class: :unknown_outcome}} = CodexResources.close(resources)
    GenServer.stop(resources)

    refute Process.alive?(context.command.server)
    refute Process.alive?(context.plan)
  end

  test "shutdown stops local children without closing an open borrowed session", %{tmp_dir: dir} do
    {:ok, session} = Session.start_link(owner_pid: self())
    resources = resources!(dir, session: session)
    assert {:ok, binding} = CodexResources.bind(resources, authority("borrowed-shutdown", []))
    assert {:ok, context} = CodexResources.context(resources, binding)

    GenServer.stop(resources)

    refute Process.alive?(context.command.server)
    refute Process.alive?(context.plan)
    assert Process.alive?(session)
    assert %{phase: :reserved} = Session.status(session)
    assert {:ok, %{status: :confirmed}} = Session.close(session)
    GenServer.stop(session)
  end

  defp resources!(dir, opts \\ []) do
    start_supervised!({CodexResources, Keyword.merge([workspace: dir, owner_pid: self()], opts)})
  end

  defp waiting_command do
    {"exec_command",
     %{"cmd" => "IFS= read -r line", "shell" => "/bin/sh", "login" => false, "yield_time_ms" => 0}}
  end

  defp run!(resources, id, calls) do
    assert {:ok, binding} = CodexResources.bind(resources, authority(id, calls))
    assert {:ok, context} = CodexResources.context(resources, binding)
    conversation = conversation!(context, binding, calls)
    assert {:ok, _} = Conversation.prompt(conversation, "Exercise explicit test profile")
    assert_receive {:agent_runtime, ^id, %{type: :run_completed}}, 5_000
    messages = Conversation.status(conversation).messages
    GenServer.stop(conversation)
    {binding, context, messages}
  end

  defp conversation!(context, binding, calls, provider_mode \\ :scripted) do
    authority = authority(binding.run_id, calls)
    tools = Enum.map(calls, &elem(&1, 0)) |> Enum.uniq()
    assert {:ok, profile} = Codex.profile(:pinned_local, context, authority, tools: tools)
    assert {:ok, store} = EphemeralStore.new(1)

    provider_context = if provider_mode == :empty, do: %{calls: []}, else: %{calls: calls}

    start_supervised!(
      {Conversation,
       run_id: binding.run_id,
       store: EphemeralStore,
       context: store,
       provider: ScriptedProvider,
       provider_context: provider_context,
       registry: profile.registry,
       tools: profile.tools,
       authority: profile.authority,
       session_binding: binding,
       subscriber: self(),
       effect_timeout: 5_000}
    )
  end

  defp authority(id, calls) do
    %{
      caller: "resource-test",
      run_id: id,
      grants: Enum.map(calls, &elem(&1, 0)) |> Enum.uniq(),
      tool_revision: 1
    }
  end

  defp result!(messages, name) do
    message = Enum.find(messages, &(&1.role == :tool and &1.name == name))
    refute message.result[:is_error]
    message.result
  end

  defp cleanup_diagnostic(context, binding, session_id, job \\ nil) do
    invocation = %{
      session_id: session_id,
      owner_run_id: binding.owner_id,
      incarnation: binding.incarnation
    }

    handle =
      if job,
        do: {:ok, %{job: job}},
        else:
          ResourceRegistry.fetch_session(
            context.session_registry,
            session_id,
            binding.owner_id,
            binding.incarnation
          )

    snapshot =
      with {:ok, %{job: retained}} <- handle do
        Command.read(context.command, invocation, retained, cursor: 0)
      end

    inspect(snapshot, pretty: true, limit: :infinity)
  catch
    :exit, reason -> inspect({:public_command_unavailable, reason})
  end
end
