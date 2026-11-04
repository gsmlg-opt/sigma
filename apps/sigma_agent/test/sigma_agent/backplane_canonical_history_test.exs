defmodule Sigma.Agent.BackplaneCanonicalHistoryTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.{Codex, Conversation}
  alias Sigma.Agent.Backplane.{CanonicalHistory, CodexResources, Provider, Store}
  alias Sigma.Agent.Message
  alias Sigma.Session.{Log, Writer}

  @moduletag :tmp_dir

  defmodule FeedbackProvider do
    def stream(_request, _context) do
      [
        %{
          type: :tool_call_completed,
          tool_call: %{
            id: "feedback-call",
            name: "update_plan",
            arguments: %{"plan" => [%{"step" => "Review", "status" => "pending"}]}
          }
        },
        %{type: :response_completed, message: %{role: :assistant, content: "Planning"}}
      ]
    end
  end

  defmodule FeedbackPreparation do
    def prepare_tool(_request, context) do
      assert_feedback = %{
        id: "terminal-feedback",
        source: "PreToolUse",
        stage: "preparation",
        text: "Review before running again"
      }

      result = context.append_feedback.(assert_feedback)
      send(context.test, {:feedback_accepted, result})
      receive do: (:release -> :allow)
    end
  end

  test "ordinary messages keep their identity and tool history is never re-executed" do
    user = Message.user("user", "Continue")

    tool =
      Message.tool_result("tool", %{tool_call_id: "old", tool_name: "exec_command", content: []})

    assert CanonicalHistory.runtime_messages([user, tool]) == [user, tool]
  end

  test "accepted terminal feedback survives JSONL reload and seeds a fresh Conversation", %{
    tmp_dir: dir
  } do
    resources = start_supervised!({CodexResources, workspace: dir, owner_pid: self()})

    authority = %{
      caller: "history",
      run_id: "history-1",
      grants: ["update_plan"],
      tool_revision: 1
    }

    assert {:ok, binding} = CodexResources.bind(resources, authority)
    assert {:ok, context} = CodexResources.context(resources, binding)

    assert {:ok, profile} =
             Codex.profile(:pinned_local, context, authority, tools: ["update_plan"])

    store = start_supervised!({Store, path: Path.join(dir, "runtime")})

    conversation =
      start_supervised!(
        {Conversation,
         run_id: "history-1",
         store: Store,
         context: store,
         provider: FeedbackProvider,
         registry: profile.registry,
         tools: profile.tools,
         authority: profile.authority,
         session_binding: binding,
         hooks: FeedbackPreparation,
         provider_context: %{test: self()},
         subscriber: self()},
        id: :first_conversation
      )

    assert {:ok, _} = Conversation.prompt(conversation, "Prepare")
    assert_receive {:feedback_accepted, {:ok, %{id: "terminal-feedback"}}}, 5_000
    assert :ok = Conversation.cancel(conversation)
    assert_receive {:agent_runtime, "history-1", %{type: :run_cancelled}}, 5_000
    status = Conversation.status(conversation)
    refute Enum.any?(status.messages, &Map.has_key?(&1, :host_feedback))
    assert [record] = status.conversation.host_feedback
    refute record["projected"]

    assert [runtime_message] = CanonicalHistory.checkpoint_messages(status)

    assert runtime_message.content ==
             "[Host feedback] PreToolUse / preparation\nReview before running again"

    assert runtime_message.host_feedback == Map.delete(record, "projected")
    assert [message] = Provider.normalize_messages([runtime_message])

    path = Path.join(dir, "session.jsonl")
    writer = start_supervised!({Writer, storage_id: path, session_id: "history", cwd: dir})
    assert {:ok, _} = Writer.append(writer, {:message_end, message})
    assert {:ok, %{messages: [reloaded]}} = Log.snapshot(path)
    assert reloaded.metadata["host_feedback"] == runtime_message.host_feedback
    assert [seed] = CanonicalHistory.runtime_messages([reloaded])
    assert seed.id == message.id
    assert seed.host_feedback == runtime_message.host_feedback
    assert seed.content == runtime_message.content

    next =
      start_supervised!(
        {Conversation, run_id: "history-2", store: Store, context: store, messages: [seed]},
        id: :next_conversation
      )

    assert [accepted] = Conversation.status(next).conversation.host_feedback
    assert Map.delete(accepted, "projected") == runtime_message.host_feedback
    assert accepted["projected"]
  end

  test "provider forwards canonical feedback before building its request context" do
    feedback = %{
      role: :user,
      content: "[Host feedback] Hook / post\nReview",
      host_feedback: %{"id" => "feedback"}
    }

    collaboration = %{role: :user, id: "collaboration", content: "Ready", collaboration: %{}}
    ordinary = %{role: :user, content: "Continue"}
    test = self()

    host = %{
      build_context: fn messages ->
        send(test, {:context_built, messages})
        %{}
      end,
      context_error: fn _ -> :test_stop end
    }

    assert [%{type: :response_failed, error: :test_stop}] =
             Provider.stream(
               %{messages: [ordinary, feedback, collaboration], tools: [], catalog_revision: 1},
               %{host: host, owner: test}
             )

    assert_receive {:backplane_collaboration_messages, [^feedback, ^collaboration]}

    assert_receive {:context_built,
                    [
                      _ordinary,
                      %Message{metadata: %{host_feedback: %{"id" => "feedback"}}},
                      _collaboration
                    ]}
  end
end
