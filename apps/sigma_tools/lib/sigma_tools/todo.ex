defmodule Sigma.Tools.Todo do
  @moduledoc """
  Session-scoped todo list tool.

  State lives in `Sigma.Tools.Store` (agent-owned ETS) and disappears with the
  session. It is not persisted to JSONL.
  """

  @behaviour Sigma.Coding.Tool

  alias Sigma.Tools.{Result, Store}

  @statuses ~w(pending in_progress completed)
  @actions ~w(add update complete remove list clear)

  @impl true
  def name, do: "todo"

  @impl true
  def description do
    """
    Manage a session-scoped todo list. Actions: add, update, complete, remove, list, clear.
    Todos exist only for the current agent session (Store-backed); they are not written to disk.
    """
  end

  @impl true
  def schema do
    %{
      "type" => "object",
      "properties" => %{
        "action" => %{
          "type" => "string",
          "enum" => @actions,
          "description" => "Todo action to perform"
        },
        "id" => %{
          "type" => "string",
          "description" => "Todo id (required for update, complete, remove)"
        },
        "content" => %{
          "type" => "string",
          "description" => "Todo text (required for add; optional for update)"
        },
        "status" => %{
          "type" => "string",
          "enum" => @statuses,
          "description" => "Todo status (optional for add/update; complete forces completed)"
        }
      },
      "required" => ["action"]
    }
  end

  @impl true
  def metadata do
    %{
      effect: :write,
      concurrency: :sequential,
      interruptible: true,
      default_deadline_ms: 5_000,
      approval_tier: :standard,
      discoverable: true,
      render_hint: :structured
    }
  end

  @impl true
  def execute(_tool_call_id, params, opts) do
    store = Store.from_opts(opts)
    action = params["action"] || params[:action]

    cond do
      is_nil(store) ->
        {:error, "todo requires session tool_state"}

      action not in @actions ->
        {:error,
         "Unknown action: #{inspect(action)}. Expected one of: #{Enum.join(@actions, ", ")}"}

      true ->
        state = Store.get_todo_state(store)
        dispatch(action, params, store, state)
    end
  end

  defp dispatch("list", _params, _store, state) do
    {:ok, list_result(state, "list")}
  end

  defp dispatch("clear", _params, store, state) do
    count = length(state.items)
    next = %{items: [], next_id: 1}
    :ok = Store.put_todo_state(store, next)
    text = "Cleared #{count} todo(s)."
    {:ok, Result.text(text, details("clear", next))}
  end

  defp dispatch("add", params, store, state) do
    content = blank_to_nil(params["content"] || params[:content])
    status = normalize_status(params["status"] || params[:status], "pending")

    cond do
      is_nil(content) ->
        {:error, "content is required for add"}

      match?({:error, _}, status) ->
        status

      true ->
        {:ok, status} = status
        id = Integer.to_string(state.next_id)
        item = %{id: id, content: content, status: status}
        next = %{items: state.items ++ [item], next_id: state.next_id + 1}
        :ok = Store.put_todo_state(store, next)
        text = "Added todo ##{id}: #{content} [#{status}]"
        {:ok, Result.text(text, details("add", next, item))}
    end
  end

  defp dispatch("update", params, store, state) do
    with {:ok, id} <- require_id(params),
         {:ok, item, index} <- find_item(state.items, id),
         {:ok, content} <- optional_content(params, item.content),
         {:ok, status} <- optional_status(params, item.status) do
      updated = %{item | content: content, status: status}
      items = List.replace_at(state.items, index, updated)
      next = %{state | items: items}
      :ok = Store.put_todo_state(store, next)
      text = "Updated todo ##{id}: #{content} [#{status}]"
      {:ok, Result.text(text, details("update", next, updated))}
    end
  end

  defp dispatch("complete", params, store, state) do
    with {:ok, id} <- require_id(params),
         {:ok, item, index} <- find_item(state.items, id) do
      updated = %{item | status: "completed"}
      items = List.replace_at(state.items, index, updated)
      next = %{state | items: items}
      :ok = Store.put_todo_state(store, next)
      text = "Completed todo ##{id}: #{item.content}"
      {:ok, Result.text(text, details("complete", next, updated))}
    end
  end

  defp dispatch("remove", params, store, state) do
    with {:ok, id} <- require_id(params),
         {:ok, item, _index} <- find_item(state.items, id) do
      items = Enum.reject(state.items, &(&1.id == id))
      next = %{state | items: items}
      :ok = Store.put_todo_state(store, next)
      text = "Removed todo ##{id}: #{item.content}"
      {:ok, Result.text(text, details("remove", next, item))}
    end
  end

  defp list_result(%{items: []} = state, action) do
    Result.text("No todos", details(action, state))
  end

  defp list_result(%{items: items} = state, action) do
    text =
      items
      |> Enum.map(&format_item/1)
      |> Enum.join("\n")

    Result.text(text, details(action, state))
  end

  defp format_item(%{id: id, content: content, status: status}) do
    mark =
      case status do
        "completed" -> "x"
        "in_progress" -> "~"
        _ -> " "
      end

    "[#{mark}] ##{id}: #{content} (#{status})"
  end

  defp details(action, state, item \\ nil) do
    base = %{
      action: action,
      todos: state.items,
      next_id: state.next_id
    }

    if item, do: Map.put(base, :item, item), else: base
  end

  defp require_id(params) do
    case blank_to_nil(params["id"] || params[:id]) do
      nil -> {:error, "id is required"}
      id -> {:ok, to_string(id)}
    end
  end

  defp find_item(items, id) do
    case Enum.find_index(items, &(&1.id == id)) do
      nil -> {:error, "Todo ##{id} not found"}
      index -> {:ok, Enum.at(items, index), index}
    end
  end

  defp optional_content(params, default) do
    case blank_to_nil(params["content"] || params[:content]) do
      nil -> {:ok, default}
      content -> {:ok, content}
    end
  end

  defp optional_status(params, default) do
    case params["status"] || params[:status] do
      nil -> {:ok, default}
      status -> normalize_status(status, default)
    end
  end

  defp normalize_status(nil, default), do: {:ok, default}

  defp normalize_status(status, _default) when status in @statuses, do: {:ok, status}

  defp normalize_status(status, _default) when is_atom(status) do
    normalize_status(Atom.to_string(status), nil)
  end

  defp normalize_status(status, _default) do
    {:error, "Invalid status: #{inspect(status)}. Expected one of: #{Enum.join(@statuses, ", ")}"}
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(value), do: to_string(value)
end
