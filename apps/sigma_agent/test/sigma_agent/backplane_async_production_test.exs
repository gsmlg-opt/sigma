defmodule Sigma.Agent.BackplaneAsyncProductionTest do
  use ExUnit.Case, async: false

  alias Sigma.Agent.Runtime
  alias Sigma.Agent.Backplane.{AsyncDelivery, AsyncInbox, Store}
  alias Sigma.Session.{Log, Writer}

  @moduletag :tmp_dir

  defmodule Provider do
    @behaviour Sigma.Ai.Provider
    def stream(params) do
      send(params.options[:test_pid], {:async_provider, self(), params})

      receive do
        {:respond, content} ->
          reason = if Enum.any?(content, &(&1.type == :tool_call)), do: :tool_use, else: :stop

          message = %{
            role: :assistant,
            content: content,
            stop_reason: reason,
            usage: %{input: 1, output: 1, total_tokens: 2, cost: %{total: 0.0}},
            model: "fixture",
            provider: "fixture",
            api: "openai-responses",
            timestamp: System.system_time(:millisecond)
          }

          [{:start, %{message | content: []}}, {:done, reason, message}]
      end
    end
  end

  setup ctx do
    on_exit(fn ->
      if supervisor = Runtime.lookup(ctx.tmp_dir, :supervisor),
        do: DynamicSupervisor.terminate_child(Sigma.Agent.DynamicSupervisor, supervisor)
    end)

    :ok
  end

  test "identical async batches stay distinct and an active answer steers exactly once", ctx do
    agent = session!(ctx.tmp_dir)
    assert {:accepted, _} = Sigma.Agent.prompt(agent, "Ask while continuing")
    {provider, params} = provider!()
    names = Enum.map(params.context.tools, & &1.name)
    assert "request_user_input_async" in names
    assert "send_message_to_user_async" in names
    send(provider, {:respond, [question("q1"), question("q2")]})
    {provider, _} = provider!()

    assert {:ok, %{items: [first, second], leaf_id: leaf}} =
             Sigma.Agent.async_interaction_snapshot(agent)

    refute first["item_id"] == second["item_id"]
    assert first["questions"] == second["questions"]
    assert first["can_reply"] and second["can_reply"]

    assert {:ok, %{status: :admitted}} =
             Sigma.Agent.reply_async_interaction(agent, first["item_id"], answer(), leaf)

    assert {:ok, %{items: pending}} = Sigma.Agent.async_interaction_snapshot(agent)
    assert Enum.find(pending, &(&1["item_id"] == first["item_id"]))["status"] == "admitted"

    send(provider, {:respond, [%{type: :text, text: "Still working"}]})
    {provider, params} = provider!()
    replies = correlated(params.context.messages)
    assert [reply] = replies
    assert reply.content =~ "  原文\n"
    assert reply.metadata["async_interaction"]["item_id"] == first["item_id"]
    assert {:ok, %{items: cards}} = Sigma.Agent.async_interaction_snapshot(agent)
    assert Enum.find(cards, &(&1["item_id"] == first["item_id"]))["status"] == "consumed"
    finish!(provider)
    assert {:ok, %{leaf_id: current}} = Sigma.Agent.async_interaction_snapshot(agent)

    assert {:ok, %{status: "consumed"}} =
             Sigma.Agent.reply_async_interaction(agent, first["item_id"], answer(), current)

    refute_receive {:async_provider, _, _}, 50
    assert length(correlated(Sigma.Agent.messages(agent))) == 1
  end

  test "an idle reply is consumed only after its exact admitted Runtime checkpoint", ctx do
    agent = session!(ctx.tmp_dir)
    item = completed_question!(agent)
    assert {:ok, %{leaf_id: leaf}} = Sigma.Agent.async_interaction_snapshot(agent)

    assert {:ok, %{status: :admitted}} =
             Sigma.Agent.reply_async_interaction(agent, item["item_id"], answer(), leaf)

    {provider, params} = provider!()
    assert [reply] = correlated(params.context.messages)
    assert reply.metadata["async_interaction"]["item_id"] == item["item_id"]
    finish!(provider)

    assert {:ok, %{items: [delivered]}} = Sigma.Agent.async_interaction_snapshot(agent)
    assert delivered["status"] == "consumed", inspect(delivered, limit: :infinity)

    agent = reopen!(ctx.tmp_dir)
    assert {:ok, %{items: [recovered]}} = Sigma.Agent.async_interaction_snapshot(agent)
    assert recovered["status"] == "consumed"
    assert recovered["delivery"] == delivered["delivery"]
    refute_receive {:async_provider, _, _}, 50
  end

  test "real Deno async notification is recoverable and its optional answer starts a new turn",
       ctx do
    agent = session!(ctx.tmp_dir)
    assert {:accepted, _} = Sigma.Agent.prompt(agent, "Notify")
    {provider, _} = provider!()
    code = "text(await tools.send_message_to_user_async({message: 'Progress ready'}));"

    send(
      provider,
      {:respond,
       [
         %{
           type: :tool_call,
           id: "exec-notice",
           name: "exec",
           input_kind: :custom,
           arguments: code
         }
       ]}
    )

    {provider, _} = provider!()
    assert {:ok, %{items: [item]}} = Sigma.Agent.async_interaction_snapshot(agent)
    assert item["message"] == "Progress ready"
    assert item["status"] == "notice"
    finish!(provider)
    agent = reopen!(ctx.tmp_dir)
    refute_receive {:async_provider, _, _}, 50

    assert {:ok, %{items: [recovered], leaf_id: leaf}} =
             Sigma.Agent.async_interaction_snapshot(agent)

    assert recovered["item_id"] == item["item_id"]
    assert recovered["can_reply"]
    payload = %{"replyId" => "notice-reply", "text" => "Continue"}

    assert {:ok, %{status: :admitted}} =
             Sigma.Agent.reply_async_interaction(agent, item["item_id"], payload, leaf)

    {provider, params} = provider!()
    assert length(correlated(params.context.messages)) == 1
    finish!(provider)
  end

  test "cancel closes outstanding questions and late answers cannot start a new turn", ctx do
    agent = session!(ctx.tmp_dir)
    assert {:accepted, _} = Sigma.Agent.prompt(agent, "Ask")
    {provider, _} = provider!()
    send(provider, {:respond, [question("cancel-q")]})
    {_provider, _} = provider!()
    assert {:cancelling, _} = Sigma.Agent.cancel(agent)
    assert_receive {:turn_cancelled}, 5_000
    assert {:ok, %{items: [item], leaf_id: leaf}} = Sigma.Agent.async_interaction_snapshot(agent)
    assert item["status"] == "dismissed"
    refute item["can_reply"]

    assert {:error, _} =
             Sigma.Agent.reply_async_interaction(agent, item["item_id"], answer(), leaf)

    refute_receive {:async_provider, _, _}, 50
  end

  test "dismiss is branch fenced and does not cancel the originating turn", ctx do
    agent = session!(ctx.tmp_dir)
    assert {:accepted, _} = Sigma.Agent.prompt(agent, "Ask")
    {provider, _} = provider!()
    send(provider, {:respond, [question("dismiss-q")]})
    {provider, _} = provider!()
    assert {:ok, %{items: [item], leaf_id: leaf}} = Sigma.Agent.async_interaction_snapshot(agent)
    assert {:error, _} = Sigma.Agent.dismiss_async_interaction(agent, item["item_id"], "stale")
    assert :ok = Sigma.Agent.dismiss_async_interaction(agent, item["item_id"], leaf)
    assert Sigma.Agent.status(agent).phase not in [:cancelled, :completed, :failed]
    finish!(provider)

    assert {:ok, %{items: [%{"status" => "dismissed"}]}} =
             Sigma.Agent.async_interaction_snapshot(agent)
  end

  test "lost dispatch acknowledgement becomes unknown after restart and is never redispatched",
       ctx do
    agent = session!(ctx.tmp_dir)
    item = completed_question!(agent)
    writer = Runtime.lookup(ctx.tmp_dir, "async", :writer)
    assert {:ok, %{leaf_id: leaf}} = Writer.async_interaction_state(writer)
    assert {:ok, _} = AsyncInbox.prepare_reply(writer, item["item_id"], answer(), leaf)
    assert :ok = AsyncDelivery.fact(writer, item, "dispatch_started", %{"reply_id" => "reply-1"})
    agent = reopen!(ctx.tmp_dir)

    assert {:ok, %{items: [unknown], leaf_id: leaf}} =
             Sigma.Agent.async_interaction_snapshot(agent)

    assert unknown["status"] == "delivery_unknown"

    assert {:ok, %{status: "delivery_unknown"}} =
             Sigma.Agent.reply_async_interaction(agent, item["item_id"], answer(), leaf)

    refute_receive {:async_provider, _, _}, 50
    assert correlated(Sigma.Agent.messages(agent)) == []
  end

  test "a canonical reply without Runtime admission stays unknown after restart", ctx do
    agent = session!(ctx.tmp_dir)
    item = completed_question!(agent)
    writer = Runtime.lookup(ctx.tmp_dir, "async", :writer)
    assert {:ok, %{leaf_id: leaf}} = Writer.async_interaction_state(writer)

    assert {:ok, %{reply: reply}} =
             AsyncInbox.prepare_reply(writer, item["item_id"], answer(), leaf)

    assert :ok = AsyncDelivery.fact(writer, item, "dispatch_started", %{"reply_id" => "reply-1"})
    user = Sigma.Agent.Message.user(reply["message_id"], reply["content"])
    user = %{user | metadata: Map.put(reply["metadata"], "turn_id", reply["turn_id"])}
    assert {:ok, _} = Writer.append(writer, {:message_end, user})
    agent = reopen!(ctx.tmp_dir)

    assert {:ok, %{items: [%{"status" => "delivery_unknown"}]}} =
             Sigma.Agent.async_interaction_snapshot(agent)

    refute_receive {:async_provider, _, _}, 50
  end

  test "idle reply preparation failure cannot prove consumption from the saved user", ctx do
    agent = session!(ctx.tmp_dir)
    item = completed_question!(agent)

    :ok =
      Sigma.Agent.set_provider(
        agent,
        Provider,
        %{id: "fixture", provider: "fixture", api: "openai-responses"},
        test_pid: self(),
        hosted_web_search: %{supported: true, enabled: true}
      )

    assert {:ok, %{leaf_id: leaf}} = Sigma.Agent.async_interaction_snapshot(agent)

    assert {:ok, %{status: :admitted}} =
             Sigma.Agent.reply_async_interaction(agent, item["item_id"], answer(), leaf)

    assert_receive {:agent_end, _}, 5_000
    refute_receive {:async_provider, _, _}, 50
    assert [canonical] = correlated(Sigma.Agent.messages(agent))

    assert {:ok, store} = Store.open(path: Path.join(ctx.tmp_dir, "async.jsonl.runtime"))

    assert {:error, %Backplane.AgentRuntime.Error{class: :not_found}} =
             Store.load(store, canonical.metadata.turn_id)

    assert {:ok, %{items: [%{"status" => "delivery_unknown"}]}} =
             Sigma.Agent.async_interaction_snapshot(agent)

    agent = reopen!(ctx.tmp_dir)

    assert {:ok, %{items: [%{"status" => "delivery_unknown"}], leaf_id: leaf}} =
             Sigma.Agent.async_interaction_snapshot(agent)

    assert {:ok, %{status: "delivery_unknown"}} =
             Sigma.Agent.reply_async_interaction(agent, item["item_id"], answer(), leaf)

    refute_receive {:async_provider, _, _}, 50
    assert [recovered] = correlated(Sigma.Agent.messages(agent))
    assert recovered.id == canonical.id
  end

  defp completed_question!(agent) do
    assert {:accepted, _} = Sigma.Agent.prompt(agent, "Ask")
    {provider, _} = provider!()
    send(provider, {:respond, [question("persisted-q")]})
    {provider, _} = provider!()
    finish!(provider)
    assert {:ok, %{items: [item]}} = Sigma.Agent.async_interaction_snapshot(agent)
    item
  end

  defp session!(dir, opts \\ []) do
    defaults = [
      cwd: dir,
      transcript_path: Path.join(dir, "async.jsonl"),
      provider: Provider,
      model: %{id: "fixture", provider: "fixture", api: "openai-responses"},
      native_tools: true,
      tools: [],
      hook_specs: [],
      options: [test_pid: self()]
    ]

    assert {:ok, handle} = Runtime.get_session(dir, "async", Keyword.merge(defaults, opts))
    :ok = Sigma.Agent.subscribe(handle.agent)
    handle.agent
  end

  defp reopen!(dir) do
    assert :ok =
             DynamicSupervisor.terminate_child(
               Runtime.lookup(dir, :sessions),
               Runtime.lookup(dir, "async", :supervisor)
             )

    assert {:ok, snapshot} = Log.snapshot(Path.join(dir, "async.jsonl"))

    session!(dir,
      messages: snapshot.messages,
      context_messages: snapshot.context_messages,
      context_window: snapshot.context_window
    )
  end

  defp provider! do
    assert_receive {:async_provider, provider, params}, 8_000
    {provider, params}
  end

  defp finish!(provider) do
    send(provider, {:respond, [%{type: :text, text: "Done"}]})
    assert_receive {:agent_end, _}, 5_000
  end

  defp question(id),
    do: %{
      type: :tool_call,
      id: id,
      name: "request_user_input_async",
      arguments: %{"questions" => [%{"title" => "Continue?", "options" => ["Yes", "Wait"]}]}
    }

  defp answer,
    do: %{"replyId" => "reply-1", "answers" => [%{"questionIndex" => 0, "answer" => "  原文\n"}]}

  defp correlated(messages),
    do:
      Enum.filter(messages, fn message ->
        message.role == :user and is_map(Map.get(message, :metadata)) and
          Map.has_key?(message.metadata, "async_interaction")
      end)
end
