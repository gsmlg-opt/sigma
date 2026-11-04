defmodule Sigma.Agent.ProtocolQuestionsTest do
  use ExUnit.Case, async: false

  alias Sigma.Agent.{ProtocolEventMapper, PublicRuntime, Runtime}
  alias Sigma.Agent.Backplane.UserInput
  alias Sigma.Protocol.{Codec, Envelope}

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    repo = Path.join(dir, "repo")
    sessions = Path.join(dir, "sessions")
    File.mkdir_p!(repo)
    File.mkdir_p!(sessions)

    context = %{
      repo_path: repo,
      sessions_dir: sessions,
      session_opts: [
        model: %{id: "mock", api: "mock", provider: "mock"},
        provider: Sigma.Ai.Providers.Anthropic
      ]
    }

    assert {:ok, command} =
             Envelope.command("session.create", "question-session", %{"cwd" => repo})

    assert {:ok, _} = PublicRuntime.execute(command, context)
    agent = Runtime.lookup(repo, "question-session", :agent)

    on_exit(fn ->
      if supervisor = Runtime.lookup(repo, :supervisor) do
        DynamicSupervisor.terminate_child(Sigma.Agent.DynamicSupervisor, supervisor)
      end
    end)

    %{context: context, agent: agent}
  end

  test "mapper emits safe generic question lifecycle without changing permission events" do
    request = %{
      question: "Pick?",
      options: [%{label: "A", value: "a", description: "First"}],
      allow_freeform: true,
      private: "hidden"
    }

    assert {%{type: "question.required", payload: payload}, "turn-1"} =
             ProtocolEventMapper.map(
               {:ask_user_question, "ask-1", request},
               "question-session",
               "turn-1"
             )

    assert payload["requestId"] == "ask-1"

    assert payload["request"]["options"] == [
             %{"label" => "A", "value" => "a", "description" => "First"}
           ]

    refute Map.has_key?(payload["request"], "private")

    assert {%{type: "question.resolved", payload: %{"requestId" => "ask-1"}}, "turn-1"} =
             ProtocolEventMapper.map(
               {:ask_user_question_resolved, "ask-1"},
               "question-session",
               "turn-1"
             )

    assert {%{type: "permission.required"}, "turn-1"} =
             ProtocolEventMapper.map(
               {:ask_user_question, "permission-1", Map.put(request, :kind, :permission)},
               "question-session",
               "turn-1"
             )
  end

  test "opt-in subscriber answers native adapter questions with exact text", %{
    context: context,
    agent: agent
  } do
    subscription = attach!(context, ["questions.v1"])
    legacy = attach!(context, [])
    resolver = UserInput.resolver(agent)

    request = %{
      kind: :request_user_input,
      questions: [
        %{
          "id" => "choice",
          "header" => "选择",
          "question" => "下一步？",
          "options" => [
            %{"label" => "A", "description" => "First"},
            %{"label" => "B", "description" => "Second"}
          ]
        }
      ]
    }

    task = Task.async(fn -> resolver.(request, fn -> true end) end)
    event = receive_type(subscription, "question.required")
    assert event.payload["request"]["question"] == "[选择] 下一步？"
    assert event.payload["request"]["allowFreeform"]
    refute_receive {:sigma_protocol, ^legacy, %{type: "question.required"}}, 30

    text = "  原文\n中文"
    assert {:ok, _} = resolve(context, event.payload["requestId"], "answer", text)
    assert {:ok, %{answers: %{"choice" => %{answers: [^text]}}}} = Task.await(task)

    assert receive_type(subscription, "question.resolved").payload["requestId"] ==
             event.payload["requestId"]

    refute_receive {:sigma_protocol, ^legacy, %{type: "question.resolved"}}, 0
  end

  test "invalid replies, wrong session and replay never consume a live question", %{
    context: context,
    agent: agent
  } do
    subscription = attach!(context, ["questions.v1"])

    task =
      Task.async(fn ->
        Sigma.Agent.ask_user_question(agent, %{question: "Pick?", allow_freeform: true})
      end)

    id = receive_type(subscription, "question.required").payload["requestId"]

    for payload <- [
          %{"requestId" => id, "action" => "answer", "answer" => " "},
          %{"requestId" => id, "action" => "answer", "answer" => ["A"]},
          %{"requestId" => id, "action" => "answer", "answer" => <<255>>},
          %{"requestId" => id, "action" => "cancel", "answer" => "A"},
          %{"requestId" => id, "action" => "answer", "answer" => "A", "unsupported" => true},
          %{"requestId" => "wrong", "action" => "answer", "answer" => "A"}
        ] do
      assert {:error, _} = execute(context, "question.resolve", payload)
      assert [%{id: ^id}] = Sigma.Agent.pending_user_questions(agent)
    end

    assert {:error, _} =
             execute(
               context,
               "question.resolve",
               %{"requestId" => id, "action" => "answer", "answer" => "A"},
               "other-session"
             )

    assert [%{id: ^id}] = Sigma.Agent.pending_user_questions(agent)
    assert {:ok, _} = resolve(context, id, "answer", "A")
    assert {:ok, "A"} = Task.await(task)
    assert {:error, _} = resolve(context, id, "answer", "replayed")
  end

  test "nonfreeform replies require the original option value", %{context: context, agent: agent} do
    subscription = attach!(context, ["questions.v1"])

    task =
      Task.async(fn ->
        Sigma.Agent.ask_user_question(agent, %{
          question: "Pick?",
          options: [%{label: "Visible", value: "actual"}],
          allow_freeform: false
        })
      end)

    id = receive_type(subscription, "question.required").payload["requestId"]
    assert {:error, _} = resolve(context, id, "answer", "Visible")
    assert [%{id: ^id}] = Sigma.Agent.pending_user_questions(agent)
    assert {:ok, _} = resolve(context, id, "answer", "actual")
    assert {:ok, "actual"} = Task.await(task)
  end

  test "question and permission answer channels cannot consume each other's requests", %{
    context: context,
    agent: agent
  } do
    subscription = attach!(context, ["questions.v1"])
    generic = Task.async(fn -> Sigma.Agent.ask_user_question(agent, %{question: "Pick?"}) end)
    generic_id = receive_type(subscription, "question.required").payload["requestId"]

    assert {:error, _} =
             execute(context, "permission.resolve", %{
               "requestId" => generic_id,
               "decision" => "allow"
             })

    assert [%{id: ^generic_id}] = Sigma.Agent.pending_user_questions(agent)
    assert {:ok, _} = resolve(context, generic_id, "cancel")
    assert {:error, :cancelled} = Task.await(generic)

    permission =
      Task.async(fn ->
        Sigma.Agent.ask_user_question(agent, %{
          kind: :permission,
          question: "Allow?",
          options: [%{label: "Allow", value: "allow_once"}],
          allow_freeform: false
        })
      end)

    permission_id = receive_type(subscription, "permission.required").payload["requestId"]
    assert {:error, _} = resolve(context, permission_id, "answer", "allow_once")
    assert [%{id: ^permission_id}] = Sigma.Agent.pending_user_questions(agent)

    assert {:ok, _} =
             execute(context, "permission.resolve", %{
               "requestId" => permission_id,
               "decision" => "allow"
             })

    assert {:ok, "allow_once"} = Task.await(permission)

    refute_receive {:sigma_protocol, ^subscription,
                    %{type: "question.resolved", payload: %{"requestId" => ^permission_id}}},
                   30
  end

  test "live pending snapshot supports reconnect without recreating questions", %{
    context: context,
    agent: agent
  } do
    Sigma.Agent.subscribe(agent)

    task =
      Task.async(fn ->
        Sigma.Agent.ask_user_question(agent, %{
          question: "Still waiting?",
          options: ["A"],
          allow_freeform: true
        })
      end)

    assert_receive {:ask_user_question, id, _}, 1_000

    assert {:ok, snapshot} =
             execute(context, "subscription.attach", %{"requiredCapabilities" => ["questions.v1"]})

    assert [%{"requestId" => ^id}] = snapshot.payload["pendingQuestions"]
    assert [%{id: ^id}] = Sigma.Agent.pending_user_questions(agent)
    assert {:ok, no_capability} = execute(context, "session.status", %{})
    refute Map.has_key?(no_capability.payload, "pendingQuestions")

    assert {:ok, status} =
             execute(context, "session.status", %{"requiredCapabilities" => ["questions.v1"]})

    assert [%{"requestId" => ^id}] = status.payload["pendingQuestions"]

    assert {:ok, _} = resolve(context, id, "cancel")
    assert {:error, :cancelled} = Task.await(task)

    assert {:ok, snapshot} =
             execute(context, "subscription.attach", %{"requiredCapabilities" => ["questions.v1"]})

    assert snapshot.payload["pendingQuestions"] == []
  end

  test "waiter death emits resolution and removes the live snapshot entry", %{
    context: context,
    agent: agent
  } do
    subscription = attach!(context, ["questions.v1"])
    waiter = spawn(fn -> Sigma.Agent.ask_user_question(agent, %{question: "Pending?"}) end)
    id = receive_type(subscription, "question.required").payload["requestId"]
    Process.exit(waiter, :kill)
    assert receive_type(subscription, "question.resolved").payload["requestId"] == id

    assert {:ok, snapshot} =
             execute(context, "session.status", %{"requiredCapabilities" => ["questions.v1"]})

    assert snapshot.payload["pendingQuestions"] == []
    assert {:error, _} = resolve(context, id, "answer", "late")
  end

  test "a dropped final question immediately requests one resync until a fresh live snapshot", %{
    context: context,
    agent: agent
  } do
    parent = self()

    sink =
      spawn(fn ->
        receive do
          :drain ->
            forward = fn forward ->
              receive do
                {:sync, ref} ->
                  send(parent, {:question_sink_synced, ref})
                  forward.(forward)

                message ->
                  send(parent, {:question_sink, message})
                  forward.(forward)
              end
            end

            forward.(forward)
        end
      end)

    on_exit(fn -> if Process.alive?(sink), do: Process.exit(sink, :kill) end)
    send(sink, :occupied)
    slow_context = Map.merge(context, %{subscriber: sink, max_subscriber_queue: 1})
    subscription = attach!(slow_context, ["questions.v1"])
    legacy = attach!(slow_context, [])
    [{relay, _}] = Registry.lookup(Sigma.Agent.ProtocolSubscriptionRegistry, subscription)
    [{legacy_relay, _}] = Registry.lookup(Sigma.Agent.ProtocolSubscriptionRegistry, legacy)
    handler_id = "question-overflow-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:sigma, :protocol, :subscriber, :dropped],
        fn _, _, meta, test ->
          send(test, {:question_dropped, meta.subscription_id})
        end,
        parent
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    Sigma.Agent.subscribe(agent)

    first = Task.async(fn -> Sigma.Agent.ask_user_question(agent, %{question: "First?"}) end)
    assert_receive {:ask_user_question, _, _}, 1_000
    assert_receive {:question_dropped, ^subscription}, 1_000
    :sys.get_state(relay)
    send(sink, :drain)

    assert_receive {:question_sink,
                    {:sigma_protocol, ^subscription,
                     %{type: "session.error", error: %{code: "resync_required"}}}},
                   1_000

    second = Task.async(fn -> Sigma.Agent.ask_user_question(agent, %{question: "Second?"}) end)
    assert_receive {:ask_user_question, _, _}, 1_000
    :sys.get_state(relay)
    :sys.get_state(legacy_relay)
    sync = make_ref()
    send(sink, {:sync, sync})
    assert_receive {:question_sink_synced, ^sync}, 1_000

    refute_receive {:question_sink,
                    {:sigma_protocol, ^subscription,
                     %{type: "session.error", error: %{code: "resync_required"}}}},
                   0

    refute_receive {:question_sink,
                    {:sigma_protocol, ^subscription, %{type: "question.required"}}},
                   0

    refute_receive {:question_sink, {:sigma_protocol, ^legacy, _}}, 0

    assert {:ok, snapshot} =
             execute(slow_context, "session.status", %{
               "subscriptionId" => subscription,
               "requiredCapabilities" => ["questions.v1"]
             })

    assert length(snapshot.payload["pendingQuestions"]) == 2

    for %{"requestId" => id} <- snapshot.payload["pendingQuestions"] do
      assert {:ok, _} = resolve(context, id, "cancel")

      assert_receive {:question_sink,
                      {:sigma_protocol, ^subscription,
                       %{type: "question.resolved", payload: %{"requestId" => ^id}}}},
                     1_000
    end

    for task <- [first, second], do: assert({:error, :cancelled} = Task.await(task))
  end

  test "question delivery validates the final correlated wire envelope without truncating choices",
       %{agent: agent} do
    session_id = String.duplicate("s", 200)
    turn_id = String.duplicate("t", 200)

    assert {:ok, subscription} =
             Sigma.Agent.ProtocolSubscription.attach(agent, session_id, self(),
               capabilities: ["questions.v1"]
             )

    [{relay, _}] = Registry.lookup(Sigma.Agent.ProtocolSubscriptionRegistry, subscription)
    send(relay, {:prompt_admitted, :accepted, %{message_id: "wire-message", turn_id: turn_id}})
    assert receive_type(subscription, "prompt.admitted").turn_id == turn_id

    request = %{
      question: String.duplicate("q", 32_768),
      options: [%{label: "A", value: "a", description: String.duplicate("d", 31_000)}],
      allow_freeform: true
    }

    assert {:ok, projected} = Sigma.Protocol.Questions.request("question-boundary", request)
    assert {:ok, probe} = Envelope.event("question.required", "projection", projected)
    assert {:ok, encoded} = Codec.encode(probe)
    padding = 65_536 - byte_size(encoded) - 16
    assert padding > 0

    request =
      put_in(
        request,
        [:options, Access.at(0), :description],
        String.duplicate("d", 31_000 + padding)
      )

    assert {:ok, _} = Sigma.Protocol.Questions.request("question-boundary", request)

    task = Task.async(fn -> Sigma.Agent.ask_user_question(agent, request) end)
    assert_receive {:sigma_protocol, ^subscription, event}, 1_000
    assert {:ok, _} = Codec.encode(event)
    assert event.type == "session.error"
    assert event.error.code == "question_payload_too_large"
    refute Map.has_key?(event.payload, "request")

    assert [%{id: id, question: question, options: [option]}] =
             Sigma.Agent.pending_user_questions(agent)

    assert question == request.question
    assert option.description == hd(request.options).description
    assert :ok = Sigma.Agent.answer_user_question(agent, id, {:error, :cancelled})
    assert {:error, :cancelled} = Task.await(task)
  end

  defp execute(context, type, payload, session_id \\ "question-session") do
    assert {:ok, command} = Envelope.command(type, session_id, payload)
    PublicRuntime.execute(command, context)
  end

  defp resolve(context, id, action, answer \\ nil) do
    payload = %{"requestId" => id, "action" => action}
    payload = if is_nil(answer), do: payload, else: Map.put(payload, "answer", answer)
    execute(context, "question.resolve", payload)
  end

  defp attach!(context, capabilities) do
    assert {:ok, %{payload: %{"subscriptionId" => id}}} =
             execute(context, "subscription.attach", %{"requiredCapabilities" => capabilities})

    id
  end

  defp receive_type(subscription, type) do
    receive do
      {:sigma_protocol, ^subscription, %{type: ^type} = event} ->
        assert {:ok, _} = Codec.encode(event)
        event

      {:sigma_protocol, ^subscription, _} ->
        receive_type(subscription, type)
    after
      1_000 -> flunk("timed out waiting for #{type}")
    end
  end
end
