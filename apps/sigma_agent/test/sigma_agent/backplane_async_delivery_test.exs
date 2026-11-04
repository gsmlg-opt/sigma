defmodule Sigma.Agent.BackplaneAsyncDeliveryTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.{Codex, Conversation}
  alias Sigma.Agent.Backplane.{AsyncDelivery, AsyncInbox, Store}
  alias Sigma.Agent.Message
  alias Sigma.Session.{Writer, Storage.JsonlFile}

  @moduletag :tmp_dir

  defmodule Provider do
    def stream(request, _context) do
      if Enum.any?(request.messages, &(&1.role == :tool)) do
        [%{type: :response_completed, message: %{role: :assistant, content: "Done"}}]
      else
        [
          %{
            type: :tool_call_completed,
            tool_call: %{
              id: "question-call",
              name: "request_user_input_async",
              arguments: %{"questions" => [%{"title" => "Continue?", "options" => ["A", "B"]}]}
            }
          },
          %{
            type: :tool_call_completed,
            tool_call: %{
              id: "notice-call",
              name: "send_message_to_user_async",
              arguments: %{"message" => "Progress"}
            }
          },
          %{type: :response_completed, message: %{role: :assistant, content: "Issued"}}
        ]
      end
    end
  end

  defmodule FaultStorage do
    def read({path, _fault}), do: JsonlFile.read(path)
    def read_with_diagnostics({path, _fault}), do: JsonlFile.read_with_diagnostics(path)

    def append({path, fault}, entry) do
      if entry["type"] == "async_interaction" and entry["event"]["fact"] == "dismissed" and
           Agent.get(fault, & &1),
         do: {:error, :injected_dismiss_failure},
         else: JsonlFile.append(path, entry)
    end
  end

  defmodule ReplyProvider do
    def stream(_request, _context),
      do: [%{type: :response_completed, message: %{role: :assistant, content: "Received"}}]
  end

  defmodule QueuedReplyProvider do
    def stream(_request, %{test_pid: owner}) do
      send(owner, {:queued_reply_provider, self()})

      receive do
        :finish ->
          [%{type: :response_completed, message: %{role: :assistant, content: "Received"}}]
      end
    end
  end

  for {label, same_content?, same_id?, expected_status} <- [
        {"matching checkpoint", true, true, "consumed"},
        {"different checkpoint content", false, true, "delivery_unknown"},
        {"wrong Runtime admission ID", true, false, "delivery_unknown"}
      ] do
    test "reply with #{label} uses exact Runtime consumption evidence", ctx do
      fixture = fixture!(ctx.tmp_dir)
      item = question(snapshot!(fixture.writer))

      assert {:ok, %{reply: reply}} =
               AsyncInbox.prepare_reply(fixture.writer, item["item_id"], reply(), fixture.anchor)

      assert :ok =
               AsyncDelivery.fact(fixture.writer, item, "dispatch_started", %{
                 "reply_id" => reply["reply_id"]
               })

      user =
        Message.user(reply["message_id"], reply["content"])
        |> Map.put(:metadata, Map.put(reply["metadata"], "turn_id", reply["turn_id"]))

      assert {:ok, _} = Writer.append(fixture.writer, {:message_end, user})
      content = if unquote(same_content?), do: user.content, else: "A different user request"
      admission = checkpoint!(fixture.store, reply["turn_id"], content)
      runtime_id = if unquote(same_id?), do: admission.message_id, else: "unmatched-admission"

      assert :ok =
               AsyncDelivery.runtime_admitted(fixture.writer, user, reply["turn_id"], runtime_id)

      GenServer.stop(fixture.writer)
      reopened = writer!(fixture.path, fixture.fault)
      assert {:ok, %{items: items}} = AsyncDelivery.refresh(reopened, fixture.store, MapSet.new())
      assert question(items)["status"] == unquote(expected_status)

      assert {:ok, %{items: ^items}} =
               AsyncDelivery.refresh(reopened, fixture.store, MapSet.new())
    end
  end

  test "a sibling canonical user cannot prove a selected branch consumed the reply", ctx do
    fixture = fixture!(ctx.tmp_dir)
    item = question(snapshot!(fixture.writer))

    assert {:ok, %{reply: reply}} =
             AsyncInbox.prepare_reply(fixture.writer, item["item_id"], reply(), fixture.anchor)

    assert :ok =
             AsyncDelivery.fact(fixture.writer, item, "dispatch_started", %{
               "reply_id" => reply["reply_id"]
             })

    user =
      Message.user(reply["message_id"], reply["content"])
      |> Map.put(:metadata, Map.put(reply["metadata"], "turn_id", reply["turn_id"]))

    assert {:ok, selected} = Writer.append(fixture.writer, {:message_end, user})
    admission = checkpoint!(fixture.store, reply["turn_id"], user.content)

    assert :ok =
             AsyncDelivery.runtime_admitted(
               fixture.writer,
               user,
               reply["turn_id"],
               admission.message_id
             )

    assert :ok = Writer.checkout(fixture.writer, fixture.anchor, selected)
    sibling = Message.user("sibling", "Unrelated sibling")
    assert {:ok, sibling_id} = Writer.append(fixture.writer, {:message_end, sibling})

    assert {:ok, %{items: items}} =
             AsyncDelivery.refresh(fixture.writer, fixture.store, MapSet.new())

    assert is_nil(question(items))

    assert :ok = Writer.checkout(fixture.writer, selected, sibling_id)

    assert {:ok, %{items: items}} =
             AsyncDelivery.refresh(fixture.writer, fixture.store, MapSet.new())

    assert question(items)["status"] == "consumed"
  end

  test "a checkpointed steering admission is not consumption until its prompt is consumed", ctx do
    fixture = fixture!(ctx.tmp_dir)
    item = question(snapshot!(fixture.writer))

    assert {:ok, %{reply: reply}} =
             AsyncInbox.prepare_reply(fixture.writer, item["item_id"], reply(), fixture.anchor)

    assert :ok =
             AsyncDelivery.fact(fixture.writer, item, "dispatch_started", %{
               "reply_id" => reply["reply_id"]
             })

    conversation =
      start_supervised!(
        Supervisor.child_spec(
          {Conversation,
           run_id: reply["turn_id"],
           store: Store,
           context: fixture.store,
           provider: QueuedReplyProvider,
           provider_context: %{test_pid: self()},
           subscriber: self()},
          id: :queued_reply
        )
      )

    assert {:ok, _} = Conversation.prompt(conversation, "A real prompt already running")
    assert_receive {:queued_reply_provider, first_provider}, 5_000
    assert {:ok, admission} = Conversation.steer(conversation, reply["content"])

    user =
      Message.user(reply["message_id"], reply["content"])
      |> Map.put(:metadata, Map.put(reply["metadata"], "turn_id", reply["turn_id"]))

    assert {:ok, _} = Writer.append(fixture.writer, {:message_end, user})

    assert :ok =
             AsyncDelivery.runtime_admitted(
               fixture.writer,
               user,
               reply["turn_id"],
               admission.message_id
             )

    assert {:ok, %{items: items}} =
             AsyncDelivery.refresh(fixture.writer, fixture.store, MapSet.new())

    assert question(items)["status"] == "delivery_unknown"
    send(first_provider, :finish)
    assert_receive {:queued_reply_provider, second_provider}, 5_000

    assert {:ok, %{items: items}} =
             AsyncDelivery.refresh(fixture.writer, fixture.store, MapSet.new())

    assert question(items)["status"] == "consumed"
    send(second_provider, :finish)
    run_id = reply["turn_id"]
    assert_receive {:agent_runtime, ^run_id, %{type: :run_completed}}, 5_000
  end

  for outcome <- [:cancelled, :failed] do
    test "reopen closes a question from persisted host #{outcome} after Store completed", ctx do
      outcome = unquote(outcome)
      fixture = fixture!(ctx.tmp_dir)
      terminal!(fixture.writer, outcome)
      assert {:ok, raw} = JsonlFile.read(fixture.path)

      assert Enum.any?(raw, fn entry ->
               entry["type"] == "metrics" and entry["fact"] == "turn_finished" and
                 entry["parentId"] == fixture.anchor and
                 entry["data"]["session_id"] == "session" and
                 entry["data"]["turn_id"] == "root-run" and
                 entry["data"]["status"] == Atom.to_string(outcome)
             end)

      assert {:ok, %{run: %{state: :completed}}} = Store.load(fixture.store, "root-run")
      GenServer.stop(fixture.writer)
      reopened = writer!(fixture.path, fixture.fault)

      assert {:ok, %{items: items, leaf_id: leaf}} =
               AsyncDelivery.refresh(reopened, fixture.store, MapSet.new())

      question = question(items)
      assert leaf == fixture.anchor
      assert question["status"] == "dismissed"
      assert question["reason"] == "origin_#{outcome}"
      refute question["can_reply"]
      assert notice(items)["status"] == "notice"

      assert {:error, _} =
               AsyncInbox.prepare_reply(reopened, question["item_id"], reply(), fixture.anchor)

      assert {:ok, %{items: ^items}} =
               AsyncDelivery.refresh(reopened, fixture.store, MapSet.new())
    end

    test "failed #{outcome} dismissal remains an error and recovery retries the durable close",
         ctx do
      outcome = unquote(outcome)
      fixture = fixture!(ctx.tmp_dir)
      terminal!(fixture.writer, outcome)
      Agent.update(fixture.fault, fn _ -> true end)

      assert {:error, {:storage_append_failed, :injected_dismiss_failure}} =
               AsyncDelivery.close_run(fixture.writer, "root-run", outcome)

      assert {:error, {:storage_append_failed, :injected_dismiss_failure}} =
               AsyncDelivery.refresh(fixture.writer, fixture.store, MapSet.new())

      assert {:ok, %{items: items}} = AsyncDelivery.snapshot(fixture.writer)
      assert question(items)["status"] == "open"
      GenServer.stop(fixture.writer)
      Agent.update(fixture.fault, fn _ -> false end)
      reopened = writer!(fixture.path, fixture.fault)

      assert {:ok, %{items: recovered}} =
               AsyncDelivery.refresh(reopened, fixture.store, MapSet.new())

      assert question(recovered)["status"] == "dismissed"
      assert question(recovered)["reason"] == "origin_#{outcome}"
      refute question(recovered)["can_reply"]
    end
  end

  test "completed host and Store outcomes preserve answerable questions", ctx do
    fixture = fixture!(ctx.tmp_dir)
    terminal!(fixture.writer, :completed)

    assert {:ok, %{items: items}} =
             AsyncDelivery.refresh(fixture.writer, fixture.store, MapSet.new())

    assert question(items)["status"] == "open"
    assert question(items)["can_reply"]

    assert {:ok, %{status: :saved}} =
             AsyncInbox.prepare_reply(
               fixture.writer,
               question(items)["item_id"],
               reply(),
               fixture.anchor
             )
  end

  test "terminal metrics from another session or run do not close the question", ctx do
    fixture = fixture!(ctx.tmp_dir)
    terminal!(fixture.writer, :cancelled, session_id: "foreign")
    terminal!(fixture.writer, :failed, turn_id: "other-run")

    assert {:ok, %{items: items}} =
             AsyncDelivery.refresh(fixture.writer, fixture.store, MapSet.new())

    assert question(items)["status"] == "open"
    assert question(items)["can_reply"]
  end

  test "terminal metrics attached to a sibling branch do not close the selected question", ctx do
    fixture = fixture!(ctx.tmp_dir)
    assert :ok = Writer.checkout(fixture.writer, nil, fixture.anchor)

    sibling =
      Message.user("sibling-user", "Sibling") |> Map.put(:metadata, %{turn_id: "sibling-run"})

    assert {:ok, sibling_id} = Writer.append(fixture.writer, {:message_end, sibling})
    terminal!(fixture.writer, :cancelled)
    assert :ok = Writer.checkout(fixture.writer, fixture.anchor, sibling_id)

    assert {:ok, %{items: items}} =
             AsyncDelivery.refresh(fixture.writer, fixture.store, MapSet.new())

    assert question(items)["status"] == "open"
    assert question(items)["can_reply"]
  end

  defp fixture!(dir) do
    path = Path.join(dir, "session.jsonl")
    fault = start_supervised!({Agent, fn -> false end})
    writer = writer!(path, fault)
    message = Message.user("initial-user", "Ask") |> Map.put(:metadata, %{turn_id: "root-run"})
    assert {:ok, anchor} = Writer.append(writer, {:message_end, message})
    store = start_supervised!({Store, path: Path.join(dir, "runtime")})
    names = ~w(request_user_input_async send_message_to_user_async)

    authority = %{
      caller: "root",
      run_id: "root-run",
      grants: names,
      tool_revisions: Map.new(names, &{&1, 1})
    }

    assert {:ok, profile} = Codex.profile(:interactive, %{root?: true}, authority, tools: names)

    conversation =
      start_supervised!(
        {Conversation,
         run_id: "root-run",
         store: Store,
         context: store,
         provider: Provider,
         subscriber: self(),
         registry: profile.registry,
         tools: profile.tools,
         authority: profile.authority,
         schema_admission: :strict,
         run_timeout: 30_000,
         effect_timeout: 10_000}
      )

    assert {:ok, _} = Conversation.prompt(conversation, "Ask")
    assert_receive {:agent_runtime, "root-run", %{type: :run_completed}}, 5_000
    assert Conversation.status(conversation).run.state == :completed
    assert {:ok, %{recovered: 2, uncertain: 0}} = AsyncInbox.reconcile(writer, store)
    %{path: path, fault: fault, writer: writer, store: store, anchor: anchor}
  end

  defp writer!(path, fault) do
    start_supervised!(
      Supervisor.child_spec(
        {Writer,
         storage_id: {path, fault},
         storage_mod: FaultStorage,
         session_id: "session",
         cwd: Path.dirname(path)},
        id: make_ref()
      )
    )
  end

  defp snapshot!(writer) do
    assert {:ok, %{items: items}} = AsyncDelivery.snapshot(writer)
    items
  end

  defp checkpoint!(store, run_id, content) do
    conversation =
      start_supervised!(
        Supervisor.child_spec(
          {Conversation,
           run_id: run_id,
           store: Store,
           context: store,
           provider: ReplyProvider,
           subscriber: self()},
          id: {:reply, run_id}
        )
      )

    assert {:ok, admission} = Conversation.prompt(conversation, content)
    assert_receive {:agent_runtime, ^run_id, %{type: :run_completed}}, 5_000
    admission
  end

  defp terminal!(writer, outcome, attrs \\ []) do
    data =
      Map.merge(
        %{
          session_id: "session",
          turn_id: "root-run",
          revision: 1,
          status: outcome,
          finished_at: "2026-10-25T00:00:00Z"
        },
        Map.new(attrs)
      )

    assert {:ok, _} = Writer.append(writer, {:metrics, :turn_finished, data})
  end

  defp question(items),
    do: Enum.find(items, &(&1["origin"]["tool_name"] == "request_user_input_async"))

  defp notice(items),
    do: Enum.find(items, &(&1["origin"]["tool_name"] == "send_message_to_user_async"))

  defp reply,
    do: %{"replyId" => "reply", "answers" => [%{"questionIndex" => 0, "answer" => "A"}]}
end
