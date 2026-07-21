defmodule Sigma.Session.Journal.Index do
  @moduledoc false

  defstruct header: nil,
            header_ids: MapSet.new(),
            header_indexes: %{},
            ordered: [],
            by_id: %{},
            diagnostics: []

  @type journal_node :: %{
          entry: map(),
          entry_index: non_neg_integer(),
          parent_id: String.t() | nil
        }

  @type diagnostic :: %{
          kind: atom(),
          entry_index: non_neg_integer(),
          entry_id: term(),
          reason: atom()
        }

  @type t :: %__MODULE__{
          header: map() | nil,
          header_ids: MapSet.t(String.t()),
          header_indexes: %{optional(String.t()) => non_neg_integer()},
          ordered: [journal_node()],
          by_id: %{optional(String.t()) => journal_node()},
          diagnostics: [diagnostic()]
        }

  @spec build([term()]) :: t()
  def build(entries) when is_list(entries) do
    indexed = Enum.with_index(entries)

    header_results =
      for {entry, index} <- indexed,
          is_map(entry),
          entry["type"] == "session",
          do: {entry, index, validate_header(entry)}

    valid_headers =
      for {entry, _index, :ok} <- header_results,
          do: entry

    header_ids = valid_headers |> Enum.map(& &1["id"]) |> MapSet.new()

    header_indexes =
      Enum.reduce(header_results, %{}, fn
        {entry, index, :ok}, indexes -> Map.put_new(indexes, entry["id"], index)
        {_entry, _index, {:error, _reason}}, indexes -> indexes
      end)

    header_diagnostics =
      for {entry, index, {:error, reason}} <- header_results,
          do: diagnostic(:invalid_header, index, entry["id"], reason)

    missing_header_diagnostics =
      if entries != [] and valid_headers == [] do
        [diagnostic(:invalid_header, 0, nil, :missing_header)]
      else
        []
      end

    initial = %__MODULE__{
      header: List.last(valid_headers),
      header_ids: header_ids,
      header_indexes: header_indexes,
      diagnostics: Enum.reverse(header_diagnostics ++ missing_header_diagnostics)
    }

    indexed
    |> Enum.reject(fn {entry, _index} -> is_map(entry) and entry["type"] == "session" end)
    |> Enum.reduce(initial, &insert/2)
    |> finalize()
  end

  @spec path(t(), :latest | String.t() | nil) ::
          {:ok, {String.t() | nil, [journal_node()]}}
          | {:error, {:leaf_not_found, String.t()}}
  def path(index, selector \\ :latest)

  def path(%__MODULE__{} = index, :latest) do
    leaf_id = index.ordered |> List.last() |> node_id()
    path(index, leaf_id)
  end

  def path(%__MODULE__{}, nil), do: {:ok, {nil, []}}

  def path(%__MODULE__{} = index, leaf_id) when is_binary(leaf_id) do
    if Map.has_key?(index.by_id, leaf_id) do
      {:ok, {leaf_id, build_path(index.by_id, leaf_id, [])}}
    else
      {:error, {:leaf_not_found, leaf_id}}
    end
  end

  defp insert({entry, entry_index}, index) do
    case validate_entry(entry, entry_index, index) do
      {:ok, id, parent_id} ->
        node = %{
          entry: Map.put(entry, "parentId", parent_id),
          entry_index: entry_index,
          parent_id: parent_id
        }

        %{
          index
          | ordered: [node | index.ordered],
            by_id: Map.put(index.by_id, id, node)
        }

      {:error, id, kind, reason} ->
        diagnostic = diagnostic(kind, entry_index, id, reason)
        %{index | diagnostics: [diagnostic | index.diagnostics]}
    end
  end

  defp finalize(index) do
    %{
      index
      | ordered: Enum.reverse(index.ordered),
        diagnostics: Enum.reverse(index.diagnostics)
    }
  end

  defp validate_entry(entry, _entry_index, _index) when not is_map(entry),
    do: {:error, nil, :invalid_entry, :not_a_map}

  defp validate_entry(entry, entry_index, index) do
    id = entry["id"]

    with {:ok, parent_id} <- Map.fetch(entry, "parentId") do
      cond do
        not is_binary(entry["type"]) ->
          {:error, id, :invalid_entry, :invalid_type}

        not valid_id?(id) ->
          {:error, id, :invalid_entry, :invalid_id}

        MapSet.member?(index.header_ids, id) or Map.has_key?(index.by_id, id) ->
          {:error, id, :duplicate_id, :duplicate_id}

        not valid_timestamp?(entry["timestamp"]) ->
          {:error, id, :invalid_entry, :invalid_timestamp}

        parent_id == id ->
          {:error, id, :invalid_entry, :self_parent}

        is_nil(parent_id) or prior_header?(index.header_indexes, parent_id, entry_index) ->
          {:ok, id, nil}

        is_binary(parent_id) and Map.has_key?(index.by_id, parent_id) ->
          {:ok, id, parent_id}

        true ->
          {:error, id, :invalid_entry, :missing_parent}
      end
    else
      :error -> {:error, id, :invalid_entry, :missing_parent_id}
    end
  end

  defp valid_id?(id), do: is_binary(id) and id != ""

  defp prior_header?(header_indexes, parent_id, entry_index) do
    case Map.fetch(header_indexes, parent_id) do
      {:ok, header_index} -> header_index < entry_index
      :error -> false
    end
  end

  defp validate_header(entry) do
    cond do
      not valid_id?(entry["id"]) ->
        {:error, :invalid_id}

      not valid_timestamp?(entry["timestamp"]) ->
        {:error, :invalid_timestamp}

      not is_binary(entry["cwd"]) ->
        {:error, :invalid_cwd}

      not (is_nil(entry["parentSession"]) or is_binary(entry["parentSession"])) ->
        {:error, :invalid_parent_session}

      true ->
        :ok
    end
  end

  defp valid_timestamp?(timestamp) when is_binary(timestamp) do
    match?({:ok, _datetime, _offset}, DateTime.from_iso8601(timestamp))
  end

  defp valid_timestamp?(_timestamp), do: false

  defp build_path(by_id, id, acc) do
    node = Map.fetch!(by_id, id)

    case node.parent_id do
      nil -> [node | acc]
      parent_id -> build_path(by_id, parent_id, [node | acc])
    end
  end

  defp node_id(nil), do: nil
  defp node_id(node), do: node.entry["id"]

  defp diagnostic(kind, entry_index, entry_id, reason) do
    %{kind: kind, entry_index: entry_index, entry_id: entry_id, reason: reason}
  end
end
