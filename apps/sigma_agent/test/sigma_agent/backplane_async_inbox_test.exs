defmodule Sigma.Agent.BackplaneAsyncInboxTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.{Codex, Conversation}
  alias Sigma.Agent.Backplane.{AsyncInbox, Store}
  alias Sigma.Agent.Message
  alias Sigma.Protocol.AsyncInteractions
  alias Sigma.Session.Writer

  @moduletag :tmp_dir

  defmodule Provider do
    def stream(request, context) do
      if Enum.any?(request.messages, &(&1.role == :tool)) do
        [%{type: :response_completed, message: %{role: :assistant, content: "Done"}}]
      else
        Enum.map(context.calls, fn {id, name, arguments} ->
          %{type: :tool_call_completed, tool_call: %{id: id, name: name, arguments: arguments}}
        end) ++ [%{type: :response_completed, message: %{role: :assistant, content: "Issued"}}]
      end
    end
  end

  defmodule GatedStore do
    defdelegate mode(), to: Store
    defdelegate capabilities(), to: Store

    def store(context, run, meta) do
      result = Store.store(context.store, run, meta)

      if match?({:ok, _}, result) and elem(meta.command, 0) == :tool_invoked do
        send(context.test, {:invocation_committed, self()})
        receive do: (:release -> :ok)
      end

      result
    end
  end

  defmodule FaultStorage do
    def read({path, _fault}), do: Sigma.Session.Storage.JsonlFile.read(path)

    def read_with_diagnostics({path, _fault}),
      do: Sigma.Session.Storage.JsonlFile.read_with_diagnostics(path)

    def append({path, fault}, entry) do
      if Agent.get(fault, & &1),
        do: {:error, :injected_append_failure},
        else: Sigma.Session.Storage.JsonlFile.append(path, entry)
    end
  end

  test "real settled Store reconstructs lost identical notifications and survives reopen", ctx do
    fixture = fixture!(ctx.tmp_dir, calls())
    finish!(fixture)

    assert {:ok, %{recovered: 2, uncertain: 0}} =
             AsyncInbox.reconcile(fixture.writer, fixture.store)

    assert {:ok, before} = Writer.async_interaction_state(fixture.writer)
    assert length(AsyncInteractions.snapshot(before.projection, [fixture.anchor])) == 2
    assert before.leaf_id == fixture.anchor

    assert {:ok, %{recovered: 0, uncertain: 0}} =
             AsyncInbox.reconcile(fixture.writer, fixture.store)

    GenServer.stop(fixture.writer)
    reopened = writer!(ctx.tmp_dir)
    assert {:ok, after_restart} = Writer.async_interaction_state(reopened)
    assert after_restart.projection == before.projection
    assert after_restart.leaf_id == fixture.anchor
  end

  test "capture checks committed invocation identity and exact admitted question payload", ctx do
    fixture = fixture!(ctx.tmp_dir, Enum.take(calls(), 1))

    assert_receive {:agent_runtime, "root-run", %{type: :async_user_input_requested} = event},
                   5_000

    finish!(fixture)
    origin = %{session_id: "session", run_id: "root-run", incarnation: 1}

    assert {:error, _} =
             AsyncInbox.capture(fixture.writer, fixture.store, origin, %{
               event
               | invocation_id: "forged"
             })

    assert {:error, _} =
             AsyncInbox.capture(fixture.writer, fixture.store, origin, %{
               event
               | questions: [%{"title" => "Forged"}]
             })

    assert {:error, _} =
             AsyncInbox.capture(
               fixture.writer,
               fixture.store,
               %{origin | session_id: "other"},
               event
             )

    assert {:ok, item} = AsyncInbox.capture(fixture.writer, fixture.store, origin, event)
    assert item["origin"]["invocation_id"] == event.invocation_id
    assert item["questions"] == event.questions
    assert {:ok, ^item} = AsyncInbox.capture(fixture.writer, fixture.store, origin, event)
  end

  test "unsettled public intent is uncertain and does not become a successful card", ctx do
    fixture = fixture!(ctx.tmp_dir, Enum.take(calls(), 1), gated: true)
    assert_receive {:invocation_committed, worker}, 5_000

    assert {:ok, %{recovered: 0, uncertain: 1}} =
             AsyncInbox.reconcile(fixture.writer, fixture.store)

    assert {:ok, %{projection: projection}} = Writer.async_interaction_state(fixture.writer)
    assert projection.items == %{}
    send(worker, :release)
    finish!(fixture)

    assert {:ok, %{recovered: 1, uncertain: 0}} =
             AsyncInbox.reconcile(fixture.writer, fixture.store)
  end

  test "selected raw ancestry excludes sibling runtime cards and stale branch answers", ctx do
    fixture = fixture!(ctx.tmp_dir, Enum.take(calls(), 1))
    finish!(fixture)
    assert {:ok, %{recovered: 1}} = AsyncInbox.reconcile(fixture.writer, fixture.store)
    assert {:ok, %{projection: projection}} = Writer.async_interaction_state(fixture.writer)
    [item] = Map.values(projection.items)
    assert :ok = Writer.checkout(fixture.writer, nil, fixture.anchor)

    sibling =
      Message.user("sibling-user", "Sibling") |> Map.put(:metadata, %{turn_id: "sibling-run"})

    assert {:ok, sibling_id} = Writer.append(fixture.writer, {:message_end, sibling})
    assert {:ok, %{recovered: 0}} = AsyncInbox.reconcile(fixture.writer, fixture.store)
    payload = %{"replyId" => "reply", "answers" => [%{"questionIndex" => 0, "answer" => "A"}]}

    assert {:error, _} =
             AsyncInbox.prepare_reply(fixture.writer, item["item_id"], payload, sibling_id)

    assert {:error, _} =
             AsyncInbox.prepare_reply(fixture.writer, item["item_id"], payload, fixture.anchor)
  end

  test "answer persistence is idempotent and an unacknowledged append schedules nothing", ctx do
    fixture = fixture!(ctx.tmp_dir, Enum.take(calls(), 1), faults: true)
    finish!(fixture)
    assert {:ok, _} = AsyncInbox.reconcile(fixture.writer, fixture.store)
    assert {:ok, %{projection: projection}} = Writer.async_interaction_state(fixture.writer)
    [item] = Map.values(projection.items)

    payload = %{
      "replyId" => "reply",
      "answers" => [%{"questionIndex" => 0, "answer" => "  原文\n"}]
    }

    Agent.update(fixture.fault, fn _ -> true end)

    assert {:error, _} =
             AsyncInbox.prepare_reply(fixture.writer, item["item_id"], payload, fixture.anchor)

    Agent.update(fixture.fault, fn _ -> false end)

    assert {:ok, %{status: :saved, reply: reply} = saved} =
             AsyncInbox.prepare_reply(fixture.writer, item["item_id"], payload, fixture.anchor)

    assert reply["content"] =~ "  原文\n"
    assert reply["metadata"]["async_interaction"]["origin_session_id"] == "session"

    assert {:ok, ^saved} =
             AsyncInbox.prepare_reply(fixture.writer, item["item_id"], payload, fixture.anchor)

    assert {:error, _} =
             AsyncInbox.prepare_reply(
               fixture.writer,
               item["item_id"],
               %{payload | "answers" => [%{"questionIndex" => 0, "answer" => "Changed"}]},
               fixture.anchor
             )

    assert {:ok, %{projection: saved_state}} = Writer.async_interaction_state(fixture.writer)
    assert saved_state.items[item["item_id"]]["status"] == "saved"
  end

  defp fixture!(dir, calls, opts \\ []) do
    fault = if opts[:faults], do: start_supervised!({Agent, fn -> false end})
    writer = writer!(dir, fault)
    message = Message.user("initial-user", "Ask") |> Map.put(:metadata, %{turn_id: "root-run"})
    {:ok, anchor} = Writer.append(writer, {:message_end, message})
    store = start_supervised!({Store, path: Path.join(dir, "runtime")})
    names = ~w(request_user_input_async send_message_to_user_async)

    authority = %{
      caller: "root",
      run_id: "root-run",
      grants: names,
      tool_revisions: Map.new(names, &{&1, 1})
    }

    {:ok, profile} = Codex.profile(:interactive, %{root?: true}, authority, tools: names)
    store_mod = if opts[:gated], do: GatedStore, else: Store
    context = if opts[:gated], do: %{store: store, test: self()}, else: store

    conversation =
      start_supervised!(
        {Conversation,
         run_id: "root-run",
         store: store_mod,
         context: context,
         provider: Provider,
         provider_context: %{calls: calls},
         subscriber: self(),
         registry: profile.registry,
         tools: profile.tools,
         authority: profile.authority,
         schema_admission: :strict,
         run_timeout: 30_000,
         effect_timeout: 10_000}
      )

    assert {:ok, _} = Conversation.prompt(conversation, "Ask")
    %{writer: writer, store: store, conversation: conversation, anchor: anchor, fault: fault}
  end

  defp writer!(dir, fault \\ nil) do
    path = Path.join(dir, "session.jsonl")

    options =
      if fault,
        do: [storage_id: {path, fault}, storage_mod: FaultStorage],
        else: [storage_id: path]

    start_supervised!(
      Supervisor.child_spec({Writer, options ++ [session_id: "session", cwd: dir]},
        id: make_ref()
      )
    )
  end

  defp calls do
    for id <- ["call-1", "call-2"],
        do:
          {id, "request_user_input_async",
           %{"questions" => [%{"title" => "Continue?", "options" => ["A", "B"]}]}}
  end

  defp finish!(fixture) do
    assert_receive {:agent_runtime, "root-run", %{type: :run_completed}}, 5_000
    assert Conversation.status(fixture.conversation).run.state == :completed
  end
end
