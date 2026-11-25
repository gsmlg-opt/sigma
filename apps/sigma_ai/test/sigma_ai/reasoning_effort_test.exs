defmodule Sigma.Ai.ReasoningEffortTest do
  use ExUnit.Case, async: true

  alias Sigma.Ai.{ReasoningEffort, Providers.OpenAIResponses, Providers.Anthropic}

  test "uses declared effort choices and respects disabled reasoning" do
    model = %{"reasoningEfforts" => ["low", "high", "ultra"]}
    assert ReasoningEffort.levels(OpenAIResponses, model) == ["low", "high", "ultra"]
    assert ReasoningEffort.validate(OpenAIResponses, model, "ultra") == {:ok, "ultra"}

    assert ReasoningEffort.validate(OpenAIResponses, model, "medium") ==
             {:error, :invalid_reasoning_effort}

    assert ReasoningEffort.levels(OpenAIResponses, Map.put(model, "reasoning", false)) == []
    assert ReasoningEffort.levels(Anthropic, model) == []
  end

  test "default levels exclude undeclared ultra and reset removes the provider option" do
    assert ReasoningEffort.levels(OpenAIResponses, %{}) == ~w(low medium high)
    assert ReasoningEffort.options(OpenAIResponses, %{}, "", reasoning_effort: "high") == []
    assert ReasoningEffort.options(OpenAIResponses, %{}, "ultra", reasoning_effort: "high") == []
    assert ReasoningEffort.options(OpenAIResponses, %{"reasoning" => false}, "high", []) == []
  end
end
