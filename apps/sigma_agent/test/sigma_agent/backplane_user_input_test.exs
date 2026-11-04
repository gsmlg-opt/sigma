defmodule Sigma.Agent.BackplaneUserInputTest do
  use ExUnit.Case, async: true

  alias Sigma.Agent.Backplane.UserInput

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    agent =
      start_supervised!({Sigma.Agent, backplane_runtime_path: dir, hook_specs: []})

    Sigma.Agent.subscribe(agent)
    %{agent: agent}
  end

  test "uses actual host questions sequentially and preserves freeform answers", %{agent: agent} do
    request = request([question("first"), question("second", "选择")])
    resolver = UserInput.resolver(agent)
    task = Task.async(fn -> resolver.(request, fn -> true end) end)

    assert_receive {:ask_user_question, first_id, first}, 1_000
    assert first.question == "[Choice] Which one?"
    assert first.allow_freeform

    assert first.options == [
             %{label: "A", value: "A", description: "First choice"},
             %{label: "B", value: "B", description: "Second choice"}
           ]

    assert [%{id: ^first_id}] = Sigma.Agent.pending_user_questions(agent)
    refute_receive {:ask_user_question, _, _}, 20
    assert :ok = Sigma.Agent.answer_user_question(agent, first_id, {:ok, "  custom answer\n"})

    assert_receive {:ask_user_question, second_id, second}, 1_000
    assert second.question == "[选择] Which one?"
    assert [%{id: ^second_id}] = Sigma.Agent.pending_user_questions(agent)
    assert :ok = Sigma.Agent.answer_user_question(agent, second_id, {:ok, "B"})

    assert {:ok,
            %{
              answers: %{
                "first" => %{answers: ["  custom answer\n"]},
                "second" => %{answers: ["B"]}
              }
            }} = Task.await(task)

    assert [] = Sigma.Agent.pending_user_questions(agent)
  end

  test "accepts three questions and twelve-character unicode headers", %{agent: agent} do
    questions = for id <- ["one", "two", "three"], do: question(id, String.duplicate("选", 12))
    resolver = UserInput.resolver(agent, timeout: 1_000)
    task = Task.async(fn -> resolver.(request(questions), fn -> true end) end)

    for _ <- questions do
      assert_receive {:ask_user_question, id, _}, 1_000
      assert :ok = Sigma.Agent.answer_user_question(agent, id, {:ok, "A"})
    end

    assert {:ok, %{answers: answers}} = Task.await(task)
    assert map_size(answers) == 3
  end

  test "rejects invalid and unsupported full batches without partial UI", %{agent: agent} do
    valid = question("first")

    invalid_questions = [
      [],
      List.duplicate(valid, 4),
      [valid, valid],
      [Map.put(valid, "id", "")],
      [Map.put(valid, "id", "   ")],
      [Map.put(valid, "header", "")],
      [Map.put(valid, "header", String.duplicate("选", 13))],
      [Map.put(valid, "question", " ")],
      [Map.put(valid, "options", [])],
      [Map.put(valid, "options", Enum.take(valid["options"], 1))],
      [Map.put(valid, "options", List.duplicate(hd(valid["options"]), 4))],
      [Map.put(valid, "options", [%{"label" => "A"}, %{"label" => "B"}])],
      [Map.put(valid, "options", [%{"label" => "A", "description" => ""} | valid["options"]])],
      [
        Map.put(valid, "options", [%{"label" => " ", "description" => "Empty"} | valid["options"]])
      ],
      [Map.put(valid, "is_secret", true)],
      [
        Map.update!(valid, "options", fn [first | rest] ->
          [Map.put(first, "value", "a") | rest]
        end)
      ],
      [valid, Map.put(question("second"), "question", nil)],
      [%{id: "atom", header: "Choice", question: "Pick?", options: valid["options"]}],
      "invalid"
    ]

    resolver = UserInput.resolver(agent)

    for questions <- invalid_questions do
      assert {:error, :invalid_user_input_request} = resolver.(request(questions), fn -> true end)
      assert [] = Sigma.Agent.pending_user_questions(agent)
      refute_receive {:ask_user_question, _, _}, 0
    end

    for invalid <- [
          %{},
          %{kind: :other, questions: [valid]},
          %{kind: :request_user_input, questions: [valid], unsupported: true}
        ] do
      assert {:error, :invalid_user_input_request} = resolver.(invalid, fn -> true end)
    end
  end

  test "stale request never prompts", %{agent: agent} do
    resolver = UserInput.resolver(agent)
    assert {:error, :stale_interaction} = resolver.(request([question("one")]), fn -> false end)
    assert [] = Sigma.Agent.pending_user_questions(agent)
    refute_receive {:ask_user_question, _, _}, 0
  end

  test "checks freshness after answer before another question", %{agent: agent} do
    calls = :atomics.new(1, [])
    current? = fn -> :atomics.add_get(calls, 1, 1) == 1 end
    resolver = UserInput.resolver(agent)
    task = Task.async(fn -> resolver.(request([question("one"), question("two")]), current?) end)

    assert_receive {:ask_user_question, id, _}, 1_000
    assert :ok = Sigma.Agent.answer_user_question(agent, id, {:ok, "A"})
    assert {:error, :stale_interaction} = Task.await(task)
    assert :atomics.get(calls, 1) == 2
    assert [] = Sigma.Agent.pending_user_questions(agent)
    refute_receive {:ask_user_question, _, _}, 0
  end

  test "checks freshness separately before the next question", %{agent: agent} do
    calls = :atomics.new(1, [])
    current? = fn -> :atomics.add_get(calls, 1, 1) < 3 end
    resolver = UserInput.resolver(agent)
    task = Task.async(fn -> resolver.(request([question("one"), question("two")]), current?) end)

    assert_receive {:ask_user_question, id, _}, 1_000
    assert :ok = Sigma.Agent.answer_user_question(agent, id, {:ok, "A"})
    assert {:error, :stale_interaction} = Task.await(task)
    assert :atomics.get(calls, 1) == 3
    assert [] = Sigma.Agent.pending_user_questions(agent)
    refute_receive {:ask_user_question, _, _}, 0
  end

  test "host cancellation ends the batch", %{agent: agent} do
    resolver = UserInput.resolver(agent)

    task =
      Task.async(fn -> resolver.(request([question("one"), question("two")]), fn -> true end) end)

    assert_receive {:ask_user_question, id, _}, 1_000
    assert :ok = Sigma.Agent.answer_user_question(agent, id, {:error, :cancelled})
    assert {:error, :cancelled} = Task.await(task)
    assert [] = Sigma.Agent.pending_user_questions(agent)
    refute_receive {:ask_user_question, _, _}, 0
  end

  test "explicit host timeout expires the pending question", %{agent: agent} do
    resolver = UserInput.resolver(agent, timeout: 20)
    task = Task.async(fn -> resolver.(request([question("one")]), fn -> true end) end)

    assert_receive {:ask_user_question, id, _}, 1_000
    assert {:error, "Timed out waiting for the user to answer."} = Task.await(task)
    assert_receive {:ask_user_question_resolved, ^id}, 1_000
    assert [] = Sigma.Agent.pending_user_questions(agent)
  end

  test "rejects malformed and empty host answers without fabricating choices", %{agent: agent} do
    resolver = UserInput.resolver(agent)

    for answer <- [{:ok, ""}, {:ok, " "}, {:ok, ["A"]}, {:ok, 1}, :ok, nil] do
      task =
        Task.async(fn ->
          resolver.(request([question("one"), question("two")]), fn -> true end)
        end)

      assert_receive {:ask_user_question, id, _}, 1_000
      assert :ok = Sigma.Agent.answer_user_question(agent, id, answer)
      assert {:error, :invalid_user_input_answer} = Task.await(task)
      assert [] = Sigma.Agent.pending_user_questions(agent)
      refute_receive {:ask_user_question, _, _}, 0
    end
  end

  test "owned resolver death clears the host question", %{agent: agent} do
    resolver = UserInput.resolver(agent)
    pid = spawn(fn -> resolver.(request([question("one")]), fn -> true end) end)
    monitor = Process.monitor(pid)
    assert_receive {:ask_user_question, id, _}, 1_000
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}, 1_000
    assert_receive {:ask_user_question_resolved, ^id}, 1_000
    assert [] = Sigma.Agent.pending_user_questions(agent)
  end

  defp request(questions), do: %{kind: :request_user_input, questions: questions}

  defp question(id, header \\ "Choice") do
    %{
      "id" => id,
      "header" => header,
      "question" => "Which one?",
      "options" => [
        %{"label" => "A", "description" => "First choice"},
        %{"label" => "B", "description" => "Second choice"}
      ]
    }
  end
end
