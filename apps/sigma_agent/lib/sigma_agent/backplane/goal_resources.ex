defmodule Sigma.Agent.Backplane.GoalResources do
  @moduledoc """
  Native extension adapter for the current public Conversation Goal binding.

  Conversation supplies its current Goal attribution on each operation. This
  adapter never owns a second Goal, creates ephemeral extension state, or
  manufactures a run identity from tool arguments.
  """

  alias Backplane.AgentRuntime.{Error, Goal}
  alias Backplane.AgentRuntime.Codex.Session

  @names ~w(get_goal create_goal update_goal)

  def names, do: @names

  def execute(
        %{tool_name: name, backend_context: backend} = operation,
        _scope,
        _context
      )
      when name in @names do
    session = backend[:session_binding] || get_in(backend, [:resource_owner, :session_binding])

    with %{goal: goal, goal_binding: binding} <- backend,
         true <- is_map(session),
         {:ok, _} <- Session.validate(session, operation),
         {:ok, result} <- Goal.tool(goal, Map.put(operation, :binding, binding)) do
      {:ok, result}
    else
      {:error, _} = error -> error
      _ -> unavailable()
    end
  catch
    :exit, reason ->
      {:error, Error.new(:execution_failure, "Goal runtime is unavailable", cause: reason)}
  end

  def execute(_operation, _scope, _context), do: unavailable()

  defp unavailable,
    do: {:error, Error.new(:unsupported_capability, "Goal host is not connected")}
end
