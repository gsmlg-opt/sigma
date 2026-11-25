defmodule Sigma.Web.SessionComposerEffortTest do
  use ExUnit.Case, async: true

  alias Sigma.Ai.Providers.OpenAIResponses
  alias Sigma.Session.{EntryEncoder, Journal}
  alias Sigma.Ai.ReasoningEffort

  test "a model change with an explicit effort reset survives journal replay" do
    {:ok, prior} = EntryEncoder.encode({:thinking_level_change, "high", "high"}, nil, false)

    {:ok, selected} =
      EntryEncoder.encode({:model_change, "openai", "new", nil}, prior["id"], false)

    {:ok, snapshot} = Journal.replay([prior, selected])

    assert snapshot.model_id == "new"
    assert snapshot.reasoning_level == nil
    assert ReasoningEffort.options(OpenAIResponses, %{}, snapshot.reasoning_level, []) == []
  end

  test "older model changes retain their existing reasoning history" do
    {:ok, prior} = EntryEncoder.encode({:thinking_level_change, "high", "high"}, nil, false)
    {:ok, selected} = EntryEncoder.encode({:model_change, "openai", "new"}, prior["id"], false)
    {:ok, snapshot} = Journal.replay([prior, selected])

    assert snapshot.reasoning_level == "high"

    assert ReasoningEffort.options(OpenAIResponses, %{}, snapshot.reasoning_level, []) ==
             [reasoning_effort: "high"]

    assert ReasoningEffort.options(
             OpenAIResponses,
             %{"reasoning" => false},
             snapshot.reasoning_level,
             []
           ) ==
             []
  end
end
