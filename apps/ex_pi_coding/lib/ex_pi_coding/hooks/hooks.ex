defmodule PiCoding.Hooks do
  @moduledoc """
  Public facade for the hook dispatch system.

  Usage:

      specs = PiCoding.Hooks.Discovery.load(cwd)
      {outcome, warnings} = PiCoding.Hooks.dispatch(:pre_tool_use, specs, ctx, event_data)

  The returned `outcome` is a single folded value from the Outcome lattice.
  `warnings` is a list of human-readable strings for hooks that were skipped,
  timed out, or produced errors — safe to surface to the user.
  """

  alias PiCoding.Hooks.Runner
  alias PiCoding.Hooks.Outcome

  @doc """
  Dispatch an event against a list of specs.

  - `event` — one of the hook event atoms (`:pre_tool_use`, `:post_tool_use`, etc.)
  - `specs` — list of `%HookSpec{}` loaded via `Discovery.load/1`
  - `ctx` — session/turn context map (`:session_id`, `:cwd`, `:transcript_path`, etc.)
  - `event_data` — event-specific payload fields (`:tool_name`, `:prompt`, etc.)

  Returns `{outcome, warnings}`.
  """
  @spec dispatch(atom(), list(), map(), map()) ::
          {Outcome.outcome(), [String.t()]}
  def dispatch(event, specs, ctx, event_data \\ %{}) do
    if specs == [] do
      {:proceed, []}
    else
      Runner.run(event, specs, ctx, event_data)
    end
  end

  @doc """
  Returns true if any specs are defined for the given event.
  Useful to skip dispatch overhead when no hooks are configured.
  """
  @spec any_for_event?(list(), atom()) :: boolean()
  def any_for_event?(specs, event) do
    Enum.any?(specs, &(&1.event == event))
  end
end
