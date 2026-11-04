defmodule Sigma.Agent.BackplaneResponsesImageFunctionalTest do
  use ExUnit.Case, async: false

  alias Sigma.Agent.Backplane.ChildIO
  alias Sigma.Agent.{Runtime, Subagents}
  alias Sigma.Ai.Providers.OpenAIResponses
  alias Sigma.Session.{Log, Writer}

  @moduletag :tmp_dir
  @moduletag :responses_image_functional
  @root "responses-image-root"
  @tool "mcp__images__render_chart"
  @png "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jR9sAAAAASUVORK5CYII="
  @uri "data:image/png;base64," <> @png
  @model %{
    id: "responses-image-model",
    provider: "responses-image-fixture",
    api: "openai-responses",
    context_window: 200_000
  }

  defmodule Provider do
    @behaviour Sigma.Ai.Provider

    def output_token_limit(model, options),
      do: OpenAIResponses.output_token_limit(model, options)

    def stream(params) do
      send(params.options[:test_pid], {:image_provider, self(), params})
      endpoint = params.options[:base_url] <> "/" <> params.session_id
      options = Keyword.put(params.options, :base_url, endpoint)
      OpenAIResponses.stream(%{params | options: options})
    end
  end

  setup %{tmp_dir: dir} do
    python = System.find_executable("python3")
    assert python, "Responses image functional acceptance requires Python"
    fixture = Path.join(dir, "images.py")
    payload = Path.join(dir, "images.json")
    log = Path.join(dir, "mcp.jsonl")
    png = Path.join(dir, "chart.png")
    File.write!(fixture, fixture())
    File.write!(payload, Jason.encode!(envelope()))
    File.write!(log, "")
    File.write!(png, Base.decode64!(@png))

    on_exit(fn ->
      case Runtime.lookup(dir, :supervisor) do
        nil -> :ok
        pid -> DynamicSupervisor.terminate_child(Sigma.Agent.DynamicSupervisor, pid)
      end
    end)

    %{dir: dir, fixture: fixture, payload: payload, log: log, png: png, python: python}
  end

  test "root MCP and native images reach real HTTP with detail and survive another turn and Agent reopen",
       c do
    with_server(fn url, server ->
      handle = session!(c, url)
      root = prompt!(handle.agent, server) |> discover!(server) |> exercise_images!(server)
      mcp = result!(root, @tool)
      native = result!(root, "view_image")
      finish!(root, handle, c)

      next = prompt!(handle.agent, server)
      assert_saved_images!(next, mcp, native)
      finish!(next, handle, c)
      assert {:ok, _} = Writer.flush(handle.writer)
      File.rm!(c.png)
      snapshot = assert_read_only_reopen!(path(c), c.log, mcp, native)
      assert_mcp_calls!(c.log, 2)

      supervisor = Runtime.lookup(c.dir, @root, :supervisor)
      monitor = Process.monitor(handle.agent)
      assert :ok = DynamicSupervisor.terminate_child(Runtime.lookup(c.dir, :sessions), supervisor)
      assert_receive {:DOWN, ^monitor, :process, _, _}, 5_000

      reopened =
        session!(c, url,
          messages: snapshot.messages,
          context_messages: snapshot.context_messages,
          context_window: snapshot.context_window,
          active_leaf: snapshot.active_leaf_id,
          context_revision: length(snapshot.branch_entry_ids),
          context_source: :journal_replay
        )

      refute reopened.agent == handle.agent
      restored = prompt!(reopened.agent, server)
      assert_saved_images!(restored, mcp, native)
      finish!(restored, reopened, c)
      assert {:ok, _} = Writer.flush(reopened.writer)
      assert_mcp_calls!(c.log, 2)
      refute File.exists?(c.png)
    end)
  end

  test "actual managed-child MCP and native image HTTP results retain detail through followup and journal reopen",
       c do
    with_server(fn url, server ->
      handle = session!(c, url)
      root = prompt!(handle.agent, server) |> discover!(server)

      send_call(root, "spawn_agent", %{
        "task_name" => "images",
        "message" => "Read the complete chart images",
        "fork_turns" => "none"
      })

      child = provider!(:child, server)
      child_id = child.params.session_id
      root = provider!(@root, server)
      refute result!(root, "spawn_agent").is_error
      child = child |> discover!(server) |> exercise_images!(server)
      mcp = result!(child, @tool)
      native = result!(child, "view_image")
      finish!(child, handle, c)

      send_call(root, "followup_task", %{
        "target" => "/root/images",
        "message" => "Continue using the saved images"
      })

      next = provider!(child_id, server)
      root = provider!(@root, server)
      refute result!(root, "followup_task").is_error
      assert_saved_images!(next, mcp, native)
      finish!(next, handle, c)

      host = Runtime.lookup(c.dir, @root, :subagents)
      assert {:ok, sources} = Subagents.archive_sources(host)
      source = Enum.find(sources.children, &(&1.identity.child_session_id == child_id))
      assert source
      assert {:ok, archive} = ChildIO.archive_source(source.io)
      assert {:ok, _} = Writer.flush(archive.writer)
      File.rm!(c.png)
      assert_read_only_reopen!(archive.transcript_path, c.log, mcp, native)
      assert_mcp_calls!(c.log, 2)
      finish!(root, handle, c)
    end)
  end

  defp session!(c, url, opts \\ []) do
    defaults = [
      cwd: c.dir,
      transcript_path: path(c),
      native_tools: true,
      native_memory_root: Path.join(c.dir, "memories"),
      provider: Provider,
      model: @model,
      tools: [],
      hook_specs: [],
      permission_config: %{default: :allow, rules: %{}},
      options: [
        test_pid: self(),
        api_key: "image-fixture",
        base_url: url,
        receive_timeout: 20_000
      ],
      mcp_servers: %{
        "images" => %{
          "type" => "stdio",
          "command" => c.python,
          "args" => ["-u", c.fixture, c.payload, c.log]
        }
      }
    ]

    assert {:ok, handle} = Runtime.get_session(c.dir, @root, Keyword.merge(defaults, opts))
    assert :ok = Sigma.Agent.subscribe(handle.agent)
    handle
  end

  defp path(c), do: Path.join(c.dir, "root.jsonl")

  defp prompt!(agent, server) do
    assert {:accepted, _} = Sigma.Agent.prompt(agent, "Read the chart images")
    provider!(@root, server)
  end

  defp discover!(provider, server) do
    refute @tool in Enum.map(provider.params.context.tools, & &1.name)
    provider = call!(provider, "tool_search", %{"query" => "chart images"}, server)
    result = result!(provider, "tool_search")
    refute result.is_error, inspect(result, pretty: true, limit: :infinity)
    assert [%{"name" => @tool}] = structured!(result)["tools"]
    assert @tool in Enum.map(provider.params.context.tools, & &1.name)
    provider
  end

  defp exercise_images!(provider, server) do
    provider = call!(provider, @tool, %{}, server)
    result = result!(provider, @tool)
    assert_mcp_result!(result)
    assert_image_wire!(provider, result, wire_images())

    provider =
      call!(provider, "view_image", %{"path" => "chart.png", "detail" => "original"}, server)

    native = result!(provider, "view_image")

    assert native.content == [
             %{type: :image, data: @png, mime_type: "image/png", detail: "original"}
           ]

    assert_image_wire!(provider, native, native_wire())

    provider =
      call!(provider, "exec", "return await tools.mcp__images__render_chart({});", server)

    nested = structured!(result!(provider, "exec"))
    assert nested["status"] == "completed"
    assert nested["value"]["content"] == json_value(images())
    assert nested["value"]["details"] == envelope()
    provider
  end

  defp assert_mcp_result!(result) do
    refute result.is_error
    assert result.content == images()
  end

  defp assert_saved_images!(provider, mcp, native) do
    restored = result!(provider, @tool)
    assert restored.tool_call_id == mcp.tool_call_id
    assert restored.content == mcp.content
    assert_mcp_result!(restored)
    assert result!(provider, "view_image").content == native.content
    assert_image_wire!(provider, restored, wire_images())
    assert_image_wire!(provider, result!(provider, "view_image"), native_wire())
    nested = structured!(result!(provider, "exec"))
    assert nested["value"]["content"] == json_value(images())
    assert nested["value"]["details"] == envelope()
  end

  defp assert_image_wire!(provider, result, expected) do
    assert %{"type" => "function_call_output", "output" => ^expected} =
             Enum.find(
               provider.body["input"],
               &(&1["call_id"] == result.tool_call_id and
                   &1["type"] == "function_call_output")
             )
  end

  defp assert_read_only_reopen!(path, log, mcp, native) do
    journal = File.read!(path)
    requests = File.read!(log)
    journal_stat = File.stat!(path, time: :posix)
    requests_stat = File.stat!(log, time: :posix)
    assert {:ok, first} = Log.snapshot(path)
    assert {:ok, reopened} = Log.snapshot(path)
    assert reopened.messages == first.messages

    for snapshot <- [first, reopened] do
      result = Enum.find(snapshot.messages, &(Map.get(&1, :tool_call_id) == mcp.tool_call_id))
      assert result
      assert_mcp_result!(result)
      assert structured!(result)["details"] == envelope()
      image = Enum.find(snapshot.messages, &(Map.get(&1, :tool_call_id) == native.tool_call_id))
      assert image.content == native.content
      assert structured!(image)["detail"] == "original"
      nested = Enum.find(snapshot.messages, &(Map.get(&1, :tool_name) == "exec"))
      assert structured!(nested)["value"]["content"] == json_value(images())
      assert structured!(nested)["value"]["details"] == envelope()
    end

    assert File.read!(path) == journal
    assert File.read!(log) == requests
    assert File.stat!(path, time: :posix).mtime == journal_stat.mtime
    assert File.stat!(log, time: :posix).mtime == requests_stat.mtime
    reopened
  end

  defp assert_mcp_calls!(log, count) do
    calls =
      log
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)
      |> Enum.filter(&(&1["method"] == "tools/call"))

    assert length(calls) == count
    assert Enum.all?(calls, &(get_in(&1, ["params", "name"]) == "render_chart"))
  end

  defp call!(provider, name, input, server) do
    send_call(provider, name, input)
    provider!(provider.params.session_id, server)
  end

  defp send_call(provider, name, input) do
    id = "image-call-#{System.unique_integer([:positive])}"

    item = %{
      "type" => if(is_binary(input), do: "custom_tool_call", else: "function_call"),
      "id" => "item-" <> id,
      "call_id" => id,
      "name" => name,
      "status" => "completed"
    }

    item =
      if is_binary(input),
        do: Map.put(item, "input", input),
        else: Map.put(item, "arguments", Jason.encode!(input))

    send(provider.http, {:image_response, [terminal([item])]})
  end

  defp provider!(session, server) do
    params =
      receive do
        {:image_provider, _pid, %{session_id: "child_" <> _} = params} when session == :child ->
          params

        {:image_provider, _pid, %{session_id: id} = params} when id == session ->
          params

        {:turn_error, error} ->
          flunk("Responses image turn failed: #{inspect(error)}")
      after
        8_000 -> flunk("image Provider did not start for #{session}")
      end

    id = params.session_id

    receive do
      {:image_http, ^server, ^id, http, body} -> %{params: params, http: http, body: body}
      {:turn_error, error} -> flunk("Responses image HTTP failed: #{inspect(error)}")
    after
      8_000 -> flunk("real image HTTP request did not arrive for #{id}")
    end
  end

  defp finish!(provider, handle, c) do
    frames = [
      %{"type" => "response.output_text.delta", "delta" => "done"},
      terminal([])
    ]

    send(provider.http, {:image_response, frames})

    case provider.params.session_id do
      "child_" <> _ = id ->
        assert eventually(fn ->
                 host = Runtime.lookup(c.dir, @root, :subagents)
                 assert {:ok, %{subagents: roster}} = Subagents.snapshot(host)

                 Enum.any?(
                   roster.agents,
                   &(&1.child_session_id == id and &1.run_id == provider.params.turn_id and
                       &1.status == :completed)
                 )
               end)

      @root ->
        assert_receive {:agent_end, _}, 8_000
        assert Sigma.Agent.status(handle.agent).phase == :completed
    end
  end

  defp eventually(fun, attempts \\ 400)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp result!(provider, name),
    do:
      Enum.find(Enum.reverse(provider.params.context.messages), &(&1[:tool_name] == name)) ||
        flunk("missing #{name} in the actual image Provider request")

  defp structured!(result) do
    metadata = Map.get(result, :metadata, %{})

    case metadata[:structured_result] || metadata["structured_result"] do
      nil ->
        assert [%{type: :text, text: json}] = result.content
        Jason.decode!(json)

      value ->
        value
    end
  end

  defp json_value(value), do: value |> Jason.encode!() |> Jason.decode!()

  defp images do
    for {data, detail} <- [{@png, "auto"}, {@uri, "low"}, {@png, "original"}, {@uri, "high"}] do
      %{type: :image, data: data, mime_type: "image/png", detail: detail}
    end
  end

  defp wire_images do
    Enum.map(images(), &%{"type" => "input_image", "image_url" => @uri, "detail" => &1.detail})
  end

  defp native_wire,
    do: [%{"type" => "input_image", "image_url" => @uri, "detail" => "original"}]

  defp envelope do
    %{
      "content" => [
        %{
          "type" => "image",
          "data" => @png,
          "mimeType" => "image/png",
          "_meta" => %{"codex/imageDetail" => "auto"}
        },
        %{
          "type" => "image",
          "data" => @uri,
          "mimeType" => "image/png",
          "_meta" => %{"codex/imageDetail" => "low"}
        },
        %{
          "type" => "image",
          "data" => @png,
          "mime_type" => "image/png",
          "_meta" => %{"codex/imageDetail" => "original"}
        },
        %{"type" => "image", "data" => @uri}
      ],
      "isError" => false,
      "_meta" => %{"images/receipt" => %{"complete" => true, "optional" => nil}}
    }
  end

  defp terminal(output) do
    %{
      "type" => "response.completed",
      "response" => %{
        "id" => "image-response-#{System.unique_integer([:positive])}",
        "status" => "completed",
        "output" => output,
        "usage" => %{"input_tokens" => 1, "output_tokens" => 1, "total_tokens" => 2}
      }
    }
  end

  defp fixture do
    ~S"""
    import json,sys
    payload=json.load(open(sys.argv[1]))
    log=sys.argv[2]
    for line in sys.stdin:
        request=json.loads(line)
        method=request.get('method')
        ident=request.get('id')
        params=request.get('params',{})
        with open(log,'a') as output:
            output.write(json.dumps({'method':method,'params':params})+'\n')
        if ident is None: continue
        if method=='initialize':
            result={'protocolVersion':'2025-06-18','capabilities':{'tools':{}},'serverInfo':{'name':'images','version':'1'}}
        elif method=='tools/list':
            result={'tools':[{'name':'render_chart','description':'Return complete chart images','inputSchema':{'type':'object','properties':{},'additionalProperties':False}}]}
        elif method=='tools/call':
            result=payload
        else:
            print(json.dumps({'jsonrpc':'2.0','id':ident,'error':{'code':-32601,'message':'Method not found'}}),flush=True)
            continue
        print(json.dumps({'jsonrpc':'2.0','id':ident,'result':result}),flush=True)
    """
  end

  defp with_server(fun) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listener)
    owner = self()
    server = make_ref()
    task = Task.async(fn -> accept(listener, owner, server) end)

    try do
      fun.("http://127.0.0.1:#{port}", server)
    after
      Task.shutdown(task, :brutal_kill)
      :gen_tcp.close(listener)
    end
  end

  defp accept(listener, owner, server) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        worker =
          spawn_link(fn ->
            receive do
              {:image_socket, socket} -> serve(socket, owner, server)
            end
          end)

        :ok = :gen_tcp.controlling_process(socket, worker)
        send(worker, {:image_socket, socket})
        accept(listener, owner, server)

      {:error, :closed} ->
        :ok
    end
  end

  defp serve(socket, owner, server) do
    try do
      request = receive_request(socket, "")
      [headers, body] = String.split(request, "\r\n\r\n", parts: 2)
      [_, path, _] = headers |> String.split("\r\n", parts: 2) |> hd() |> String.split(" ")
      [id, "responses"] = String.split(path, "/", trim: true)
      send(owner, {:image_http, server, id, self(), Jason.decode!(body)})

      receive do
        {:image_response, frames} ->
          response = Enum.map_join(frames, &("data: " <> Jason.encode!(&1) <> "\n\n"))

          :ok =
            :gen_tcp.send(socket, [
              "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\n",
              "content-length: #{byte_size(response)}\r\nconnection: close\r\n\r\n",
              response
            ])
      after
        30_000 -> raise "image HTTP response was not supplied"
      end
    after
      :gen_tcp.close(socket)
    end
  end

  defp receive_request(socket, acc) do
    {:ok, bytes} = :gen_tcp.recv(socket, 0, 5_000)
    acc = acc <> bytes

    case String.split(acc, "\r\n\r\n", parts: 2) do
      [headers, body] ->
        [_, length] = Regex.run(~r/content-length: (\d+)/i, headers)

        if byte_size(body) >= String.to_integer(length),
          do: acc,
          else: receive_request(socket, acc)

      _ ->
        receive_request(socket, acc)
    end
  end
end
