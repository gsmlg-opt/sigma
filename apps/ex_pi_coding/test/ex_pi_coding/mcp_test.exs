defmodule PiCoding.MCPTest do
  use ExUnit.Case, async: true

  @tag :tmp_dir
  test "discovers and dispatches stdio MCP tools", %{tmp_dir: tmp_dir} do
    python = System.find_executable("python3") || System.find_executable("python")
    assert python

    server_path = Path.join(tmp_dir, "mcp_fixture.py")

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
                "serverInfo": {"name": "fixture", "version": "1.0.0"},
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

    servers = %{
      "fixture" => %{
        "type" => "stdio",
        "command" => python,
        "args" => ["-u", server_path]
      }
    }

    assert [
             %PiCoding.MCP.Tool{
               name: "mcp__fixture__echo",
               description: "Echo text",
               server_tool_name: "echo"
             } = tool
           ] = PiCoding.MCP.tools_for_servers(servers, timeout: 2_000)

    tool_call = %{id: "call_1", name: tool.name, arguments: %{"text" => "hello mcp"}}

    assert [{^tool_call, {:ok, %{content: [%{type: :text, text: "hello mcp"}]}}}] =
             PiCoding.Dispatcher.dispatch_batch([tool_call], [tool], mode: :sequential, timeout: 2_000)
  end
end
