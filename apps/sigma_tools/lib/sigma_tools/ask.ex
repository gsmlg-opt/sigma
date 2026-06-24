defmodule Sigma.Tools.Ask do
  @moduledoc false
  @behaviour Sigma.Coding.Tool

  @impl true
  def name, do: "ask"

  @impl true
  def description, do: Sigma.Coding.Tools.AskUserQuestion.description()

  @impl true
  def schema, do: Sigma.Coding.Tools.AskUserQuestion.schema()

  @impl true
  def execute(tool_call_id, params, opts) do
    Sigma.Coding.Tools.AskUserQuestion.execute(tool_call_id, params, opts)
  end
end
