defmodule Sigma.Agent.Backplane.ChildIO do
  @moduledoc """
  Child-local provider, tool, and transcript boundary for a stable subagent.

  `prepare/5` uses cached contracts and never calls the multi-agent manager. Each
  new run gets fresh tool ETS and a fenced provider owner. Only committed runtime
  messages are projected to the child's writer; chat never enters the root stream.
  """

  use GenServer

  alias Backplane.AgentRuntime.Error
  alias Sigma.Agent.{ContextBuilder, Message, SessionContext}
  alias Sigma.Agent.Backplane.{ChildStore, Provider, Store, ToolCatalog}
  alias Sigma.Ai.{ProviderRequest, ProviderUsage}
  alias Sigma.Coding.{Dispatcher, Tool}
  alias Sigma.Session.{Log, Writer}

  @config_keys ~w(model provider provider_options system_prompt session_context context_limit cwd tools mcp_servers hook_specs dispatcher_opts policy task_supervisor)a

  defmodule QuestionTool do
    @moduledoc false
    @behaviour Sigma.Coding.Tool

    alias Sigma.Coding.Tools.AskUserQuestion

    defdelegate name(), to: AskUserQuestion
    defdelegate description(), to: AskUserQuestion
    defdelegate schema(), to: AskUserQuestion

    def execute(tool_call_id, arguments, opts) do
      opts =
        case Keyword.get(opts, :ask_user_question_fn) do
          ask when is_function(ask, 2) ->
            Keyword.put(opts, :ask_user_question_fn, fn request, tool_opts ->
              request = Map.merge(request, %{tool_call_id: tool_call_id, arguments: arguments})
              ask.(request, tool_opts)
            end)

          _ ->
            opts
        end

      AskUserQuestion.execute(tool_call_id, arguments, opts)
    end
  end

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def prepare(io, identity, parent_authority, contracts, opts \\ []),
    do: GenServer.call(io, {:prepare, identity, parent_authority, contracts, opts}, :infinity)

  def store(io), do: GenServer.call(io, :store)
  def metadata(io), do: GenServer.call(io, :metadata)
  def validate(io, key), do: GenServer.call(io, {:validate, key}, :infinity)
  def project(io, key, messages), do: GenServer.call(io, {:project, key, messages}, :infinity)

  @impl true
  def init(opts) do
    config = opts |> Keyword.fetch!(:config) |> Map.take(@config_keys)
    identity = Keyword.fetch!(opts, :identity)
    path = Keyword.fetch!(opts, :transcript_path)
    sidecar_path = Keyword.fetch!(opts, :backplane_store_path)
    storage_mod = Keyword.get(opts, :storage_mod, Sigma.Session.Storage.JsonlFile)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, snapshot} <- apply(Log, :snapshot, [path, [], storage_mod]),
         {:ok, sidecar} <- Store.start_link(path: sidecar_path),
         {:ok, writer} <-
           apply(Writer, :start_link, [
             [
               storage_id: path,
               storage_mod: storage_mod,
               session_id: identity.child_session_id,
               cwd: config.cwd
             ]
           ]) do
      {:ok,
       %{
         config: config,
         identity: identity,
         transcript_path: path,
         backplane_store_path: sidecar_path,
         store: sidecar,
         writer: writer,
         messages:
           if(snapshot.messages == [],
             do: Keyword.get(opts, :messages, []),
             else: snapshot.messages
           ),
         persisted: MapSet.new(Map.keys(snapshot.message_entry_ids)),
         permission_request_fn: Keyword.get(opts, :permission_request_fn),
         ask_user_question_fn: Keyword.get(opts, :ask_user_question_fn),
         notify: Keyword.get(opts, :notify),
         key: nil,
         prepared: nil,
         tool_state: nil,
         active_tools: [],
         request: nil,
         current_request_id: nil,
         finished_requests: MapSet.new(),
         persistence_error: nil
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:store, _from, state), do: {:reply, {:ok, state.store}, state}

  def handle_call(:metadata, _from, state) do
    {:reply, {:ok, Map.take(state, [:identity, :transcript_path, :backplane_store_path])}, state}
  end

  def handle_call({:validate, key}, _from, %{key: key} = state),
    do: {:reply, :ok, state}

  def handle_call({:validate, _key}, _from, state), do: {:reply, stale(), state}

  def handle_call({:prepare, identity, authority, contracts, opts}, _from, state) do
    key = {identity.run_id, identity.incarnation}

    cond do
      identity.agent_id != state.identity.agent_id or
          identity.child_session_id != state.identity.child_session_id ->
        {:reply, {:error, Error.new(:validation, "child identity changed")}, state}

      key == state.key ->
        {:reply, {:ok, state.prepared}, state}

      state.persistence_error != nil ->
        {:reply, {:error, state.persistence_error}, state}

      true ->
        state = %{
          state
          | config: Map.take(Keyword.get(opts, :config, state.config), @config_keys),
            permission_request_fn:
              Keyword.get(opts, :permission_request_fn, state.permission_request_fn),
            ask_user_question_fn:
              Keyword.get(opts, :ask_user_question_fn, state.ask_user_question_fn)
        }

        io = self()
        grants = MapSet.new(Map.get(authority, :grants, []))

        tools =
          Enum.filter(Map.get(state.config, :tools, []), &MapSet.member?(grants, Tool.name(&1)))

        contracts = Enum.filter(contracts, &MapSet.member?(grants, contract_name(&1)))
        names = Enum.map(tools, &Tool.name/1) ++ Enum.map(contracts, &contract_name/1)

        authority =
          authority
          |> Map.put(:run_id, identity.run_id)
          |> Map.put(:caller, identity.child_session_id)
          |> Map.put(:grants, names)

        case ToolCatalog.admit(tools, authority, &execute(io, key, &1), contracts: contracts) do
          {:ok, catalog} ->
            if state.tool_state, do: :ets.delete(state.tool_state)
            tool_state = :ets.new(__MODULE__, [:set, :public, read_concurrency: true])

            messages =
              if state.messages == [], do: Keyword.get(opts, :messages, []), else: state.messages

            state = %{
              state
              | identity: identity,
                key: key,
                tool_state: tool_state,
                active_tools: tools,
                request: nil,
                current_request_id: nil,
                finished_requests: MapSet.new(),
                messages: messages
            }

            options = conversation_options(state, catalog)
            prepared = %{options: options, catalog: catalog, key: key}
            {:reply, {:ok, prepared}, %{state | prepared: prepared}}

          {:error, _error} = error ->
            {:reply, error, state}
        end
    end
  end

  def handle_call({:project, key, messages}, _from, %{key: key} = state) do
    if state.persistence_error do
      {:reply, {:error, state.persistence_error}, state}
    else
      {result, state} = project_messages(state, messages)
      {:reply, result, state}
    end
  end

  def handle_call({:project, _key, _messages}, _from, state), do: {:reply, stale(), state}

  def handle_call({:tool_context, key}, _from, %{key: key} = state) do
    notify(state, :running_tools)
    {:reply, {:ok, state.active_tools, dispatcher_options(state)}, state}
  end

  def handle_call({:tool_context, _key}, _from, state), do: {:reply, stale(), state}

  def handle_call({:tool_boundary, key}, _from, %{key: key} = state),
    do: {:reply, :ok, state}

  def handle_call({:tool_boundary, _key}, _from, state), do: {:reply, stale(), state}

  def handle_call({:tool_fact, key, fact}, _from, %{key: key} = state) do
    state = append(state, {:metrics, :tool_finished, fact})
    {:reply, :ok, state}
  end

  def handle_call({:tool_fact, _key, _fact}, _from, state), do: {:reply, stale(), state}

  @impl true
  def handle_info({:child_io, key, event}, %{key: key} = state),
    do: {:noreply, provider_event(event, state)}

  def handle_info({:child_io, _key, {:backplane_request_started, worker, ref, _, _}}, state) do
    send(worker, {:backplane_request_ready, ref, {:error, :stale_child_io}})
    {:noreply, state}
  end

  def handle_info({:child_io, _key, {:backplane_provider_boundary, worker, ref, _request}}, state) do
    send(worker, {:backplane_provider_continue, ref})
    {:noreply, state}
  end

  def handle_info({:child_io, _key, _event}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    Enum.each([state.writer, state.store], fn pid ->
      if Process.alive?(pid), do: GenServer.stop(pid, :normal)
    end)
  end

  defp conversation_options(state, catalog) do
    config = state.config

    host = %{
      model: config.model,
      provider: config.provider,
      provider_options: Map.get(config, :provider_options, []),
      session_id: state.identity.child_session_id,
      log_session_id: state.identity.child_session_id,
      turn_id: public_run_id(state.identity),
      build_context: fn messages ->
        ContextBuilder.build(
          messages: messages,
          session_context: Map.get(config, :session_context) || SessionContext.new(),
          system_prompt: Map.get(config, :system_prompt),
          tools: catalog.tools,
          cwd: config.cwd,
          model: config.model
        )
      end,
      context_error:
        &Sigma.Agent.__backplane_context_error__(
          Map.merge(
            %{
              context_limit: nil,
              provider_options: []
            },
            config
          ),
          &1
        )
    }

    [
      run_id: state.identity.run_id,
      incarnation: state.identity.incarnation,
      store: ChildStore,
      context: %{store: state.store, io: self(), key: state.key},
      provider: Provider,
      provider_context: %{host: host, owner: {self(), state.key}},
      registry: catalog.registry,
      tools: catalog.tools,
      authority: catalog.authority,
      messages: state.messages,
      work: 100,
      provider_output_limit: :infinity,
      run_timeout: :infinity,
      effect_timeout: 300_000
    ]
  end

  defp execute(io, key, operation) do
    with {:ok, tools, opts} <- GenServer.call(io, {:tool_context, key}, :infinity) do
      tools =
        Enum.map(tools, fn
          Sigma.Coding.Tools.AskUserQuestion -> QuestionTool
          tool -> tool
        end)

      call = %{
        id: operation.tool_call_id,
        name: operation.tool_name,
        arguments: operation.arguments,
        type: :tool_call
      }

      result = Dispatcher.dispatch(call, tools, opts)

      case GenServer.call(io, {:tool_boundary, key}, :infinity) do
        :ok -> result
        {:error, _error} = error -> error
      end
    end
  end

  defp dispatcher_options(state) do
    identity = state.identity
    io = self()
    key = state.key
    config = state.config

    opts =
      Map.get(config, :dispatcher_opts, [])
      |> Keyword.drop([
        :permission_request_fn,
        :ask_user_question_fn,
        :tool_state,
        :on_tool_fact,
        :on_tool_update,
        :on_update
      ])
      |> Keyword.merge(
        observed_permission_denials: true,
        cwd: config.cwd,
        permission_policy: resolve_policy(Map.get(config, :policy)),
        session_id: identity.child_session_id,
        log_session_id: identity.child_session_id,
        turn_id: public_run_id(identity),
        request_id: state.current_request_id,
        transcript_path: state.transcript_path,
        tool_state: state.tool_state,
        hook_specs: Map.get(config, :hook_specs, []),
        on_tool_fact: fn fact -> GenServer.call(io, {:tool_fact, key, fact}, :infinity) end
      )

    opts =
      if config[:task_supervisor],
        do: Keyword.put(opts, :task_supervisor, config.task_supervisor),
        else: opts

    opts =
      if state.permission_request_fn do
        Keyword.put(opts, :permission_request_fn, fn call ->
          state.permission_request_fn.(identity, call)
        end)
      else
        opts
      end

    if state.ask_user_question_fn do
      Keyword.put(opts, :ask_user_question_fn, fn request, tool_opts ->
        state.ask_user_question_fn.(identity, request, tool_opts)
      end)
    else
      opts
    end
  end

  defp provider_event({:backplane_request_started, worker, ref, request, _context}, state) do
    notify(state, :streaming_provider)

    state =
      state
      |> Map.put(:request, request)
      |> Map.put(:current_request_id, request.request_id)
      |> append({:metrics, :request_started, request_fact(request)})

    result = if state.persistence_error, do: {:error, state.persistence_error}, else: :ok
    send(worker, {:backplane_request_ready, ref, result})
    state
  end

  defp provider_event({:backplane_request_progress, request}, state),
    do: %{state | request: request}

  defp provider_event({:backplane_request_finished, request}, state),
    do: finish_request(state, request)

  defp provider_event({:backplane_provider_boundary, worker, ref, request}, state) do
    state = finish_request(state, request)
    send(worker, {:backplane_provider_continue, ref})
    state
  end

  defp provider_event(_event, state), do: state

  defp finish_request(state, request) do
    if MapSet.member?(state.finished_requests, request.request_id) do
      state
    else
      state = append(state, {:metrics, :request_finished, request_fact(request)})

      %{
        state
        | request: nil,
          finished_requests: MapSet.put(state.finished_requests, request.request_id)
      }
    end
  end

  defp project_messages(state, messages) do
    messages
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, state}, fn {message, index}, {:ok, state} ->
      message = canonical_message(message, index)

      if MapSet.member?(state.persisted, message.id) do
        {:cont, {:ok, state}}
      else
        case apply(Writer, :append, [state.writer, {:message_end, message}]) do
          {:ok, _entry_id} ->
            {:cont, {:ok, %{state | persisted: MapSet.put(state.persisted, message.id)}}}

          {:error, reason} ->
            error = Error.new(:execution_failure, "child journal append failed", cause: reason)
            {:halt, {{:error, error}, %{state | persistence_error: error}}}
        end
      end
    end)
    |> case do
      {:ok, state} -> {:ok, %{state | messages: messages}}
      {error, state} -> {error, state}
    end
  end

  defp canonical_message(%Message{} = message, _index), do: message

  defp canonical_message(%{role: :tool} = message, index) do
    [normalized] = Provider.normalize_messages([message])
    %{normalized | id: "msg_child_tool_#{index}_#{message.tool_call_id}"}
  end

  defp canonical_message(message, _index) do
    [normalized] = Provider.normalize_messages([message])
    normalized
  end

  defp append(state, event) do
    case apply(Writer, :append, [state.writer, event]) do
      {:ok, _entry_id} ->
        state

      {:error, reason} ->
        %{
          state
          | persistence_error:
              Error.new(:execution_failure, "child metrics append failed", cause: reason)
        }
    end
  end

  defp request_fact(%ProviderRequest{} = request) do
    usage = if request.usage, do: ProviderUsage.to_fact(request.usage), else: %{}

    request
    |> Map.take([
      :request_id,
      :message_id,
      :session_id,
      :origin_session_id,
      :turn_id,
      :purpose,
      :status,
      :elapsed_ms,
      :first_output_ms,
      :ttft_ms
    ])
    |> Map.merge(usage)
    |> Map.merge(%{
      revision: request.usage_revision,
      provider: request.model[:provider],
      model: request.model[:id],
      started_at: iso(request.started_at),
      finished_at: iso(request.finished_at)
    })
  end

  defp notify(%{notify: notify, identity: identity}, phase) when is_function(notify, 2),
    do: notify.(identity, phase)

  defp notify(_state, _phase), do: :ok

  defp contract_name(contract),
    do:
      Map.get(contract, :tool_name) ||
        Backplane.AgentRuntime.Codex.Contract.canonical_name(
          Map.get(contract, :namespace),
          contract.name
        )

  defp public_run_id(identity), do: Map.get(identity, :public_run_id, identity.run_id)
  defp resolve_policy(nil), do: nil
  defp resolve_policy(policy) when is_pid(policy) or is_atom(policy), do: policy
  defp resolve_policy(policy), do: GenServer.whereis(policy)
  defp iso(%DateTime{} = time), do: DateTime.to_iso8601(time)
  defp iso(_time), do: nil
  defp stale, do: {:error, Error.new(:resource_conflict, "stale child IO run")}
end
