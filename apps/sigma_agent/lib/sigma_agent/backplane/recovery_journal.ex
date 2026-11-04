defmodule Sigma.Agent.Backplane.RecoveryJournal do
  @moduledoc "Exact command inputs committed atomically with their Runtime snapshot."

  alias Backplane.AgentRuntime.Codex.Reconciliation.Evidence
  alias Backplane.AgentRuntime.Error

  # A legacy snapshot has no admission prefix. A later mutation must not turn
  # that snapshot into a fabricated complete journal.
  def append(nil, current, _next, _command) when not is_nil(current), do: {:ok, nil}
  def append(nil, nil, _next, nil), do: {:ok, nil}

  def append(journal, current, next, command) do
    with {:ok, entries} <- entries(journal),
         :ok <- prefix(entries, current),
         {:ok, kind, input} <- command(command),
         entry = %{
           "revision" => next.revision,
           "prior_revision" => if(current, do: current.revision, else: 0),
           "prior_incarnation" => if(current, do: current.incarnation, else: next.incarnation),
           "incarnation" => next.incarnation,
           "kind" => kind,
           "input" => input
         } do
      {:ok, %{version: 1, entries: entries ++ [entry]}}
    end
  end

  def read(nil, _record), do: missing()

  def read(journal, record) do
    with {:ok, entries} <- entries(journal),
         :ok <- prefix(entries, record),
         do: entries |> host_values() |> Evidence.public()
  end

  # The journal commits the original command. Only its public read projection
  # converts these two host-owned value types, preserving every field. Runtime
  # Error normalization and rejection of other structs remain with Evidence.
  defp host_values(%Sigma.Agent.Message{} = value),
    do: value |> Map.from_struct() |> host_values()

  defp host_values(%Sigma.Ai.ProviderStopReason{} = value),
    do: value |> Map.from_struct() |> host_values()

  defp host_values(%_{} = value), do: value

  defp host_values(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {key, host_values(item)} end)

  defp host_values(value) when is_list(value), do: Enum.map(value, &host_values/1)
  defp host_values(value), do: value

  defp entries(nil), do: {:ok, []}
  defp entries(%{version: 1, entries: [_ | _] = entries}), do: {:ok, entries}
  defp entries(_), do: malformed()

  defp prefix([], nil), do: :ok

  defp prefix([%{"kind" => "admit", "revision" => 1} | _] = entries, record)
       when is_map(record) do
    case List.last(entries) do
      %{"revision" => revision, "incarnation" => incarnation}
      when revision == record.revision and incarnation == record.incarnation ->
        :ok

      _ ->
        malformed()
    end
  end

  defp prefix(_, _), do: malformed()

  defp command(:fence), do: {:ok, "fence", %{}}

  defp command(command) when is_tuple(command) do
    case Tuple.to_list(command) do
      [kind, _at, input] when is_atom(kind) and is_map(input) ->
        {:ok, Atom.to_string(kind), input}

      [kind, _at] when is_atom(kind) ->
        {:ok, Atom.to_string(kind), %{}}

      _ ->
        malformed()
    end
  end

  defp command(_), do: malformed()

  defp missing,
    do: {:error, Error.new(:unsupported_capability, "Runtime has no complete recovery journal")}

  defp malformed,
    do: {:error, Error.new(:validation, "Runtime recovery journal is incomplete or invalid")}
end
