defmodule Sigma.Agent.Backplane.ExtensionResources do
  @moduledoc false

  alias Backplane.AgentRuntime.Error

  alias Sigma.Agent.Backplane.{
    GoalResources,
    HistoryResources,
    MemoryResources,
    MessageBoardResources,
    NotesResources,
    SkillResources
  }

  def execute(%{tool_name: name} = operation, scope, _context)
      when name in ~w(get_goal create_goal update_goal),
      do: GoalResources.execute(operation, scope, %{})

  def execute(%{tool_name: "collaboration::" <> _} = operation, scope, context),
    do: MessageBoardResources.execute(operation, scope, context.board)

  def execute(%{tool_name: "skills::" <> _} = operation, scope, context),
    do: SkillResources.execute(operation, scope, context.skills)

  def execute(%{tool_name: "memories::" <> _} = operation, scope, context),
    do: MemoryResources.execute(operation, scope, context.memories)

  def execute(%{tool_name: "history::" <> _} = operation, scope, context),
    do: HistoryResources.execute(operation, scope, context.history)

  def execute(%{tool_name: "notes::" <> _} = operation, scope, context),
    do: NotesResources.execute(operation, scope, context.notes)

  def execute(_operation, _scope, _context),
    do: {:error, Error.new(:unsupported_capability, "extension host is not connected")}
end
