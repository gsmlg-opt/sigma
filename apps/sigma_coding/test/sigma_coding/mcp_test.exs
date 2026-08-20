defmodule Sigma.Coding.MCPTest do
  use ExUnit.Case, async: true

  @tag :tmp_dir
  test "discovers and dispatches stdio MCP tools", %{tmp_dir: tmp_dir} do
    python = System.find_executable("python3") || System.find_executable("python")
    assert python

    server_path = write_stdio_fixture!(tmp_dir, "fixture")

    servers = %{
      "fixture" => %{
        "type" => "stdio",
        "command" => python,
        "args" => ["-u", server_path]
      }
    }

    session_id = "test-#{System.unique_integer([:positive])}"

    assert {:ok, [tool], session} =
             Sigma.Coding.MCP.start_session(session_id, servers, timeout: 5_000)

    on_exit(fn -> Sigma.Coding.MCP.stop(session) end)

    assert %Sigma.Coding.MCP.Tool{
             name: "mcp__fixture__echo",
             description: "Echo text",
             server_tool_name: "echo"
           } = tool

    tool_call = %{id: "call_1", name: tool.name, arguments: %{"text" => "hello mcp"}}

    assert [{^tool_call, {:ok, %{content: [%{type: :text, text: "hello mcp"}]}}}] =
             Sigma.Coding.Dispatcher.dispatch_batch([tool_call], [tool],
               mode: :sequential,
               timeout: 5_000
             )

    assert :ok = Sigma.Coding.MCP.stop(session)
  end

  @tag :tmp_dir
  test "discovers tools from multiple MCP clients in one session", %{tmp_dir: tmp_dir} do
    python = System.find_executable("python3") || System.find_executable("python")
    assert python

    servers = %{
      "one" => %{
        "type" => "stdio",
        "command" => python,
        "args" => ["-u", write_stdio_fixture!(tmp_dir, "one")]
      },
      "two" => %{
        "type" => "stdio",
        "command" => python,
        "args" => ["-u", write_stdio_fixture!(tmp_dir, "two")]
      }
    }

    session_id = "test-#{System.unique_integer([:positive])}"

    assert {:ok, tools, session} =
             Sigma.Coding.MCP.start_session(session_id, servers, timeout: 5_000)

    on_exit(fn -> Sigma.Coding.MCP.stop(session) end)

    assert [
             %Sigma.Coding.MCP.Tool{name: "mcp__one__echo"},
             %Sigma.Coding.MCP.Tool{name: "mcp__two__echo"}
           ] = Enum.sort_by(tools, & &1.name)
  end

  test "falls back to legacy initialization when HTTP discovery is unsupported" do
    {server, port} = start_legacy_http_fixture!()
    on_exit(fn -> Process.exit(server.pid, :kill) end)

    servers = %{
      "legacy-http" => %{
        "type" => "http",
        "url" => "http://127.0.0.1:#{port}/mcp"
      }
    }

    assert {:ok, [tool], session} =
             Sigma.Coding.MCP.start_session(
               "legacy-http-#{System.unique_integer([:positive])}",
               servers,
               timeout: 5_000
             )

    on_exit(fn -> Sigma.Coding.MCP.stop(session) end)

    assert %Sigma.Coding.MCP.Tool{
             name: "mcp__legacy-http__echo",
             server_tool_name: "echo"
           } = tool
  end

  @tag :tmp_dir
  test "elicitation callback can accept schema content during tools/call", %{tmp_dir: tmp_dir} do
    python = System.find_executable("python3") || System.find_executable("python")
    assert python

    parent = self()

    servers = %{
      "ask" => %{
        "type" => "stdio",
        "command" => python,
        "args" => ["-u", write_elicitation_fixture!(tmp_dir)]
      }
    }

    assert {:ok, [tool], session} =
             Sigma.Coding.MCP.start_session(
               "elicit-#{System.unique_integer([:positive])}",
               servers,
               timeout: 5_000,
               elicitation_callback: fn message, schema ->
                 send(parent, {:elicited, message, schema})
                 {:accept, %{"name" => "sigma"}}
               end
             )

    on_exit(fn -> Sigma.Coding.MCP.stop(session) end)

    assert {:ok, %{content: [%{type: :text, text: "hello sigma"}]}} =
             Sigma.Coding.MCP.call_tool(tool, "call_1", %{}, timeout: 5_000)

    assert_receive {:elicited, "What is your name?", %{"type" => "object"}}, 1_000
  end

  @tag :tmp_dir
  test "sampling callback returns an assistant message", %{tmp_dir: tmp_dir} do
    python = System.find_executable("python3") || System.find_executable("python")
    assert python

    servers = %{
      "sample" => %{
        "type" => "stdio",
        "command" => python,
        "args" => ["-u", write_sampling_fixture!(tmp_dir)]
      }
    }

    assert {:ok, [tool], session} =
             Sigma.Coding.MCP.start_session(
               "sample-#{System.unique_integer([:positive])}",
               servers,
               timeout: 5_000,
               sampling_callback: fn _params ->
                 {:ok,
                  %{
                    "role" => "assistant",
                    "content" => %{"type" => "text", "text" => "sampled"},
                    "model" => "test-model",
                    "stopReason" => "endTurn"
                  }}
               end
             )

    on_exit(fn -> Sigma.Coding.MCP.stop(session) end)

    assert {:ok, %{content: [%{type: :text, text: "sampled"}]}} =
             Sigma.Coding.MCP.call_tool(tool, "call_1", %{}, timeout: 5_000)
  end

  defp write_stdio_fixture!(tmp_dir, server_name) do
    server_path = Path.join(tmp_dir, "#{server_name}_mcp_fixture.py")

    File.write!(server_path, """
    import json
    import sys

    for line in sys.stdin:
        message = json.loads(line)
        method = message.get("method")
        msg_id = message.get("id")
        if method == "initialize":
            result = {
                "protocolVersion": "2025-06-18",
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "#{server_name}", "version": "1.0.0"},
            }
            print(json.dumps({"jsonrpc": "2.0", "id": msg_id, "result": result}), flush=True)
        elif method == "notifications/initialized":
            continue
        elif method == "tools/list":
            result = {
                "tools": [
                    {
                        "name": "echo",
                        "description": "Echo text",
                        "inputSchema": {
                            "type": "object",
                            "properties": {"text": {"type": "string"}},
                            "required": ["text"],
                        },
                    }
                ]
            }
            print(json.dumps({"jsonrpc": "2.0", "id": msg_id, "result": result}), flush=True)
        elif method == "tools/call":
            text = message["params"]["arguments"]["text"]
            result = {"content": [{"type": "text", "text": text}], "isError": False}
            print(json.dumps({"jsonrpc": "2.0", "id": msg_id, "result": result}), flush=True)
        elif msg_id is not None:
            print(
                json.dumps(
                    {
                        "jsonrpc": "2.0",
                        "id": msg_id,
                        "error": {"code": -32601, "message": f"Method not found: {method}"},
                    }
                ),
                flush=True,
            )
    """)

    server_path
  end

  defp start_legacy_http_fixture! do
    parent = self()

    server =
      Task.async(fn ->
        {:ok, listener} =
          :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

        {:ok, {{127, 0, 0, 1}, port}} = :inet.sockname(listener)
        send(parent, {:legacy_http_fixture, self(), port})
        serve_legacy_http(listener)
      end)

    port =
      receive do
        {:legacy_http_fixture, pid, port} when pid == server.pid -> port
      after
        5_000 -> raise "legacy HTTP MCP fixture did not start"
      end

    {server, port}
  end

  defp serve_legacy_http(listener) do
    {:ok, socket} = :gen_tcp.accept(listener)
    {:ok, request} = read_http_request(socket, "")
    message = Jason.decode!(request)
    send_http_response(socket, legacy_http_response(message))
    :gen_tcp.close(socket)
    serve_legacy_http(listener)
  end

  defp read_http_request(socket, buffer) do
    case String.split(buffer, "\r\n\r\n", parts: 2) do
      [headers, body] ->
        content_length =
          headers
          |> String.split("\r\n")
          |> Enum.find_value(0, fn line ->
            case String.split(line, ":", parts: 2) do
              [name, value] ->
                if String.downcase(name) == "content-length",
                  do: value |> String.trim() |> String.to_integer()

              _ ->
                nil
            end
          end)

        read_http_body(socket, body, content_length)

      [_partial] ->
        with {:ok, data} <- :gen_tcp.recv(socket, 0, 5_000) do
          read_http_request(socket, buffer <> data)
        end
    end
  end

  defp read_http_body(_socket, body, content_length) when byte_size(body) >= content_length,
    do: {:ok, binary_part(body, 0, content_length)}

  defp read_http_body(socket, body, content_length) do
    with {:ok, data} <- :gen_tcp.recv(socket, 0, 5_000) do
      read_http_body(socket, body <> data, content_length)
    end
  end

  defp legacy_http_response(%{"method" => "server/discover", "id" => id}) do
    {200, [],
     %{
       "jsonrpc" => "2.0",
       "id" => id,
       "error" => %{"code" => -32_601, "message" => "Method not found"}
     }}
  end

  defp legacy_http_response(%{"method" => "initialize", "id" => id}) do
    result = %{
      "protocolVersion" => "2025-03-26",
      "capabilities" => %{"tools" => %{}},
      "serverInfo" => %{"name" => "legacy-http", "version" => "1.0.0"}
    }

    {200, [{"mcp-session-id", "legacy-http-session"}],
     %{"jsonrpc" => "2.0", "id" => id, "result" => result}}
  end

  defp legacy_http_response(%{"method" => "notifications/initialized"}), do: {202, [], nil}

  defp legacy_http_response(%{"method" => "tools/list", "id" => id}) do
    tool = %{
      "name" => "echo",
      "description" => "Echo text",
      "inputSchema" => %{"type" => "object", "properties" => %{}}
    }

    {200, [], %{"jsonrpc" => "2.0", "id" => id, "result" => %{"tools" => [tool]}}}
  end

  defp send_http_response(socket, {status, extra_headers, payload}) do
    body = if payload, do: Jason.encode!(payload), else: ""

    headers =
      [
        {"content-type", "application/json"},
        {"content-length", byte_size(body)},
        {"connection", "close"} | extra_headers
      ]
      |> Enum.map_join("", fn {name, value} -> "#{name}: #{value}\r\n" end)

    :gen_tcp.send(
      socket,
      "HTTP/1.1 #{status} #{if status == 202, do: "Accepted", else: "OK"}\r\n#{headers}\r\n#{body}"
    )
  end

  defp write_elicitation_fixture!(tmp_dir) do
    server_path = Path.join(tmp_dir, "elicitation_mcp_fixture.py")

    File.write!(server_path, """
    import json
    import sys

    for line in sys.stdin:
        message = json.loads(line)
        method = message.get("method")
        msg_id = message.get("id")
        if method == "initialize":
            result = {
                "protocolVersion": "2025-06-18",
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "ask", "version": "1.0.0"},
            }
            print(json.dumps({"jsonrpc": "2.0", "id": msg_id, "result": result}), flush=True)
        elif method == "notifications/initialized":
            continue
        elif method == "tools/list":
            result = {
                "tools": [
                    {
                        "name": "greet",
                        "description": "Greet after elicitation",
                        "inputSchema": {"type": "object", "properties": {}},
                    }
                ]
            }
            print(json.dumps({"jsonrpc": "2.0", "id": msg_id, "result": result}), flush=True)
        elif method == "tools/call":
            elicit_id = "elicit-1"
            print(
                json.dumps(
                    {
                        "jsonrpc": "2.0",
                        "id": elicit_id,
                        "method": "elicitation/create",
                        "params": {
                            "message": "What is your name?",
                            "requestedSchema": {
                                "type": "object",
                                "properties": {"name": {"type": "string"}},
                                "required": ["name"],
                            },
                        },
                    }
                ),
                flush=True,
            )
            response = json.loads(sys.stdin.readline())
            name = response.get("result", {}).get("content", {}).get("name", "world")
            result = {"content": [{"type": "text", "text": f"hello {name}"}], "isError": False}
            print(json.dumps({"jsonrpc": "2.0", "id": msg_id, "result": result}), flush=True)
        elif msg_id is not None:
            print(
                json.dumps(
                    {
                        "jsonrpc": "2.0",
                        "id": msg_id,
                        "error": {"code": -32601, "message": f"Method not found: {method}"},
                    }
                ),
                flush=True,
            )
    """)

    server_path
  end

  defp write_sampling_fixture!(tmp_dir) do
    server_path = Path.join(tmp_dir, "sampling_mcp_fixture.py")

    File.write!(server_path, """
    import json
    import sys

    for line in sys.stdin:
        message = json.loads(line)
        method = message.get("method")
        msg_id = message.get("id")
        if method == "initialize":
            result = {
                "protocolVersion": "2025-06-18",
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "sample", "version": "1.0.0"},
            }
            print(json.dumps({"jsonrpc": "2.0", "id": msg_id, "result": result}), flush=True)
        elif method == "notifications/initialized":
            continue
        elif method == "tools/list":
            result = {
                "tools": [
                    {
                        "name": "ask_model",
                        "description": "Ask via sampling",
                        "inputSchema": {"type": "object", "properties": {}},
                    }
                ]
            }
            print(json.dumps({"jsonrpc": "2.0", "id": msg_id, "result": result}), flush=True)
        elif method == "tools/call":
            sample_id = "sample-1"
            print(
                json.dumps(
                    {
                        "jsonrpc": "2.0",
                        "id": sample_id,
                        "method": "sampling/createMessage",
                        "params": {
                            "messages": [{"role": "user", "content": {"type": "text", "text": "hi"}}],
                            "maxTokens": 32,
                        },
                    }
                ),
                flush=True,
            )
            response = json.loads(sys.stdin.readline())
            text = response.get("result", {}).get("content", {}).get("text", "")
            result = {"content": [{"type": "text", "text": text}], "isError": False}
            print(json.dumps({"jsonrpc": "2.0", "id": msg_id, "result": result}), flush=True)
        elif msg_id is not None:
            print(
                json.dumps(
                    {
                        "jsonrpc": "2.0",
                        "id": msg_id,
                        "error": {"code": -32601, "message": f"Method not found: {method}"},
                    }
                ),
                flush=True,
            )
    """)

    server_path
  end
end
