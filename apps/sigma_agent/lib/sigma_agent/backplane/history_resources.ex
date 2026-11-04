defmodule Sigma.Agent.Backplane.HistoryResources do
  @moduledoc """
  Read-only normalized history from the selected, original JSONL ancestry.

  The resource owner supplies the root archive and current agent identity. A live
  Writer determines branch selection, including transient checkout; stopped
  agents use their latest persisted conversation leaf. Window IDs are journal
  header/context-boundary IDs and item IDs derive from persisted message entries.
  Compaction and context reset never remove original archive items.

  Omitted agent names retain the exact current child Session. Named agents prefer
  live bindings, then the latest durable registration for that name. The latter
  is Sigma's deterministic interpretation when a later generation reuses a name.
  Capturing child Writers happens outside the Subagents owner to avoid call cycles.
  """

  alias Backplane.AgentRuntime.{Error, Codex.Session}
  alias Sigma.Agent.Backplane.ChildIO
  alias Sigma.Agent.Subagents

  @filters ~w(limit recent_first tool_namespace role agent_name tool_name window_id)

  def execute(operation, _scope, %{archive: archive, binding: binding})
      when is_map(archive) and is_map(binding) do
    with {:ok, _} <- Session.validate(binding, operation),
         {:ok, selected} <- load(archive, operation.arguments["agent_name"]),
         {:ok, result} <- dispatch(operation.tool_name, operation.arguments, selected) do
      {:ok, result}
    end
  catch
    :exit, reason -> unavailable("history resource owner is unavailable", reason)
  end

  def execute(_operation, _scope, _context),
    do: error(:unsupported_capability, "history resource host is not connected")

  @doc false
  def load(archive, requested \\ nil) do
    with {:ok, name} <- agent_name(archive.agent_name, requested),
         {:ok, directory} <- Subagents.archive_sources(archive.host),
         {:ok, source} <- source(directory, archive, name, requested),
         {:ok, entries, selector} <- capture(source),
         {:ok, selected} <- project(entries, selector, name) do
      {:ok, selected}
    end
  catch
    :exit, reason -> unavailable("history archive capture is unavailable", reason)
  end

  defp agent_name(current, nil), do: {:ok, current}
  defp agent_name(_current, "/" <> _ = name), do: {:ok, name}

  defp agent_name(current, name) when is_binary(name) and name != "",
    do: {:ok, current <> "/" <> name}

  defp agent_name(_current, _name), do: error(:validation, "agent_name must name an agent")

  defp source(directory, _archive, "/root", _requested), do: {:ok, directory.root}

  defp source(directory, archive, name, requested) do
    exact_session = if is_nil(requested), do: archive[:child_session_id]

    live =
      Enum.find(directory.children, fn %{identity: identity} ->
        identity.agent_path == name and
          (is_nil(exact_session) or identity.child_session_id == exact_session)
      end)

    if live && Process.alive?(live.io) do
      ChildIO.archive_source(live.io)
    else
      exact_session = if live, do: live.identity.child_session_id, else: exact_session

      registration =
        directory.roster.events
        |> Map.values()
        |> Enum.filter(fn event ->
          event.fact == :registered and event.data.agent_path == name and
            (is_nil(exact_session) or event.data.child_session_id == exact_session)
        end)
        |> Enum.max_by(& &1.revision, fn -> nil end)

      if registration do
        {:ok,
         %{
           writer: nil,
           transcript_path:
             Path.join([
               directory.root.transcript_path <> ".subagents",
               registration.data.child_session_id,
               "session.jsonl"
             ])
         }}
      else
        error(:not_found, "history agent was not found")
      end
    end
  end

  defp capture(%{writer: writer}) when not is_nil(writer) do
    with {:ok, selected} <- apply(Sigma.Session.Writer, :selected_journal, [writer]) do
      {:ok, selected.entries, selected.leaf_id}
    else
      {:error, reason} -> unavailable("selected history journal is unavailable", reason)
    end
  end

  defp capture(%{writer: nil, transcript_path: path}) do
    with {:ok, entries, []} <-
           apply(Sigma.Session.Storage.JsonlFile, :read_with_diagnostics, [path]) do
      {:ok, entries, :latest}
    else
      {:ok, _entries, diagnostics} -> unavailable("history journal has diagnostics", diagnostics)
      {:error, reason} -> unavailable("history journal could not be read", reason)
    end
  end

  @doc false
  def project(entries, selector, agent_name) do
    index = apply(Sigma.Session.Journal.Index, :build, [entries])

    with %{"id" => initial_id, "timestamp" => created} <- index.header,
         [] <- index.diagnostics,
         {:ok, {_leaf, nodes}} <- apply(Sigma.Session.Journal.Index, :path, [index, selector]),
         {:ok, windows, items} <-
           project_nodes(nodes, agent_name, [window(initial_id, 1, created)], []) do
      items = Enum.sort_by(items, &{&1.ordinal, &1.part, &1.created_at})

      windows =
        Enum.map(windows, fn window ->
          Map.put(window, :item_count, Enum.count(items, &(&1.window_id == window.window_id)))
        end)

      {:ok, %{agent_name: agent_name, windows: windows, items: items}}
    else
      {:error, %Error{}} = error -> error
      reason -> unavailable("history journal could not be normalized", reason)
    end
  end

  defp project_nodes([], _agent, windows, items), do: {:ok, Enum.reverse(windows), items}

  defp project_nodes(
         [%{entry: %{"type" => "context_window"} = entry} | rest],
         agent,
         windows,
         items
       ) do
    next = window(entry["id"], length(windows) + 1, entry["timestamp"])
    project_nodes(rest, agent, [next | windows], items)
  end

  defp project_nodes(
         [%{entry: %{"type" => "message"} = entry} = node | rest],
         agent,
         windows,
         items
       ) do
    with {:ok, message} <- apply(Sigma.Session.EntryDecoder, :message, [entry]),
         {:ok, normalized} <- message_items(message, node, agent, hd(windows).window_id) do
      project_nodes(rest, agent, windows, normalized ++ items)
    else
      {:error, reason} -> unavailable("history message could not be normalized", reason)
    end
  end

  defp project_nodes([_node | rest], agent, windows, items),
    do: project_nodes(rest, agent, windows, items)

  defp window(id, ordinal, created), do: %{window_id: id, ordinal: ordinal, created_at: created}

  defp message_items(message, node, agent, window_id) do
    role =
      case message.role do
        :tool_result -> "tool"
        :thought -> "assistant"
        value when value in [:user, :assistant, :system, :developer] -> to_string(value)
        _ -> nil
      end

    base = %{
      id: node.entry["id"],
      message_id: message.id,
      window_id: window_id,
      agent_name: agent,
      ordinal: node.entry_index,
      part: 0,
      created_at: node.entry["timestamp"],
      role: role,
      tool_namespace: nil,
      tool_name: nil,
      canonical_tool_name: nil
    }

    cond do
      is_nil(role) ->
        {:ok, []}

      role == "tool" ->
        {:ok, [item(callable(base, message.tool_name), message.content)]}

      role == "assistant" and is_list(message.content) ->
        {calls, ordinary} = Enum.split_with(message.content, &(&1[:type] == :tool_call))
        text = if ordinary == [], do: [], else: [item(base, ordinary)]

        calls =
          calls
          |> Enum.with_index(1)
          |> Enum.map(fn {call, part} ->
            arguments =
              if is_binary(call.arguments),
                do: call.arguments,
                else: Jason.encode!(call.arguments)

            base
            |> Map.merge(%{id: base.id <> ":call:#{part}", part: part})
            |> callable(call.name)
            |> item(call.name <> "\n" <> arguments)
          end)

        {:ok, text ++ calls}

      true ->
        {:ok, [item(base, message.content)]}
    end
  end

  defp callable(base, name) when is_binary(name) do
    {namespace, tool_name} =
      case String.split(name, "::", parts: 2) do
        [namespace, tool_name] -> {namespace, tool_name}
        [tool_name] -> {nil, tool_name}
      end

    Map.merge(base, %{tool_namespace: namespace, tool_name: tool_name, canonical_tool_name: name})
  end

  defp callable(base, _name), do: base

  defp item(base, content) do
    {text, images} = item_content(content)
    Map.merge(base, %{content: text, images: images, n_chars: scalar_length(text)})
  end

  defp item_content(text) when is_binary(text), do: {text, []}

  defp item_content(blocks) when is_list(blocks) do
    text =
      Enum.map_join(blocks, "", fn
        %{type: :text, text: text} -> text
        %{type: :thinking, thinking: text} when is_binary(text) -> text
        _ -> ""
      end)

    images =
      Enum.flat_map(blocks, fn
        %{type: :image, data: _data, mime_type: _mime} = image ->
          [Map.take(image, [:type, :data, :mime_type, :detail])]

        _ ->
          []
      end)

    {text, images}
  end

  defp item_content(nil), do: {"", []}

  defp dispatch("history::list_windows", args, selected) do
    with {:ok, limit} <- positive(args, "limit", 100) do
      {:ok,
       %{
         agent_name: selected.agent_name,
         windows: ordered(selected.windows, args["recent_first"]) |> Enum.take(limit)
       }}
    end
  end

  defp dispatch("history::list_items", args, selected) do
    with {:ok, limit} <- positive(args, "limit", 100),
         {:ok, max_chars} <- positive(args, "max_chars_per_item", 1_000),
         :ok <- fields(args, @filters ++ ["max_chars_per_item"]) do
      items =
        selected.items |> filtered(args) |> Enum.take(limit) |> Enum.map(&preview(&1, max_chars))

      {:ok, %{agent_name: selected.agent_name, items: items}}
    end
  end

  defp dispatch("history::search_contents", args, selected) do
    with {:ok, limit} <- positive(args, "limit", 100),
         query when is_binary(query) <- args["query"],
         :ok <- fields(args, @filters ++ ["query"]) do
      items =
        selected.items
        |> filtered(args)
        |> Enum.filter(&String.contains?(&1.content, query))
        |> Enum.take(limit)
        |> Enum.map(&preview(&1, 1_000))

      {:ok, %{agent_name: selected.agent_name, items: items}}
    else
      {:error, _} = error -> error
      _ -> error(:validation, "history query must be a string")
    end
  end

  defp dispatch("history::read_item", args, selected) do
    with {:ok, offset} <- nonnegative(args, "offset_chars", 0),
         {:ok, limit} <- positive(args, "limit_chars", 20_000),
         %{} = item <-
           Enum.find(
             selected.items,
             &(&1.id == args["item_id"] and &1.window_id == args["window_id"])
           ) do
      content = scalar_slice(item.content, offset, limit)
      next = min(offset + scalar_length(content), item.n_chars)

      {:ok,
       %{
         item: Map.drop(item, [:content, :images, :part]),
         content: content,
         images: item.images,
         n_chars: item.n_chars,
         offset_chars: offset,
         next_offset_chars: if(next < item.n_chars, do: next),
         truncated: next < item.n_chars
       }}
    else
      nil -> error(:not_found, "history item was not found in the selected window")
      {:error, _} = error -> error
    end
  end

  defp dispatch(_name, _args, _selected),
    do: error(:unsupported_capability, "unknown history tool")

  defp filtered(items, args) do
    Enum.filter(items, fn item ->
      Enum.all?(~w(role tool_namespace window_id), fn field ->
        key =
          case field do
            "role" -> :role
            "tool_namespace" -> :tool_namespace
            "window_id" -> :window_id
          end

        is_nil(args[field]) or item[key] == args[field]
      end) and
        (is_nil(args["tool_name"]) or
           args["tool_name"] in [item.tool_name, item.canonical_tool_name])
    end)
    |> ordered(args["recent_first"])
  end

  defp ordered(items, true), do: Enum.reverse(items)
  defp ordered(items, _), do: items

  defp preview(item, limit) do
    item
    |> Map.drop([:content, :images, :part])
    |> Map.put(:truncated_content, scalar_slice(item.content, 0, limit))
    |> Map.put(:truncated, item.n_chars > limit)
    |> Map.put(:image_count, length(item.images))
  end

  defp positive(args, key, default), do: integer(args, key, default, 1)
  defp nonnegative(args, key, default), do: integer(args, key, default, 0)

  defp integer(args, key, default, minimum) do
    case Map.get(args, key, default) do
      value when is_integer(value) and value >= minimum -> {:ok, value}
      _ -> error(:validation, "#{key} must be an integer at least #{minimum}")
    end
  end

  defp fields(args, allowed) do
    if Enum.all?(Map.keys(args), &(&1 in allowed)),
      do: :ok,
      else: error(:validation, "unsupported history argument")
  end

  defp scalar_length(text), do: text |> String.codepoints() |> length()

  defp scalar_slice(text, offset, limit),
    do: text |> String.codepoints() |> Enum.slice(offset, limit) |> Enum.join()

  defp error(class, message), do: {:error, Error.new(class, message)}

  defp unavailable(message, reason),
    do: {:error, Error.new(:execution_failure, message, cause: reason)}
end
