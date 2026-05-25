defmodule PiCoding.MCP.Client do
  @moduledoc """
  Minimal MCP client for tool discovery and calls.

  Supports stdio and Streamable HTTP-style request/response calls. Legacy SSE
  config entries are treated as HTTP endpoints.
  """

  @protocol_version "2025-06-18"
  @default_timeout 5_000

  def list_tools(server, opts \\ []) do
    with {:ok, result} <- request(server, "tools/list", %{}, opts) do
      {:ok, Map.get(result, "tools", [])}
    end
  end

  def call_tool(server, name, arguments, opts \\ []) do
    request(server, "tools/call", %{"name" => name, "arguments" => arguments || %{}}, opts)
  end

  def request(server, method, params, opts \\ []) do
    server = normalize_server(server)

    case server["type"] do
      "stdio" ->
        stdio_request(server, method, params, opts)

      transport when transport in ["http", "streamable-http", "sse"] ->
        http_request(Map.put(server, "type", "http"), method, params, opts)

      other ->
        {:error, "Unsupported MCP transport: #{inspect(other)}"}
    end
  end

  defp stdio_request(server, method, params, opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    command = expand_env(server["command"] || "")
    args = Enum.map(server["args"] || [], &expand_env(to_string(&1)))

    with {:ok, executable} <- find_executable(command),
         {:ok, port} <- open_stdio_port(executable, args, server, opts) do
      try do
        with {:ok, context} <- initialize_stdio(port, timeout),
             {:ok, result, _context} <- stdio_json_rpc(context, method, params, timeout) do
          {:ok, result}
        end
      after
        close_port(port)
      end
    else
      {:error, _reason} = error -> error
      other -> {:error, "MCP stdio request failed: #{inspect(other)}"}
    end
  end

  defp initialize_stdio(port, timeout) do
    context = %{port: port, buffer: ""}

    with {:ok, _result, context} <-
           stdio_json_rpc(context, "initialize", initialize_params(), timeout),
         :ok <- stdio_notification(port, "notifications/initialized", %{}) do
      {:ok, context}
    end
  end

  defp stdio_json_rpc(context, method, params, timeout) do
    id = System.unique_integer([:positive])
    payload = json_rpc_request(id, method, params)
    :ok = send_stdio(context.port, payload)
    await_stdio_response(context, id, System.monotonic_time(:millisecond) + timeout)
  end

  defp stdio_notification(port, method, params) do
    send_stdio(port, %{"jsonrpc" => "2.0", "method" => method, "params" => params})
  end

  defp send_stdio(port, payload) do
    Port.command(port, Jason.encode!(payload) <> "\n")
    :ok
  end

  defp await_stdio_response(context, id, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {port, {:data, data}} when port == context.port ->
        {messages, buffer} = decode_stdio_messages(context.buffer <> data)

        case Enum.find(messages, &(Map.get(&1, "id") == id)) do
          nil ->
            await_stdio_response(%{context | buffer: buffer}, id, deadline)

          %{"error" => error} ->
            {:error, format_json_rpc_error(error)}

          %{"result" => result} ->
            {:ok, result, %{context | buffer: buffer}}
        end

      {port, {:exit_status, status}} when port == context.port ->
        {:error, "MCP server exited with status #{status}"}
    after
      remaining ->
        {:error, "MCP server timed out waiting for response #{id}"}
    end
  end

  defp decode_stdio_messages(buffer) do
    parts = String.split(buffer, "\n")
    {complete, rest} = Enum.split(parts, max(length(parts) - 1, 0))

    messages =
      complete
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.flat_map(fn line ->
        case Jason.decode(line) do
          {:ok, message} -> [message]
          {:error, _} -> []
        end
      end)

    {messages, List.first(rest) || ""}
  end

  defp http_request(server, method, params, opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    with {:ok, _} <- Application.ensure_all_started(:inets),
         {:ok, _result, session_id} <-
           http_json_rpc(server, "initialize", initialize_params(), timeout),
         :ok <- http_notification(server, "notifications/initialized", %{}, timeout, session_id),
         {:ok, result, _session_id} <- http_json_rpc(server, method, params, timeout, session_id) do
      {:ok, result}
    end
  end

  defp http_json_rpc(server, method, params, timeout, session_id \\ nil) do
    id = System.unique_integer([:positive])

    case post_json(server, json_rpc_request(id, method, params), timeout, session_id) do
      {:ok, body, headers} ->
        with {:ok, result} <- decode_http_response(body, id) do
          {:ok, result, response_session_id(headers) || session_id}
        end

      error ->
        error
    end
  end

  defp http_notification(server, method, params, timeout, session_id) do
    case post_json(
           server,
           %{"jsonrpc" => "2.0", "method" => method, "params" => params},
           timeout,
           session_id
         ) do
      {:ok, _body, _headers} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp post_json(server, payload, timeout, session_id) do
    url = expand_env(server["url"] || "")
    body = Jason.encode!(payload)

    headers =
      [
        {~c"content-type", ~c"application/json"},
        {~c"accept", ~c"application/json, text/event-stream"},
        {~c"mcp-protocol-version", String.to_charlist(@protocol_version)}
      ] ++ http_headers(server["headers"] || %{})

    headers =
      if session_id do
        [{~c"mcp-session-id", String.to_charlist(session_id)} | headers]
      else
        headers
      end

    request = {String.to_charlist(url), headers, ~c"application/json", String.to_charlist(body)}

    case :httpc.request(:post, request, [{:timeout, timeout}], body_format: :binary) do
      {:ok, {{_, status, _}, response_headers, response_body}} when status in 200..299 ->
        {:ok, response_body || "", response_headers}

      {:ok, {{_, status, _}, _headers, response_body}} ->
        {:error, "MCP HTTP request failed with status #{status}: #{response_body}"}

      {:error, reason} ->
        {:error, "MCP HTTP request failed: #{inspect(reason)}"}
    end
  end

  defp decode_http_response("", _id), do: {:ok, %{}}

  defp decode_http_response(body, id) do
    body
    |> extract_json_payloads()
    |> Enum.find_value({:error, "MCP HTTP response did not include response #{id}"}, fn payload ->
      case Jason.decode(payload) do
        {:ok, %{"id" => ^id, "error" => error}} -> {:error, format_json_rpc_error(error)}
        {:ok, %{"id" => ^id, "result" => result}} -> {:ok, result}
        _ -> nil
      end
    end)
  end

  defp extract_json_payloads(body) do
    trimmed = String.trim(body)

    cond do
      trimmed == "" ->
        [""]

      String.starts_with?(trimmed, "{") ->
        [trimmed]

      true ->
        Regex.scan(~r/^data:\s*(.+)$/m, body)
        |> Enum.map(fn [_, data] -> String.trim(data) end)
        |> Enum.reject(&(&1 in ["", "[DONE]"]))
    end
  end

  defp json_rpc_request(id, method, params) do
    %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}
  end

  defp initialize_params do
    %{
      "protocolVersion" => @protocol_version,
      "capabilities" => %{"tools" => %{}},
      "clientInfo" => %{"name" => "ex_pi", "version" => "0.1.0"}
    }
  end

  defp open_stdio_port(executable, args, server, opts) do
    cwd = server["cwd"] || Keyword.get(opts, :cwd) || File.cwd!()
    env = server["env"] || %{}

    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        args: args,
        cd: cwd,
        env:
          Enum.map(env, fn {key, value} ->
            {to_charlist(key), to_charlist(expand_env(to_string(value)))}
          end)
      ])

    {:ok, port}
  rescue
    e -> {:error, "Could not start MCP server #{inspect(executable)}: #{Exception.message(e)}"}
  end

  defp close_port(port) do
    Port.close(port)
  rescue
    _ -> :ok
  end

  defp find_executable(""), do: {:error, "MCP stdio server command is empty"}

  defp find_executable(command) do
    cond do
      Path.type(command) == :absolute and File.exists?(command) ->
        {:ok, command}

      executable = System.find_executable(command) ->
        {:ok, executable}

      true ->
        {:error, "MCP stdio server command not found: #{command}"}
    end
  end

  defp normalize_server(server) do
    server
    |> Enum.into(%{}, fn {key, value} -> {to_string(key), value} end)
    |> Map.update("type", if(server["url"], do: "http", else: "stdio"), fn
      "streamable-http" -> "http"
      "sse" -> "http"
      other -> other
    end)
  end

  defp http_headers(headers) do
    Enum.map(headers, fn {name, value} ->
      {String.to_charlist(to_string(name)), String.to_charlist(expand_env(to_string(value)))}
    end)
  end

  defp response_session_id(headers) do
    Enum.find_value(headers, fn {name, value} ->
      if name |> to_string() |> String.downcase() == "mcp-session-id" do
        to_string(value)
      end
    end)
  end

  defp format_json_rpc_error(%{"message" => message}), do: message
  defp format_json_rpc_error(error), do: inspect(error)

  defp expand_env(value) do
    Regex.replace(~r/\$\{([A-Za-z_][A-Za-z0-9_]*)(:-([^}]*))?\}/, value, fn
      _full, name, _default_expr, default ->
        System.get_env(name) || default || ""
    end)
  end
end
