defmodule Sigma.Agent.Backplane.MemoryResources do
  @moduledoc """
  User-scoped durable memory files behind public Backplane extension dispatch.

  The trusted host selects a Sigma memory root at startup. A unique registered
  process serializes this node's writes across Sessions; each invocation still
  needs a live public Session binding. Reads never create storage. Notes are
  exclusive new files, never updates to generated memories. A failed write or
  sync may leave a partial file and is reported as unknown outcome, without
  removal, overwrite or retry. File data is synced; directory sync and
  cross-node exclusion are not claimed.

  List cursors are process-local capabilities scoped to the binding, query and
  current directory revision. This deliberately strengthens pinned Codex's
  decimal-offset pagination. Each traversal occupies one of 256 slots for five
  minutes; signed offsets keep page retries stable without consuming more slots.
  File reads retain Codex's line-offset interface
  and 20,000 approximate-token middle truncation.

  Search reads the same durable tree, preserves Codex's tagged substring modes,
  line contexts and query ordering, and returns at most 200 matches per page.
  Its cursors use the same traversal lifetime as list, bound to the search input
  and complete ordered result revision.
  """

  use GenServer

  alias Backplane.AgentRuntime.Error
  alias Backplane.AgentRuntime.Codex.Session

  @list_limit 2_000
  @read_bytes 80_000
  @max_cursors 256
  @cursor_ttl_ms 300_000
  @note_filename ~r/^\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}-[a-z0-9][a-z0-9-]{0,79}\.md$/

  defmodule FileSystem do
    @moduledoc false
    alias Backplane.AgentRuntime.Error

    def create_exclusive(_context, path, contents) do
      case :file.open(String.to_charlist(path), [:write, :binary, :raw, :exclusive]) do
        {:ok, file} ->
          result =
            with :ok <- File.chmod(path, 0o600),
                 :ok <- :file.write(file, contents),
                 do: :file.sync(file)

          closed = :file.close(file)

          case {result, closed} do
            {:ok, :ok} ->
              :ok

            {error, close_error} ->
              {:error,
               Error.new(
                 :unknown_outcome,
                 "memory note creation is unconfirmed",
                 cause: {error, close_error}
               )}
          end

        {:error, :eexist} ->
          {:error, Error.new(:resource_conflict, "ad-hoc note already exists")}

        {:error, reason} ->
          {:error,
           Error.new(
             :execution_failure,
             "memory note creation failed",
             cause: reason
           )}
      end
    end
  end

  def start_link(opts) do
    with {:ok, root} <- root(opts[:root]),
         {:ok, filesystem} <- filesystem(opts[:filesystem]) do
      GenServer.start_link(__MODULE__, {root, filesystem}, name: via(root))
    end
  end

  @doc "Obtains the application-owned writer shared by every Session using this root."
  def open(opts) do
    case DynamicSupervisor.start_child(Sigma.Agent.DynamicSupervisor, {__MODULE__, opts}) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, _} = error -> error
    end
  end

  def execute(operation, _scope, %{resources: resources, binding: binding})
      when is_map(operation) and is_pid(resources) and is_map(binding) do
    with :ok <- operation_identity(operation),
         {:ok, _} <- validate_binding(binding, operation) do
      call_host(resources, binding, operation)
    end
  end

  def execute(_operation, _scope, _context),
    do: error(:unsupported_capability, "memory resource host and Session binding are required")

  @impl true
  def init({root, filesystem}), do: {:ok, %{root: root, filesystem: filesystem, cursors: %{}}}

  @impl true
  def handle_call({:execute, binding, operation}, _from, state) do
    result =
      with {:ok, _} <- validate_binding(binding, operation),
           :ok <- reject_symlinks(state.root) do
        dispatch(operation.tool_name, operation.arguments, binding, expire(state))
      end

    case result do
      {:error, %Error{}} = error -> {:reply, error, state}
      {reply, next} when is_map(next) -> {:reply, reply, next}
    end
  end

  defp dispatch("memories::list", args, binding, state) do
    result =
      with :ok <- fields(args, ~w(path cursor max_results)),
           {:ok, path} <- optional_string(args, "path"),
           {:ok, cursor} <- optional_string(args, "cursor"),
           {:ok, limit} <- positive(args, "max_results", @list_limit),
           {:ok, absolute, canonical, metadata} <- resolve(state.root, path),
           {:ok, entries, revision} <- entries(state.root, absolute, metadata),
           query = {canonical, min(limit, @list_limit)},
           {:ok, offset, traversal} <- cursor_offset(state, cursor, binding, query, revision) do
        paginate(state, path, entries, offset, query, revision, binding, traversal)
      end

    case result do
      {{status, _}, _} when status in [:ok, :error] -> result
      {:error, _} = error -> {error, state}
    end
  end

  defp dispatch("memories::read", args, _binding, state) do
    result =
      with :ok <- fields(args, ~w(path line_offset max_lines)),
           {:ok, path} <- required_string(args, "path"),
           {:ok, offset} <- positive(args, "line_offset", 1),
           {:ok, max_lines} <- positive(args, "max_lines", nil),
           {:ok, absolute, _canonical, metadata} <- resolve(state.root, path),
           :ok <- regular_file(metadata),
           {:ok, contents} <- read_text(absolute),
           {:ok, selected, suffix?} <- select_lines(contents, offset, max_lines) do
        content = truncate(selected)

        {:ok,
         %{
           path: path,
           start_line_number: offset,
           content: content,
           truncated: suffix? or content != selected
         }}
      end

    {result, state}
  end

  defp dispatch("memories::add_ad_hoc_note", args, _binding, state) do
    result =
      with :ok <- fields(args, ~w(filename note)),
           {:ok, filename} <- required_string(args, "filename"),
           {:ok, note} <- required_string(args, "note"),
           :ok <- valid_note(filename, note),
           {:ok, directory} <- notes_directory(state.root),
           path = Path.join(directory, filename),
           :ok <- absent(path),
           :ok <- create(state.filesystem, path, note),
           do: {:ok, %{}}

    {result, state}
  end

  defp dispatch("memories::search", args, binding, state) do
    result =
      with :ok <-
             fields(
               args,
               ~w(queries match_mode path cursor context_lines case_sensitive normalized max_results)
             ),
           {:ok, queries} <- search_queries(args["queries"]),
           {:ok, mode} <- search_mode(Map.get(args, "match_mode", %{"type" => "any"})),
           {:ok, path} <- optional_string(args, "path"),
           {:ok, cursor} <- optional_string(args, "cursor"),
           {:ok, context_lines} <- nonnegative(args, "context_lines", 0),
           {:ok, sensitive?} <- boolean(args, "case_sensitive", true),
           {:ok, normalized?} <- boolean(args, "normalized", false),
           {:ok, limit} <- positive(args, "max_results", 200),
           prepared = Enum.map(queries, &search_comparison(&1, sensitive?, normalized?)),
           :ok <- searchable_queries(prepared),
           {:ok, absolute, canonical, metadata} <- resolve(state.root, path),
           matcher = %{
             queries: queries,
             prepared: prepared,
             mode: mode,
             context_lines: context_lines,
             sensitive?: sensitive?,
             normalized?: normalized?
           },
           {:ok, matches} <- search_entries(state.root, absolute, metadata, matcher),
           matches = Enum.sort_by(matches, &{&1.path, &1.match_line_number}),
           query =
             {{:search, canonical, queries, mode, context_lines, sensitive?, normalized?},
              min(limit, 200)},
           revision = digest(matches),
           {:ok, offset, traversal} <- cursor_offset(state, cursor, binding, query, revision) do
        search_page(state, path, matcher, matches, offset, query, revision, binding, traversal)
      end

    case result do
      {{status, _}, _} when status in [:ok, :error] -> result
      {:error, _} = error -> {error, state}
    end
  end

  defp dispatch(_name, _args, _binding, state),
    do: {error(:unsupported_capability, "memory tool is not supported by this host"), state}

  defp operation_identity(%{
         run_id: run,
         incarnation: incarnation,
         tool_name: name,
         arguments: args
       })
       when is_binary(run) and is_integer(incarnation) and is_binary(name) and is_map(args),
       do: :ok

  defp operation_identity(_), do: error(:validation, "invalid memory operation")

  defp validate_binding(binding, operation) do
    Session.validate(binding, operation)
  catch
    :exit, _ -> error(:cancelled, "memory Session is unavailable before dispatch")
  end

  defp call_host(resources, binding, operation) do
    GenServer.call(resources, {:execute, binding, operation}, :infinity)
  catch
    :exit, _ ->
      if operation.tool_name == "memories::add_ad_hoc_note",
        do: error(:unknown_outcome, "memory note dispatch exited before acknowledgement"),
        else: error(:cancelled, "memory resource host is unavailable")
  end

  defp fields(args, allowed) when is_map(args) do
    if Enum.all?(Map.keys(args), &(&1 in allowed)),
      do: :ok,
      else: error(:validation, "unsupported memory argument")
  end

  defp fields(_args, _allowed), do: error(:validation, "memory arguments must be an object")

  defp optional_string(args, key) do
    case Map.fetch(args, key) do
      :error -> {:ok, nil}
      {:ok, value} when is_binary(value) -> {:ok, value}
      _ -> error(:validation, "#{key} must be a string")
    end
  end

  defp required_string(args, key) do
    case Map.get(args, key) do
      value when is_binary(value) -> {:ok, value}
      _ -> error(:validation, "#{key} is required")
    end
  end

  defp positive(args, key, default) do
    case Map.fetch(args, key) do
      :error -> {:ok, default}
      {:ok, value} when is_integer(value) and value > 0 -> {:ok, value}
      _ -> error(:validation, "#{key} must be a positive integer")
    end
  end

  defp nonnegative(args, key, default) do
    case Map.get(args, key, default) do
      value when is_integer(value) and value >= 0 -> {:ok, value}
      _ -> error(:validation, "#{key} must be a nonnegative integer")
    end
  end

  defp boolean(args, key, default) do
    case Map.get(args, key, default) do
      value when is_boolean(value) -> {:ok, value}
      _ -> error(:validation, "#{key} must be a boolean")
    end
  end

  defp search_queries(queries) when is_list(queries) and queries != [] do
    if Enum.all?(queries, &(is_binary(&1) and String.valid?(&1))) do
      trimmed = Enum.map(queries, &String.trim/1)

      with :ok <- searchable_queries(trimmed), do: {:ok, trimmed}
    else
      error(:validation, "queries must contain nonempty strings")
    end
  end

  defp search_queries(_), do: error(:validation, "queries must contain nonempty strings")

  defp searchable_queries(queries) do
    if Enum.any?(queries, &(&1 == "")),
      do: error(:validation, "queries must contain searchable characters"),
      else: :ok
  end

  defp search_mode(%{"type" => type} = mode)
       when type in ["any", "all_on_same_line"] and map_size(mode) == 1,
       do: {:ok, mode}

  defp search_mode(%{"type" => "all_within_lines", "line_count" => count} = mode)
       when is_integer(count) and count >= 1 and map_size(mode) == 2,
       do: {:ok, mode}

  defp search_mode(_), do: error(:validation, "invalid memory search match mode")

  defp search_comparison(value, sensitive?, normalized?) do
    value = if sensitive?, do: value, else: String.downcase(value)
    if normalized?, do: String.replace(value, ~r/[^\p{Alphabetic}\p{N}]/u, ""), else: value
  end

  defp search_entries(root, path, %{type: :regular}, matcher) do
    case File.read(path) do
      {:ok, contents} ->
        matches =
          if String.valid?(contents),
            do: search_file(Path.relative_to(path, root), contents, matcher),
            else: []

        {:ok, matches}

      {:error, reason} ->
        io_error("memory search file read failed", reason)
    end
  end

  defp search_entries(root, path, %{type: :directory} = metadata, matcher) do
    with {:ok, entries, _revision} <- entries(root, path, metadata) do
      Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, matches} ->
        case resolve(root, entry.path) do
          {:ok, absolute, _canonical, metadata} ->
            case search_entries(root, absolute, metadata, matcher) do
              {:ok, found} -> {:cont, {:ok, found ++ matches}}
              error -> {:halt, error}
            end

          {:error, %Error{class: :not_found}} ->
            {:cont, {:ok, matches}}

          error ->
            {:halt, error}
        end
      end)
    end
  end

  defp search_entries(_root, _path, _metadata, _matcher), do: {:ok, []}

  defp search_file(path, contents, matcher) do
    lines = String.split(contents, ~r/\r?\n/, trim: false)
    lines = if List.last(lines) == "", do: Enum.drop(lines, -1), else: lines

    flags =
      Enum.map(lines, fn line ->
        source = search_comparison(line, matcher.sensitive?, matcher.normalized?)
        Enum.map(matcher.prepared, &String.contains?(source, &1))
      end)

    flags
    |> search_windows(matcher.mode)
    |> Enum.map(fn {first, last, matched} ->
      start = max(first - matcher.context_lines, 0)
      stop = min(last + matcher.context_lines + 1, length(lines))

      %{
        path: path,
        match_line_number: first + 1,
        content_start_line_number: start + 1,
        content: lines |> Enum.slice(start, stop - start) |> Enum.join("\n"),
        matched_queries:
          matcher.queries
          |> Enum.zip(matched)
          |> Enum.flat_map(fn
            {query, true} -> [query]
            {_query, false} -> []
          end)
      }
    end)
  end

  defp search_windows(flags, %{"type" => type}) when type in ["any", "all_on_same_line"] do
    predicate = if type == "any", do: &Enum.any?/1, else: &Enum.all?/1

    flags
    |> Enum.with_index()
    |> Enum.filter(fn {matched, _index} -> predicate.(matched) end)
    |> Enum.map(fn {matched, index} -> {index, index, matched} end)
  end

  defp search_windows(flags, %{"type" => "all_within_lines", "line_count" => count}) do
    windows =
      flags
      |> Enum.with_index()
      |> Enum.flat_map(fn {matched, first} ->
        if Enum.any?(matched), do: matching_window(flags, first, count), else: []
      end)

    Enum.reject(windows, fn {first, last, _matched} ->
      Enum.any?(windows, fn {other_first, other_last, _matched} ->
        first <= other_first and last >= other_last and
          (first != other_first or last != other_last)
      end)
    end)
  end

  defp matching_window(flags, first, count) do
    flags
    |> Enum.drop(first)
    |> Enum.take(count)
    |> Enum.with_index(first)
    |> Enum.reduce_while(nil, fn {matched, last}, accumulated ->
      combined =
        if is_nil(accumulated),
          do: matched,
          else: Enum.zip_with(accumulated, matched, fn left, right -> left or right end)

      if Enum.all?(combined),
        do: {:halt, {first, last, combined}},
        else: {:cont, combined}
    end)
    |> case do
      {_first, _last, _matched} = window -> [window]
      _incomplete -> []
    end
  end

  defp search_page(state, path, matcher, matches, offset, query, revision, binding, traversal) do
    case paginate(state, path, matches, offset, query, revision, binding, traversal) do
      {{:ok, result}, next} ->
        response = %{
          queries: matcher.queries,
          match_mode: matcher.mode,
          path: path,
          matches: result.entries,
          next_cursor: result.next_cursor,
          truncated: result.truncated
        }

        {{:ok, response}, next}

      error ->
        error
    end
  end

  defp root(path) when is_binary(path) do
    if Path.type(path) == :absolute do
      expanded = Path.expand(path)
      with :ok <- reject_symlinks(path), :ok <- reject_symlinks(expanded), do: {:ok, expanded}
    else
      error(:validation, "memory root must be absolute")
    end
  end

  defp root(_), do: error(:validation, "memory root must be absolute")

  defp resolve(root, path) do
    relative = path || ""
    components = Path.split(relative)

    cond do
      not String.valid?(relative) or String.contains?(relative, <<0>>) ->
        error(:validation, "invalid memory path")

      Path.type(relative) == :absolute or ".." in components ->
        error(:validation, "memory path must stay within its root")

      Enum.any?(components, &(&1 != "." and String.starts_with?(&1, "."))) ->
        error(:not_found, "memory path was not found")

      true ->
        absolute = Path.expand(relative, root)
        canonical = Path.relative_to(absolute, root)

        with :ok <- reject_symlinks(absolute),
             {:ok, metadata} <- metadata(absolute),
             do: {:ok, absolute, canonical, metadata}
    end
  end

  defp reject_symlinks(path) do
    [root | parts] = Path.split(path)

    Enum.reduce_while(parts, root, fn part, parent ->
      current = Path.join(parent, part)

      case File.lstat(current) do
        {:ok, %{type: :symlink}} ->
          {:halt, error(:validation, "memory path must not contain symbolic links")}

        {:ok, _} ->
          {:cont, current}

        {:error, :enoent} ->
          {:cont, current}

        {:error, reason} ->
          {:halt, io_error("memory path is unavailable", reason)}
      end
    end)
    |> case do
      {:error, _} = error -> error
      _ -> :ok
    end
  end

  defp metadata(path) do
    case File.lstat(path, time: :posix) do
      {:ok, stat} -> {:ok, stat}
      {:error, :enoent} -> error(:not_found, "memory path was not found")
      {:error, reason} -> io_error("memory metadata read failed", reason)
    end
  end

  defp entries(root, path, %{type: :regular} = stat),
    do:
      {:ok, [%{path: Path.relative_to(path, root), entry_type: "file"}],
       digest([{path, revision(stat)}])}

  defp entries(root, path, %{type: :directory}) do
    with {:ok, names} <- File.ls(path) do
      names
      |> Enum.reject(&String.starts_with?(&1, "."))
      |> Enum.sort()
      |> Enum.reduce_while({:ok, [], []}, fn name, {:ok, entries, revisions} ->
        absolute = Path.join(path, name)

        case File.lstat(absolute, time: :posix) do
          {:ok, %{type: type} = stat} when type in [:regular, :directory] ->
            entry = %{
              path: Path.relative_to(absolute, root),
              entry_type: if(type == :regular, do: "file", else: "directory")
            }

            {:cont, {:ok, [entry | entries], [{entry, revision(stat)} | revisions]}}

          {:ok, _} ->
            {:cont, {:ok, entries, revisions}}

          {:error, :enoent} ->
            {:cont, {:ok, entries, revisions}}

          {:error, reason} ->
            {:halt, io_error("memory directory read failed", reason)}
        end
      end)
      |> case do
        {:ok, entries, revisions} -> {:ok, Enum.reverse(entries), digest(revisions)}
        error -> error
      end
    else
      {:error, reason} -> io_error("memory directory read failed", reason)
    end
  end

  defp entries(_root, _path, _metadata), do: {:ok, [], digest([])}

  defp digest(value), do: :crypto.hash(:sha256, :erlang.term_to_binary(value))
  defp revision(stat), do: Map.take(stat, [:type, :inode, :size, :mtime, :ctime, :mode])

  defp cursor_offset(_state, nil, _binding, _query, _revision), do: {:ok, 0, nil}

  defp cursor_offset(state, cursor, binding, query, revision) do
    with [id, encoded] <- String.split(cursor, ".", parts: 2),
         %{secret: secret} = saved <- state.cursors[id],
         {:ok, <<offset::unsigned-64, mac::binary-size(32)>>} <-
           Base.url_decode64(encoded, padding: false),
         true <-
           :crypto.hash_equals(:crypto.mac(:hmac, :sha256, secret, <<offset::unsigned-64>>), mac) do
      cond do
        saved.owner != owner(binding) ->
          error(:forbidden, "memory cursor belongs to another Session run")

        saved.query != query ->
          error(:validation, "memory cursor query differs")

        saved.revision != revision ->
          error(:resource_conflict, "memory directory changed during pagination")

        true ->
          {:ok, offset, id}
      end
    else
      _ -> error(:validation, "unknown, expired or invalid memory cursor")
    end
  end

  defp paginate(
         state,
         path,
         entries,
         offset,
         {_canonical, limit} = query,
         revision,
         binding,
         traversal
       ) do
    page = Enum.slice(entries, offset, limit)
    next = offset + length(page)

    if next < length(entries) do
      if is_nil(traversal) and map_size(state.cursors) >= @max_cursors do
        {error(:overloaded, "memory cursor capacity reached"), state}
      else
        id = traversal || Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

        saved =
          state.cursors[id] ||
            %{
              owner: owner(binding),
              query: query,
              revision: revision,
              secret: :crypto.strong_rand_bytes(32),
              expires_at: System.monotonic_time(:millisecond) + @cursor_ttl_ms
            }

        mac = :crypto.mac(:hmac, :sha256, saved.secret, <<next::unsigned-64>>)

        cursor =
          id <> "." <> Base.url_encode64(<<next::unsigned-64, mac::binary>>, padding: false)

        response = %{path: path, entries: page, next_cursor: cursor, truncated: true}
        {{:ok, response}, %{state | cursors: Map.put(state.cursors, id, saved)}}
      end
    else
      {{:ok, %{path: path, entries: page, next_cursor: nil, truncated: false}}, state}
    end
  end

  defp owner(binding),
    do:
      Map.take(
        binding,
        [:session, :token, :owner_id, :incarnation, :run_id, :run_incarnation]
      )

  defp expire(state) do
    now = System.monotonic_time(:millisecond)
    %{state | cursors: Map.reject(state.cursors, fn {_key, value} -> value.expires_at <= now end)}
  end

  defp regular_file(%{type: :regular}), do: :ok
  defp regular_file(_), do: error(:validation, "memory path is not a file")

  defp read_text(path) do
    case File.read(path) do
      {:ok, contents} ->
        if String.valid?(contents),
          do: {:ok, contents},
          else: io_error("memory file is not valid UTF-8", :invalid_data)

      {:error, reason} ->
        io_error("memory file read failed", reason)
    end
  end

  defp select_lines(contents, offset, max_lines) do
    starts = [0 | Enum.map(:binary.matches(contents, "\n"), fn {position, 1} -> position + 1 end)]

    if offset > length(starts) do
      error(:validation, "line_offset exceeds file length")
    else
      first = Enum.at(starts, offset - 1)

      last =
        if max_lines,
          do: Enum.at(starts, offset - 1 + max_lines, byte_size(contents)),
          else: byte_size(contents)

      {:ok, binary_part(contents, first, last - first), last < byte_size(contents)}
    end
  end

  defp truncate(contents) when byte_size(contents) <= @read_bytes, do: contents

  defp truncate(contents) do
    prefix = utf8_prefix(contents, div(@read_bytes, 2))
    suffix = utf8_suffix(contents, byte_size(contents) - div(@read_bytes, 2))
    tokens = div(byte_size(contents) - @read_bytes + 3, 4)
    prefix <> "…#{tokens} tokens truncated…" <> suffix
  end

  defp utf8_prefix(contents, bytes) do
    prefix = binary_part(contents, 0, bytes)
    if String.valid?(prefix), do: prefix, else: utf8_prefix(contents, bytes - 1)
  end

  defp utf8_suffix(contents, offset) do
    suffix = binary_part(contents, offset, byte_size(contents) - offset)
    if String.valid?(suffix), do: suffix, else: utf8_suffix(contents, offset + 1)
  end

  defp valid_note(filename, note) do
    if byte_size(filename) in 24..128 and String.valid?(filename) and
         Regex.match?(@note_filename, filename) and
         String.valid?(note) and String.trim(note) != "",
       do: :ok,
       else: error(:validation, "invalid ad-hoc memory filename or note")
  end

  defp notes_directory(root) do
    [
      root,
      Path.join(root, "extensions"),
      Path.join(root, "extensions/ad_hoc"),
      Path.join(root, "extensions/ad_hoc/notes")
    ]
    |> Enum.reduce_while(:ok, fn path, :ok ->
      case ensure_directory(path) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
    |> case do
      :ok -> {:ok, Path.join(root, "extensions/ad_hoc/notes")}
      error -> error
    end
  end

  defp ensure_directory(path) do
    with :ok <- reject_symlinks(path) do
      case File.lstat(path) do
        {:ok, %{type: :directory}} ->
          :ok

        {:ok, _} ->
          error(:validation, "memory note path must be a directory")

        {:error, :enoent} ->
          case File.mkdir(path) do
            :ok ->
              case File.chmod(path, 0o700) do
                :ok -> :ok
                {:error, reason} -> io_error("new memory directory permissions failed", reason)
              end

            {:error, :eexist} ->
              ensure_directory(path)

            {:error, reason} ->
              io_error("memory directory creation failed", reason)
          end

        {:error, reason} ->
          io_error("memory directory is unavailable", reason)
      end
    end
  end

  defp absent(path) do
    case File.lstat(path) do
      {:error, :enoent} -> :ok
      {:ok, _} -> error(:resource_conflict, "ad-hoc note already exists")
      {:error, reason} -> io_error("memory note path is unavailable", reason)
    end
  end

  defp filesystem(nil), do: {:ok, {FileSystem, nil}}

  defp filesystem({module, context}) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :create_exclusive, 3),
      do: {:ok, {module, context}},
      else: error(:validation, "invalid memory filesystem")
  end

  defp filesystem(_), do: error(:validation, "invalid memory filesystem")

  defp create({module, context}, path, note) do
    case module.create_exclusive(context, path, note) do
      :ok -> :ok
      {:error, %Error{}} = error -> error
      _ -> error(:unknown_outcome, "memory note creation acknowledgement is invalid")
    end
  rescue
    _ -> error(:unknown_outcome, "memory note creation raised after dispatch")
  catch
    :exit, _ -> error(:unknown_outcome, "memory note creation exited after dispatch")
  end

  defp via(root),
    do: {:via, Registry, {Sigma.Agent.RepositoryRegistry, {:memory_resources, root}}}

  defp error(class, message), do: {:error, Error.new(class, message)}

  defp io_error(message, reason),
    do: {:error, Error.new(:execution_failure, message, cause: reason)}
end
