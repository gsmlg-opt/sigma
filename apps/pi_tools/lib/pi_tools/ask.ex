defmodule PiTools.Ask do
  @moduledoc false
  @behaviour PiCoding.Tool

  @impl true
  def name, do: "ask"

  @impl true
  def description, do: PiCoding.Tools.AskUserQuestion.description()

  @impl true
  def schema, do: PiCoding.Tools.AskUserQuestion.schema()

  @impl true
  def execute(tool_call_id, params, opts) do
    PiCoding.Tools.AskUserQuestion.execute(tool_call_id, params, opts)
  end
end
