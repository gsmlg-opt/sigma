defmodule Sigma.Session.Subagents do
  @moduledoc "Pure root-session roster projection of acknowledged subagent lifecycle facts."

  alias Sigma.Protocol.Subagents, as: DTO

  @stable_fields [
    :agent_id,
    :agent_path,
    :root_session_id,
    :parent_agent_id,
    :child_session_id,
    :origin_turn_id,
    :origin_tool_call_id,
    :depth,
    :created_at
  ]
  @required_identity @stable_fields -- [:created_at]
  @terminal [:completed, :errored, :interrupted, :shutdown]
  @active [:pending_init, :running, :cancelling]

  defstruct revision: 0,
            agents: %{},
            events: %{},
            observer_incarnation: nil,
            retired_observers: MapSet.new(),
            root_session_id: nil

  @type t :: %__MODULE__{}
  @type error :: {:invalid_event, term()} | {:resync_required, term()} | {:stale_event, term()}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec apply_event(t(), term()) :: {:ok, t()} | {:error, error()}
  def apply_event(%__MODULE__{} = roster, attrs) do
    with {:ok, event} <- DTO.event(attrs) do
      case Map.fetch(roster.events, event.event_id) do
        {:ok, ^event} -> {:ok, roster}
        {:ok, _conflict} -> {:error, {:resync_required, :event_conflict}}
        :error -> apply_new_event(roster, event)
      end
    end
  end

  @spec snapshot(t()) :: map()
  def snapshot(%__MODULE__{} = roster) do
    agents =
      roster.agents |> Map.values() |> Enum.sort_by(&{&1.depth, &1.agent_path, &1.agent_id})

    counts =
      Enum.reduce(
        agents,
        %{created: 0, executing: 0, pending: 0, stopped: 0, unknown: 0},
        fn agent, acc ->
          bucket =
            cond do
              agent.status in [:running, :cancelling] -> :executing
              agent.status == :pending_init -> :pending
              agent.status in @terminal -> :stopped
              agent.status == :unknown_outcome -> :unknown
            end

          acc |> Map.update!(:created, &(&1 + 1)) |> Map.update!(bucket, &(&1 + 1))
        end
      )

    %{revision: roster.revision, agents: agents, counts: counts}
  end

  @doc "Projects lost active observations as unknown without replaying effects or inventing terminal facts."
  @spec recover(t()) :: t()
  def recover(%__MODULE__{} = roster) do
    agents =
      Map.new(roster.agents, fn {id, agent} ->
        {id,
         if(agent.status in @active,
           do: %{agent | status: :unknown_outcome, activity: nil, reason: "owner_restart"},
           else: agent
         )}
      end)

    %{roster | agents: agents}
  end

  defp apply_new_event(roster, event) do
    with :ok <- observer(roster, event),
         :ok <- revision(roster, event),
         :ok <- root_identity(roster, event),
         {:ok, agent} <- update_agent(roster.agents[event.data.agent_id], event) do
      retired =
        if roster.observer_incarnation &&
             roster.observer_incarnation != event.observer_incarnation,
           do: MapSet.put(roster.retired_observers, roster.observer_incarnation),
           else: roster.retired_observers

      {:ok,
       %{
         roster
         | revision: event.revision,
           agents: Map.put(roster.agents, agent.agent_id, agent),
           events: Map.put(roster.events, event.event_id, event),
           observer_incarnation: event.observer_incarnation,
           retired_observers: retired,
           root_session_id: roster.root_session_id || agent.root_session_id
       }}
    end
  end

  defp observer(roster, event) do
    cond do
      MapSet.member?(roster.retired_observers, event.observer_incarnation) ->
        {:error, {:stale_event, :observer_incarnation}}

      is_nil(roster.observer_incarnation) or
          roster.observer_incarnation == event.observer_incarnation ->
        :ok

      event.fact == :recovered ->
        :ok

      true ->
        {:error, {:resync_required, :observer_incarnation}}
    end
  end

  defp revision(roster, event) do
    cond do
      event.revision <= roster.revision ->
        {:error, {:resync_required, :revision_conflict}}

      event.revision != roster.revision + 1 ->
        {:error, {:resync_required, {:revision_gap, roster.revision + 1, event.revision}}}

      true ->
        :ok
    end
  end

  defp root_identity(roster, event) do
    if roster.root_session_id && event.data[:root_session_id] &&
         roster.root_session_id != event.data.root_session_id,
       do: {:error, {:invalid_event, {:identity_conflict, :root_session_id}}},
       else: :ok
  end

  defp update_agent(nil, %{fact: :registered} = event) do
    with :ok <- registered_identity(event.data), :ok <- fact_status(event) do
      agent = Map.new(DTO.agent_fields(), &{&1, nil}) |> Map.merge(event.data)
      {:ok, stamp(agent, event)}
    end
  end

  defp update_agent(nil, _), do: {:error, {:invalid_event, :agent_not_registered}}

  defp update_agent(previous, event) do
    with :ok <- stable_identity(previous, event.data),
         :ok <- run_identity(previous, event),
         :ok <- fact_status(event),
         :ok <- transition(previous, event) do
      data = if event.fact == :registered, do: %{}, else: event.data

      previous =
        if previous.run_id != event.data.run_id,
          do: %{previous | started_at: nil, finished_at: nil, reason: nil, activity: nil},
          else: previous

      {:ok, previous |> Map.merge(data) |> stamp(event)}
    end
  end

  defp registered_identity(data) do
    case Enum.find(@required_identity, fn field ->
           if field == :depth,
             do: not (is_integer(data[field]) and data[field] > 0),
             else: not (is_binary(data[field]) and data[field] != "")
         end) do
      nil -> :ok
      field -> {:error, {:invalid_event, field}}
    end
  end

  defp stable_identity(previous, data) do
    case Enum.find(@stable_fields, fn field ->
           Map.has_key?(data, field) and data[field] != previous[field]
         end) do
      nil -> :ok
      field -> {:error, {:invalid_event, {:identity_conflict, field}}}
    end
  end

  defp run_identity(previous, event) do
    cond do
      previous.run_id == event.data.run_id and previous.incarnation == event.data.incarnation ->
        :ok

      event.fact == :run_started and event.data.incarnation > previous.incarnation and
        event.data.run_id != previous.run_id and
          previous.status in (@terminal ++ [:unknown_outcome]) ->
        :ok

      true ->
        {:error, {:stale_event, :run_identity}}
    end
  end

  defp fact_status(event) do
    valid =
      case event.fact do
        :registered -> event.data.status == :pending_init
        :run_started -> event.data.status in [:running, :cancelling]
        :run_finished -> event.data.status in @terminal
        :closed -> event.data.status in @terminal and event.data[:closure] == :closed
        :recovered -> event.data.status in (@terminal ++ [:unknown_outcome])
      end

    if valid, do: :ok, else: {:error, {:invalid_event, :fact_status}}
  end

  defp transition(previous, event) do
    if previous.status in @terminal and event.data.run_id == previous.run_id and
         event.fact in [:run_started, :run_finished, :closed, :recovered] and
         previous.status != event.data.status,
       do: {:error, {:invalid_event, :terminal_transition}},
       else: :ok
  end

  defp stamp(agent, event),
    do: Map.merge(agent, Map.take(event, [:revision, :event_id, :observer_incarnation]))
end
