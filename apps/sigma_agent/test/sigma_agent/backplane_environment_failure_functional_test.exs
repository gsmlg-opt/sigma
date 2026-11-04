defmodule Sigma.Agent.BackplaneEnvironmentFailureFunctionalTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.Codex.{Control, Readiness}
  alias Backplane.AgentRuntime.{Conversation, EphemeralStore, Error, Plan}
  alias Sigma.Agent.Backplane.{CodexResources, NativeTools, PlainCommand, Provider}
  alias Sigma.Session.{Log, Writer}

  @moduletag :tmp_dir
  @moduletag :codex_alignment_functional

  defmodule ScriptedProvider do
    def stream(request, %{calls: calls}) do
      completed = Enum.count(request.messages, &(&1.role == :tool))

      case Enum.at(calls, completed) do
        nil ->
          [response("readiness-finished", [%{type: :text, text: "Finished"}])]

        {name, arguments} ->
          tool = %{
            type: :tool_call,
            id: "readiness-#{completed}",
            name: name,
            arguments: arguments,
            input_kind: if(is_binary(arguments), do: :custom, else: :function)
          }

          [
            %{type: :tool_call_completed, tool_call: tool},
            response("readiness-assistant-#{completed}", [tool])
          ]
      end
    end

    defp response(id, content),
      do: %{type: :response_completed, message: %{id: id, role: :assistant, content: content}}
  end

  # Public #128 startup-failure results retain the actual PlainCommand reason.
  # Control presents these as ordinary model errors, rather than aborting a run.
  test "an actual failed command bootstrap retains its reason through public readiness" do
    {failed, original} = failed_startup!()
    assert_failure(Readiness.await(fn -> failed end, 30), original)
  end

  test "an actual failed command bootstrap retains its reason through public Control" do
    {failed, original} = failed_startup!()

    assert {:ok, result} =
             Control.call(%{
               tool_name: "wait_for_environment",
               arguments: %{"environment_id" => failed.environment_id},
               backend_context: %{
                 context: %{
                   environment_provider: fn _id -> failed end,
                   environment_wait_timeout: 30
                 }
               }
             })

    assert_model_failure(result, failed, original)
  end

  test "a native root profile continues after a startup error and persists the complete result",
       %{tmp_dir: dir} do
    {failed, original} = failed_startup!()

    calls = [
      {"wait_for_environment", %{"environment_id" => failed.environment_id}},
      {"update_plan",
       %{"plan" => [%{"step" => "Continue after failure", "status" => "completed"}]}}
    ]

    {context, messages} = run!(dir, "readiness-direct", failed, calls)
    error = tool_result!(messages, "wait_for_environment")
    assert_model_failure(error.result, failed, original)
    continuation = tool_result!(messages, "update_plan")
    refute continuation.result[:is_error]

    assert {:ok, %{revision: 2, content: %{"plan" => [%{"status" => "completed"}]}}} =
             Plan.read(context.plan)

    assert_persisted!(dir, "readiness-direct", messages, error, true)
    assert {:ok, %{status: :confirmed}} = CodexResources.close(context.codex_resources)
  end

  @tag timeout: 60_000
  test "real Deno receives a startup error as a value and continues with a native plan",
       %{tmp_dir: dir} do
    assert is_binary(System.find_executable("deno"))
    {failed, original} = failed_startup!()

    code = """
    const failed = await tools.wait_for_environment({environment_id: #{Jason.encode!(failed.environment_id)}});
    const plan = await tools.update_plan({plan: [{step: "Continue inside Deno", status: "completed"}]});
    return {failed, plan};
    """

    {context, messages} = run!(dir, "readiness-deno", failed, [{"exec", code}])
    result = tool_result!(messages, "exec")
    refute result.result[:is_error]
    assert %{status: :completed, value: %{"failed" => failure, "plan" => plan}} = result.result
    assert_model_failure(failure, failed, original)
    assert plan["revision"] == 2

    assert {:ok, %{revision: 2, content: %{"plan" => [%{"status" => "completed"}]}}} =
             Plan.read(context.plan)

    assert_persisted!(dir, "readiness-deno", messages, result, false)
    assert {:ok, %{status: :confirmed}} = CodexResources.close(context.codex_resources)
  end

  test "a real startup failure observed after starting retains the failure instead of timing out" do
    {failed, original} = failed_startup!()
    reads = :atomics.new(1, [])

    provider = fn ->
      if :atomics.add_get(reads, 1, 1) == 1,
        do: failed |> Map.put(:status, "starting") |> Map.delete(:error),
        else: failed
    end

    assert_failure(Readiness.await(provider, 50), original)
    assert :atomics.get(reads, 1) >= 2
  end

  defp run!(dir, run_id, failed, calls) do
    resources = start_supervised!({CodexResources, workspace: dir, owner_pid: self()})
    names = ~w(wait_for_environment update_plan exec wait)
    authority = %{caller: "readiness-root", run_id: run_id, grants: names, tool_revision: 1}
    assert {:ok, binding} = CodexResources.bind(resources, authority)
    assert {:ok, context} = CodexResources.context(resources, binding)

    # The production resource host has no failure-injection option. This explicit
    # test host callback supplies only the failure observed from PlainCommand;
    # native composition, Runtime, Deno, plan and persistence use public paths.
    context = Map.put(context, :environment_provider, fn _id -> failed end)

    assert {:ok, profile} =
             NativeTools.profile(context, authority, %{hook_specs: []}, tools: names)

    assert {:ok, store} = EphemeralStore.new(1)

    conversation =
      start_supervised!(
        {Conversation,
         run_id: run_id,
         store: EphemeralStore,
         context: store,
         provider: ScriptedProvider,
         provider_context: %{calls: calls},
         registry: profile.registry,
         tools: profile.tools,
         authority: profile.authority,
         session_binding: binding,
         subscriber: self(),
         effect_timeout: 15_000,
         run_timeout: 30_000}
      )

    assert {:ok, _} = Conversation.prompt(conversation, "Continue after environment failure")
    assert_receive {:agent_runtime, ^run_id, %{type: :run_completed}}, 30_000
    messages = Conversation.status(conversation).messages
    GenServer.stop(conversation)
    {context, messages}
  end

  defp tool_result!(messages, name) do
    result = Enum.find(messages, &(&1.role == :tool and &1.name == name))
    assert result, "missing #{name} result from the completed Runtime run"
    result
  end

  defp assert_persisted!(dir, id, messages, result, is_error) do
    [message] = Provider.normalize_messages([result])
    assert message.is_error == is_error
    expected = result.result |> Jason.encode!() |> Jason.decode!()
    assert message.metadata.structured_result == expected
    path = Path.join(dir, id <> ".jsonl")
    writer = start_supervised!({Writer, storage_id: path, session_id: id, cwd: dir})

    # Journal reads require the actual assistant call paired with each result.
    # Persist the Runtime's complete assistant/tool sequence rather than an
    # orphaned result that the production reader correctly repairs away.
    projected =
      messages
      |> Enum.filter(&(&1.role in [:assistant, :tool]))
      |> Provider.normalize_messages()

    for entry <- projected,
        do: assert({:ok, _} = Writer.append(writer, {:message_end, entry}))

    assert {:ok, snapshot} = Log.snapshot(path)
    assert Enum.map(snapshot.messages, & &1.id) == Enum.map(projected, & &1.id)
    refute Enum.any?(snapshot.diagnostics, &(&1.kind == :message_repair))

    saved = Enum.find(snapshot.messages, &(&1.id == message.id))
    assert saved
    assert saved.tool_call_id == result.tool_call_id
    assert saved.is_error == is_error
    assert saved.metadata["structured_result"] == expected
    before = File.read!(path)
    assert {:ok, same} = Log.snapshot(path)
    assert same.messages == snapshot.messages
    assert File.read!(path) == before
  end

  defp assert_model_failure(result, failed, original) do
    canonical = result |> Jason.encode!() |> Jason.decode!()

    assert %{
             "is_error" => true,
             "error" => %{
               "class" => "execution_failure",
               "message" => message,
               "details" => %{
                 "environment_id" => id,
                 "status" => "failed",
                 "startup_class" => "validation",
                 "reason_truncated" => false
               }
             }
           } = canonical

    assert id == failed.environment_id
    assert message =~ original.message
  end

  defp failed_startup! do
    command =
      start_supervised!(
        {PlainCommand, owner_pid: self(), async_start: true, local: [cleanup_timeout: 0]}
      )

    assert_receive {:plain_command_startup, ^command, {:error, %Error{} = actual}}, 2_000
    assert actual.class == :validation
    assert actual.message =~ "cleanup_timeout"
    assert :ok = PlainCommand.stop(command)

    {%{
       environment_id: "actual-command-startup-failure",
       kind: "local-command-runtime",
       status: "failed",
       ready: false,
       authorized: true,
       error: %{class: actual.class, message: actual.message}
     }, actual}
  end

  defp assert_failure(result, original) do
    assert {:error, %Error{} = error} = result
    refute error.class == :timeout
    assert Jason.encode!(Error.to_map(error)) =~ original.message
  end
end
