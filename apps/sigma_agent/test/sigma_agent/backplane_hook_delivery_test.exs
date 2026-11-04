defmodule Sigma.Agent.BackplaneHookDeliveryTest do
  use ExUnit.Case, async: false

  alias Sigma.Agent.{BackplaneHookDeliveryTest, Runtime}
  alias Sigma.Agent.Backplane.{HookDelivery, Store}
  alias Sigma.Session.{Log, Writer}

  @moduletag :tmp_dir
  @text "  异步原文\nnext  "

  defmodule Provider do
    @behaviour Sigma.Ai.Provider
    def stream(params) do
      send(params.options[:test_pid], {:hook_provider, self(), params})

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

  defmodule CheckpointProvider do
    def stream(_request, _context),
      do: [%{type: :response_completed, message: %{role: :assistant, content: "Done"}}]
  end

  setup ctx do
    on_exit(fn ->
      if supervisor = Runtime.lookup(ctx.tmp_dir, :supervisor),
        do: DynamicSupervisor.terminate_child(Sigma.Agent.DynamicSupervisor, supervisor)
    end)

    :ok
  end

  test "a settled native hook steers an active run once with original text and real admission",
       ctx do
    agent = session!(ctx.tmp_dir)
    assert {:accepted, _} = Sigma.Agent.prompt(agent, "Make a plan")
    {provider, _} = provider!()
    send(provider, {:respond, [plan_call()]})
    {provider, _} = provider!()
    release!(ctx.tmp_dir)
    await!(fn -> match?([%{"status" => "admitted"}], items(ctx.tmp_dir)) end)
    refute Enum.any?(items(ctx.tmp_dir), &(&1["status"] == "consumed"))
    send(provider, {:respond, [%{type: :text, text: "Still working"}]})
    {provider, params} = provider!()
    assert [message] = feedback(params.context.messages)
    assert message.content == "[Developer context from async hook]\n" <> @text
    await!(fn -> match?([%{"status" => "consumed"}], items(ctx.tmp_dir)) end)
    [item] = items(ctx.tmp_dir)
    assert item["text"] == @text
    {:ok, snapshot} = Log.snapshot(Path.join(ctx.tmp_dir, "session.jsonl"))
    assert [canonical] = feedback(snapshot.messages)
    assert canonical.content == message.content
    assert canonical.metadata["hook_feedback"] == message.metadata["hook_feedback"]
    assert item["delivery"]["message_id"] == canonical.id
    assert is_binary(item["delivery"]["runtime_message_id"])
    refute item["delivery"]["runtime_message_id"] == canonical.id
    finish!(provider)
    assert length(feedback(Sigma.Agent.messages(agent))) == 1
  end

  test "idle feedback waits for the next real prompt and reaches its first provider request",
       ctx do
    agent = session!(ctx.tmp_dir)
    assert {:accepted, _} = Sigma.Agent.prompt(agent, "Make a plan")
    {provider, _} = provider!()
    send(provider, {:respond, [plan_call()]})
    {provider, _} = provider!()
    finish!(provider)
    release!(ctx.tmp_dir)
    await!(fn -> match?([%{"status" => "received"}], items(ctx.tmp_dir)) end)
    refute_receive {:hook_provider, _, _}, 100
    assert {:accepted, _} = Sigma.Agent.prompt(agent, "Review it")
    {provider, params} = provider!()
    assert [message] = feedback(params.context.messages)
    assert message.content == "Review it\n\n[Developer context from async hook]\n" <> @text
    await!(fn -> match?([%{"status" => "consumed"}], items(ctx.tmp_dir)) end)
    finish!(provider)
    assert {:accepted, _} = Sigma.Agent.prompt(agent, "Next")
    {provider, params} = provider!()
    assert length(feedback(params.context.messages)) == 1
    finish!(provider)
  end

  test "saved idle feedback survives host recreation without executing hooks again", ctx do
    agent = session!(ctx.tmp_dir)
    assert {:accepted, _} = Sigma.Agent.prompt(agent, "Make a plan")
    {provider, _} = provider!()
    send(provider, {:respond, [plan_call()]})
    {provider, _} = provider!()
    finish!(provider)
    release!(ctx.tmp_dir)
    await!(fn -> match?([%{"status" => "received"}], items(ctx.tmp_dir)) end)
    [original] = items(ctx.tmp_dir)

    assert :ok =
             DynamicSupervisor.terminate_child(
               Runtime.lookup(ctx.tmp_dir, :sessions),
               Runtime.lookup(ctx.tmp_dir, "hooks", :supervisor)
             )

    {:ok, snapshot} = Log.snapshot(Path.join(ctx.tmp_dir, "session.jsonl"))
    agent = session!(ctx.tmp_dir, messages: snapshot.messages)
    refute_receive {:hook_provider, _, _}, 50
    assert {:accepted, _} = Sigma.Agent.prompt(agent, "Resume")
    {provider, params} = provider!()
    assert [message] = feedback(params.context.messages)
    assert message.content =~ @text
    finish!(provider)
    [recovered] = items(ctx.tmp_dir)
    assert recovered["item_id"] == original["item_id"]
    assert recovered["status"] == "consumed"
    assert File.read!(Path.join(ctx.tmp_dir, "hook-runs")) == "run\n"
  end

  test "session shutdown stops detached hooks before their Writer is retired", ctx do
    agent = session!(ctx.tmp_dir)
    assert {:accepted, _} = Sigma.Agent.prompt(agent, "Make a plan")
    {provider, _} = provider!()
    send(provider, {:respond, [plan_call()]})
    {provider, _} = provider!()
    await!(fn -> File.exists?(Path.join(ctx.tmp_dir, "hook-runs")) end)
    finish!(provider)

    assert :ok =
             DynamicSupervisor.terminate_child(
               Runtime.lookup(ctx.tmp_dir, :sessions),
               Runtime.lookup(ctx.tmp_dir, "hooks", :supervisor)
             )

    release!(ctx.tmp_dir)
    refute_receive {:hook_provider, _, _}, 100
    {:ok, entries} = Sigma.Session.Storage.JsonlFile.read(Path.join(ctx.tmp_dir, "session.jsonl"))
    refute Enum.any?(entries, &(&1["type"] == "hook_feedback"))
  end

  test "late feedback from a cancelled origin is discarded without starting another turn", ctx do
    agent = session!(ctx.tmp_dir)
    assert {:accepted, _} = Sigma.Agent.prompt(agent, "Make a plan")
    {provider, _} = provider!()
    send(provider, {:respond, [plan_call()]})
    {_provider, _} = provider!()
    assert {:cancelling, _} = Sigma.Agent.cancel(agent)
    assert_receive {:turn_cancelled}, 5_000
    release!(ctx.tmp_dir)
    await!(fn -> length(items(ctx.tmp_dir)) == 1 end)
    refute_receive {:hook_provider, _, _}, 50
    assert {:accepted, _} = Sigma.Agent.prompt(agent, "Continue")
    {provider, params} = provider!()
    assert feedback(params.context.messages) == []
    finish!(provider)
    assert [%{"status" => "discarded"}] = items(ctx.tmp_dir)
  end

  test "durable host cancellation wins over an already completed Runtime origin", ctx do
    agent = session!(ctx.tmp_dir)
    assert {:accepted, origin} = Sigma.Agent.prompt(agent, "Make a plan")
    {provider, _} = provider!()
    send(provider, {:respond, [plan_call()]})
    {provider, _} = provider!()
    finish!(provider)
    writer = Runtime.lookup(ctx.tmp_dir, "hooks", :writer)

    assert {:ok, _} =
             Writer.append(
               writer,
               {:metrics, :turn_finished,
                %{
                  session_id: "hooks",
                  turn_id: origin.turn_id,
                  status: :cancelled
                }}
             )

    release!(ctx.tmp_dir)
    await!(fn -> length(items(ctx.tmp_dir)) == 1 end)
    assert {:accepted, _} = Sigma.Agent.prompt(agent, "Continue")
    {provider, params} = provider!()
    assert feedback(params.context.messages) == []
    finish!(provider)
    assert [%{"status" => "discarded"}] = items(ctx.tmp_dir)
  end

  test "identical handlers keep separate receipts and block content proves consumption", ctx do
    hooks = specs(ctx.tmp_dir)
    agent = session!(ctx.tmp_dir, hook_specs: hooks ++ hooks)
    assert {:accepted, _} = Sigma.Agent.prompt(agent, "Make a plan")
    {provider, _} = provider!()
    send(provider, {:respond, [plan_call()]})
    {provider, _} = provider!()
    finish!(provider)
    release!(ctx.tmp_dir)
    await!(fn -> length(items(ctx.tmp_dir)) == 2 end)
    assert {:accepted, _} = Sigma.Agent.prompt(agent, [%{type: :text, text: "Review blocks"}])
    {provider, params} = provider!()
    assert [message] = feedback(params.context.messages)
    assert is_list(message.content)
    assert Enum.map(items(ctx.tmp_dir), & &1["origin"]["handler_index"]) |> Enum.sort() == [0, 1]
    await!(fn -> Enum.all?(items(ctx.tmp_dir), &(&1["status"] == "consumed")) end)
    finish!(provider)
  end

  test "a real Deno nested operation has its own settled origin and delivers once", ctx do
    agent = session!(ctx.tmp_dir)
    assert {:accepted, _} = Sigma.Agent.prompt(agent, "Use Code Mode")
    {provider, _} = provider!()

    send(
      provider,
      {:respond,
       [
         %{
           type: :tool_call,
           id: "outer-code",
           name: "exec",
           arguments:
             "return await tools.update_plan({plan: [{step: 'Nested', status: 'completed'}]});"
         }
       ]}
    )

    {provider, _} = provider!()
    release!(ctx.tmp_dir)
    await!(fn -> match?([%{"status" => "admitted"}], items(ctx.tmp_dir)) end)
    [item] = items(ctx.tmp_dir)
    assert item["origin"]["tool_name"] == "update_plan"
    refute item["origin"]["tool_call_id"] == "outer-code"
    send(provider, {:respond, [%{type: :text, text: "Before feedback"}]})
    {provider, params} = provider!()
    assert [message] = feedback(params.context.messages)
    assert message.content == "[Developer context from async hook]\n" <> @text
    await!(fn -> match?([%{"status" => "consumed"}], items(ctx.tmp_dir)) end)
    finish!(provider)
  end

  for {label, same_text?} <- [{"missing checkpoint content", false}, {"wrong Runtime ID", true}] do
    test "canonical text with #{label} stays unknown and is not redelivered", ctx do
      {writer, store} = received_source!(ctx.tmp_dir)
      destination = "negative-destination"
      assert {:ok, message} = HookDelivery.next(writer, store, destination)
      assert {:ok, _} = Writer.append(writer, {:message_end, message})

      content = if unquote(same_text?), do: message.content, else: "unrelated real prompt"
      actual_id = checkpoint!(store, destination, content)
      admitted_id = if unquote(same_text?), do: "unmatched-admission", else: actual_id
      assert :ok = HookDelivery.admitted(writer, message, admitted_id)
      assert :ok = HookDelivery.reconcile(writer, store)
      assert [%{"status" => "delivery_unknown"}] = items(ctx.tmp_dir)
      assert :none = HookDelivery.next(writer, store, "later")
      assert :none = HookDelivery.next(writer, store, "later-again")
      assert [%{"status" => "delivery_unknown"}] = items(ctx.tmp_dir)
    end
  end

  test "a sibling canonical message cannot prove selected-branch consumption", ctx do
    {writer, store} = received_source!(ctx.tmp_dir)
    {:ok, before} = Writer.hook_feedback_state(writer)
    assert {:ok, message} = HookDelivery.next(writer, store, "branch-destination")
    assert {:ok, _} = Writer.append(writer, {:message_end, message})
    {:ok, first} = Writer.hook_feedback_state(writer)
    runtime_id = checkpoint!(store, "branch-destination", message.content)
    assert :ok = HookDelivery.admitted(writer, message, runtime_id)
    assert :ok = Writer.checkout(writer, before.leaf_id, first.leaf_id)

    assert {:ok, _} =
             Writer.append(writer, {:message_end, Sigma.Agent.Message.user("sibling", "other")})

    assert :ok = HookDelivery.reconcile(writer, store)
    assert items(ctx.tmp_dir) == []
    {:ok, selected} = Writer.hook_feedback_state(writer)
    assert [%{"status" => "admitted"}] = Map.values(selected.history.items)
    assert :none = HookDelivery.next(writer, store, "another-run")
    {:ok, sibling} = Writer.hook_feedback_state(writer)
    assert :ok = Writer.checkout(writer, first.leaf_id, sibling.leaf_id)
    assert :ok = HookDelivery.reconcile(writer, store)
    assert [%{"status" => "consumed"}] = items(ctx.tmp_dir)
  end

  defp received_source!(dir) do
    agent = session!(dir)
    assert {:accepted, origin} = Sigma.Agent.prompt(agent, "Make a plan")
    {provider, _} = provider!()
    send(provider, {:respond, [plan_call()]})
    {provider, _} = provider!()
    finish!(provider)
    release!(dir)
    await!(fn -> match?([%{"status" => "received"}], items(dir)) end)
    writer = Runtime.lookup(dir, "hooks", :writer)
    {:ok, store} = Store.open(path: Path.join(dir, "session.jsonl.runtime"))
    assert {:ok, _} = Store.load(store, origin.turn_id)
    {writer, store}
  end

  defp checkpoint!(store, run_id, content) do
    conversation =
      start_supervised!(
        Supervisor.child_spec(
          {Backplane.AgentRuntime.Conversation,
           run_id: run_id,
           store: Store,
           context: store,
           provider: CheckpointProvider,
           provider_context: %{},
           subscriber: self()},
          id: {:checkpoint, run_id}
        )
      )

    assert {:ok, admission} = Backplane.AgentRuntime.Conversation.prompt(conversation, content)
    assert_receive {:agent_runtime, ^run_id, %{type: :run_completed}}, 5_000
    admission.message_id
  end

  defp session!(dir, extra \\ []) do
    {:ok, handle} =
      Runtime.get_session(
        dir,
        "hooks",
        Keyword.merge(
          [
            cwd: dir,
            transcript_path: Path.join(dir, "session.jsonl"),
            model: %{
              id: "fixture",
              provider: "fixture",
              api: "openai-responses",
              context_window: 100_000
            },
            provider: BackplaneHookDeliveryTest.Provider,
            options: [test_pid: self()],
            native_tools: true,
            tools: [],
            hook_specs: specs(dir)
          ],
          extra
        )
      )

    Sigma.Agent.subscribe(handle.agent)
    handle.agent
  end

  defp specs(dir) do
    output =
      Jason.encode!(%{
        "hookSpecificOutput" => %{"hookEventName" => "PostToolUse", "additionalContext" => @text}
      })

    quote = fn value -> "'" <> String.replace(value, "'", "'\\''") <> "'" end

    command =
      "cat >/dev/null; printf 'run\\n' >> " <>
        quote.(Path.join(dir, "hook-runs")) <>
        "; while [ ! -f " <>
        quote.(Path.join(dir, "release")) <>
        " ]; do sleep 0.01; done; printf '%s' " <> quote.(output)

    {:ok, specs} =
      Sigma.Coding.Hooks.Discovery.parse(
        Jason.encode!(%{
          "hooks" => %{
            "PostToolUse" => [
              %{
                "matcher" => "update_plan",
                "hooks" => [
                  %{"type" => "command", "command" => command, "async" => true, "timeout" => 10}
                ]
              }
            ]
          }
        }),
        :codex
      )

    Enum.map(specs, &%{&1 | origin: {:user, "test"}, trusted?: true})
  end

  defp plan_call do
    %{
      type: :tool_call,
      id: "hook-plan",
      name: "update_plan",
      arguments: %{"plan" => [%{"step" => "Review", "status" => "completed"}]}
    }
  end

  defp provider! do
    assert_receive {:hook_provider, provider, params}, 8_000
    {provider, params}
  end

  defp finish!(provider) do
    send(provider, {:respond, [%{type: :text, text: "Done"}]})
    assert_receive {:agent_end, _}, 5_000
  end

  defp release!(dir), do: File.write!(Path.join(dir, "release"), "ready")

  defp items(dir) do
    writer = Runtime.lookup(dir, "hooks", :writer)
    {:ok, state} = Writer.hook_feedback_state(writer)
    Map.values(state.projection.items)
  end

  defp feedback(messages) do
    Enum.filter(messages, fn message ->
      message.role == :user and Map.has_key?(Map.get(message, :metadata, %{}), "hook_feedback")
    end)
  end

  defp await!(check, attempts \\ 300)
  defp await!(check, 0), do: assert(check.())

  defp await!(check, attempts) do
    if check.(),
      do: :ok,
      else:
        (
          Process.sleep(10)
          await!(check, attempts - 1)
        )
  end
end
