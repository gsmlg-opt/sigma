defmodule Sigma.Agent.Backplane.CodexResources do
  @moduledoc """
  Host-owned resources for explicitly selected native Backplane Codex profiles.

  This boundary does not register tools or authorize hooks and permissions.
  Commands use the ordinary host adapter: non-PTY work delegates to the public
  Linux LocalCommand, while configured native PTYs have independent lifetimes.
  Plan processes and bindings are ephemeral;
  Engine hydrates confirmed plan content from the selected journal branch.
  Normal termination of an owned Session stops its registry infrastructure.

  An owned Session is closed before its command backend is stopped. A borrowed
  Session must first be closed by its owner; explicit resource close refuses
  while that Session remains open. Shutdown still stops this owner's command
  backend and plan, without closing a borrowed Session.
  """

  use GenServer, restart: :temporary, shutdown: 10_000
  require Logger

  alias Backplane.AgentRuntime.{Command, Error, Plan}
  alias Backplane.AgentRuntime.Codex.{DynamicRuntime, ExtensionRuntime, Session}

  alias Sigma.Agent.Backplane.{
    ExtensionResources,
    LifetimeRecovery,
    MemoryResources,
    NotesResources,
    PlainCommand,
    PluginResources,
    PluginRuntime,
    SkillResources,
    Store
  }

  alias Sigma.Session.ConfigManager

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc false
  def session(resources), do: GenServer.call(resources, :session)

  def bind(resources, authority, opts \\ []),
    do: GenServer.call(resources, {:bind, authority, opts})

  def context(resources, binding), do: GenServer.call(resources, {:context, binding})

  def context(resources, binding, opts),
    do: GenServer.call(resources, {:context, binding, Keyword.fetch!(opts, :candidates)})

  @doc "Returns the actual local command startup state for the current resource binding."
  def environment(%{codex_resources: resources, session_binding: binding}) do
    case GenServer.call(resources, {:environment, binding}) do
      {:ok, environment} -> environment
      {:error, _} -> nil
    end
  catch
    :exit, _reason -> nil
  end

  def environment(_context), do: nil

  def close(resources), do: GenServer.call(resources, :close, :infinity)
  def retirement_context(resources), do: GenServer.call(resources, :retirement_context, :infinity)

  def plugin_tools(resources, binding),
    do: GenServer.call(resources, {:plugin_tools, binding}, :infinity)

  @impl true
  def init(opts) do
    workspace = Keyword.fetch!(opts, :workspace)
    owner = Keyword.fetch!(opts, :owner_pid)

    with :ok <- validate_host(workspace, owner),
         {:ok, plugins} <- PluginResources.open(Keyword.get(opts, :plugins)),
         {:ok, session, owned?} <-
           session(Keyword.get(opts, :session), owner, Keyword.get(opts, :lifetime_recovery)) do
      case start_resources(workspace, plugins) do
        {:ok, command, plan, dynamic_runtime, skill_resources} ->
          {:ok,
           %{
             workspace: Path.expand(workspace),
             owner_monitor: Process.monitor(owner),
             session: session,
             owned_session?: owned?,
             lifetime_recovery: Keyword.get(opts, :lifetime_recovery),
             recovery_binding: nil,
             session_cleanup: nil,
             command: command,
             environment: %{
               environment_id:
                 "local-" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false),
               kind: "local-command-runtime",
               cwd: Path.expand(workspace),
               status: "starting",
               ready: false,
               authorized: true
             },
             plan: plan,
             dynamic_runtime: dynamic_runtime,
             dynamic_binding: nil,
             candidates: [],
             plugin_resources: plugins,
             plugin_installations: [],
             plugin_runtime: nil,
             plugin_binding: nil,
             skill_resources: skill_resources,
             skills_closed?: false,
             memory_root:
               Keyword.get_lazy(opts, :memory_root, fn ->
                 Path.join(apply(ConfigManager, :agent_dir, []), "memories")
               end),
             memory_resources: nil,
             host_retirement: Keyword.get(opts, :host_retirement),
             retirement_identity: nil,
             retirement_pending_binding: nil,
             retirement_recorded?: false,
             archive: Keyword.get(opts, :archive),
             notes_resources: nil,
             extension_runtime: nil,
             binding: nil,
             closed: nil
           }}

        {:error, reason} ->
          if owned?, do: stop_resource(session)
          {:stop, reason}
      end
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:session, _from, state), do: {:reply, state.session, state}

  def handle_call(:retirement_context, _from, state) do
    {:reply,
     %{
       session: state.session,
       binding: state.recovery_binding,
       recovery: state.lifetime_recovery
     }, state}
  end

  def handle_call({:bind, _authority, _opts}, _from, %{closed: closed} = state)
      when not is_nil(closed),
      do: {:reply, closed_error(), state}

  def handle_call({:bind, _authority, _opts}, _from, %{session_cleanup: cleanup} = state)
      when not is_nil(cleanup),
      do: {:reply, closed_error(), state}

  def handle_call({:bind, authority, opts}, _from, state) do
    opts =
      if state.lifetime_recovery,
        do: Keyword.put(opts, :recovery_store_ref, state.lifetime_recovery.store_ref),
        else: opts

    case Session.bind(state.session, authority, opts) do
      {:ok, binding} = result ->
        case register_retirement_binding(state, binding) do
          {:ok, state} ->
            case start_extension(state, binding, authority) do
              {:ok, runtime, memories, notes, plugins, installations} ->
                {:reply, result,
                 %{
                   state
                   | binding: binding,
                     recovery_binding: binding,
                     extension_runtime: runtime,
                     memory_resources: memories,
                     notes_resources: notes,
                     plugin_resources: plugins,
                     plugin_installations: installations
                 }}

              error ->
                reject_binding(state, error)
            end

          {{:error, _} = error, state} ->
            reject_binding(state, error)
        end

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:context, binding}, _from, %{binding: binding, closed: nil} = state)
      when is_map(binding) do
    {:reply, {:ok, resource_context(state, binding)}, state}
  end

  def handle_call(
        {:plugin_tools, binding},
        _from,
        %{binding: binding, closed: nil, session_cleanup: nil} = state
      )
      when is_map(binding) do
    case prepare_plugin_runtime(state, binding) do
      {:ok, state} ->
        result =
          if state.plugin_runtime, do: PluginRuntime.tools(state.plugin_runtime), else: {:ok, []}

        {:reply, result, state}

      {:error, error, state} ->
        {:reply, {:error, error}, state}
    end
  end

  def handle_call({:plugin_tools, _binding}, _from, state),
    do: {:reply, closed_error(), state}

  def handle_call(
        {:context, binding, candidates},
        _from,
        %{binding: binding, closed: nil} = state
      )
      when is_map(binding) and is_list(candidates) do
    case prepare_discovery(state, binding, candidates) do
      {:ok, state} -> {:reply, {:ok, resource_context(state, binding)}, state}
      error -> {:reply, error, state}
    end
  end

  def handle_call({:context, _binding, _candidates}, _from, state),
    do:
      {:reply, {:error, Error.new(:forbidden, "stale or foreign Codex resource binding")}, state}

  def handle_call({:context, _binding}, _from, state),
    do:
      {:reply, {:error, Error.new(:forbidden, "stale or foreign Codex resource binding")}, state}

  def handle_call(
        {:environment, binding},
        _from,
        %{binding: binding, closed: nil, session_cleanup: nil} = state
      )
      when is_map(binding),
      do: {:reply, {:ok, environment_state(state)}, state}

  def handle_call({:environment, _binding}, _from, state),
    do: {:reply, closed_error(), state}

  def handle_call(
        {:environment, binding, id},
        _from,
        %{binding: binding, closed: nil, session_cleanup: nil} = state
      )
      when is_map(binding) do
    environment =
      if id == state.environment.environment_id,
        do: environment_state(state),
        else: unavailable_environment(id)

    {:reply, environment, state}
  end

  def handle_call({:environment, _binding, id}, _from, state),
    do: {:reply, unavailable_environment(id), state}

  def handle_call(:close, _from, %{closed: closed} = state) when not is_nil(closed),
    do: close_reply(state, closed)

  def handle_call(:close, _from, state) do
    case close_session(state) do
      {:ok, %{status: :confirmed}} = result ->
        state = %{state | session_cleanup: result, binding: nil}

        case stop_resources(state) do
          {:ok, state} -> close_reply(%{state | closed: result}, result)
          {error, state} -> {:reply, error, state}
        end

      error ->
        {:reply, error, state}
    end
  end

  defp register_retirement_binding(%{host_retirement: nil} = state, _binding),
    do: {:ok, state}

  defp register_retirement_binding(state, binding) do
    %{store: store, identity: identity} = state.host_retirement

    native =
      Map.merge(identity, %{
        native_owner_id: binding.owner_id,
        native_session_incarnation: binding.incarnation
      })

    membership =
      Map.merge(native, %{run_id: binding.run_id, run_incarnation: binding.run_incarnation})

    state = %{state | retirement_identity: native, retirement_pending_binding: membership}

    result =
      try do
        Store.register_host_binding(store, membership)
      catch
        :exit, cause ->
          {:error,
           Error.new(:unknown_outcome, "host binding writer is unavailable", cause: cause)}
      end

    case result do
      :ok -> {:ok, %{state | retirement_pending_binding: nil}}
      {:error, _} = error -> {error, state}
    end
  end

  defp reject_binding(state, error) do
    cleanup = close_session(state)

    state =
      if match?({:ok, %{status: :confirmed}}, cleanup),
        do: %{state | session_cleanup: cleanup},
        else: state

    {:reply, error, %{state | binding: nil}}
  end

  defp close_reply(state, result) do
    case persist_native_retirement(state, result) do
      :ok ->
        {:reply, result, %{state | retirement_recorded?: true, retirement_pending_binding: nil}}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  defp persist_native_retirement(%{retirement_recorded?: true}, _result), do: :ok
  defp persist_native_retirement(%{host_retirement: nil}, _result), do: :ok
  defp persist_native_retirement(%{retirement_identity: nil}, _result), do: :ok

  defp persist_native_retirement(state, {:ok, confirmation}) do
    with :ok <- persist_pending_binding(state) do
      Store.record_host_retirement(
        state.host_retirement.store,
        state.retirement_identity,
        :native,
        Map.take(confirmation, [:status, :owner_id])
      )
    end
  catch
    :exit, cause ->
      {:error,
       Error.new(:unknown_outcome, "native retirement writer is unavailable", cause: cause)}
  end

  defp persist_pending_binding(%{retirement_pending_binding: nil}), do: :ok

  defp persist_pending_binding(state),
    do: Store.register_host_binding(state.host_retirement.store, state.retirement_pending_binding)

  defp resource_context(state, binding) do
    resources = self()

    %{
      codex_resources: resources,
      lifetime_recovery: state.lifetime_recovery,
      command: state.command,
      caller: %{run_id: binding.run_id},
      workspace: state.workspace,
      plan: state.plan,
      dynamic_runtime: state.dynamic_runtime,
      plugin_resources:
        if(state.plugin_resources, do: Map.put(state.plugin_resources, :binding, binding)),
      extension_runtime: state.extension_runtime,
      memory_resources: state.memory_resources,
      history_resources: state.archive,
      notes_resources: state.notes_resources,
      message_board_resources: if(state.archive, do: %{archive: state.archive, binding: binding}),
      session_binding: binding,
      session_registry: binding.resource_registry,
      resource_registry: binding.resource_registry,
      environment_provider: fn id ->
        try do
          GenServer.call(resources, {:environment, binding, id})
        catch
          :exit, _reason -> unavailable_environment(id)
        end
      end
    }
  end

  defp environment_state(state) do
    if Process.alive?(state.command.server),
      do: state.environment,
      else: %{state.environment | status: "closed", ready: false}
  end

  defp unavailable_environment(id),
    do: %{environment_id: id, status: "unavailable", ready: false, authorized: true}

  defp prepare_discovery(
         %{dynamic_binding: binding, candidates: candidates} = state,
         binding,
         candidates
       ),
       do: {:ok, state}

  defp prepare_discovery(%{dynamic_binding: binding}, binding, _candidates),
    do: {:error, Error.new(:resource_conflict, "discovery inventory is fixed for this run")}

  defp prepare_discovery(state, binding, candidates) do
    # The published runtime owns discarded staged publications. Each binding
    # gets a fresh inventory; never reset an active runtime's private state.
    case DynamicRuntime.start_link(
           dynamic_options(state.plugin_resources,
             candidates: candidates,
             max_results: max(8, length(candidates))
           )
         ) do
      {:ok, runtime} ->
        case stop_dynamic_runtime(state.dynamic_runtime) do
          :ok ->
            {:ok,
             %{state | dynamic_runtime: runtime, dynamic_binding: binding, candidates: candidates}}

          error ->
            stop_dynamic_runtime(runtime)
            error
        end

      error ->
        error
    end
  end

  @impl true
  def handle_info(
        {:plain_command_startup, server, result},
        %{command: %{server: server}, closed: nil} = state
      ) do
    environment =
      case result do
        :ok ->
          %{state.environment | status: "ready", ready: true}

        {:error, %Error{} = error} ->
          Map.merge(state.environment, %{
            status: "failed",
            ready: false,
            error: %{class: error.class, message: error.message}
          })
      end

    {:noreply, %{state | environment: environment}}
  end

  def handle_info({:plain_command_startup, _server, _result}, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, _owner, _reason}, %{owner_monitor: ref} = state),
    do: {:stop, :normal, state}

  @impl true
  def terminate(_reason, state) do
    if state.closed == nil do
      result = close_session(state)

      case stop_resources(state) do
        {:ok, state} ->
          case result do
            {:ok, %{status: :confirmed}} ->
              log_retirement_result(persist_native_retirement(state, result))

            error ->
              Logger.error("Codex session shutdown cleanup is unconfirmed: #{inspect(error)}")
          end

        {{:error, error}, _state} ->
          Logger.error("Codex resource shutdown cleanup is unconfirmed: #{inspect(error)}")
          stop_children(state)
      end
    else
      log_retirement_result(persist_native_retirement(state, state.closed))
    end

    if state.owned_session? and state.lifetime_recovery, do: stop_resource(state.session)
  end

  defp log_retirement_result(:ok), do: :ok

  defp log_retirement_result({:error, error}),
    do: Logger.error("Native retirement was not persisted: #{inspect(error)}")

  defp close_session(%{session_cleanup: {:ok, %{status: :confirmed}} = result}), do: result

  defp close_session(state) do
    session_cleanup(state)
  catch
    :exit, reason ->
      {:error, Error.new(:unknown_outcome, "Codex session cleanup is unavailable", cause: reason)}
  end

  defp session_cleanup(%{owned_session?: true, session: session}), do: Session.close(session)

  defp session_cleanup(%{session: session}) do
    case Session.status(session) do
      %{phase: :closed, cleanup: {:ok, %{status: :confirmed}} = result} ->
        result

      %{phase: :closed, cleanup: {:error, _} = error} ->
        error

      _ ->
        {:error,
         Error.new(:resource_conflict, "borrowed Codex session must be closed by its owner")}
    end
  end

  defp stop_resources(state) do
    # Fence the public Session first, then stop extension dispatch before its
    # cache releases any prepared package roots. Retain each confirmed step so
    # retries remain possible after the corresponding child has stopped.
    case stop_optional(state.extension_runtime) do
      :ok ->
        case close_plugin_runtime(state) do
          {:ok, state} ->
            case close_skills(state) do
              :ok -> {stop_children(state), %{state | skills_closed?: true}}
              error -> {error, state}
            end

          {:error, error, state} ->
            {{:error, error}, state}
        end

      error ->
        {error, state}
    end
  end

  defp prepare_plugin_runtime(%{plugin_binding: binding} = state, binding), do: {:ok, state}

  defp prepare_plugin_runtime(state, binding) do
    case close_plugin_runtime(state) do
      {:ok, %{plugin_installations: []} = state} ->
        {:ok, %{state | plugin_binding: binding}}

      {:ok, state} ->
        case PluginRuntime.start_link(
               owner_pid: self(),
               run_id: binding.run_id,
               installations: state.plugin_installations
             ) do
          {:ok, runtime} -> {:ok, %{state | plugin_runtime: runtime, plugin_binding: binding}}
          {:error, error} -> {:error, error, state}
        end

      error ->
        error
    end
  end

  defp close_plugin_runtime(%{plugin_runtime: nil} = state), do: {:ok, state}

  defp close_plugin_runtime(state) do
    case PluginRuntime.close(state.plugin_runtime) do
      :ok ->
        case stop_resource(state.plugin_runtime) do
          :ok -> {:ok, %{state | plugin_runtime: nil, plugin_binding: nil}}
          {:error, error} -> {:error, error, state}
        end

      {:error, error} ->
        {:error, error, state}
    end
  end

  defp close_skills(%{skills_closed?: true}), do: :ok
  defp close_skills(state), do: SkillResources.close(state.skill_resources)

  defp stop_children(state) do
    children = [state.skill_resources, state.command.server, state.plan]

    children =
      if state.owned_session? and is_nil(state.lifetime_recovery),
        do: children ++ [state.session],
        else: children

    results = [stop_dynamic_runtime(state.dynamic_runtime) | Enum.map(children, &stop_resource/1)]
    Enum.find(results, :ok, &match?({:error, _}, &1))
  end

  defp start_extension(state, binding, authority) do
    scope = %{
      host_id: binding.owner_id,
      caller_id: authority.caller,
      run_id: binding.run_id,
      project_id: state.workspace
    }

    with {:ok, plugin_host} <- PluginResources.refresh(state.plugin_resources),
         {:ok, plugins} <- PluginResources.installed(plugin_host),
         {:ok, memories} <- MemoryResources.open(root: state.memory_root),
         {:ok, notes} <- open_notes(state.archive),
         {:ok, runtime} <-
           ExtensionRuntime.start_link(
             scope: scope,
             owner_pid: self(),
             adapter: ExtensionResources,
             adapter_context: %{
               skills: %{resources: state.skill_resources, binding: binding},
               memories: %{resources: memories, binding: binding},
               history: %{archive: state.archive, binding: binding},
               notes: %{
                 resources: notes,
                 binding: binding,
                 agent_name: archive_agent(state.archive)
               },
               board: %{archive: state.archive, binding: binding}
             }
           ) do
      with :ok <- stop_optional(state.extension_runtime),
           :ok <- SkillResources.bind(state.skill_resources, binding, plugins: plugins) do
        {:ok, runtime, memories, notes, plugin_host, plugins}
      else
        error ->
          stop_resource(runtime)
          error
      end
    end
  end

  defp open_notes(nil), do: {:ok, nil}
  defp open_notes(archive), do: NotesResources.open(root_transcript: archive.root_transcript)
  defp archive_agent(nil), do: nil
  defp archive_agent(archive), do: archive.agent_name

  defp stop_optional(nil), do: :ok
  defp stop_optional(pid), do: stop_resource(pid)

  # DynamicRuntime may be servicing a bounded MCP read, so an ordinary stop call
  # can queue behind it. Confirm local exit; the public Client then observes its
  # actual request owner's death and cancels that exact handle. This does not
  # establish remote rollback or settle the child's interrupted tool effect.
  defp stop_dynamic_runtime(pid) do
    monitor = Process.monitor(pid)
    Process.unlink(pid)
    Process.exit(pid, :shutdown)

    receive do
      {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
    after
      3_000 ->
        Process.demonitor(monitor, [:flush])
        {:error, Error.new(:unknown_outcome, "MCP resource runtime shutdown is unconfirmed")}
    end
  end

  defp stop_resource(pid) do
    GenServer.stop(pid, :normal, 3_000)
  catch
    :exit, {:noproc, _} ->
      :ok

    :exit, reason ->
      {:error,
       Error.new(:unknown_outcome, "Codex resource shutdown is unconfirmed", cause: reason)}
  end

  defp dynamic_options(plugins, opts \\ []) do
    opts = Keyword.put(opts, :mcp_adapter, Sigma.Agent.Backplane.McpResources)

    if plugins,
      do: opts ++ [plugin_adapter: PluginResources, plugin_context: plugins],
      else: opts
  end

  defp start_resources(workspace, plugins) do
    with {:ok, command_server} <- PlainCommand.start_link(owner_pid: self(), async_start: true) do
      result =
        with {:ok, command} <-
               Command.new(%{
                 adapter: PlainCommand,
                 server: command_server,
                 allowed_environment: %{}
               }),
             {:ok, plan} <- Plan.start_link(Path.expand(workspace)) do
          case DynamicRuntime.start_link(dynamic_options(plugins)) do
            {:ok, dynamic_runtime} ->
              case SkillResources.start_link(workspace: Path.expand(workspace)) do
                {:ok, skill_resources} ->
                  {:ok, command, plan, dynamic_runtime, skill_resources}

                error ->
                  stop_dynamic_runtime(dynamic_runtime)
                  stop_resource(plan)
                  error
              end

            error ->
              stop_resource(plan)
              error
          end
        end

      case result do
        {:ok, _, _, _, _} ->
          result

        {:error, _} ->
          stop_resource(command_server)
          result
      end
    end
  end

  defp session(nil, owner, recovery) do
    opts =
      if recovery,
        do: [
          recovery: LifetimeRecovery.configuration(recovery.writer),
          recovery_scope_id: LifetimeRecovery.scope(recovery.writer)
        ],
        else: []

    case Session.start_link([owner_pid: owner] ++ opts) do
      {:ok, session} -> {:ok, session, true}
      error -> error
    end
  end

  defp session(session, _owner, _recovery) when is_pid(session) do
    if Process.alive?(session),
      do: {:ok, session, false},
      else: {:error, Error.new(:validation, "borrowed Codex session must be alive")}
  end

  defp validate_host(workspace, owner) do
    cond do
      not (is_binary(workspace) and File.dir?(workspace) and is_pid(owner) and
               Process.alive?(owner)) ->
        {:error,
         Error.new(:validation, "Codex resources require a workspace and live host owner")}

      :os.type() != {:unix, :linux} ->
        {:error, Error.new(:unsupported_capability, "plain Codex commands require Linux")}

      true ->
        :ok
    end
  end

  defp closed_error, do: {:error, Error.new(:resource_conflict, "Codex resources are closed")}
end
