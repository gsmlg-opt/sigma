defmodule Sigma.Agent.BackplaneMcpResourceLifecycleFunctionalTest do
  use ExUnit.Case, async: false

  alias Backplane.McpProtocol.Client
  alias Backplane.McpProtocol.MCP.Response
  alias Sigma.Agent.Runtime

  @moduletag :tmp_dir
  @moduletag timeout: 30_000

  defmodule Provider do
    @behaviour Sigma.Ai.Provider
    def output_token_limit(_, _), do: 2_000

    def stream(params) do
      send(params.options[:test_pid], {:resource_lifecycle_provider, self(), params})

      receive do
        {:resource_lifecycle_response, content} ->
          reason = if Enum.any?(content, &(&1.type == :tool_call)), do: :tool_use, else: :stop

          message = %{
            role: :assistant,
            content: content,
            stop_reason: reason,
            usage: %{input: 1, output: 1, total_tokens: 2},
            model: "resource-lifecycle",
            provider: "resource-lifecycle",
            api: "openai-responses",
            timestamp: System.system_time(:millisecond)
          }

          [{:start, %{message | content: []}}, {:done, reason, message}]
      end
    end
  end

  setup %{tmp_dir: dir} = tags do
    python = System.find_executable("python3")
    assert is_binary(python)
    fixture = Path.join(dir, "resource-lifecycle.py")
    log = Path.join(dir, "requests.jsonl")
    release = Path.join(dir, "release-other")
    File.write!(fixture, fixture())
    File.write!(log, "")
    pagination = if tags[:resource_pagination], do: "true", else: "false"
    servers = if tags[:resource_pagination], do: ["resources", "zz-next"], else: ["resources"]

    on_exit(fn ->
      case Runtime.lookup(dir, :supervisor) do
        nil -> :ok
        pid -> DynamicSupervisor.terminate_child(Sigma.Agent.DynamicSupervisor, pid)
      end
    end)

    assert {:ok, handle} =
             Runtime.get_session(dir, "resource-lifecycle",
               cwd: dir,
               transcript_path: Path.join(dir, "root.jsonl"),
               native_tools: true,
               native_memory_root: Path.join(dir, "memories"),
               provider: Provider,
               model: %{
                 id: "resource-lifecycle",
                 provider: "resource-lifecycle",
                 api: "openai-responses"
               },
               tools: [],
               hook_specs: [],
               options: [test_pid: self()],
               mcp_servers:
                 Map.new(servers, fn server ->
                   {server,
                    %{
                      "type" => "stdio",
                      "command" => python,
                      "args" => ["-u", fixture, log, release, pagination, server]
                    }}
                 end)
             )

    :ok = Sigma.Agent.subscribe(handle.agent)

    assert {:accepted, _} = Sigma.Agent.prompt(handle.agent, "Use MCP resources")
    root = provider!("resource-lifecycle")
    turn_id = Sigma.Agent.status(handle.agent).turn_id

    assert {:ok, %{"resources" => client}} =
             GenServer.call(handle.agent, {:native_mcp_clients, turn_id})

    %{agent: handle.agent, root: root, client: client, log: log, release: release}
  end

  test "ordinary native resources and an independent caller share one live connection", c do
    {other, other_request} = other_caller!(c)

    root = call!(c.root, "list_mcp_resources", %{"server" => "resources"})
    resources = result!(root, "list_mcp_resources")
    refute resources.is_error

    assert value!(resources)["resources"] == [
             %{"server" => "resources", "uri" => "mem://immediate", "name" => "Immediate"}
           ]

    root = call!(root, "list_mcp_resource_templates", %{"server" => "resources"})
    templates = result!(root, "list_mcp_resource_templates")
    refute templates.is_error

    assert value!(templates)["resourceTemplates"] == [
             %{"server" => "resources", "uriTemplate" => "mem://{name}", "name" => "Memory"}
           ]

    root =
      call!(root, "read_mcp_resource", %{"server" => "resources", "uri" => "mem://immediate"})

    read = result!(root, "read_mcp_resource")
    refute read.is_error
    assert value!(read)["contents"] == [%{"uri" => "mem://immediate", "text" => "ready"}]

    assert_other_survives!(c, other, other_request)
    assert Enum.count(events(c.log), &(&1["method"] == "initialize")) == 1
    finish!(root)
    assert_receive {:agent_end, _}, 5_000
    assert Sigma.Agent.status(c.agent).phase == :completed
  end

  for {name, method, arguments} <- [
        {"list_mcp_resources", "resources/list",
         %{"server" => "resources", "cursor" => "pending"}},
        {"list_mcp_resource_templates", "resources/templates/list",
         %{"server" => "resources", "cursor" => "pending"}},
        {"read_mcp_resource", "resources/read",
         %{"server" => "resources", "uri" => "mem://pending"}}
      ] do
    @tag resource_name: name, resource_method: method, resource_arguments: arguments
    @tag resource_scenario: "#{name}_root"
    test "root cancellation settles only its pending #{method} on a shared client", c do
      send_call(c.root, c.resource_name, c.resource_arguments)
      request = pending!(c.log, c.resource_method, :native)
      {other, other_request} = other_caller!(c)
      refute other_request["id"] == request["id"]

      assert {:cancelling, _} = Sigma.Agent.cancel(c.agent)
      assert_receive {:agent_end, _}, 5_000
      cancelled!(c.log, request["id"])
      assert_other_survives!(c, other, other_request)
      assert Enum.count(events(c.log), &(&1["method"] == "initialize")) == 1
    end

    @tag resource_name: name, resource_method: method, resource_arguments: arguments
    @tag resource_scenario: "#{name}_child"
    test "managed child interruption settles only its pending #{method} on the borrowed client",
         c do
      send_call(c.root, "spawn_agent", %{
        "task_name" => "resource_child",
        "message" => "Read a resource",
        "fork_turns" => "none"
      })

      child = provider!(:child)
      root = provider!(c.root.params.session_id)
      refute result!(root, "spawn_agent").is_error
      send_call(child, c.resource_name, c.resource_arguments)
      request = pending!(c.log, c.resource_method, :native)
      {other, other_request} = other_caller!(c)

      root = call!(root, "interrupt_agent", %{"target" => "/root/resource_child"})
      refute result!(root, "interrupt_agent").is_error
      cancelled!(c.log, request["id"])
      assert_other_survives!(c, other, other_request)

      root =
        call!(root, "read_mcp_resource", %{
          "server" => "resources",
          "uri" => "mem://immediate"
        })

      result = result!(root, "read_mcp_resource")
      refute result.is_error
      assert value!(result)["contents"] == [%{"uri" => "mem://immediate", "text" => "ready"}]
      assert Enum.count(events(c.log), &(&1["method"] == "initialize")) == 1
      finish!(root)
      assert_receive {:agent_end, _}, 5_000
      assert Sigma.Agent.status(c.agent).phase == :completed
    end
  end

  for mode <- [:direct, :deno] do
    @tag :resource_scope_pagination
    @tag :resource_scope_full_retirement
    @tag resource_pagination: true, resource_execution: mode
    test "managed child #{mode} pagination retires earlier pages before cancelling its exact pending page",
         c do
      if c.resource_execution == :deno, do: assert(is_binary(System.find_executable("deno")))

      send_call(c.root, "spawn_agent", %{
        "task_name" => "paginated_child",
        "message" => "List every server's resources",
        "fork_turns" => "none"
      })

      child = provider!(:child)
      root = provider!(c.root.params.session_id)
      refute result!(root, "spawn_agent").is_error

      case c.resource_execution do
        :direct -> send_call(child, "list_mcp_resources", %{})
        :deno -> send_call(child, "exec", "return await tools.list_mcp_resources({});")
      end

      completed =
        await_event!(c.log, fn event ->
          event["event"] == "page_completed" and event["server"] == "resources"
        end)

      request = pending!(c.log, "resources/list", :native)
      refute request["id"] == completed["id"]
      {other, other_request} = other_caller!(c)

      root = call!(root, "interrupt_agent", %{"target" => "/root/paginated_child"})
      refute result!(root, "interrupt_agent").is_error
      cancelled!(c.log, request["id"])
      assert_other_survives!(c, other, other_request)

      refute Enum.any?(events(c.log), fn event ->
               event["method"] == "notifications/cancelled" and
                 get_in(event, ["params", "requestId"]) == completed["id"]
             end)

      refute Enum.any?(events(c.log), fn event ->
               event["method"] == "resources/list" and event["server"] == "zz-next"
             end)

      root =
        call!(root, "read_mcp_resource", %{
          "server" => "resources",
          "uri" => "mem://immediate"
        })

      result = result!(root, "read_mcp_resource")
      refute result.is_error
      assert value!(result)["contents"] == [%{"uri" => "mem://immediate", "text" => "ready"}]
      assert Enum.count(events(c.log), &(&1["method"] == "initialize")) == 2
      finish!(root)
      assert_receive {:agent_end, _}, 5_000
      assert Sigma.Agent.status(c.agent).phase == :completed
      assert {:ok, %{status: :confirmed}} = Sigma.Agent.retire_host(c.agent)
    end
  end

  defp other_caller!(c) do
    other = Task.async(fn -> Client.read_resource(c.client, "mem://other", timeout: 8_000) end)
    {other, pending!(c.log, "resources/read", :other)}
  end

  defp assert_other_survives!(c, other, request) do
    refute Enum.any?(events(c.log), fn event ->
             event["method"] == "notifications/cancelled" and
               get_in(event, ["params", "requestId"]) == request["id"]
           end)

    File.write!(c.release, "release")
    assert {:ok, %Response{} = response} = Task.await(other, 5_000)
    refute Response.error?(response)

    assert Response.get_result(response)["contents"] == [
             %{"uri" => "mem://other", "text" => "other caller completed"}
           ]

    assert {:ok, %Response{} = immediate} =
             Client.read_resource(c.client, "mem://immediate", timeout: 1_000)

    assert Response.get_result(immediate)["contents"] == [
             %{"uri" => "mem://immediate", "text" => "ready"}
           ]
  end

  defp pending!(log, method, kind) do
    await_event!(log, fn event ->
      event["event"] == "pending" and event["method"] == method and
        event["kind"] == Atom.to_string(kind)
    end)
  end

  defp cancelled!(log, request_id) do
    await_event!(log, fn event ->
      event["method"] == "notifications/cancelled" and
        get_in(event, ["params", "requestId"]) == request_id
    end)
  end

  defp await_event!(path, predicate, attempts \\ 250)

  defp await_event!(path, _predicate, 0),
    do: flunk("Expected MCP lifecycle event was not observed: #{inspect(events(path))}")

  defp await_event!(path, predicate, attempts) do
    case Enum.find(events(path), predicate) do
      nil ->
        Process.sleep(10)
        await_event!(path, predicate, attempts - 1)

      event ->
        event
    end
  end

  defp events(path) do
    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  defp provider!(session) do
    receive do
      {:resource_lifecycle_provider, pid, %{session_id: "child_" <> _} = params}
      when session == :child ->
        %{pid: pid, params: params}

      {:resource_lifecycle_provider, pid, %{session_id: ^session} = params} ->
        %{pid: pid, params: params}

      {:turn_error, error} ->
        flunk("Resource lifecycle turn failed: #{inspect(error)}")
    after
      8_000 -> flunk("Resource lifecycle Provider did not start for #{session}")
    end
  end

  defp send_call(provider, name, arguments) do
    send(provider.pid, {
      :resource_lifecycle_response,
      [
        %{
          type: :tool_call,
          id: "resource-lifecycle-#{System.unique_integer([:positive])}",
          name: name,
          arguments: arguments
        }
      ]
    })
  end

  defp call!(provider, name, arguments) do
    send_call(provider, name, arguments)
    provider!(provider.params.session_id)
  end

  defp result!(provider, name) do
    Enum.find(Enum.reverse(provider.params.context.messages), &(Map.get(&1, :tool_name) == name)) ||
      flunk("Missing #{name} result")
  end

  defp value!(message) do
    assert [%{type: :text, text: json}] = message.content
    Jason.decode!(json)
  end

  defp finish!(provider),
    do: send(provider.pid, {:resource_lifecycle_response, [%{type: :text, text: "Finished"}]})

  defp fixture do
    """
    import json, os, sys, threading, time

    log_path, release_other, pagination, server = sys.argv[1:]
    lock = threading.RLock()
    cancellations = {}

    def record(value):
        with lock:
            with open(log_path, "a", encoding="utf-8") as output:
                output.write(json.dumps(value, ensure_ascii=False) + "\\n")
                output.flush()

    def reply(identifier, result):
        with lock:
            print(json.dumps({"jsonrpc": "2.0", "id": identifier, "result": result}), flush=True)

    def resource(request):
        identifier = request["id"]
        method = request["method"]
        params = request.get("params", {})
        uri = params.get("uri")
        pending = params.get("cursor") == "pending" or uri in ["mem://pending", "mem://other"]
        if pending:
            with lock:
                cancelled = cancellations.setdefault(identifier, threading.Event())
            record({"event": "pending", "kind": "other" if uri == "mem://other" else "native",
                    "method": method, "id": identifier, "params": params})
            if uri == "mem://other":
                while not os.path.exists(release_other):
                    if cancelled.wait(0.01):
                        return
                reply(identifier, {"contents": [{"uri": uri, "text": "other caller completed"}]})
            else:
                cancelled.wait()
            return
        if method == "resources/read":
            reply(identifier, {"contents": [{"uri": uri, "text": "ready"}]})
        elif method == "resources/list":
            result = {"resources": [{"uri": "mem://immediate", "name": "Immediate"}]}
            if pagination == "true" and server == "resources":
                result["nextCursor"] = "pending"
            reply(identifier, result)
            record({"event": "page_completed", "server": server, "id": identifier})
        else:
            reply(identifier, {"resourceTemplates": [{"uriTemplate": "mem://{name}", "name": "Memory"}]})

    for line in sys.stdin:
        request = json.loads(line)
        method = request.get("method")
        record(dict(request, server=server))
        if method == "initialize":
            reply(request["id"], {"protocolVersion": "2025-06-18",
                  "capabilities": {"tools": {}, "resources": {}},
                  "serverInfo": {"name": "resource-lifecycle", "version": "1"}})
        elif method == "tools/list":
            reply(request["id"], {"tools": []})
        elif method == "notifications/cancelled":
            identifier = request["params"]["requestId"]
            with lock:
                cancellations.setdefault(identifier, threading.Event()).set()
        elif method in ["resources/list", "resources/templates/list", "resources/read"]:
            threading.Thread(target=resource, args=(request,), daemon=True).start()
        elif "id" in request:
            with lock:
                print(json.dumps({"jsonrpc": "2.0", "id": request["id"],
                      "error": {"code": -32601, "message": "Method not found"}}), flush=True)
    """
  end
end
