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

    assert {:ok, [tool], handles} =
             Sigma.Coding.MCP.start_session(session_id, servers, timeout: 5_000)

    on_exit(fn -> Sigma.Coding.MCP.stop(handles) end)

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

    assert :ok = Sigma.Coding.MCP.stop(handles)
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

    assert {:ok, tools, handles} =
             Sigma.Coding.MCP.start_session(session_id, servers, timeout: 5_000)

    on_exit(fn -> Sigma.Coding.MCP.stop(handles) end)

    assert [
             %Sigma.Coding.MCP.Tool{name: "mcp__one__echo"},
             %Sigma.Coding.MCP.Tool{name: "mcp__two__echo"}
           ] = Enum.sort_by(tools, & &1.name)
  end

  defp write_stdio_fixture!(tmp_dir, server_name) do
    server_path = Path.join(tmp_dir, "#{server_name}_mcp_fixture.py")

    File.write!(server_path, """
    import json
    import sys

    for line in sys.stdin:
        message = json.loads(line)
        method = message.get("method")
        if method == "initialize":
            result = {
                "protocolVersion": "2025-06-18",
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "#{server_name}", "version": "1.0.0"},
            }
            print(json.dumps({"jsonrpc": "2.0", "id": message["id"], "result": result}), flush=True)
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
            print(json.dumps({"jsonrpc": "2.0", "id": message["id"], "result": result}), flush=True)
        elif method == "tools/call":
            text = message["params"]["arguments"]["text"]
            result = {"content": [{"type": "text", "text": text}], "isError": False}
            print(json.dumps({"jsonrpc": "2.0", "id": message["id"], "result": result}), flush=True)
    """)

    server_path
  end
end
