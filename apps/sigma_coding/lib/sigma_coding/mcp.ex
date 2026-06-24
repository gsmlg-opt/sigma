defmodule Sigma.Coding.MCP do
  @moduledoc """
  Discovers and executes tools exposed by configured MCP servers.

  Each server is backed by a long-lived `Anubis.Client` process started under
  `Sigma.Coding.MCP.ClientSupervisor` and addressed through `Sigma.Coding.MCP.Registry`.
  Clients are keyed by `{session_id, server_id}` so a session keeps its
  connections warm across many tool calls.

  Lifecycle is owned by the caller (the agent session process):

    * `start_session/3` starts the clients and returns the discovered tools
      plus opaque handles used to tear them down.
    * `stop/1` terminates the clients for those handles.
    * `call_tool/4` routes a tool call to the live client carried by the tool.
  """

  alias Sigma.Coding.MCP.Tool

  @registry Sigma.Coding.MCP.Registry
  @supervisor Sigma.Coding.MCP.ClientSupervisor

  @protocol_version "2025-06-18"
  @client_info %{"name" => "sigma", "version" => "0.1.0"}

  @startup_timeout 15_000
  @call_timeout 30_000

  @type handle :: pid()

  @doc """
  Starts (or reuses) a persistent client per server and lists their tools.

  Returns `{:ok, tools, handles}`. A server that fails to connect or list its
  tools is skipped (with telemetry) rather than failing the whole session.
  Pass `:cwd` to set the working directory for stdio servers and `:timeout`
  to bound the connect/list step.
  """
  @spec start_session(String.t(), map(), keyword()) :: {:ok, [Tool.t()], [handle()]}
  def start_session(session_id, servers, opts \\ []) when is_map(servers) do
    {tools, handles} =
      Enum.reduce(servers, {[], []}, fn {server_id, server}, {tools_acc, handles_acc} ->
        case ensure_client(session_id, server_id, server, opts) do
          {:ok, client, sup} ->
            case list_tools(client, opts) do
              {:ok, mcp_tools} ->
                discovered = Enum.map(mcp_tools, &to_tool(server_id, client, &1))
                {tools_acc ++ discovered, [sup | handles_acc]}

              {:error, reason} ->
                telemetry_error(server_id, reason)
                {tools_acc, [sup | handles_acc]}
            end

          {:error, reason} ->
            telemetry_error(server_id, reason)
            {tools_acc, handles_acc}
        end
      end)

    {:ok, tools, Enum.reverse(handles)}
  end

  @doc """
  Terminates the client supervision trees referenced by `handles`.
  """
  @spec stop([handle()]) :: :ok
  def stop(handles) when is_list(handles) do
    Enum.each(handles, fn sup ->
      DynamicSupervisor.terminate_child(@supervisor, sup)
    end)

    :ok
  end

  @doc """
  Executes a discovered MCP tool against its live client.
  """
  def call_tool(%Tool{client: client} = tool, _tool_call_id, params, opts) do
    timeout = Keyword.get(opts, :timeout, @call_timeout)

    try do
      case Anubis.Client.call_tool(client, tool.server_tool_name, params || %{}, timeout: timeout) do
        {:ok, %Anubis.MCP.Response{} = response} ->
          result = Anubis.MCP.Response.get_result(response) || %{}

          {:ok,
           %{
             content: normalize_content(result["content"]),
             details: result,
             is_error: Anubis.MCP.Response.error?(response)
           }}

        {:error, error} ->
          {:error, format_error(error)}
      end
    catch
      :exit, reason -> {:error, "MCP tool call failed: #{inspect(reason)}"}
    end
  end

  defp ensure_client(session_id, server_id, server, opts) do
    ref = System.unique_integer([:positive])
    client = client_via(session_id, server_id, ref)

    spec =
      {Anubis.Client,
       name: client,
       transport_name: transport_via(session_id, server_id, ref),
       transport: transport_config(server, opts),
       client_info: client_info(session_id, server_id, ref),
       capabilities: %{},
       protocol_version: @protocol_version}

    case DynamicSupervisor.start_child(@supervisor, spec) do
      {:ok, sup} -> await_ready(client, sup, opts)
      {:error, reason} -> {:error, reason}
    end
  end

  defp await_ready(client, sup, opts) do
    timeout = Keyword.get(opts, :timeout, @startup_timeout)

    try do
      case Anubis.Client.await_ready(client, timeout: timeout) do
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
      case Anubis.Client.list_tools(client, timeout: timeout) do
        {:ok, %Anubis.MCP.Response{} = response} ->
          result = Anubis.MCP.Response.get_result(response) || %{}
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
      server_id: server_id,
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

  defp format_error(%Anubis.MCP.Error{message: message}) when is_binary(message), do: message

  defp format_error(%Anubis.MCP.Error{reason: reason}) when not is_nil(reason),
    do: inspect(reason)

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
