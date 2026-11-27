defmodule Sigma.Agent.Backplane.SkillResources do
  @moduledoc """
  Executor-owned skill resources and remote creation for one Codex resource host.

  Listing pins catalog descriptors, not file contents. The first package read
  prepares a verified immutable bundle; text pages then share that bundle and
  one bounded content snapshot. Neither operation activates skills or executes
  bundled scripts. All handles expire with the run or the bounded cache TTL.
  """

  use GenServer
  require Logger

  alias Backplane.AgentRuntime.Error
  alias Backplane.AgentRuntime.Codex.Session
  alias Sigma.Agent.Backplane.PluginSkills
  alias Sigma.Session.Skills.{Catalog, RemoteAdapter, Snapshot}

  @list_page_size 20
  @text_page_bytes 16 * 1024
  @max_resource_bytes 5 * 1024 * 1024
  @max_catalogs 8
  @max_catalog_entries 4_096
  @max_prepared 8
  @max_reads 16
  @cache_ttl_ms 300_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def bind(resources, binding, opts \\ []),
    do: GenServer.call(resources, {:bind, binding, Keyword.get(opts, :plugins, [])}, :infinity)

  def close(resources), do: GenServer.call(resources, :close, :infinity)

  # ExtensionRuntime's public run check does not fence Session incarnation or
  # detachment. Keep that public fence at the adapter and cache boundaries.
  def execute(operation, _scope, %{resources: resources, binding: binding}) do
    with {:ok, _owner} <- validate(binding, operation) do
      GenServer.call(resources, {:execute, binding, operation}, :infinity)
    end
  catch
    :exit, _ -> error(:cancelled, "skill resource host is unavailable")
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    {:ok,
     empty(%{
       workspace: Keyword.fetch!(opts, :workspace),
       binding: nil,
       plugin_skills: %{entries: %{}, diagnostics: []},
       remote_skills: %{skills: [], diagnostics: []}
     })}
  end

  @impl true
  def handle_call({:bind, binding, plugins}, _from, state) do
    case release(state) do
      {:ok, next} ->
        case PluginSkills.load(plugins) do
          {:ok, plugin_skills} ->
            {:reply, :ok,
             empty(%{
               next
               | binding: binding,
                 plugin_skills: plugin_skills,
                 remote_skills: apply(RemoteAdapter, :discovery, [])
             })}

          {:error, _} = error ->
            {:reply, error, empty(%{next | binding: nil})}
        end

      {{:error, _} = error, next} ->
        {:reply, error, next}
    end
  end

  def handle_call(:close, _from, state) do
    case release(state) do
      {:ok, next} -> {:reply, :ok, empty(%{next | binding: nil})}
      {{:error, _} = error, next} -> {:reply, error, %{next | binding: nil}}
    end
  end

  def handle_call({:execute, binding, operation}, _from, state) do
    with true <- state.binding == binding,
         {:ok, _owner} <- validate(binding, operation) do
      case expire(state) do
        {:ok, state} ->
          {result, state} = dispatch(operation.tool_name, operation.arguments, operation, state)
          {:reply, result, state}

        {{:error, _} = error, state} ->
          {:reply, error, state}
      end
    else
      false -> {:reply, error(:forbidden, "stale skill resource binding"), state}
      {:error, _} = error -> {:reply, error, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    case release(state) do
      {:ok, _} ->
        :ok

      {{:error, _}, pending} ->
        roots = Enum.map(pending.prepared, fn {_package, snapshot} -> snapshot.root end)
        Logger.error("skill package cleanup is unconfirmed; retained roots: #{inspect(roots)}")
    end
  end

  defp dispatch("skills::list", %{"authority" => authority} = args, _operation, state)
       when authority in ["executor", "cloud"] do
    case Map.get(args, "cursor") do
      nil -> list(state, authority)
      cursor -> list_next(state, authority, cursor)
    end
  end

  defp dispatch("skills::search", %{"query" => _} = args, operation, state)
       when not is_map_key(args, "authority"),
       do: dispatch("skills::search", Map.put(args, "authority", "executor"), operation, state)

  defp dispatch(
         "skills::search",
         %{"authority" => authority, "source_id" => source_id, "query" => query} = args,
         operation,
         state
       )
       when authority in ["executor", "cloud"] do
    params = %{source_id: source_id, q: query, cursor: args["cursor"], limit: args["limit"]}

    cancelled? = fn -> not match?({:ok, _}, validate(state.binding, operation)) end

    case apply(RemoteAdapter, :search, [params, [cancelled?: cancelled?]]) do
      {:ok, result}
      when map_size(state.packages) + length(result.items) <= @max_catalog_entries ->
        entries = Enum.map(result.items, &remote_entry(&1, authority))

        packages =
          entries |> Enum.filter(& &1.listed.model_readable) |> Map.new(&{&1.listed.package, &1})

        {{:ok, %{skills: Enum.map(entries, & &1.listed), next_cursor: result.next_cursor}},
         %{state | packages: Map.merge(state.packages, packages)}}

      {:ok, _result} ->
        {error(:overloaded, "skill catalog entry limit exceeded"), state}

      {:error, reason} ->
        {{:error,
          Error.new(:unsupported_capability, reason.message,
            details: Map.take(reason, [:code, :reason, :retryable?])
          )}, state}
    end
  end

  defp dispatch("skills::create", %{"authority" => "cloud"}, _operation, state),
    do: {error(:unsupported_capability, "cloud skill authority is not connected"), state}

  defp dispatch("skills::create", %{"source_id" => _}, _operation, state)
       when map_size(state.packages) >= @max_catalog_entries,
       do: {error(:overloaded, "skill catalog entry limit exceeded"), state}

  defp dispatch("skills::create", %{"source_id" => _} = args, operation, state) do
    cancelled? = fn -> not match?({:ok, _}, validate(state.binding, operation)) end

    case apply(RemoteAdapter, :create, [args, [cancelled?: cancelled?]]) do
      {:ok, skill} ->
        entry = remote_entry(skill)

        packages =
          if entry.listed.model_readable,
            do: Map.put(state.packages, entry.listed.package, entry),
            else: state.packages

        {{:ok, entry.listed}, %{state | packages: packages}}

      {:error, reason} ->
        class =
          case reason.code do
            :already_exists -> :resource_conflict
            :invalid_request -> :validation
            :unsupported_skill_kind -> :unsupported_capability
            code when code in [:temporarily_unavailable, :timeout, :cancelled] -> :unknown_outcome
            _ -> :forbidden
          end

        {{:error,
          Error.new(class, reason.message,
            details: Map.take(reason, [:code, :reason, :retryable?])
          )}, state}
    end
  end

  defp dispatch("skills::read", %{"package" => package} = args, operation, state)
       when is_binary(package) do
    with {:ok, entry} <- fetch(state.packages, package, "unknown or expired skill package"),
         :ok <- eligible(state, entry),
         {:ok, relative, resource} <- resource(entry, args["resource"]) do
      case args["cursor"] do
        nil ->
          case authorize_cached_read(state, package, entry, operation) do
            :ok -> read(state, package, entry, relative, resource, operation)
            {:error, reason} -> {remote_error(reason), state}
          end

        cursor ->
          read_next(state, package, resource, cursor)
      end
    else
      {:error, _} = error -> {error, state}
    end
  end

  defp dispatch(_name, _args, _operation, state),
    do: {error(:validation, "unsupported skill resource request"), state}

  defp list(state, "cloud") do
    if apply(RemoteAdapter, :discovery_sources, []) == [] do
      {error(:unsupported_capability, "Enable model discovery for a Backplane skill source"),
       state}
    else
      list_snapshot(
        state,
        "cloud",
        nil,
        state.remote_skills.skills,
        state.remote_skills.diagnostics
      )
    end
  end

  defp list(state, "executor") do
    catalog = apply(Catalog, :build, [state.workspace])

    skills =
      apply(Catalog, :automatic, [catalog]) ++
        Enum.map(state.plugin_skills.entries, fn {_id, entry} -> entry.skill end) ++
        state.remote_skills.skills

    warnings =
      Enum.map(catalog.diagnostics, &Map.from_struct/1) ++
        state.plugin_skills.diagnostics ++ state.remote_skills.diagnostics

    list_snapshot(state, "executor", catalog, skills, warnings)
  end

  defp list_snapshot(state, authority, catalog, skills, warnings) do
    skills =
      skills
      |> Enum.filter(&listed_skill?(state, catalog, &1))
      |> Enum.sort_by(&{reference(&1), &1.skill_id})

    cond do
      map_size(state.catalogs) >= @max_catalogs ->
        {error(:overloaded, "skill catalog snapshot capacity reached"), state}

      length(skills) > @max_catalog_entries ->
        {error(:overloaded, "skill catalog entry limit exceeded"), state}

      true ->
        entries = Enum.map(skills, &list_entry(state, &1, authority))
        id = opaque()
        snapshot = %{authority: authority, entries: entries, warnings: warnings}

        packages = Map.new(entries, &{&1.listed.package, &1})

        state = %{
          state
          | catalogs: Map.put(state.catalogs, id, snapshot),
            packages: Map.merge(state.packages, packages)
        }

        list_page(state, id, snapshot, 0)
    end
  end

  defp list_entry(_state, %{source_kind: "backplane"} = skill, authority),
    do: remote_entry(skill, authority)

  defp list_entry(state, skill, "executor") do
    package = opaque()

    entry = %{
      skill: skill,
      listed: %{
        package: package,
        name: skill.name,
        description: skill.description,
        authority: "executor",
        reference: reference(skill),
        main_resource: "skill://#{package}/SKILL.md"
      }
    }

    case Map.fetch(state.plugin_skills.entries, skill.skill_id) do
      {:ok, plugin} -> Map.put(entry, :installation, plugin.installation)
      :error -> entry
    end
  end

  defp list_next(state, authority, cursor) do
    with {:ok, %{kind: :list, id: id, offset: offset}} <- cursor(state, cursor, :list),
         {:ok, %{authority: ^authority} = snapshot} <-
           fetch(state.catalogs, id, "skill catalog snapshot expired"),
         :ok <- eligible_entries(state, snapshot) do
      list_page(state, id, snapshot, offset)
    else
      {:ok, _other_authority} ->
        {error(:validation, "cursor belongs to another skill authority"), state}

      {:error, _} = error ->
        {error, state}
    end
  end

  defp list_page(state, id, snapshot, offset) do
    entries = Enum.slice(snapshot.entries, offset, @list_page_size)

    {next_cursor, state} =
      continuation(state, :list, id, offset + length(entries), length(snapshot.entries))

    {{:ok,
      %{
        skills: Enum.map(entries, & &1.listed),
        sources: apply(RemoteAdapter, :discovery_sources, []),
        warnings: snapshot.warnings,
        next_cursor: next_cursor
      }}, state}
  end

  defp read(state, package, entry, relative, resource, operation) do
    key = {package, resource}

    case Map.fetch(state.reads, key) do
      {:ok, snapshot} ->
        read_page(state, key, snapshot, 0)

      :error when map_size(state.reads) >= @max_reads ->
        {error(:overloaded, "skill text snapshot capacity reached"), state}

      :error ->
        case prepared(state, package, entry, operation) do
          {:ok, prepared, next} ->
            with {:ok, contents} <-
                   read_prepared(prepared, relative),
                 :ok <- text(contents),
                 {:ok, _owner} <- validate(state.binding, operation),
                 :ok <- eligible(state, entry) do
              snapshot = %{contents: contents, resource: resource, skill_root: prepared.root}
              next = %{next | reads: Map.put(next.reads, key, snapshot)}
              read_page(next, key, snapshot, 0)
            else
              {:error, %Error{}} = error -> {error, next}
              {:error, _} -> {error(:forbidden, "skill resource cannot be read"), next}
            end

          {:error, reason, next} ->
            {{:error, reason}, next}
        end
    end
  end

  defp prepared(state, package, entry, operation) do
    case Map.fetch(state.prepared, package) do
      {:ok, snapshot} ->
        {:ok, snapshot, state}

      :error when map_size(state.prepared) >= @max_prepared ->
        {:error, Error.new(:overloaded, "prepared skill package capacity reached"), state}

      :error ->
        cancelled? = fn -> not match?({:ok, _}, validate(state.binding, operation)) end

        result =
          with :ok <- verify_plugin(entry),
               do: prepare_skill(entry.skill, cancelled?)

        case result do
          {:ok, snapshot} ->
            with {:ok, _owner} <- validate(state.binding, operation),
                 :ok <- eligible(state, entry) do
              {:ok, snapshot, %{state | prepared: Map.put(state.prepared, package, snapshot)}}
            else
              {:error, _} = error ->
                case release_prepared(snapshot) do
                  :ok ->
                    {:error, elem(error, 1), state}

                  {:error, _} ->
                    pending = %{
                      state
                      | prepared: Map.put(state.prepared, package, snapshot),
                        expires_at: System.monotonic_time(:millisecond)
                    }

                    {:error, cleanup_error(), pending}
                end
            end

          {:error, %Error{} = error} ->
            {:error, error, state}

          {:error, _} ->
            {:error, Error.new(:forbidden, "skill package could not be safely prepared"), state}
        end
    end
  end

  defp read_next(state, package, resource, token) do
    with {:ok, %{kind: :read, id: {^package, ^resource} = key, offset: offset}} <-
           cursor(state, token, :read),
         {:ok, snapshot} <- fetch(state.reads, key, "skill text snapshot expired") do
      read_page(state, key, snapshot, offset)
    else
      {:ok, _foreign} -> {error(:forbidden, "skill cursor belongs to another resource"), state}
      {:error, _} = error -> {error, state}
    end
  end

  defp read_page(state, key, snapshot, offset) do
    remaining = binary_part(snapshot.contents, offset, byte_size(snapshot.contents) - offset)
    bytes = utf8_page_bytes(remaining, min(byte_size(remaining), @text_page_bytes))
    contents = binary_part(remaining, 0, bytes)

    {next_cursor, state} =
      continuation(state, :read, key, offset + bytes, byte_size(snapshot.contents))

    {{:ok,
      %{
        resource: snapshot.resource,
        contents: contents,
        skill_root: snapshot.skill_root,
        next_cursor: next_cursor
      }}, state}
  end

  defp continuation(state, _kind, _id, offset, size) when offset >= size, do: {nil, state}

  defp continuation(state, kind, id, offset, _size) do
    position = {kind, id, offset}

    case Map.fetch(state.positions, position) do
      {:ok, token} ->
        {token, state}

      :error ->
        token = opaque()
        cursor = %{kind: kind, id: id, offset: offset}

        {token,
         %{
           state
           | cursors: Map.put(state.cursors, token, cursor),
             positions: Map.put(state.positions, position, token)
         }}
    end
  end

  defp cursor(state, token, kind) do
    case Map.fetch(state.cursors, token) do
      {:ok, %{kind: ^kind} = cursor} -> {:ok, cursor}
      _ -> error(:forbidden, "unknown, expired or foreign skill cursor")
    end
  end

  defp resource(entry, nil), do: resource(entry, entry.listed.main_resource)

  defp resource(entry, uri) when is_binary(uri) do
    prefix = "skill://#{entry.listed.package}/"

    if String.starts_with?(uri, prefix) do
      {:ok, binary_part(uri, byte_size(prefix), byte_size(uri) - byte_size(prefix)), uri}
    else
      error(:forbidden, "skill resource does not belong to the issued package")
    end
  end

  defp resource(_entry, _uri), do: error(:validation, "invalid skill resource")

  defp authorize_cached_read(
         state,
         package,
         %{skill: %{source_kind: "backplane"} = skill},
         operation
       ) do
    if Map.has_key?(state.prepared, package) do
      cancelled? = fn -> not match?({:ok, _}, validate(state.binding, operation)) end
      apply(RemoteAdapter, :authorize_exact, [skill, [cancelled?: cancelled?]])
    else
      :ok
    end
  end

  defp authorize_cached_read(_state, _package, _entry, _operation), do: :ok

  defp remote_error(reason) do
    {:error,
     Error.new(:forbidden, reason.message,
       details: Map.take(reason, [:code, :reason, :retryable?])
     )}
  end

  defp remote_entry(skill, authority \\ "executor") do
    package = opaque()
    readable? = apply(RemoteAdapter, :eligible?, [skill])

    %{
      skill: skill,
      listed: %{
        package: if(readable?, do: package),
        name: skill.name,
        description: skill.description,
        authority: authority,
        reference: skill.reference,
        revision: skill.revision,
        artifact_digest: skill.artifact_digest,
        manual_only: skill.manual_only?,
        model_readable: readable?,
        main_resource: if(readable?, do: "skill://#{package}/SKILL.md")
      }
    }
  end

  defp prepare_skill(%{source_kind: "backplane"} = skill, cancelled?) do
    case apply(RemoteAdapter, :prepare_exact, [skill, [cancelled?: cancelled?]]) do
      {:ok, prepared} -> {:ok, %{root: prepared.root, remote_prepared: prepared}}
      {:error, reason} -> remote_error(reason)
    end
  end

  defp prepare_skill(skill, cancelled?),
    do: apply(Snapshot, :prepare, [skill, [cancelled?: cancelled?]])

  defp read_prepared(%{remote_prepared: prepared}, relative),
    do:
      apply(RemoteAdapter, :read_prepared, [prepared, relative, [max_bytes: @max_resource_bytes]])

  defp read_prepared(prepared, relative),
    do: apply(Snapshot, :read, [prepared, relative, [max_bytes: @max_resource_bytes]])

  defp release_prepared(%{remote_prepared: _}), do: :ok
  defp release_prepared(prepared), do: apply(Snapshot, :release, [prepared])

  defp eligible(_state, %{skill: %{source_kind: "backplane"} = skill}) do
    if apply(RemoteAdapter, :eligible?, [skill]),
      do: :ok,
      else: error(:forbidden, "remote skill source changed; list again")
  end

  defp eligible(state, %{skill: %{source: :plugin} = skill}) do
    case Map.fetch(state.plugin_skills.entries, skill.skill_id) do
      {:ok, %{skill: ^skill}} -> :ok
      _ -> error(:not_found, "plugin skill does not belong to the current binding")
    end
  end

  defp eligible(state, entry) do
    case apply(Catalog, :resolve, [
           apply(Catalog, :build, [state.workspace]),
           entry.listed.reference,
           :automatic
         ]) do
      {:ok, skill}
      when skill.skill_id == entry.skill.skill_id and skill.path == entry.skill.path ->
        :ok

      _ ->
        error(:forbidden, "skill is no longer eligible for model access")
    end
  end

  defp eligible_entries(state, %{entries: entries, authority: authority}) do
    catalog = if authority == "executor", do: apply(Catalog, :build, [state.workspace])

    if Enum.all?(entries, fn entry ->
         listed_skill?(state, catalog, entry.skill)
       end),
       do: :ok,
       else: error(:forbidden, "skill catalog policy changed; list again")
  end

  defp reference(%{source_kind: "backplane", reference: reference}), do: reference
  defp reference(%{source: :repository, name: name}), do: "repo:" <> name
  defp reference(%{source: :global, name: name}), do: "global:" <> name
  defp reference(%{source: :plugin} = skill), do: PluginSkills.reference(skill)

  defp listed_skill?(_state, _catalog, %{source_kind: "backplane"} = skill),
    do: apply(RemoteAdapter, :eligible?, [skill])

  defp listed_skill?(state, _catalog, %{source: :plugin} = skill),
    do: match?({:ok, %{skill: ^skill}}, Map.fetch(state.plugin_skills.entries, skill.skill_id))

  defp listed_skill?(_state, catalog, skill) do
    case apply(Catalog, :resolve, [catalog, reference(skill), :automatic]) do
      {:ok, actual} -> actual.skill_id == skill.skill_id and actual.path == skill.path
      _ -> false
    end
  end

  defp verify_plugin(%{installation: installation}), do: PluginSkills.verify(installation)
  defp verify_plugin(_entry), do: :ok

  defp validate(binding, operation) do
    Session.validate(binding, operation)
  catch
    :exit, _ -> error(:cancelled, "skill Session is unavailable")
  end

  defp text(contents) do
    if String.valid?(contents) and not String.contains?(contents, <<0>>),
      do: :ok,
      else: error(:unsupported_capability, "skill resource is not UTF-8 text")
  end

  defp utf8_page_bytes(contents, bytes) do
    if String.valid?(binary_part(contents, 0, bytes)),
      do: bytes,
      else: utf8_page_bytes(contents, bytes - 1)
  end

  defp fetch(map, key, message) do
    case Map.fetch(map, key) do
      {:ok, value} -> {:ok, value}
      :error -> error(:not_found, message)
    end
  end

  defp expire(state) do
    if System.monotonic_time(:millisecond) >= state.expires_at do
      case release(state) do
        {:ok, next} -> {:ok, empty(next)}
        {error, next} -> {error, next}
      end
    else
      {:ok, state}
    end
  end

  defp empty(state) do
    Map.merge(state, %{
      catalogs: %{},
      packages: %{},
      prepared: %{},
      reads: %{},
      cursors: %{},
      positions: %{},
      expires_at: System.monotonic_time(:millisecond) + @cache_ttl_ms
    })
  end

  defp release(state) do
    pending =
      Map.reject(state.prepared, fn {_package, snapshot} ->
        release_prepared(snapshot) == :ok
      end)

    next = %{state | prepared: pending}
    if map_size(pending) == 0, do: {:ok, next}, else: {{:error, cleanup_error()}, next}
  end

  defp cleanup_error, do: Error.new(:unknown_outcome, "skill package cleanup is unconfirmed")

  defp opaque, do: Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
  defp error(class, message), do: {:error, Error.new(class, message)}
end
