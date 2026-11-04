defmodule Sigma.Agent.Backplane.PluginResources do
  @moduledoc """
  Configured Backplane plugin catalogs and durable installation requests.

  One application-owned writer serializes requests under the configured root.
  Catalog reads use the public Plugin Protocol client and never create files.
  Requests retain their original Runtime invocation and exact arguments. Exact
  retries return the saved receipt without another write. Native calls retain
  their public request identity and wait for an explicit settings or Protocol
  installation. Host outcomes are durable facts separate from Runtime settlement;
  late installation never rewrites an already settled tool result. Native calls
  never install or activate plugins automatically.
  """

  use GenServer, restart: :temporary

  alias Backplane.AgentRuntime.Codex.{DynamicRuntime, Session}
  alias Backplane.AgentRuntime.Error
  alias Backplane.AgentRuntime.Plugins.Session, as: PluginSession
  alias Backplane.PluginProtocol.{Archive, Client}
  alias Sigma.Agent.Backplane.PluginPackages
  alias Sigma.Agent.Backplane.Store.FileSystem
  alias Sigma.Session.ConfigManager

  @identity_fields ~w(caller run_id incarnation step_id attempt_id invocation_id enclosing_invocation_id tool_call_id turn_id)a

  def open(nil), do: {:ok, nil}

  def open(%{"registryUrl" => url} = config) when is_binary(url) and url != "" do
    root =
      config["requestsRoot"] || Path.join(apply(ConfigManager, :agent_dir, []), "plugins")

    root = Path.expand(root)

    client =
      Client.new(
        base_url: url,
        headers: Enum.to_list(config["headers"] || %{}),
        transport: &transport/1
      )

    with {:ok, writer} <- writer(root),
         do: {:ok, %{root: root, writer: writer, client: client, registry_url: client.base_url}}
  end

  def open(_config),
    do: error(:validation, "plugin configuration requires registryUrl")

  def start_link(root), do: GenServer.start_link(__MODULE__, root, name: via(root))

  @doc "Resolves the application writer for a new run without reading or rewriting storage."
  def refresh(nil), do: {:ok, nil}

  def refresh(%{root: root} = host) do
    with {:ok, writer} <- writer(root), do: {:ok, %{host | writer: writer}}
  end

  def list_candidates(operation, _context) do
    with {:ok, host} <- host(operation),
         {:ok, catalog} <- Client.catalog(host.client) do
      {:ok, catalog}
    else
      {:error, %Error{}} = error ->
        error

      {:error, reason} ->
        error(:execution_failure, "plugin catalog request failed", reason)
    end
  end

  def request_install(arguments, operation) do
    with {:ok, host} <- host(operation),
         {:ok, request} <-
           GenServer.call(
             host.writer,
             {:request, host.registry_url, arguments, operation},
             :infinity
           ) do
      if is_binary(request["plugin_request_id"]),
        do: observe_installation(host, request, operation),
        else: {:ok, request}
    end
  catch
    :exit, cause -> error(:unknown_outcome, "plugin request did not acknowledge", cause)
  end

  @doc "Installs a saved request through the configured host, independently of a native tool call."
  def install(host, request_id, confirmation_source \\ nil) do
    GenServer.call(
      host.writer,
      {:install, host.registry_url, host.client, request_id, confirmation_source},
      :infinity
    )
  catch
    :exit, cause -> error(:unknown_outcome, "plugin installation did not acknowledge", cause)
  end

  @doc "Pins the newest installed release per plugin in the configured registry without effects."
  def installed(nil), do: {:ok, []}

  def installed(host) do
    GenServer.call(host.writer, {:installed, host.registry_url}, :infinity)
  catch
    :exit, cause -> error(:unavailable, "plugin installation host is unavailable", cause)
  end

  @doc "Reads requests and installation receipts together under their application writer."
  def requests(host) do
    GenServer.call(host.writer, {:requests, host.registry_url}, :infinity)
  catch
    :exit, cause -> error(:unavailable, "plugin installation host is unavailable", cause)
  end

  @doc "Starts a public run-owned plugin Session; the calling host owns and must stop it."
  def activate(host, request_id, run_id, opts \\ []) do
    with {:ok, record} <-
           GenServer.call(host.writer, {:installation, host.registry_url, request_id}, :infinity) do
      installation =
        Map.new(~w(root data_dir plugin_id release_id artifact_digest content_digest)a, fn key ->
          {key, Map.fetch!(record, Atom.to_string(key))}
        end)

      PluginSession.start_link(Keyword.merge(opts, installation: installation, run_id: run_id))
    end
  catch
    :exit, cause -> error(:unavailable, "plugin activation host is unavailable", cause)
  end

  @impl true
  def init(root),
    do: {:ok, %{root: root, path: Path.join(root, "requests.json"), completion_errors: %{}}}

  @impl true
  def handle_call({:request, registry, arguments, operation}, _from, state) do
    result =
      with {:ok, _host} <- host(operation),
           {:ok, requests} <- load(state.path) do
        identity = Enum.map(@identity_fields, &Map.get(operation, &1))

        id =
          "plugin-request-" <>
            Base.url_encode64(:crypto.hash(:sha256, Jason.encode!([registry | identity])),
              padding: false
            )

        case Enum.find(requests, &(&1["id"] == id)) do
          nil ->
            request = %{
              "id" => id,
              "status" => "requested",
              "registry_url" => registry,
              "arguments" => arguments,
              "plugin_request_id" => Map.get(operation, :plugin_request_id),
              "invocation" =>
                Map.new(@identity_fields, &{Atom.to_string(&1), Map.get(operation, &1)}),
              "requested_at" => System.system_time(:microsecond)
            }

            with :ok <- save(state.path, requests ++ [request]), do: {:ok, request}

          %{"arguments" => ^arguments} = request ->
            if request["plugin_request_id"] == Map.get(operation, :plugin_request_id),
              do: {:ok, request},
              else: error(:resource_conflict, "plugin invocation has a different public request")

          _ ->
            error(:resource_conflict, "plugin invocation already has a different request")
        end
      end

    {:reply, result, state}
  end

  def handle_call({:install, registry, client, request_id, source}, _from, state) do
    result =
      with true <- source in [nil, :settings, :protocol],
           {:ok, requests} <- load(state.path) do
        case Enum.find(requests, &(&1["id"] == request_id)) do
          %{"registry_url" => ^registry} = request ->
            install_request(state, client, request, source)

          nil ->
            error(:validation, "plugin request was not found")

          _ ->
            error(:validation, "plugin request belongs to another registry")
        end
      else
        false -> error(:validation, "plugin installation confirmation source is invalid")
        {:error, _} = error -> error
      end

    case result do
      {:host_outcome, installed, request, source} ->
        case save_completion(state, request, source, installed) do
          :ok ->
            {:reply, installed, state}

          {:error, _} = failure ->
            # Installation may already be durable. Preserve its acknowledgement
            # independently of the native completion fact that could not commit.
            next = put_in(state.completion_errors[request["id"]], failure)
            {:reply, installed, next}
        end

      result ->
        {:reply, result, state}
    end
  end

  def handle_call({:native_outcome, request}, _from, state) do
    result =
      case Map.fetch(state.completion_errors, request["id"]) do
        {:ok, failure} -> failure
        :error -> completion(state, request)
      end

    {:reply, result, state}
  end

  def handle_call({:installation, registry, request_id}, _from, state),
    do: {:reply, PluginPackages.lookup(state.root, registry, request_id), state}

  def handle_call({:installed, registry}, _from, state),
    do: {:reply, PluginPackages.installed(state.root, registry), state}

  def handle_call({:requests, registry}, _from, state) do
    result =
      with {:ok, requests} <- load(state.path),
           {:ok, installations} <- PluginPackages.records(state.root, registry) do
        {:ok,
         %{
           requests: Enum.filter(requests, &(&1["registry_url"] == registry)),
           installations: installations
         }}
      end

    {:reply, result, state}
  end

  defp host(%{backend_context: %{plugin_resources: %{binding: binding} = host}} = operation) do
    with {:ok, _owner} <- Session.validate(binding, operation), do: {:ok, host}
  catch
    :exit, cause -> error(:cancelled, "plugin Session is unavailable before dispatch", cause)
  end

  defp host(_operation), do: error(:unsupported_capability, "plugin host is not configured")

  defp observe_installation(host, request, %{backend_context: %{runtime: runtime}} = operation)
       when is_pid(runtime) do
    DynamicRuntime.plugin_install_wait(operation, request["id"], fn ->
      await_installation(host, request, operation)
    end)
  end

  # Explicit host callers have no Runtime effect to register or retire.
  defp observe_installation(host, request, operation),
    do: await_installation(host, request, operation)

  defp await_installation(host, request, operation) do
    with {:ok, _host} <- host(operation),
         {:ok, outcome} <- GenServer.call(host.writer, {:native_outcome, request}, :infinity) do
      case outcome do
        nil ->
          receive do
          after
            100 -> await_installation(host, request, operation)
          end

        %{result: {:error, %Error{}} = failure} ->
          failure

        %{result: {:ok, _installed}, confirmation_source: source}
        when source in [:settings, :protocol] ->
          # The installation may arrive after cancellation. Its durable host
          # receipt never establishes that the original Runtime is still live.
          with {:ok, _host} <- host(operation) do
            {:ok,
             {:completed,
              %{
                completed: true,
                user_confirmed: true,
                tool_type: request["arguments"]["tool_type"],
                action_type: request["arguments"]["action_type"],
                tool_id: request["arguments"]["tool_id"]
              }}}
          end
      end
    end
  end

  defp install_request(state, client, request, source) do
    if source && is_binary(request["plugin_request_id"]) do
      with {:ok, saved} <- completion(state, request) do
        case saved do
          nil ->
            result =
              with {:ok, installed} <- PluginPackages.install(state.root, client, request),
                   :ok <- verify_installation(installed),
                   do: {:ok, installed}

            {:host_outcome, result, request, source}

          %{result: {:error, _} = failure} ->
            # A native failure is immutable. An explicit host check may still
            # confirm an independently pending package without preparing it again.
            with {:ok, records} <- PluginPackages.records(state.root, request["registry_url"]) do
              case Enum.find(records, &(&1["request_id"] == request["id"])) do
                %{"status" => status} when status in ["installing", "installed"] ->
                  PluginPackages.install(state.root, client, request)

                _ ->
                  failure
              end
            end

          %{result: result} ->
            result
        end
      end
    else
      PluginPackages.install(state.root, client, request)
    end
  end

  defp verify_installation(installed) do
    with {:ok, snapshot} <- Archive.read_directory_with_metadata(installed["root"]),
         {:ok, bytes} <- Archive.pack(snapshot.files, modes: snapshot.modes),
         true <- Archive.digest(bytes) == installed["content_digest"] do
      :ok
    else
      cause -> error(:execution_failure, "installed plugin verification failed", cause)
    end
  end

  defp completion(state, request) do
    with {:ok, outcomes} <- load_completions(state.root) do
      public_id = request["plugin_request_id"]
      invocation = request["invocation"]

      case Map.get(outcomes, request["id"]) do
        nil ->
          {:ok, nil}

        %{plugin_request_id: ^public_id, invocation: ^invocation} = outcome ->
          {:ok, outcome}

        _ ->
          error(:resource_conflict, "plugin completion belongs to another invocation")
      end
    end
  end

  defp save_completion(state, request, source, result) do
    with {:ok, outcomes} <- load_completions(state.root) do
      outcome = %{
        plugin_request_id: request["plugin_request_id"],
        invocation: request["invocation"],
        confirmation_source: source,
        confirmed_at: System.system_time(:microsecond),
        result: result
      }

      bytes =
        :erlang.term_to_binary(%{version: 1, outcomes: Map.put(outcomes, request["id"], outcome)})

      case FileSystem.write_atomic(Path.join(state.root, "native-installations.etf"), bytes) do
        :ok ->
          :ok

        {:error, cause} ->
          error(:unknown_outcome, "native plugin completion persistence is unconfirmed", cause)
      end
    else
      {:error, cause} ->
        error(:unknown_outcome, "native plugin completion persistence is unconfirmed", cause)
    end
  end

  defp load_completions(root) do
    case File.read(Path.join(root, "native-installations.etf")) do
      {:ok, bytes} ->
        case :erlang.binary_to_term(bytes, [:safe]) do
          %{version: 1, outcomes: outcomes} when is_map(outcomes) ->
            if Enum.all?(outcomes, &stored_completion?/1),
              do: {:ok, outcomes},
              else:
                error(:execution_failure, "native plugin completion store has malformed records")

          _ ->
            error(:execution_failure, "native plugin completion store is malformed")
        end

      {:error, :enoent} ->
        {:ok, %{}}

      {:error, cause} ->
        error(:execution_failure, "native plugin completion store read failed", cause)
    end
  rescue
    cause -> error(:execution_failure, "native plugin completion store is malformed", cause)
  end

  defp stored_completion?(
         {id,
          %{
            plugin_request_id: public_id,
            invocation: invocation,
            confirmation_source: source,
            confirmed_at: time,
            result: result
          }}
       ) do
    is_binary(id) and is_binary(public_id) and public_id != "" and is_map(invocation) and
      source in [:settings, :protocol] and is_integer(time) and
      case result do
        {:ok, %{"status" => "installed", "request_id" => ^id}} -> true
        {:error, %Error{}} -> true
        _ -> false
      end
  end

  defp stored_completion?(_), do: false

  defp load(path) do
    case File.read(path) do
      {:ok, bytes} ->
        case Jason.decode(bytes) do
          {:ok, %{"version" => 1, "requests" => requests}} when is_list(requests) ->
            if Enum.all?(requests, &stored_request?/1),
              do: {:ok, requests},
              else: error(:execution_failure, "plugin request store has malformed records")

          result ->
            error(:execution_failure, "plugin request store is malformed", result)
        end

      {:error, :enoent} ->
        {:ok, []}

      {:error, cause} ->
        error(:execution_failure, "plugin request store read failed", cause)
    end
  end

  defp stored_request?(%{
         "id" => id,
         "status" => "requested",
         "registry_url" => registry,
         "arguments" => arguments,
         "invocation" => invocation,
         "requested_at" => timestamp
       }) do
    is_binary(id) and is_binary(registry) and is_map(arguments) and is_map(invocation) and
      is_integer(timestamp)
  end

  defp stored_request?(_request), do: false

  defp save(path, requests) do
    with {:ok, bytes} <- Jason.encode(%{version: 1, requests: requests}),
         :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- FileSystem.write_atomic(path, bytes) do
      :ok
    else
      {:error, cause} ->
        error(:unknown_outcome, "plugin request persistence is unconfirmed", cause)
    end
  end

  defp transport(request) do
    case Req.request(
           method: request.method,
           url: request.url,
           headers: request.headers,
           body: request.body,
           decode_body: false,
           receive_timeout: 30_000,
           retry: false,
           redirect: false
         ) do
      {:ok, response} -> {:ok, %{status: response.status, body: response.body}}
      {:error, _} = error -> error
    end
  end

  defp via(root),
    do: {:via, Registry, {Sigma.Agent.RepositoryRegistry, {:plugin_requests, root}}}

  defp writer(root) do
    case DynamicSupervisor.start_child(Sigma.Agent.DynamicSupervisor, {__MODULE__, root}) do
      {:ok, writer} -> {:ok, writer}
      {:error, {:already_started, writer}} -> {:ok, writer}
      {:error, _} = error -> error
    end
  end

  defp error(class, message, cause \\ nil),
    do: {:error, Error.new(class, message, cause: cause)}
end
