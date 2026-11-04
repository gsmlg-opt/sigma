defmodule Sigma.Agent.BackplaneCodexLocalToolsTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.{Conversation, EphemeralStore, Error}
  alias Backplane.AgentRuntime.Codex
  alias Backplane.AgentRuntime.Codex.Session
  alias Sigma.Agent.Backplane.{CodexResources, Provider}
  alias Sigma.Session.{EntryDecoder, EntryEncoder}
  alias Sigma.Session.Storage.JsonlFile

  @moduletag :tmp_dir

  # A complete one-pixel RGBA PNG, including valid IHDR/IDAT/IEND chunks.
  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg=="
       )

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
              tool_call: %{id: "local-#{completed}", name: name, arguments: arguments}
            },
            response("Running local tool")
          ]
      end
    end

    defp response(text),
      do: %{type: :response_completed, message: %{role: :assistant, content: text}}
  end

  test "view_image reads a real PNG and its projected image survives JSONL replay", %{
    tmp_dir: dir
  } do
    image_path = Path.join(dir, "pixel.png")
    File.write!(image_path, @png)

    run =
      start_run!(dir, "image", [
        {"view_image", %{"path" => "pixel.png", "detail" => "original"}}
      ])

    messages = completed_messages!(run)
    [tool] = Enum.filter(messages, &(&1.role == :tool))
    encoded = Base.encode64(@png)
    image_url = "data:image/png;base64,#{encoded}"

    assert %{
             data: @png,
             mime_type: "image/png",
             path: "pixel.png",
             detail: "original",
             image_url: ^image_url,
             is_error: false
           } = tool.result

    assert tool.result.bytes == byte_size(@png)
    [projected] = Provider.normalize_messages([tool])
    refute projected.is_error
    assert projected.content == [%{type: :image, data: encoded, mime_type: "image/png"}]
    assert projected.metadata.structured_result["image_url"] == image_url
    refute Map.has_key?(projected.metadata.structured_result, "data")

    journal = Path.join(dir, "images.jsonl")
    assert {:ok, entry} = EntryEncoder.encode({:message_end, projected}, nil, true)
    assert :ok = JsonlFile.append(journal, entry)
    File.rm!(image_path)

    assert {:ok, [stored], []} = JsonlFile.read_with_diagnostics(journal)
    assert {:ok, replayed} = EntryDecoder.message(stored)
    assert replayed.tool_name == "view_image"
    assert replayed.content == projected.content
    assert replayed.metadata["structured_result"] == projected.metadata.structured_result
    assert replayed.metadata["structured_result"]["detail"] == "original"
    assert replayed.metadata["structured_result"]["bytes"] == byte_size(@png)
    assert {:ok, @png} = Base.decode64(hd(replayed.content).data)
    assert {:ok, %{status: :confirmed}} = CodexResources.close(run.resources)
  end

  test "view_image refuses an existing PNG outside its bound workspace", %{tmp_dir: dir} do
    workspace = Path.join(dir, "workspace")
    File.mkdir!(workspace)
    File.write!(Path.join(dir, "outside.png"), @png)
    run = start_run!(workspace, "outside-image", [{"view_image", %{"path" => "../outside.png"}}])
    [tool] = run |> completed_messages!() |> Enum.filter(&(&1.role == :tool))

    assert %{is_error: true, error: %Error{class: :forbidden}} = tool.result
    refute Map.has_key?(tool.result, :data)
    [projected] = Provider.normalize_messages([tool])
    assert projected.is_error
    assert [%{type: :text}] = projected.content
    assert projected.metadata.structured_result["error"]["class"] == "forbidden"
    assert {:ok, %{status: :confirmed}} = CodexResources.close(run.resources)
  end

  test "native clock calls return current UTC and an elapsed real sleep", %{tmp_dir: dir} do
    before_time = DateTime.utc_now() |> DateTime.truncate(:second)
    started = System.monotonic_time(:microsecond)

    run =
      start_run!(dir, "clock", [
        {"clock::curr_time", %{}},
        {"clock::sleep", %{"duration_ms" => 25}},
        {"clock::curr_time", %{}}
      ])

    tools = run |> completed_messages!() |> Enum.filter(&(&1.role == :tool))
    elapsed = (System.monotonic_time(:microsecond) - started) / 1_000_000
    after_time = DateTime.utc_now() |> DateTime.truncate(:second)
    assert [first_clock, sleep, second_clock] = tools
    assert Enum.map(tools, & &1.name) == ["clock::curr_time", "clock::sleep", "clock::curr_time"]
    assert Enum.all?(tools, &(&1.result.is_error == false))

    for clock <- [first_clock, second_clock] do
      assert String.ends_with?(clock.result.current_time, " UTC")

      reported =
        clock.result.current_time
        |> String.replace_suffix(" UTC", "")
        |> NaiveDateTime.from_iso8601!()
        |> DateTime.from_naive!("Etc/UTC")

      assert DateTime.compare(reported, before_time) in [:eq, :gt]
      assert DateTime.compare(reported, after_time) in [:eq, :lt]
    end

    assert sleep.result.wall_time_seconds >= 0.025
    assert sleep.result.wall_time_seconds <= elapsed
    assert {:ok, %{status: :confirmed}} = CodexResources.close(run.resources)
  end

  test "cancelling a running sleep closes admission without a successful tool result", %{
    tmp_dir: dir
  } do
    run = start_sleep!(dir, "cancel-sleep")
    started = System.monotonic_time(:millisecond)
    assert :ok = Conversation.cancel(run.conversation)
    assert_interrupted_sleep!(run)
    assert System.monotonic_time(:millisecond) - started < 5_000

    assert %{phase: :closed, cleanup: {:ok, %{status: :confirmed}}} =
             Session.status(run.binding.session)

    assert {:error, %Error{class: :resource_conflict}} =
             CodexResources.bind(run.resources, authority("after-cancel", []))

    assert {:ok, %{status: :confirmed}} = CodexResources.close(run.resources)
    assert_owned_children_stopped!(run)
  end

  test "closing owned resources interrupts an active sleep before its duration elapses", %{
    tmp_dir: dir
  } do
    run = start_sleep!(dir, "close-sleep")
    started = System.monotonic_time(:millisecond)
    assert {:ok, %{status: :confirmed}} = CodexResources.close(run.resources)
    assert_interrupted_sleep!(run)
    assert System.monotonic_time(:millisecond) - started < 5_000
    assert_owned_children_stopped!(run)

    assert {:error, %Error{class: :resource_conflict}} =
             CodexResources.bind(run.resources, authority("after-close", []))
  end

  defp start_sleep!(dir, id) do
    run = start_run!(dir, id, [{"clock::sleep", %{"duration_ms" => 30_000}}])

    assert_receive {:agent_runtime, ^id,
                    %{type: :tool_started, invocation: %{tool_name: "clock::sleep"}}}

    refute_receive {:agent_runtime, ^id, %{type: :tool_completed}}, 25
    run
  end

  defp assert_interrupted_sleep!(%{id: id, conversation: conversation}) do
    assert_receive {:agent_runtime, ^id, %{type: :run_cancelled}}, 5_000

    assert %{phase: :terminal, resource_cleanup: :confirmed, run: run, messages: messages} =
             Conversation.status(conversation)

    # Runtime may conservatively retain an interrupted invocation as uncertain;
    # a cleanup receipt never turns that interrupted effect into a completed one.
    assert run.state in [:cancelled, :unknown_outcome]
    refute Enum.any?(messages, &(&1.role == :tool))
    refute_receive {:agent_runtime, ^id, %{type: :tool_completed}}, 25
    refute_receive {:agent_runtime, ^id, %{type: :run_completed}}, 0
  end

  defp assert_owned_children_stopped!(run) do
    refute Process.alive?(run.binding.session)
    refute Process.alive?(run.context.command.server)
    refute Process.alive?(run.context.plan)
  end

  defp completed_messages!(%{id: id, conversation: conversation}) do
    assert_receive {:agent_runtime, ^id, %{type: :run_completed}}, 5_000

    assert %{phase: :terminal, run: %{state: :completed}, messages: messages} =
             Conversation.status(conversation)

    messages
  end

  defp start_run!(dir, id, calls) do
    resources = start_supervised!({CodexResources, workspace: dir, owner_pid: self()})
    authority = authority(id, calls)
    assert {:ok, binding} = CodexResources.bind(resources, authority)
    assert {:ok, context} = CodexResources.context(resources, binding)

    assert {:ok, profile} =
             Codex.profile(:pinned_local, context, authority, tools: authority.grants)

    assert {:ok, store} = EphemeralStore.new(1)

    conversation =
      start_supervised!(
        {Conversation,
         run_id: id,
         store: EphemeralStore,
         context: store,
         provider: ScriptedProvider,
         provider_context: %{calls: calls},
         registry: profile.registry,
         tools: profile.tools,
         authority: profile.authority,
         session_binding: binding,
         subscriber: self(),
         effect_timeout: 40_000}
      )

    assert {:ok, _} = Conversation.prompt(conversation, "Exercise real native local tools")

    %{
      resources: resources,
      binding: binding,
      context: context,
      conversation: conversation,
      id: id
    }
  end

  defp authority(id, calls) do
    %{
      caller: "local-tools-test",
      run_id: id,
      grants: calls |> Enum.map(&elem(&1, 0)) |> Enum.uniq(),
      tool_revision: 1
    }
  end
end
