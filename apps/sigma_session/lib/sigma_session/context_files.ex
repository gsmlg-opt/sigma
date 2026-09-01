defmodule Sigma.Session.ContextFiles do
  @moduledoc """
  Assembles project context from repo-local instruction files.

  Walks from filesystem root down to `cwd`. In each directory, prefers
  `AGENTS.md`; falls back to `CLAUDE.md` only when `AGENTS.md` is absent.
  Files are concatenated after the global prompt, with `/`-rooted entries
  appearing first and `cwd` entries last — so deeper directories have
  higher attention precedence (matches upstream pi).

  Files are read once per discovery call. A running Agent changes context only
  through its explicit idle-only reload operation.
  """

  @candidates ["AGENTS.md", "CLAUDE.md"]
  @max_import_depth 8
  @max_file_bytes 65_536
  @max_total_bytes 524_288
  @max_sources 64
  @max_path_scopes 32
  @max_glob_bytes 256

  @doc """
  Returns assembled context: `global_prompt` followed by each
  discovered context file (tagged with its absolute path so the LLM can
  distinguish global rules from project rules).

  `global_prompt` may be `nil` or empty; either is treated as "no global
  section". `cwd` must be an absolute path.

  Options:
    * `:stop_at` — only include directories under this path during the
      walk (defaults to `nil`, meaning walk all the way to `/`).
  """
  @spec assemble(String.t() | nil, Path.t(), keyword()) :: String.t()
  def assemble(global_prompt, cwd, opts \\ []) do
    discover(global_prompt, cwd, opts).content
  end

  @doc """
  Discovers context sections with provenance, imports, scopes, diagnostics, and
  a deterministic composition trace.

  Directives are Markdown comments:

      <!-- sigma:import rules/common.md -->
      <!-- sigma:paths lib/**/*.ex,test/**/*.exs -->
      <!-- sigma:sticky -->
      <!-- sigma:disabled -->

  Imports are relative to and constrained beneath the importing file's
  directory. `:target_path` controls path-scoped selection and defaults to the
  active `cwd`. Sticky sections remain applicable outside their path scope.
  """
  def discover(global_prompt, cwd, opts \\ []) do
    cwd = Path.expand(cwd)
    opts = normalize_options(cwd, opts)

    initial = %{
      sections: global_sections(global_prompt),
      diagnostics: [],
      trace: global_trace(global_prompt),
      source_count: 0,
      total_bytes: byte_size(global_prompt || "")
    }

    state =
      Enum.reduce(walk_files(cwd, stop_at: opts.stop_at), initial, fn path, state ->
        load_source(path, nil, :project, 0, [], opts, state)
      end)

    content =
      state.sections
      |> Enum.filter(& &1.applied?)
      |> Enum.map(&render_section/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n\n")

    %{
      content: content,
      sections: state.sections,
      diagnostics: state.diagnostics,
      trace: state.trace,
      target_path: opts.target_path
    }
  end

  @doc "Returns the same discovery result intended for settings/debug previews."
  def preview(global_prompt, cwd, opts \\ []), do: discover(global_prompt, cwd, opts)

  @doc """
  Returns the list of context file paths the walk would include, in
  global-to-deepest order. Useful for tests and Settings previews.

  Options:
    * `:stop_at` — only include directories under this path during the
      walk (defaults to `nil`).
  """
  @spec walk_files(Path.t(), keyword()) :: [Path.t()]
  def walk_files(cwd, opts \\ []) do
    stop_at = opts |> Keyword.get(:stop_at) |> maybe_expand()

    cwd
    |> Path.expand()
    |> ancestors_oldest_first()
    |> Enum.filter(&below_or_equal?(&1, stop_at))
    |> Enum.map(&pick_file/1)
    |> Enum.reject(&is_nil/1)
  end

  defp maybe_expand(nil), do: nil
  defp maybe_expand(path), do: Path.expand(path)

  defp below_or_equal?(_dir, nil), do: true

  defp below_or_equal?(dir, root) do
    dir == root or String.starts_with?(dir, root <> "/")
  end

  defp ancestors_oldest_first(absolute_path) do
    absolute_path
    |> Path.split()
    |> Enum.scan("", fn segment, acc ->
      if acc == "", do: segment, else: Path.join(acc, segment)
    end)
  end

  defp pick_file(dir) do
    Enum.find_value(@candidates, fn name ->
      path = Path.join(dir, name)
      if File.regular?(path), do: path
    end)
  end

  defp normalize_options(cwd, opts) do
    %{
      target_path: opts |> Keyword.get(:target_path, cwd) |> Path.expand(),
      max_depth: min(Keyword.get(opts, :max_import_depth, @max_import_depth), @max_import_depth),
      max_file_bytes: min(Keyword.get(opts, :max_file_bytes, @max_file_bytes), @max_file_bytes),
      max_total_bytes: min(Keyword.get(opts, :max_total_bytes, @max_total_bytes), @max_total_bytes),
      max_sources: min(Keyword.get(opts, :max_sources, @max_sources), @max_sources),
      stop_at: Keyword.get(opts, :stop_at)
    }
  end

  defp global_sections(nil), do: []
  defp global_sections(""), do: []

  defp global_sections(text) do
    [
      %{
        kind: :global,
        source: "global_prompt",
        imported_from: nil,
        depth: 0,
        sticky?: true,
        paths: [],
        applied?: true,
        content: text
      }
    ]
  end

  defp global_trace(nil), do: []
  defp global_trace(""), do: []
  defp global_trace(_text), do: [%{action: :include, kind: :global, source: "global_prompt"}]

  defp load_source(path, imported_from, kind, depth, stack, opts, state) do
    cond do
      state.source_count >= opts.max_sources ->
        add_diagnostic(state, :source_limit, path, imported_from, depth)

      path in stack ->
        add_diagnostic(state, :cyclic_import, path, imported_from, depth)

      depth > opts.max_depth ->
        add_diagnostic(state, :import_depth_exceeded, path, imported_from, depth)

      true ->
        read_source(path, imported_from, kind, depth, stack, opts, state)
    end
  end

  defp read_source(path, imported_from, kind, depth, stack, opts, state) do
    remaining = max(opts.max_total_bytes - state.total_bytes, 0)
    read_limit = min(opts.max_file_bytes, remaining)

    result =
      File.open(path, [:read, :binary], fn io ->
        read_open_source(io, path, imported_from, read_limit)
      end)

    case result do
      {:ok, {:ok, content}} when byte_size(content) <= read_limit ->
        include_source(path, imported_from, kind, depth, stack, content, opts, state)

      {:ok, {:ok, _too_large}} ->
        kind = if remaining < opts.max_file_bytes, do: :context_budget_exceeded, else: :source_too_large
        add_diagnostic(state, kind, path, imported_from, depth)

      {:ok, {:error, reason}} ->
        add_diagnostic(state, :unreadable_source, path, imported_from, depth, reason)

      {:error, :enoent} ->
        add_diagnostic(
          state,
          if(imported_from, do: :missing_import, else: :missing_source),
          path,
          imported_from,
          depth
        )

      {:error, reason} ->
        add_diagnostic(state, :unreadable_source, path, imported_from, depth, reason)
    end
  end

  defp read_open_source(io, path, imported_from, read_limit) do
    with {:ok, real_path} <- resolve_components(path),
         :ok <- validate_import_root(real_path, imported_from),
         {:ok, open_info} <- :file.read_file_info(io),
         {:ok, path_info} <- :file.read_file_info(String.to_charlist(real_path)),
         true <- same_file?(open_info, path_info) do
      case IO.binread(io, read_limit + 1) do
        :eof -> {:ok, ""}
        content when is_binary(content) -> {:ok, content}
        {:error, reason} -> {:error, reason}
      end
    else
      false -> {:error, :source_changed_during_open}
      {:error, _reason} = error -> error
    end
  end

  defp validate_import_root(_real_path, nil), do: :ok

  defp validate_import_root(real_path, imported_from) do
    with {:ok, real_root} <- resolve_components(Path.dirname(imported_from)),
         true <- within_path?(real_path, real_root) do
      :ok
    else
      _outside -> {:error, :import_outside_source}
    end
  end

  defp same_file?(open_info, path_info) do
    {elem(open_info, 9), elem(open_info, 10), elem(open_info, 11)} ==
      {elem(path_info, 9), elem(path_info, 10), elem(path_info, 11)}
  end

  defp include_source(path, imported_from, kind, depth, stack, content, opts, state) do
    {directives, body, directive_diagnostics} = parse_directives(content, path)

    state =
      %{
        state
        | source_count: state.source_count + 1,
          total_bytes: state.total_bytes + byte_size(content),
          diagnostics: state.diagnostics ++ directive_diagnostics
      }

    if directives.disabled? do
      state
      |> add_diagnostic(:disabled_source, path, imported_from, depth)
      |> add_trace(:skip, kind, path, imported_from, depth, :disabled)
    else
      applied? = directives.sticky? or path_scope_matches?(directives.paths, path, opts.target_path)

      section = %{
        kind: kind,
        source: path,
        imported_from: imported_from,
        depth: depth,
        sticky?: directives.sticky?,
        paths: directives.paths,
        applied?: applied?,
        content: body
      }

      state =
        state
        |> Map.update!(:sections, &(&1 ++ [section]))
        |> add_trace(if(applied?, do: :include, else: :skip), kind, path, imported_from, depth, scope_reason(applied?))

      Enum.reduce(directives.imports, state, fn import, acc ->
        case resolve_import(path, import) do
          {:ok, import_path} ->
            load_source(import_path, path, :import, depth + 1, [path | stack], opts, acc)

          {:error, reason} ->
            add_diagnostic(acc, reason, import, path, depth + 1)
        end
      end)
    end
  end

  defp parse_directives(content, source) do
    initial = {%{imports: [], paths: [], sticky?: false, disabled?: false}, [], []}

    {directives, body_lines, diagnostics} =
      content
      |> String.split("\n", trim: false)
      |> Enum.reduce(initial, fn line, {directives, body, diagnostics} ->
        case parse_directive(line) do
          {:import, value} ->
            {%{directives | imports: directives.imports ++ [value]}, body, diagnostics}

          {:paths, values} ->
            valid = Enum.filter(values, &valid_glob?/1) |> Enum.take(@max_path_scopes)

            diagnostics =
              if length(valid) == length(values) and length(values) <= @max_path_scopes,
                do: diagnostics,
                else: diagnostics ++ [diagnostic(:invalid_path_scope, source, nil, 0)]

            {%{directives | paths: directives.paths ++ valid}, body, diagnostics}

          :sticky ->
            {%{directives | sticky?: true}, body, diagnostics}

          :disabled ->
            {%{directives | disabled?: true}, body, diagnostics}

          :none ->
            {directives, body ++ [line], diagnostics}
        end
      end)

    {directives, Enum.join(body_lines, "\n"), diagnostics}
  end

  defp parse_directive(line) do
    cond do
      Regex.match?(~r/^\s*<!--\s*sigma:sticky\s*-->\s*$/, line) ->
        :sticky

      Regex.match?(~r/^\s*<!--\s*sigma:disabled\s*-->\s*$/, line) ->
        :disabled

      match = Regex.run(~r/^\s*<!--\s*sigma:import\s+(.+?)\s*-->\s*$/, line) ->
        {:import, match |> Enum.at(1) |> String.trim()}

      match = Regex.run(~r/^\s*<!--\s*sigma:paths\s+(.+?)\s*-->\s*$/, line) ->
        values =
          match
          |> Enum.at(1)
          |> String.split(",", trim: true)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))

        {:paths, values}

      true ->
        :none
    end
  end

  defp resolve_import(source, import) do
    source_dir = Path.dirname(source)

    cond do
      import == "" or byte_size(import) > 512 or String.contains?(import, <<0>>) ->
        {:error, :invalid_import}

      Path.type(import) != :relative ->
        {:error, :import_outside_source}

      true ->
        expanded = Path.expand(import, source_dir)
        relative = Path.relative_to(expanded, source_dir)

        if relative == ".." or String.starts_with?(relative, "../") do
          {:error, :import_outside_source}
        else
          with {:ok, real_source_dir} <- resolve_components(source_dir),
               {:ok, real_import} <- resolve_components(expanded),
               true <- within_path?(real_import, real_source_dir) do
            {:ok, real_import}
          else
            _outside_or_loop -> {:error, :import_outside_source}
          end
        end
    end
  end

  defp resolve_components(path, depth \\ 0)

  defp resolve_components(_path, depth) when depth >= 40, do: {:error, :symlink_loop}

  defp resolve_components(path, depth) do
    path
    |> Path.expand()
    |> Path.split()
    |> Enum.reduce_while({:ok, ""}, fn segment, {:ok, resolved} ->
      candidate = if resolved == "", do: segment, else: Path.join(resolved, segment)

      case File.read_link(candidate) do
        {:ok, target} ->
          target =
            if Path.type(target) == :absolute,
              do: target,
              else: Path.expand(target, Path.dirname(candidate))

          case resolve_components(target, depth + 1) do
            {:ok, real_target} -> {:cont, {:ok, real_target}}
            {:error, _reason} = error -> {:halt, error}
          end

        {:error, _reason} ->
          {:cont, {:ok, candidate}}
      end
    end)
  end

  defp within_path?(path, root) do
    path == root or String.starts_with?(path, root <> "/")
  end

  defp path_scope_matches?([], _source, _target_path), do: true

  defp path_scope_matches?(paths, source, target_path) do
    relative = Path.relative_to(target_path, Path.dirname(source))
    Enum.any?(paths, &glob_match?(&1, relative))
  end

  defp valid_glob?(glob) do
    is_binary(glob) and glob != "" and byte_size(glob) <= @max_glob_bytes and
      not String.contains?(glob, <<0>>)
  end

  defp glob_match?(glob, path) do
    pattern =
      glob
      |> Regex.escape()
      |> String.replace("\\*\\*", ".*")
      |> String.replace("\\*", "[^/]*")
      |> String.replace("\\?", "[^/]")

    case Regex.compile("^#{pattern}$") do
      {:ok, regex} -> Regex.match?(regex, path)
      {:error, _reason} -> false
    end
  end

  defp scope_reason(true), do: :matched
  defp scope_reason(false), do: :path_scope_mismatch

  defp render_section(%{kind: :global, content: content}), do: content
  defp render_section(%{source: source, content: content}), do: "# Context: #{source}\n\n#{content}"

  defp add_diagnostic(state, kind, source, imported_from, depth, reason \\ nil) do
    diagnostic = diagnostic(kind, source, imported_from, depth, reason)
    %{state | diagnostics: state.diagnostics ++ [diagnostic]}
  end

  defp diagnostic(kind, source, imported_from, depth, reason \\ nil) do
    %{
      kind: kind,
      source: source,
      imported_from: imported_from,
      depth: depth,
      reason: reason
    }
  end

  defp add_trace(state, action, kind, source, imported_from, depth, reason) do
    trace = %{
      action: action,
      kind: kind,
      source: source,
      imported_from: imported_from,
      depth: depth,
      reason: reason
    }

    %{state | trace: state.trace ++ [trace]}
  end
end
