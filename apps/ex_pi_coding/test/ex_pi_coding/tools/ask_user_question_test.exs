defmodule PiCoding.Tools.AskUserQuestionTest do
  use ExUnit.Case, async: true

  alias PiCoding.Tools.AskUserQuestion

  test "uses the Claude Code-compatible tool name" do
    assert AskUserQuestion.name() == "AskUserQuestion"
  end

  test "asks through configured callback and returns the user's answer" do
    test_pid = self()

    ask_fn = fn request, _opts ->
      send(test_pid, {:request, request})
      {:ok, "Project AGENTS.md"}
    end

    params = %{
      "question" => "Which file should I update?",
      "options" => [
        "Project AGENTS.md",
        %{
          "label" => "User AGENTS.md",
          "value" => "user",
          "description" => "Private global instructions"
        }
      ],
      "allow_freeform" => true,
      "placeholder" => "Type a different path"
    }

    assert {:ok, result} =
             AskUserQuestion.execute("call_1", params, ask_user_question_fn: ask_fn)

    assert_receive {:request,
                    %{
                      question: "Which file should I update?",
                      allow_freeform: true,
                      placeholder: "Type a different path",
                      options: [
                        %{label: "Project AGENTS.md", value: "Project AGENTS.md"},
                        %{label: "User AGENTS.md", value: "user"}
                      ]
                    }}

    assert [%{type: :text, text: "User answer: Project AGENTS.md"}] = result.content
    assert result.details.answer == "Project AGENTS.md"
  end

  test "promotes placeholder examples to selectable options" do
    test_pid = self()

    ask_fn = fn request, _opts ->
      send(test_pid, {:request, request})
      {:ok, "latency-based"}
    end

    assert {:ok, result} =
             AskUserQuestion.execute(
               "call_1",
               %{
                 "question" => "How should the faster proxy be selected?",
                 "allow_freeform" => true,
                 "placeholder" => "e.g., geo-based, latency-based, load-balanced"
               },
               ask_user_question_fn: ask_fn
             )

    assert_receive {:request,
                    %{
                      options: [
                        %{label: "geo-based", value: "geo-based"},
                        %{label: "latency-based", value: "latency-based"},
                        %{label: "load-balanced", value: "load-balanced"}
                      ],
                      placeholder: nil
                    }}

    assert [%{type: :text, text: "User answer: latency-based"}] = result.content
  end

  test "requires a question" do
    assert {:error, "Question is required."} =
             AskUserQuestion.execute("call_1", %{"question" => " "},
               ask_user_question_fn: fn _ -> :ok end
             )
  end

  test "requires a configured user question handler" do
    assert {:error, reason} =
             AskUserQuestion.execute("call_1", %{"question" => "Continue?"}, [])

    assert reason =~ "no user question handler"
  end
end
