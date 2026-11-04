defmodule Sigma.Agent.BackplaneCodexCodeModeTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.{Codex, Conversation, EphemeralStore, Error, Plan}
  alias Backplane.AgentRuntime.Codex.{CodeMode, ResourceRegistry, Tools}
  alias Sigma.Agent.Backplane.{CodexResources, Provider}
  alias Sigma.Session.{EntryDecoder, EntryEncoder}

  @moduletag :tmp_dir

  defmodule ControlledProvider do
    def stream(request, %{test: test}) do
      send(test, {:code_provider, request, self()})

      Stream.resource(
        fn -> nil end,
        fn state ->
          receive do
            {:events, events} -> {events, state}
          end
        end,
        fn _ -> :ok end
      )
    end
  end

  test "an explicitly unavailable executor is not admitted", %{tmp_dir: dir} do
    resources = resources!(dir)
    authority = authority("unavailable", [])
    assert {:ok, binding} = CodexResources.bind(resources, authority)
    assert {:ok, context} = CodexResources.context(resources, binding)

    for unavailable <- [
          Map.put(context, :deno_path, nil),
          Map.put(context, :process_lifecycle_capability, :unsupported)
        ] do
      assert CodeMode.contracts(unavailable) == []

      assert {:error, %Error{class: :unsupported_capability}} =
               Codex.profile(:code_mode_only, unavailable, authority)
    end

    assert {:ok, %{status: :confirmed}} = CodexResources.close(resources)
  end

  test "real JavaScript yields, resumes through wait and executes an admitted native plan", %{
    tmp_dir: dir
  } do
    resources = resources!(dir)

    {conversation, binding, context, provider} =
      conversation!(resources, "execute", ["update_plan"])

    code = """
    text("before");
    yield "checkpoint";
    const result = await tools.update_plan({plan: [{step: "Native nested plan", status: "completed"}]});
    text("after");
    return {revision: result.revision, status: result.status};
    """

    {yielded, provider} = call!(provider, "exec", code)
    assert %{status: :yielded, value: "checkpoint", cell_id: cell_id} = yielded
    assert Enum.any?(yielded.output, &(&1["text"] == "before"))
    worker = worker!(context, binding, cell_id)
    monitor = Process.monitor(worker)

    {completed, provider} = call!(provider, "wait", %{"cell_id" => cell_id})
    assert %{status: :completed, value: %{"revision" => 2}} = completed
    assert Enum.any?(completed.output, &(&1["text"] == "after"))
    refute Enum.any?(completed.output, &(&1["text"] == "before"))
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 5_000

    assert {:ok, %{revision: 2, content: %{"plan" => [%{"status" => "completed"}]}}} =
             Plan.read(context.plan)

    assert {:error, %Error{class: :not_found}} =
             ResourceRegistry.fetch(
               context.resource_registry,
               handle(binding, cell_id),
               binding.owner_id
             )

    finish!(conversation, provider, binding.run_id)
    assert {:ok, %{status: :confirmed}} = CodexResources.close(resources)
  end

  @tag :code_mode_slice
  test "a generator arriving between native timer slices preserves output and one nested effect",
       %{
         tmp_dir: dir
       } do
    resources = resources!(dir)

    {conversation, binding, context, provider} =
      conversation!(resources, "slice-generator", ["update_plan"])

    code = """
    yield "ready";
    text("before");
    yield "first";
    text("between");
    const result = await tools.update_plan({plan: [{step: "Exactly once", status: "completed"}]});
    yield "second";
    text("after");
    return result.status;
    """

    {yielded, provider} = call!(provider, "exec", code)
    assert %{status: :yielded, value: "ready", cell_id: cell_id} = yielded
    worker = worker!(context, binding, cell_id)
    monitor = Process.monitor(worker)
    assert {:ok, identity} = CodeMode.Worker.os_identity(worker)
    assert {_, 0} = System.cmd("kill", ["-STOP", to_string(identity.pid)])

    provider =
      try do
        {slice, next_provider} =
          call!(provider, "wait", %{"cell_id" => cell_id, "yield_time_ms" => 0})

        assert slice.status == :yielded
        refute Map.has_key?(slice, :value)
        assert :sys.get_state(worker).from == nil
        next_provider
      after
        System.cmd("kill", ["-CONT", to_string(identity.pid)])
      end

    await_generator(worker, System.monotonic_time(:millisecond) + 2_000)
    assert {:ok, %{revision: 1}} = Plan.read(context.plan)
    {first, provider} = call!(provider, "wait", %{"cell_id" => cell_id})
    assert %{status: :yielded, value: "first"} = first
    assert first.output == [%{"type" => "text", "text" => "before"}]
    assert {:ok, %{revision: 1}} = Plan.read(context.plan)

    {second, provider} = call!(provider, "wait", %{"cell_id" => cell_id})
    assert %{status: :yielded, value: "second"} = second
    assert second.output == [%{"type" => "text", "text" => "between"}]

    assert {:ok, %{revision: 2, content: %{"plan" => [%{"step" => "Exactly once"}]}}} =
             Plan.read(context.plan)

    {completed, provider} = call!(provider, "wait", %{"cell_id" => cell_id})
    assert %{status: :completed, value: "updated"} = completed
    assert completed.output == [%{"type" => "text", "text" => "after"}]
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 5_000
    assert_os_stopped(identity)
    assert {:ok, %{revision: 2}} = Plan.read(context.plan)
    finish!(conversation, provider, binding.run_id)
    assert {:ok, %{status: :confirmed}} = CodexResources.close(resources)
  end

  test "a retained cell uses the next run's admitted authority and refuses a removed tool", %{
    tmp_dir: dir
  } do
    resources = resources!(dir)

    {first, binding, context, provider} =
      conversation!(resources, "before-revoke", ["update_plan", "clock::curr_time"])

    code = """
    yield "checkpoint";
    const clock = await codex.tool("clock::curr_time", {});
    try {
      await codex.tool("update_plan", {plan: [{step: "Must not run", status: "completed"}]});
      return {denied: false};
    } catch (error) {
      return {denied: true, message: error.message, current_time: clock.current_time, tools: ALL_TOOLS.map(tool => tool.tool_name)};
    }
    """

    {yielded, provider} = call!(provider, "exec", code)
    assert %{status: :yielded, cell_id: cell_id} = yielded
    worker = worker!(context, binding, cell_id)
    finish!(first, provider, binding.run_id)
    assert Process.alive?(worker)

    {second, next_binding, next_context, provider} =
      conversation!(resources, "after-revoke", ["clock::curr_time"])

    assert next_binding.owner_id == binding.owner_id
    assert next_context.resource_registry == context.resource_registry
    {completed, provider} = call!(provider, "wait", %{"cell_id" => cell_id})

    assert %{status: :completed, value: %{"denied" => true, "tools" => ["clock::curr_time"]}} =
             completed

    assert String.ends_with?(completed.value["current_time"], " UTC")
    assert completed.value["message"] == "tool is not registered"
    assert {:ok, %{revision: 1}} = Plan.read(context.plan)
    finish!(second, provider, next_binding.run_id)
    assert {:ok, %{status: :confirmed}} = CodexResources.close(resources)
  end

  test "wait termination withdraws a yielded cell and stops its Deno process", %{tmp_dir: dir} do
    resources = resources!(dir)
    {conversation, binding, context, provider} = conversation!(resources, "terminate", [])
    {yielded, provider} = call!(provider, "exec", "yield 'checkpoint'; return 'unreachable';")
    worker = worker!(context, binding, yielded.cell_id)
    assert {:ok, identity} = CodeMode.Worker.os_identity(worker)
    monitor = Process.monitor(worker)

    {terminated, provider} =
      call!(provider, "wait", %{"cell_id" => yielded.cell_id, "terminate" => true})

    assert %{status: :terminated, cell_id: cell_id} = terminated
    assert cell_id == yielded.cell_id
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 5_000
    assert_os_stopped(identity)
    finish!(conversation, provider, binding.run_id)
    assert {:ok, %{status: :confirmed}} = CodexResources.close(resources)
  end

  test "cancelling CPU-bound resumed JavaScript cleans up the worker and session", %{tmp_dir: dir} do
    resources = resources!(dir)
    {conversation, binding, context, provider} = conversation!(resources, "cancel", [])

    {yielded, provider} =
      call!(provider, "exec", "yield 'checkpoint'; notify('cpu-started'); while (true) {}")

    worker = worker!(context, binding, yielded.cell_id)
    assert {:ok, identity} = CodeMode.Worker.os_identity(worker)
    monitor = Process.monitor(worker)

    send_call(provider, "wait", %{"cell_id" => yielded.cell_id, "yield_time_ms" => 10_000})

    assert_receive {:agent_runtime, "cancel",
                    %{type: :custom_tool_call_output, output: "cpu-started"}},
                   5_000

    tree_monitors = monitor_registry_tree!(binding)
    assert :ok = Conversation.cancel(conversation)
    assert_receive {:agent_runtime, "cancel", %{type: :run_cancelled}}, 10_000
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 5_000
    assert_os_stopped(identity)
    assert {:ok, %{status: :confirmed}} = CodexResources.close(resources)
    assert_registry_tree_stopped!(tree_monitors)
  end

  test "closing host resources stops a cell retained after a successful run", %{tmp_dir: dir} do
    resources = resources!(dir)
    {conversation, binding, context, provider} = conversation!(resources, "close", [])
    {yielded, provider} = call!(provider, "exec", "yield 'retained'; return 1;")
    worker = worker!(context, binding, yielded.cell_id)
    assert {:ok, identity} = CodeMode.Worker.os_identity(worker)
    monitor = Process.monitor(worker)
    finish!(conversation, provider, binding.run_id)
    assert Process.alive?(worker)

    tree_monitors = monitor_registry_tree!(binding)
    assert {:ok, %{status: :confirmed}} = CodexResources.close(resources)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 5_000
    assert_os_stopped(identity)
    assert_registry_tree_stopped!(tree_monitors)
  end

  test "normal Session shutdown stops its entire owned registry tree", %{tmp_dir: dir} do
    resources = resources!(dir)
    assert {:ok, binding} = CodexResources.bind(resources, authority("registry-close", []))
    tree_monitors = monitor_registry_tree!(binding)

    assert {:ok, %{status: :confirmed}} = CodexResources.close(resources)
    assert_registry_tree_stopped!(tree_monitors)
  end

  defp monitor_registry_tree!(binding) do
    registry = binding.resource_registry
    assert {:ok, workers} = ResourceRegistry.worker_supervisor(registry)
    {:links, children} = Process.info(registry, :links)
    assert [cleanup] = children -- [binding.session, workers]

    Enum.map([binding.session, registry, workers, cleanup], fn pid ->
      assert Process.alive?(pid)
      {pid, Process.monitor(pid)}
    end)
  end

  defp assert_registry_tree_stopped!(monitors) do
    for {child, monitor} <- monitors do
      assert_receive {:DOWN, ^monitor, :process, ^child, _}, 5_000
      refute Process.alive?(child)
    end
  end

  defp resources!(dir),
    do: start_supervised!({CodexResources, workspace: dir, owner_pid: self()})

  defp authority(id, targets),
    do: %{
      caller: "code-mode-test",
      run_id: id,
      grants: ["exec", "wait" | targets],
      tool_revision: 1
    }

  defp conversation!(resources, id, targets) do
    deno = System.find_executable("deno")
    assert is_binary(deno), "real Code Mode integration requires Deno in the project shell"
    assert CodeMode.lifecycle_capability(%{}) == :verified
    authority = authority(id, targets)
    assert {:ok, binding} = CodexResources.bind(resources, authority)
    assert {:ok, context} = CodexResources.context(resources, binding)

    contracts =
      Enum.filter(Tools.contracts(context), fn contract ->
        name =
          if contract[:namespace],
            do: contract.namespace <> "::" <> contract.name,
            else: contract.name

        name in targets
      end)

    context = Map.merge(context, %{deno_path: deno, code_mode_contracts: contracts})
    assert {:ok, profile} = Codex.profile(:code_mode_only, context, authority)
    assert Enum.sort(Enum.map(profile.tools, & &1.name)) == ["exec", "wait"]
    assert {:ok, store} = EphemeralStore.new(1)

    opts = [
      run_id: id,
      store: EphemeralStore,
      context: store,
      provider: ControlledProvider,
      provider_context: %{test: self()},
      registry: profile.registry,
      tools: profile.tools,
      authority: profile.authority,
      session_binding: binding,
      subscriber: self(),
      schema_admission: :strict,
      effect_timeout: 15_000,
      run_timeout: 30_000
    ]

    conversation = start_supervised!(Supervisor.child_spec({Conversation, opts}, id: id))
    assert {:ok, _} = Conversation.prompt(conversation, "Exercise explicitly selected Code Mode")
    assert_receive {:code_provider, _, provider}, 5_000
    {conversation, binding, context, provider}
  end

  defp call!(provider, name, arguments) do
    send_call(provider, name, arguments)
    assert_receive {:code_provider, %{messages: messages}, next_provider}, 10_000
    message = List.last(messages)
    assert message.role == :tool
    assert message.name == name
    refute message.result[:is_error]
    assert_roundtrip(message)
    {message.result, next_provider}
  end

  defp send_call(provider, name, arguments) do
    send(
      provider,
      {:events,
       [
         %{
           type: :tool_call_completed,
           tool_call: %{
             id: "#{name}-#{System.unique_integer([:positive])}",
             name: name,
             arguments: arguments
           }
         },
         %{type: :response_completed, message: %{role: :assistant, content: "Running #{name}"}}
       ]}
    )
  end

  defp finish!(conversation, provider, run_id) do
    send(
      provider,
      {:events, [%{type: :response_completed, message: %{role: :assistant, content: "Done"}}]}
    )

    assert_receive {:agent_runtime, ^run_id, %{type: :run_completed}}, 10_000
    GenServer.stop(conversation)
  end

  defp worker!(context, binding, cell_id) do
    assert {:ok, worker} =
             ResourceRegistry.fetch(
               context.resource_registry,
               handle(binding, cell_id),
               binding.owner_id
             )

    worker
  end

  defp handle(binding, cell_id),
    do: %{
      resource_id: cell_id,
      owner_id: binding.owner_id,
      incarnation: binding.incarnation,
      kind: :continuation
    }

  defp assert_roundtrip(message) do
    canonical = message.result |> Jason.encode!() |> Jason.decode!()
    refute Map.has_key?(canonical, "handle")
    refute Map.has_key?(canonical, "token")
    [normalized] = Provider.normalize_messages([message])
    refute normalized.is_error
    assert normalized.metadata.structured_result == canonical
    assert {:ok, entry} = EntryEncoder.encode({:message_end, normalized}, nil, true)
    encoded = Jason.encode!(entry)
    refute encoded =~ "#PID<"
    refute encoded =~ "#Reference<"
    assert {:ok, restored} = encoded |> Jason.decode!() |> EntryDecoder.message()
    assert restored.metadata["structured_result"] == canonical
    assert restored.content == normalized.content
  end

  defp assert_os_stopped(identity) do
    case File.read("/proc/#{identity.pid}/stat") do
      {:error, :enoent} ->
        :ok

      {:ok, stat} ->
        assert Regex.match?(~r/\) [ZX] /, stat), "Deno process is still running after cleanup"
    end
  end

  defp await_generator(worker, deadline) do
    state = :sys.get_state(worker)

    if state.pending_yield == nil and state.terminal_result == nil do
      assert System.monotonic_time(:millisecond) < deadline
      Process.sleep(5)
      await_generator(worker, deadline)
    end
  end
end
