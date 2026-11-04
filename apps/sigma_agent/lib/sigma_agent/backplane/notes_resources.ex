defmodule Sigma.Agent.Backplane.NotesResources do
  @moduledoc """
  Rollout-scoped virtual notes shared by root and managed-child Sessions.

  One application-owned process serializes operations for an absolute root
  transcript. Every call reads `<transcript>.subagents/notes.json` again; no note
  contents survive in process state. Read-only calls never create storage.
  Existing session rename/adopt/delete operations move or remove this subtree,
  while forks start with an independent notes store.

  Writes sync a same-directory temporary file before atomic rename using the
  existing Store filesystem. Directory fsync and cross-node exclusion are not
  provided. Failed acknowledgements preserve the actual storage reason and are
  never retried. This host returns local JSON results; the pinned remote Codex
  backend does not specify a canonical output schema.

  Creation/update metadata uses Unix microseconds with persisted ordering. Result
  limits apply only when explicitly supplied. Line ranges count physical lines
  and retain their original LF/CRLF terminators; an empty file has zero lines.
  """

  use GenServer

  alias Backplane.AgentRuntime.Error
  alias Backplane.AgentRuntime.Codex.Session
  alias Sigma.Agent.Backplane.Store.FileSystem

  @max_file_bytes 1_000_000
  @writes ~w(notes::write_file notes::append_to_file)

  def start_link(opts) do
    case Keyword.get(opts, :root_transcript) do
      path when is_binary(path) and path != "" ->
        if Path.type(path) == :absolute do
          root = Path.expand(path)
          GenServer.start_link(__MODULE__, root, name: via(root))
        else
          error(:validation, "notes require an absolute root transcript")
        end

      _ ->
        error(:validation, "notes require an absolute root transcript")
    end
  end

  @doc "Obtains the application-owned writer without creating any files."
  def open(opts) do
    case DynamicSupervisor.start_child(Sigma.Agent.DynamicSupervisor, {__MODULE__, opts}) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, _} = error -> error
    end
  end

  def execute(operation, _scope, %{
        resources: resources,
        binding: binding,
        agent_name: agent
      })
      when is_pid(resources) and is_map(binding) and is_map(operation) do
    with :ok <- operation_identity(operation),
         :ok <- agent_name(agent),
         {:ok, _} <- validate_binding(binding, operation) do
      call_host(resources, binding, agent, operation)
    end
  end

  def execute(_operation, _scope, _context),
    do: error(:unsupported_capability, "notes require a resource host and Session binding")

  @impl true
  def init(root), do: {:ok, %{path: Path.join(root <> ".subagents", "notes.json")}}

  @impl true
  def handle_call({:execute, binding, agent, operation}, _from, state) do
    result =
      with {:ok, _} <- validate_binding(binding, operation),
           {:ok, notes} <- load(state.path) do
        dispatch(operation.tool_name, operation.arguments, agent, notes, state.path)
      end

    {:reply, result, state}
  end

  defp dispatch(name, args, agent, notes, store) when name in @writes do
    with {:ok, path} <- file_path(args["path"], agent),
         {:ok, text} <- text(args["text"]),
         previous = Map.get(notes, path),
         contents =
           if(name == "notes::append_to_file" and previous,
             do: previous["text"] <> text,
             else: text
           ),
         :ok <- file_size(contents),
         now = timestamp(notes),
         note = %{
           "text" => contents,
           "created_at" => if(previous, do: previous["created_at"], else: now),
           "updated_at" => now,
           "size_bytes" => byte_size(contents)
         },
         :ok <- save(store, Map.put(notes, path, note)) do
      {:ok, metadata(path, note)}
    end
  end

  defp dispatch("notes::read_file", args, agent, notes, _store) do
    with {:ok, path} <- file_path(args["path"], agent),
         {:ok, note} <- fetch(notes, path),
         {:ok, first} <- line_argument(args["start_line"]),
         {:ok, last} <- line_argument(args["stop_line"]) do
      lines = lines(note["text"])
      count = length(lines)
      start_index = line_index(first || 1, count)
      stop_index = line_index(last || count, count)

      contents =
        if count > 0 and start_index <= stop_index do
          lines
          |> Enum.slice(start_index, stop_index - start_index + 1)
          |> IO.iodata_to_binary()
        else
          ""
        end

      {:ok,
       metadata(path, note)
       |> Map.merge(%{contents: contents, n_lines: count})}
    end
  end

  defp dispatch("notes::list_files_by_prefix", args, agent, notes, _store) do
    with {:ok, prefix} <- prefix(args["prefix"], agent),
         {:ok, limit} <- limit(args["max_results"]),
         {:ok, field} <- order_field(Map.get(args, "file_order_by", "name")),
         {:ok, direction} <- order_direction(Map.get(args, "file_order", "ascending")) do
      files =
        notes
        |> Enum.filter(fn {path, _} -> String.starts_with?(path, prefix) end)
        |> Enum.map(fn {path, note} -> metadata(path, note) end)
        |> Enum.sort_by(&{Map.fetch!(&1, field), &1.path}, direction)
        |> take(limit)

      {:ok, %{files: files}}
    end
  end

  defp dispatch("notes::search_contents", args, agent, notes, _store) do
    with {:ok, query} <- text(args["query"]),
         {:ok, prefix} <- prefix(args["path_prefix"], agent),
         {:ok, max_files} <- limit(args["max_files"]),
         {:ok, max_matches} <- limit(args["max_matches_per_file"]),
         {:ok, recent?} <- boolean(Map.get(args, "recent_file_first", false)) do
      candidates = Enum.filter(notes, fn {path, _} -> String.starts_with?(path, prefix) end)

      candidates =
        if recent?,
          do: Enum.sort_by(candidates, fn {path, note} -> {-note["created_at"], path} end),
          else: Enum.sort_by(candidates, &elem(&1, 0))

      files =
        candidates
        |> Enum.flat_map(fn {path, note} ->
          matches =
            note["text"]
            |> lines()
            |> Enum.with_index(1)
            |> Enum.flat_map(fn {raw, number} ->
              line = line_content(raw)
              if String.contains?(line, query), do: [%{line: line, line_number: number}], else: []
            end)
            |> take(max_matches)

          if matches == [], do: [], else: [Map.put(metadata(path, note), :matches, matches)]
        end)
        |> take(max_files)

      {:ok, %{files: files}}
    end
  end

  defp dispatch(_name, _args, _agent, _notes, _store),
    do: error(:unsupported_capability, "notes operation is not supported")

  defp load(path) do
    case File.read(path) do
      {:ok, bytes} ->
        with {:ok, %{"version" => 1, "files" => files}} when is_map(files) <- Jason.decode(bytes),
             true <- Enum.all?(files, fn {path, note} -> stored_note?(path, note) end) do
          {:ok, files}
        else
          reason -> io_error("notes store is malformed", reason)
        end

      {:error, :enoent} ->
        {:ok, %{}}

      {:error, reason} ->
        io_error("notes store read failed", reason)
    end
  end

  defp stored_note?(path, %{
         "text" => contents,
         "size_bytes" => size,
         "created_at" => created,
         "updated_at" => updated
       })
       when is_binary(path) and is_binary(contents) and is_integer(created) and
              is_integer(updated),
       do: String.valid?(contents) and byte_size(contents) == size and size <= @max_file_bytes

  defp stored_note?(_path, _note), do: false

  defp save(path, notes) do
    with {:ok, bytes} <- Jason.encode(%{version: 1, files: notes}),
         :ok <- File.mkdir_p(Path.dirname(path)) do
      case FileSystem.write_atomic(path, bytes) do
        :ok ->
          :ok

        {:error, reason} ->
          {:error, Error.new(:unknown_outcome, "notes write is unconfirmed", cause: reason)}
      end
    else
      {:error, reason} -> io_error("notes store preparation failed", reason)
    end
  end

  defp metadata(path, note) do
    %{
      path: path,
      size_bytes: note["size_bytes"],
      created_at: note["created_at"],
      updated_at: note["updated_at"]
    }
  end

  defp timestamp(notes) do
    latest = Enum.reduce(notes, 0, fn {_path, note}, acc -> max(acc, note["updated_at"]) end)
    max(System.system_time(:microsecond), latest + 1)
  end

  defp agent_name(agent) when is_binary(agent) do
    case components(agent) do
      {:ok, ["root" | _]} ->
        if String.starts_with?(agent, "/"),
          do: :ok,
          else: error(:validation, "invalid current agent name")

      _ ->
        error(:validation, "invalid current agent name")
    end
  end

  defp agent_name(_), do: error(:validation, "invalid current agent name")

  defp file_path(path, agent) do
    with {:ok, canonical} <- virtual_path(path, agent),
         {:ok, parts} <- components(canonical),
         true <- Enum.any?(Enum.drop(parts, -1), &(&1 == "notes")) do
      {:ok, canonical}
    else
      {:error, _} = error -> error
      _ -> error(:validation, "note operations require a file path")
    end
  end

  defp prefix(nil, agent), do: {:ok, agent <> "/notes/"}
  defp prefix(path, agent), do: virtual_path(path, agent)

  defp virtual_path(path, agent) when is_binary(path) do
    canonical = if String.starts_with?(path, "/"), do: path, else: agent <> "/notes/" <> path

    with {:ok, ["root" | rest]} <- components(canonical),
         true <- "notes" in rest do
      {:ok, canonical}
    else
      _ -> error(:validation, "invalid virtual note path")
    end
  end

  defp virtual_path(_path, _agent), do: error(:validation, "note path must be a string")

  defp components(path) do
    relative =
      case path do
        "/" <> rest -> rest
        value -> value
      end

    parts = String.split(relative, "/", trim: false)

    if Enum.any?(parts, &(&1 in ["", ".", ".."])),
      do: error(:validation, "virtual path has an unsupported component"),
      else: {:ok, parts}
  end

  defp text(value) when is_binary(value) do
    if String.valid?(value), do: {:ok, value}, else: error(:validation, "note text must be UTF-8")
  end

  defp text(_value), do: error(:validation, "note text must be a string")

  defp file_size(text) when byte_size(text) <= @max_file_bytes, do: :ok
  defp file_size(_text), do: error(:budget_exceeded, "note exceeds 1000000 UTF-8 bytes")

  defp fetch(notes, path) do
    case Map.fetch(notes, path) do
      {:ok, note} -> {:ok, note}
      :error -> error(:not_found, "note not found")
    end
  end

  defp line_argument(nil), do: {:ok, nil}
  defp line_argument(value) when is_integer(value), do: {:ok, value}
  defp line_argument(_value), do: error(:validation, "line range must use integers")
  defp line_index(value, count) when value < 0, do: max(count + value, 0)
  defp line_index(value, _count), do: max(value - 1, 0)

  defp lines(""), do: []

  defp lines(text) do
    parts = String.split(text, "\n", trim: false)
    last = length(parts) - 1

    parts
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {"", ^last} -> []
      {part, ^last} -> [part]
      {part, _} -> [part <> "\n"]
    end)
  end

  defp line_content(raw) do
    if String.ends_with?(raw, "\r\n"),
      do: binary_part(raw, 0, byte_size(raw) - 2),
      else: String.trim_trailing(raw, "\n")
  end

  defp limit(nil), do: {:ok, nil}
  defp limit(value) when is_integer(value) and value >= 1, do: {:ok, value}
  defp limit(_value), do: error(:validation, "note result limit must be positive")
  defp take(values, nil), do: values
  defp take(values, limit), do: Enum.take(values, limit)
  defp boolean(value) when is_boolean(value), do: {:ok, value}
  defp boolean(_value), do: error(:validation, "recent_file_first must be boolean")
  defp order_field("name"), do: {:ok, :path}
  defp order_field("created_at"), do: {:ok, :created_at}
  defp order_field("updated_at"), do: {:ok, :updated_at}
  defp order_field(_field), do: error(:validation, "invalid notes ordering field")
  defp order_direction("ascending"), do: {:ok, :asc}
  defp order_direction("descending"), do: {:ok, :desc}
  defp order_direction(_direction), do: error(:validation, "invalid notes ordering direction")

  defp operation_identity(%{
         run_id: run,
         incarnation: incarnation,
         tool_name: name,
         arguments: args
       })
       when is_binary(run) and is_integer(incarnation) and is_binary(name) and is_map(args),
       do: :ok

  defp operation_identity(_operation), do: error(:validation, "invalid notes operation")

  defp validate_binding(binding, operation) do
    Session.validate(binding, operation)
  catch
    :exit, _ -> error(:cancelled, "notes Session is unavailable before dispatch")
  end

  defp call_host(resources, binding, agent, operation) do
    GenServer.call(resources, {:execute, binding, agent, operation}, :infinity)
  catch
    :exit, reason ->
      class = if operation.tool_name in @writes, do: :unknown_outcome, else: :cancelled
      {:error, Error.new(class, "notes host call did not acknowledge", cause: reason)}
  end

  defp via(root),
    do: {:via, Registry, {Sigma.Agent.RepositoryRegistry, {:notes_resources, root}}}

  defp error(class, message), do: {:error, Error.new(class, message)}

  defp io_error(message, reason),
    do: {:error, Error.new(:execution_failure, message, cause: reason)}
end
