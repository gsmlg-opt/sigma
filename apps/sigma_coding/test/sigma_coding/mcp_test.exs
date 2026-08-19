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
