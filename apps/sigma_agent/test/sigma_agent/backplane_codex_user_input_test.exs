defmodule Sigma.Agent.BackplaneCodexUserInputTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.{Codex, Conversation, Error, Plan}
  alias Sigma.Agent.Backplane.{CodexResources, InteractionResponder, Store, UserInput}

  @moduletag :tmp_dir

  defmodule Provider do
    def stream(request, %{test: test, questions: questions}) do
      send(test, {:provider_messages, request.messages})

      case Enum.filter(request.messages, &(&1.role == :tool)) do
        [] ->
          tool("question-call", "request_user_input", %{"questions" => questions})

        [%{name: "request_user_input", result: %{answers: answers}}] ->
          %{"answers" => [answer]} = answers[hd(questions)["id"]] |> json()

          tool("plan-call", "update_plan", %{
            "plan" => [%{"step" => answer, "status" => "completed"}]
          })

        _ ->
          [%{type: :response_completed, message: %{role: :assistant, content: "Finished"}}]
      end
    end

    defp json(value), do: value |> Jason.encode!() |> Jason.decode!()

    defp tool(id, name, arguments) do
      [
        %{type: :tool_call_completed, tool_call: %{id: id, name: name, arguments: arguments}},
        %{type: :response_completed, message: %{role: :assistant, content: "Use tool"}}
      ]
    end
  end

  defmodule ObservedStore do
    defdelegate mode(), to: Store
    defdelegate capabilities(), to: Store
    def load(context, id, opts), do: Store.load(context.store, id, opts)

    def store(context, record, meta) do
      transition = interaction_transition(meta.command)

      if transition != nil and transition == context.fail do
        {:error, Error.new(:execution_failure, "injected interaction checkpoint failure")}
      else
        result = Store.store(context.store, record, meta)

        if match?({:ok, _}, result) do
          {:ok, persisted} = Store.load(context.store, record.run_id)

          if transition do
            send(context.test, {:interaction_checkpoint, transition, record.run_id, self()})
            if transition in context.gates, do: receive(do: (:release_commit -> :ok))
          end

          if elem(meta.command, 0) == :cleanup_settled do
            send(context.test, {:cleanup_committed, record.run_id, persisted.run.state})
          end
        end

        result
      end
    end

    defp interaction_transition(
           {:conversation_updated, _, %{base_conversation: base, conversation: next}}
         ) do
      case {base.pending_interaction, next.pending_interaction} do
        {nil, %{id: _}} -> :requested
        {%{id: _}, nil} -> :resolved
        _ -> nil
      end
    end

    defp interaction_transition(_), do: nil
  end

  test "native questionnaire and answers are checkpointed before UI and dependent Plan execution",
       %{tmp_dir: dir} do
    run = start_run!(dir, "checkpointed", gates: [:requested, :resolved])
    prompt!(run)
    assert_receive {:interaction_checkpoint, :requested, "checkpointed", commit}, 5_000
    refute_receive {:ask_user_question, _, _}, 0
    assert {:ok, pending} = Store.load(run.store, run.id)
    interaction = pending.run.context.conversation.pending_interaction
    assert %{request: %{kind: :request_user_input, questions: [question]}} = interaction
    assert question["id"] == "choice"
    assert {:ok, %{revision: 1}} = Plan.read(run.context.plan)
    send(commit, :release_commit)

    assert_receive {:ask_user_question, question_id, request}, 5_000
    assert request.question == "[Choice] 选择下一步？"
    assert request.allow_freeform
    assert [%{label: "继续", description: "完成当前任务"}, _] = request.options
    assert :ok = Sigma.Agent.answer_user_question(run.agent, question_id, {:ok, "保留原文\n中文"})
    assert_receive {:interaction_checkpoint, :resolved, "checkpointed", commit}, 5_000
    assert {:ok, resolved} = Store.load(run.store, run.id)
    assert resolved.run.context.conversation.pending_interaction == nil
    assert {:ok, %{revision: 1}} = Plan.read(run.context.plan)
    send(commit, :release_commit)

    [question_result, plan_result] = complete!(run)

    assert question_result.result == %{
             answers: %{"choice" => %{answers: ["保留原文\n中文"]}},
             is_error: false
           }

    assert {:ok, %{revision: 2, content: %{"plan" => [%{"step" => "保留原文\n中文"}]}}} =
             Plan.read(run.context.plan)

    assert {:ok, saved} = Store.load(run.store, run.id)
    assert saved.run.state == :completed
    assert saved.run.context.conversation.pending_interaction == nil

    assert Enum.filter(saved.run.context.conversation.messages, &(&1.role == :tool)) == [
             question_result,
             plan_result
           ]
  end

  test "three sequential questions aggregate by stable ID without resolving partial answers", %{
    tmp_dir: dir
  } do
    questions = Enum.map(["first", "second", "third"], &question/1)
    run = start_run!(dir, "batch", questions: questions)
    prompt!(run)

    assert_receive {:agent_runtime, _,
                    %{type: :interaction_requested, interaction_id: interaction_id}},
                   5_000

    for {question, answer} <- Enum.zip(questions, ["继续", "another answer", "最后一项"]) do
      assert_receive {:ask_user_question, question_id, request}, 5_000
      assert request.question == "[Choice] #{question["question"]}"

      assert Conversation.status(run.conversation).conversation.pending_interaction.id ==
               interaction_id

      assert {:ok, %{revision: 1}} = Plan.read(run.context.plan)
      assert :ok = Sigma.Agent.answer_user_question(run.agent, question_id, {:ok, answer})
    end

    [tool, _] = complete!(run)

    assert tool.result.answers == %{
             "first" => %{answers: ["继续"]},
             "second" => %{answers: ["another answer"]},
             "third" => %{answers: ["最后一项"]}
           }

    assert Sigma.Agent.pending_user_questions(run.agent) == []
    refute_receive {:ask_user_question, _, _}, 0
  end

  test "human wait outlives original Runtime deadlines", %{tmp_dir: dir} do
    run = start_run!(dir, "long-wait", run_timeout: 1_500, effect_timeout: 1_000)
    prompt!(run)
    assert_receive {:ask_user_question, question_id, _}, 5_000
    Process.sleep(1_600)
    assert Conversation.status(run.conversation).phase == :waiting_interaction
    assert :ok = Sigma.Agent.answer_user_question(run.agent, question_id, {:ok, "继续"})
    complete!(run)
    assert {:ok, %{revision: 2}} = Plan.read(run.context.plan)
  end

  for cause <- [:user, :external, :responder, :owner] do
    test "#{cause} cancellation clears durable pending state and rejects late answers", %{
      tmp_dir: dir
    } do
      owner = spawn(fn -> receive do: (:stop -> :ok) end)
      on_exit(fn -> if Process.alive?(owner), do: send(owner, :stop) end)
      run = start_run!(dir, "cancel-#{unquote(cause)}", owner_pid: owner)
      prompt!(run)

      assert_receive {:agent_runtime, _,
                      %{type: :interaction_requested, interaction_id: interaction_id}},
                     5_000

      assert_receive {:ask_user_question, question_id, _}, 5_000

      cancel!(unquote(cause), run, question_id, owner)

      id = run.id
      assert_receive {:cleanup_committed, ^id, :unknown_outcome}, 5_000
      assert {:ok, saved} = Store.load(run.store, id)
      assert saved.run.state == :unknown_outcome
      assert saved.run.context.conversation.pending_interaction == nil
      assert {:error, _} = Conversation.resolve(run.conversation, interaction_id, %{answers: %{}})

      assert_receive {:ask_user_question_resolved, ^question_id}, 5_000

      assert {:error, :not_found} =
               Sigma.Agent.answer_user_question(run.agent, question_id, {:ok, "late"})

      assert Sigma.Agent.pending_user_questions(run.agent) == []
      assert {:ok, %{revision: 1}} = Plan.read(run.context.plan)
      refute Enum.any?(saved.run.context.conversation.messages, &(&1.role == :tool))
    end
  end

  test "an unsupported duplicate-ID batch cancels the exact durable interaction without opening UI",
       %{tmp_dir: dir} do
    run = start_run!(dir, "duplicate-ids", questions: [question("choice"), question("choice")])
    prompt!(run)
    assert_receive {:interaction_checkpoint, :requested, "duplicate-ids", _}, 5_000
    assert_receive {:cleanup_committed, "duplicate-ids", :unknown_outcome}, 5_000
    assert {:ok, saved} = Store.load(run.store, run.id)
    assert saved.run.context.conversation.pending_interaction == nil
    assert Sigma.Agent.pending_user_questions(run.agent) == []
    refute_receive {:ask_user_question, _, _}, 0
    assert {:ok, %{revision: 1}} = Plan.read(run.context.plan)
  end

  test "question host exit stops its owned waiter and cancels the native run", %{tmp_dir: dir} do
    run = start_run!(dir, "host-exit", [])
    prompt!(run)
    assert_receive {:ask_user_question, _, _}, 5_000
    monitor = Process.monitor(run.responder)
    stop_supervised!(Sigma.Agent)
    assert_receive {:DOWN, ^monitor, :process, _, _}, 5_000
    assert_receive {:cleanup_committed, "host-exit", :unknown_outcome}, 5_000
    assert {:ok, saved} = Store.load(run.store, run.id)
    assert saved.run.context.conversation.pending_interaction == nil
    assert {:ok, %{revision: 1}} = Plan.read(run.context.plan)
  end

  test "Conversation exit removes the host question without replaying a dependent effect", %{
    tmp_dir: dir
  } do
    run = start_run!(dir, "conversation-exit", [])
    prompt!(run)
    assert_receive {:ask_user_question, question_id, _}, 5_000
    monitor = Process.monitor(run.responder)
    GenServer.stop(run.conversation, :normal)
    assert_receive {:DOWN, ^monitor, :process, _, _}, 5_000
    assert_receive {:ask_user_question_resolved, ^question_id}, 5_000
    assert Sigma.Agent.pending_user_questions(run.agent) == []

    assert {:error, :not_found} =
             Sigma.Agent.answer_user_question(run.agent, question_id, {:ok, "late"})

    assert {:ok, %{revision: 1}} = Plan.read(run.context.plan)
  end

  test "failed request checkpoint never opens a host question", %{tmp_dir: dir} do
    run = start_run!(dir, "request-failure", fail: :requested)
    prompt!(run)
    assert_receive {:agent_runtime, _, %{type: :storage_failed}}, 5_000
    assert Conversation.status(run.conversation).phase == :storage_failed
    refute_receive {:ask_user_question, _, _}, 0
    assert Sigma.Agent.pending_user_questions(run.agent) == []
    assert {:ok, %{revision: 1}} = Plan.read(run.context.plan)
  end

  test "failed answer checkpoint retains pending disk state and never executes the dependent Plan",
       %{tmp_dir: dir} do
    run = start_run!(dir, "answer-failure", fail: :resolved)
    prompt!(run)
    assert_receive {:ask_user_question, question_id, _}, 5_000
    assert :ok = Sigma.Agent.answer_user_question(run.agent, question_id, {:ok, "继续"})
    assert_receive {:agent_runtime, _, %{type: :storage_failed}}, 5_000
    assert {:ok, saved} = Store.load(run.store, run.id)
    assert saved.run.context.conversation.pending_interaction != nil
    assert {:ok, %{revision: 1}} = Plan.read(run.context.plan)
    refute Enum.any?(saved.run.context.conversation.messages, &(&1.role == :tool))
    assert Sigma.Agent.pending_user_questions(run.agent) == []
  end

  defp start_run!(dir, id, opts) do
    agent =
      start_supervised!(
        {Sigma.Agent,
         cwd: dir,
         session_id: "question-host",
         backplane_runtime_path: Path.join(dir, "host"),
         tools: [],
         hook_specs: []}
      )

    Sigma.Agent.subscribe(agent)
    resources = start_supervised!({CodexResources, workspace: dir, owner_pid: self()})

    authority = %{
      caller: "question-test",
      run_id: id,
      grants: ["request_user_input", "update_plan"],
      tool_revision: 1
    }

    assert {:ok, binding} = CodexResources.bind(resources, authority)
    assert {:ok, context} = CodexResources.context(resources, binding)

    assert {:ok, profile} =
             Codex.profile(:configured, Map.put(context, :root?, true), authority,
               families: [:interactive, :local],
               tools: authority.grants
             )

    store = start_supervised!({Store, path: Path.join(dir, "runtime")})

    responder =
      start_supervised!(
        {InteractionResponder,
         run_id: id,
         incarnation: 1,
         owner_pid: opts[:owner_pid] || agent,
         subscriber: self(),
         user_input_request_fn: UserInput.resolver(agent)}
      )

    conversation =
      start_supervised!(
        {Conversation,
         run_id: id,
         store: ObservedStore,
         context: %{store: store, test: self(), gates: opts[:gates] || [], fail: opts[:fail]},
         provider: Provider,
         provider_context: %{test: self(), questions: opts[:questions] || [question("choice")]},
         registry: profile.registry,
         tools: profile.tools,
         authority: profile.authority,
         session_binding: binding,
         subscriber: responder,
         run_timeout: opts[:run_timeout] || :infinity,
         effect_timeout: opts[:effect_timeout] || 5_000}
      )

    assert :ok = InteractionResponder.attach(responder, conversation)

    %{
      id: id,
      agent: agent,
      resources: resources,
      context: context,
      store: store,
      responder: responder,
      conversation: conversation
    }
  end

  defp prompt!(run), do: assert({:ok, _} = Conversation.prompt(run.conversation, "Ask the user"))

  defp cancel!(:user, run, question_id, _owner),
    do:
      assert(:ok = Sigma.Agent.answer_user_question(run.agent, question_id, {:error, :cancelled}))

  defp cancel!(:external, run, _question_id, _owner),
    do: assert(:ok = Conversation.cancel(run.conversation))

  defp cancel!(:responder, _run, _question_id, _owner), do: stop_supervised!(InteractionResponder)
  defp cancel!(:owner, _run, _question_id, owner), do: send(owner, :stop)

  defp complete!(run) do
    id = run.id
    assert_receive {:agent_runtime, ^id, %{type: :run_completed}}, 5_000
    Enum.filter(Conversation.status(run.conversation).messages, &(&1.role == :tool))
  end

  defp question(id) do
    %{
      "id" => id,
      "header" => "Choice",
      "question" => "选择下一步？",
      "options" => [
        %{"label" => "继续", "description" => "完成当前任务"},
        %{"label" => "暂停", "description" => "保留当前状态"}
      ]
    }
  end
end
