defmodule Sigma.Coding.MCP do
  @moduledoc """
  Discovers and executes tools exposed by configured MCP servers.

  Each server is backed by a long-lived `Backplane.McpProtocol.Client` process
  started under `Sigma.Coding.MCP.ClientSupervisor` and addressed through
  `Sigma.Coding.MCP.Registry`. Clients are keyed by `{session_id, server_id}` so
  a session keeps its connections warm across many tool calls.

  Lifecycle is owned by the caller (the agent session process):

    * `start_session/3` starts the clients and returns the discovered tools
      plus opaque session metadata used to tear them down.
    * `stop/1` closes subscriptions and terminates the client supervisors.
    * `call_tool/4` routes a tool call to the live client carried by the tool.
    * `refresh_server_tools/3` re-lists tools for one live client after a
      `tools/list_changed` notification.
  """

  alias Backplane.McpProtocol.Client
  alias Backplane.McpProtocol.MCP.Error
  alias Backplane.McpProtocol.MCP.Response
  alias Backplane.McpProtocol.Protocol
  alias Sigma.Coding.MCP.Tool

  @registry Sigma.Coding.MCP.Registry
  @supervisor Sigma.Coding.MCP.ClientSupervisor

  @client_info %{"name" => "sigma", "version" => "0.1.0"}

  @startup_timeout 15_000
  @call_timeout 60_000

  @type handle :: pid()
  @type client_ref :: term()

  @type session :: %{
          handles: [handle()],
          subscriptions: [{String.t(), client_ref(), term()}],
          clients: %{optional(String.t()) => client_ref()}
        }

  @doc """
  Starts a persistent client per server and lists their tools.

  Returns `{:ok, tools, session}`. A server that fails to connect or list its
  tools is skipped (with telemetry) rather than failing the whole session.

  Options:

    * `:cwd` — working directory for stdio servers and MCP roots
    * `:timeout` — connect/list timeout
    * `:subscriber` — process that receives `{:mcp_subscription, handle, notification}`
    * `:elicitation_callback` — `(message, schema) -> {:accept, map} | :decline | :cancel`
    * `:sampling_callback` — `(params) -> {:ok, map} | {:error, reason}`
  """
  @spec start_session(String.t(), map(), keyword()) :: {:ok, [Tool.t()], session()}
  def start_session(session_id, servers, opts \\ []) when is_map(servers) do
    {tools, session} =
      Enum.reduce(servers, {[], empty_session()}, fn {server_id, server},
                                                     {tools_acc, session_acc} ->
        case ensure_client(session_id, server_id, server, opts) do
          {:ok, client, sup} ->
            configure_client!(client, opts)

            session_acc =
              session_acc
              |> put_handle(sup)
              |> put_client(server_id, client)
              |> maybe_subscribe(to_string(server_id), client, opts)

            case list_tools(client, opts) do
              {:ok, mcp_tools} ->
                discovered = Enum.map(mcp_tools, &to_tool(server_id, client, &1))
                {tools_acc ++ discovered, session_acc}

              {:error, reason} ->
                telemetry_error(server_id, reason)
                {tools_acc, session_acc}
            end

          {:error, reason} ->
            telemetry_error(server_id, reason)
            {tools_acc, session_acc}
        end
      end)

    {:ok, tools, finalize_session(session)}
  end

  @doc """
  Closes subscriptions and terminates client supervision trees.
  """
  @spec stop(session() | [handle()]) :: :ok
  def stop(%{handles: handles, subscriptions: subscriptions}) do
    Enum.each(subscriptions, fn {_server_id, client, subscription} ->
      _ = Client.close_subscription(client, subscription)
    end)

    Enum.each(handles, fn sup ->
      DynamicSupervisor.terminate_child(@supervisor, sup)
    end)

    :ok
  end

  def stop(handles) when is_list(handles) do
    Enum.each(handles, fn
      %{handles: _} = session -> stop(session)
      sup when is_pid(sup) -> DynamicSupervisor.terminate_child(@supervisor, sup)
      _ -> :ok
    end)

    :ok
  end

  @doc """
  Re-lists tools for a live client after a catalog change notification.
  """
  @spec refresh_server_tools(String.t(), client_ref(), keyword()) ::
          {:ok, [Tool.t()]} | {:error, String.t()}
  def refresh_server_tools(server_id, client, opts \\ []) do
    case list_tools(client, opts) do
      {:ok, mcp_tools} ->
        {:ok, Enum.map(mcp_tools, &to_tool(server_id, client, &1))}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Executes a discovered MCP tool against its live client.
  """
  def call_tool(%Tool{client: client} = tool, _tool_call_id, params, opts) do
    timeout = Keyword.get(opts, :timeout, @call_timeout)

    try do
      case Client.call_tool(client, tool.server_tool_name, params || %{}, timeout: timeout) do
        {:ok, %Response{} = response} ->
          result = Response.get_result(response) || %{}
          content = normalize_tool_content(result)

          {:ok,
           %{
             content: content,
             details: result,
             is_error: Response.error?(response)
           }}

        {:error, error} ->
          {:error, format_error(error)}
      end
    catch
      :exit, reason -> {:error, "MCP tool call failed: #{inspect(reason)}"}
    end
  end

  defp empty_session do
    %{handles: [], subscriptions: [], clients: %{}}
  end

  defp finalize_session(session) do
    %{
      handles: Enum.reverse(session.handles),
      subscriptions: Enum.reverse(session.subscriptions),
      clients: session.clients
    }
  end

  defp put_handle(session, handle), do: %{session | handles: [handle | session.handles]}

  defp put_client(session, server_id, client) do
    %{session | clients: Map.put(session.clients, to_string(server_id), client)}
  end

  defp maybe_subscribe(session, server_id, client, opts) do
    subscriber = Keyword.get(opts, :subscriber, self())

    case Client.get_protocol_info(client) do
      %{era: :modern} ->
        case Client.listen_subscriptions(client, ["notifications/tools/list_changed"],
               subscriber: subscriber
             ) do
          {:ok, subscription} ->
            %{
              session
              | subscriptions: [{server_id, client, subscription} | session.subscriptions]
            }

          {:error, _reason} ->
            session
        end

      _other ->
        session
    end
  rescue
    _ -> session
  catch
    :exit, _ -> session
  end

  defp configure_client!(client, opts) do
    cwd = Keyword.get(opts, :cwd)

    if is_binary(cwd) and cwd != "" do
      uri = cwd_to_file_uri(cwd)
      _ = Client.add_root(client, uri, "workspace")
    end

    case Keyword.get(opts, :elicitation_callback) do
      callback when is_function(callback, 2) ->
        Client.register_elicitation_callback(client, callback)

      _ ->
        Client.register_elicitation_callback(client, fn _message, _schema -> :decline end)
    end

    case Keyword.get(opts, :sampling_callback) do
      callback when is_function(callback, 1) ->
        Client.register_sampling_callback(client, callback)

      _ ->
        Client.register_sampling_callback(client, fn _params ->
          {:error, "MCP sampling is not configured for this session"}
        end)
    end

    :ok
  end

  defp cwd_to_file_uri(cwd) do
    abs = Path.expand(cwd)
    "file://" <> abs
  end

  defp client_capabilities do
    Enum.reduce([:roots, :elicitation, :sampling], %{}, &Client.parse_capability/2)
  end

  defp ensure_client(session_id, server_id, server, opts) do
    ensure_client(session_id, server_id, server, opts, :auto)
  end

  defp ensure_client(session_id, server_id, server, opts, protocol_version) do
    ref = System.unique_integer([:positive])
    client = client_via(session_id, server_id, ref)

    spec =
      {Client,
       name: client,
       transport_name: transport_via(session_id, server_id, ref),
       transport: transport_config(server, opts),
       client_info: client_info(session_id, server_id, ref),
       capabilities: client_capabilities(),
       protocol_version: protocol_version}

    case DynamicSupervisor.start_child(@supervisor, spec) do
      {:ok, sup} ->
        case await_ready(client, sup, opts) do
          {:error, %Error{reason: :method_not_found}} when protocol_version == :auto ->
            _ = DynamicSupervisor.terminate_child(@supervisor, sup)
            ensure_client(session_id, server_id, server, opts, Protocol.fallback_version())

          result ->
            result
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp await_ready(client, sup, opts) do
    timeout = Keyword.get(opts, :timeout, @startup_timeout)

    try do
      case Client.await_ready(client, timeout: timeout) do
        :ok -> {:ok, client, sup}
        {:error, reason} -> {:error, reason}
      end
    catch
      :exit, reason -> {:error, reason}
    end
  end

  defp list_tools(client, opts) do
    timeout = Keyword.get(opts, :timeout, @startup_timeout)

    try do
      case Client.list_tools(client, timeout: timeout) do
        {:ok, %Response{} = response} ->
          result = Response.get_result(response) || %{}
          {:ok, Map.get(result, "tools", [])}

        {:error, error} ->
          {:error, format_error(error)}
      end
    catch
      :exit, reason -> {:error, reason}
    end
  end

  defp transport_config(server, opts) do
    case server["type"] do
      "stdio" ->
        config =
          [
            command: expand_env(to_string(server["command"] || "")),
            args: Enum.map(server["args"] || [], &expand_env(to_string(&1)))
          ]
          |> maybe_put(:env, expand_env_map(server["env"]))
          |> maybe_put(:cwd, server["cwd"] || Keyword.get(opts, :cwd))

        {:stdio, config}

      _http ->
        uri = server["url"] |> to_string() |> expand_env() |> URI.parse()
        base_url = %URI{uri | path: nil, query: nil, fragment: nil} |> URI.to_string()
        mcp_path = if uri.path in [nil, ""], do: "/mcp", else: uri.path

        config =
          [base_url: base_url, mcp_path: mcp_path]
          |> maybe_put(:headers, expand_env_map(server["headers"]))

        {:streamable_http, config}
    end
  end

  defp maybe_put(opts, _key, value) when value in [nil, %{}], do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp client_via(session_id, server_id, ref) do
    {:via, Registry, {@registry, {:client, session_id, server_id, ref}}}
  end

  defp transport_via(session_id, server_id, ref) do
    {:via, Registry, {@registry, {:transport, session_id, server_id, ref}}}
  end

  defp client_info(session_id, server_id, ref) do
    Map.put(@client_info, "name", unique_client_name(session_id, server_id, ref))
  end

  defp unique_client_name(session_id, server_id, ref) do
    hash =
      :crypto.hash(:sha256, :erlang.term_to_binary({session_id, server_id, ref}))
      |> Base.encode16(case: :lower)
      |> String.slice(0, 16)

    "sigma_#{hash}"
  end

  defp telemetry_error(server_id, reason) do
    :telemetry.execute(
      [:sigma, :mcp, :server, :error],
      %{system_time: System.system_time()},
      %{server_id: server_id, reason: inspect(reason)}
    )
  end

  defp to_tool(server_id, client, mcp_tool) do
    server_tool_name = mcp_tool["name"] || ""

    %Tool{
      name: tool_name(server_id, server_tool_name),
      description: mcp_tool["description"] || "MCP tool #{server_id}/#{server_tool_name}",
      schema: mcp_tool["inputSchema"] || %{"type" => "object", "properties" => %{}},
      server_id: to_string(server_id),
      client: client,
      server_tool_name: server_tool_name
    }
  end

  defp tool_name(server_id, tool_name) do
    "mcp__#{tool_safe_name(server_id, 20)}__#{tool_safe_name(tool_name, 36)}"
  end

  defp tool_safe_name(value, max_length) do
    safe =
      value
      |> to_string()
      |> String.replace(~r/[^A-Za-z0-9_-]/, "_")

    if String.length(safe) <= max_length do
      safe
    else
      hash = :crypto.hash(:sha256, safe) |> Base.encode16(case: :lower) |> String.slice(0, 6)

      safe
      |> String.slice(0, max_length - 7)
      |> then(&"#{&1}_#{hash}")
    end
  end

  defp normalize_tool_content(result) when is_map(result) do
    case normalize_content(result["content"]) do
      [] ->
        case Map.get(result, "structuredContent") do
          nil -> []
          structured -> [%{type: :text, text: inspect(structured)}]
        end

      content ->
        content
    end
  end

  defp normalize_tool_content(_), do: []

  defp normalize_content(content) when is_list(content) do
    Enum.map(content, &normalize_content_block/1)
  end

  defp normalize_content(content) when is_binary(content) do
    [%{type: :text, text: content}]
  end

  defp normalize_content(_), do: []

  defp normalize_content_block(%{"type" => "text", "text" => text}) do
    %{type: :text, text: text}
  end

  defp normalize_content_block(%{"type" => "image", "data" => data, "mimeType" => mime_type}) do
    %{type: :image, data: data, mime_type: mime_type}
  end

  defp normalize_content_block(%{"type" => "image", "data" => data, "mime_type" => mime_type}) do
    %{type: :image, data: data, mime_type: mime_type}
  end

  defp normalize_content_block(block) do
    %{type: :text, text: inspect(block)}
  end

  defp format_error(%Error{message: message}) when is_binary(message), do: message
  defp format_error(%Error{reason: reason}) when not is_nil(reason), do: inspect(reason)
  defp format_error(error), do: inspect(error)

  defp expand_env_map(values) when is_map(values) and map_size(values) > 0 do
    Map.new(values, fn {key, value} ->
      {to_string(key), expand_env(to_string(value))}
    end)
  end

  defp expand_env_map(_), do: %{}

  defp expand_env(value) do
    Regex.replace(~r/\$\{([A-Za-z_][A-Za-z0-9_]*)(:-([^}]*))?\}/, value, fn
      _full, name, _default_expr, default ->
        System.get_env(name) || default || ""
    end)
  end
end
