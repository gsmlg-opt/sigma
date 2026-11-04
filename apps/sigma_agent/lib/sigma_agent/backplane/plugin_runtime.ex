defmodule Sigma.Agent.Backplane.PluginRuntime do
  @moduledoc """
  Owns the public plugin Sessions pinned by one native resource binding.

  Installed receipts are supplied by the host after its ordinary writer refresh.
  Each immutable release gets an independent public Session; its admitted names,
  descriptions and schemas become ordinary MCP tools for the shared Dispatcher.
  The callbacks retain the actual run and Session rather than borrowing another
  binding's connections. No installation or registry request runs here.

  Explicit close retains each public cleanup report before stopping its Session.
  Public stop observes the same memoized cleanup attempt and retires only a
  confirmed Session. An unconfirmed report and its original public stop error
  remain inspectable; repeated runtime close never repeats either operation.
  """

  use GenServer, restart: :temporary

  alias Backplane.AgentRuntime.Error
  alias Backplane.AgentRuntime.Plugins.Session
  alias Backplane.PluginProtocol.Archive
  alias Sigma.Coding.MCP.Tool
  alias Sigma.Coding.ToolError

  @installation_keys ~w(root data_dir plugin_id release_id artifact_digest content_digest)a

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def tools(runtime), do: request(runtime, :tools, :unavailable)
  def snapshot(runtime), do: request(runtime, :snapshot, :unavailable)
  def close(runtime), do: request(runtime, :close, :unknown_outcome)

  def call_tool(runtime, name, arguments),
    do: request(runtime, {:call_tool, name, arguments}, :unknown_outcome)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    owner = Keyword.fetch!(opts, :owner_pid)

    state = %{
      owner: owner,
      owner_monitor: Process.monitor(owner),
      run_id: Keyword.fetch!(opts, :run_id),
      entries: [],
      preparation_error: nil,
      close_result: nil
    }

    state =
      prepare(
        state,
        Keyword.fetch!(opts, :installations),
        Keyword.get(opts, :session_options, [])
      )

    {:ok, state}
  end

  @impl true
  def handle_call(:tools, _from, %{preparation_error: error} = state) when not is_nil(error),
    do: {:reply, {:error, error}, state}

  def handle_call(:tools, _from, %{close_result: result} = state) when not is_nil(result),
    do: {:reply, failure(:unavailable, "plugin runtime is closed", result), state}

  def handle_call(:tools, _from, state) do
    runtime = self()

    tools =
      for entry <- state.entries,
          descriptor <- entry.descriptors do
        name = descriptor.tool_name

        struct!(Tool,
          name: name,
          description: descriptor.description,
          schema: descriptor.schema,
          server_id: entry.source_id,
          client: entry.session,
          server_tool_name: name,
          call_tool: fn _tool_call_id, arguments, _opts ->
            case call_tool(runtime, name, arguments) do
              {:error, %Error{class: :unknown_outcome} = error} ->
                {:error,
                 ToolError.new(:unknown_outcome, error.message, details: Error.to_map(error))}

              {:error, %Error{} = error} ->
                {:error, ToolError.new(:execution, error.message, details: Error.to_map(error))}

              result ->
                result
            end
          end
        )
      end

    {:reply, {:ok, tools}, state}
  end

  def handle_call(:snapshot, _from, state) do
    entries =
      Enum.map(state.entries, fn entry ->
        %{
          plugin_id: entry.installation.plugin_id,
          release_id: entry.installation.release_id,
          source_id: entry.source_id,
          session: entry.session,
          names: Enum.map(entry.descriptors, & &1.tool_name),
          components: entry.components,
          diagnostics: entry.diagnostics,
          cleanup_report: entry.cleanup_report,
          close_result: entry.close_result,
          exit: entry.exit
        }
      end)

    {:reply,
     {:ok,
      %{
        run_id: state.run_id,
        entries: entries,
        preparation_error: state.preparation_error,
        close_result: state.close_result
      }}, state}
  end

  def handle_call({:call_tool, _name, _arguments}, _from, %{close_result: result} = state)
      when not is_nil(result),
      do: {:reply, failure(:unavailable, "plugin runtime is closed", result), state}

  def handle_call({:call_tool, name, arguments}, _from, state) do
    entry =
      Enum.find(state.entries, &Enum.any?(&1.descriptors, fn tool -> tool.tool_name == name end))

    result =
      case entry do
        nil ->
          failure(:not_found, "plugin function is not in this runtime's catalog", name)

        %{exit: exit} when not is_nil(exit) ->
          failure(:unavailable, "plugin Session has exited", exit)

        %{session: session} ->
          invoke(fn -> Session.call_tool(session, state.run_id, name, arguments) end)
      end

    {:reply, result, state}
  end

  def handle_call(:close, _from, state) do
    {result, state} = close_entries(state)
    {:reply, result, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_monitor: ref} = state) do
    {result, state} = close_entries(state)

    case result do
      :ok -> {:stop, :normal, state}
      {:error, _} -> {:noreply, %{state | owner: nil, owner_monitor: nil}}
    end
  end

  def handle_info({:EXIT, session, reason}, state) do
    entries =
      Enum.map(state.entries, fn
        %{session: ^session, close_result: nil} = entry -> %{entry | exit: reason}
        entry -> entry
      end)

    {:noreply, %{state | entries: entries}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    {result, _state} = close_entries(state)
    result
  end

  defp prepare(state, installations, opts) do
    Enum.reduce_while(installations, state, fn record, acc ->
      with {:ok, installation} <- installation(record),
           {:ok, session} <-
             invoke(fn ->
               Session.start_link(
                 Keyword.merge(opts, installation: installation, run_id: acc.run_id)
               )
             end) do
        entry = %{
          installation: installation,
          source_id: source_id(record),
          session: session,
          descriptors: [],
          components: %{},
          diagnostics: [],
          cleanup_report: nil,
          close_result: nil,
          exit: nil
        }

        case invoke(fn ->
               with {:ok, catalog} <- Session.catalog(session, acc.run_id),
                    do: {:ok, {catalog, Session.snapshot(session)}}
             end) do
          {:ok, {catalog, snapshot}} ->
            descriptors =
              catalog.registry.tools |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1))

            entry = %{
              entry
              | descriptors: descriptors,
                components: snapshot.components,
                diagnostics: snapshot.diagnostics
            }

            {:cont, %{acc | entries: acc.entries ++ [entry]}}

          {:error, error} ->
            {:halt, %{acc | entries: acc.entries ++ [entry], preparation_error: error}}
        end
      else
        {:error, error} -> {:halt, %{acc | preparation_error: error}}
      end
    end)
  end

  defp installation(record) do
    Enum.reduce_while(@installation_keys, {:ok, %{}}, fn key, {:ok, acc} ->
      case Map.fetch(record, Atom.to_string(key)) do
        {:ok, value} when is_binary(value) and value != "" ->
          {:cont, {:ok, Map.put(acc, key, value)}}

        _ ->
          {:halt, failure(:validation, "installed plugin receipt is incomplete", key)}
      end
    end)
  end

  defp source_id(record) do
    "plugin:" <>
      Archive.digest(
        Jason.encode!(
          Enum.map(
            ~w(registry_url plugin_id release_id artifact_digest content_digest),
            &record[&1]
          )
        )
      )
  end

  defp close_entries(%{close_result: result} = state) when not is_nil(result),
    do: {result, state}

  defp close_entries(state) do
    entries =
      Enum.map(state.entries, fn entry ->
        {result, report} =
          if is_nil(entry.exit) do
            close_session(entry.session)
          else
            {failure(
               :unknown_outcome,
               "plugin Session exited without a cleanup acknowledgement",
               entry.exit
             ), nil}
          end

        %{entry | close_result: result, cleanup_report: report}
      end)

    result = Enum.find_value(entries, :ok, &if(&1.close_result != :ok, do: &1.close_result))
    {result, %{state | entries: entries, close_result: result}}
  end

  defp close_session(session) do
    case invoke(fn -> Session.close(session) end) do
      {:ok, report} -> {invoke(fn -> Session.stop(session) end), report}
      {:error, _} = error -> {error, nil}
    end
  end

  defp invoke(fun) do
    case fun.() do
      :ok -> :ok
      {:ok, _} = result -> result
      {:error, %Error{}} = result -> result
      {:error, cause} -> failure(:execution_failure, "public plugin operation failed", cause)
      other -> failure(:unknown_outcome, "public plugin operation did not acknowledge", other)
    end
  catch
    :exit, cause ->
      failure(:unknown_outcome, "public plugin operation did not acknowledge", cause)
  end

  defp request(runtime, message, class) do
    GenServer.call(runtime, message, :infinity)
  catch
    :exit, cause -> failure(class, "plugin runtime did not acknowledge", cause)
  end

  defp failure(class, message, cause), do: {:error, Error.new(class, message, cause: cause)}
end
