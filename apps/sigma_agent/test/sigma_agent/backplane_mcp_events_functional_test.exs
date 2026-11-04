defmodule Sigma.Agent.BackplaneMcpEventsFunctionalTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.Error
  alias Backplane.McpProtocol.Client
  alias Sigma.Agent.Backplane.{ChildIO, Store}
  alias Sigma.Agent.{Runtime, Subagents}
  alias Sigma.Coding.Hooks.Spec
  alias Sigma.Coding.Hooks.Spec.Command
  alias Sigma.Session.{Log, Writer}

  @moduletag :tmp_dir
  @moduletag :codex_alignment_functional
  @moduletag timeout: 30_000
  @cursor "  opaque/+page=汉字\r\n  "
  @next "  opaque/+next=汉字\r\n  "

  defmodule Provider do
    @behaviour Sigma.Ai.Provider
    def output_token_limit(_, _), do: 2_000

    def stream(params) do
      send(params.options[:test_pid], {:events_provider, self(), params})

      receive do
        {:events_response, content} ->
          reason = if Enum.any?(content, &(&1.type == :tool_call)), do: :tool_use, else: :stop

          message = %{
            role: :assistant,
            content: content,
            stop_reason: reason,
            usage: %{input: 1, output: 1, total_tokens: 2},
            model: "events",
            provider: "events",
            api: "openai-responses",
            timestamp: System.system_time(:millisecond)
          }

          [{:start, %{message | content: []}}, {:done, reason, message}]
      end
    end
  end

  defmodule Fixture do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
    def endpoint(pid), do: GenServer.call(pid, :endpoint)
    def close(pid), do: GenServer.call(pid, :close, 5_000)

    @impl true
    def init(opts) do
      port =
        Port.open({:spawn_executable, System.find_executable("python3")}, [
          :binary,
          :exit_status,
          args: ["-u", opts[:fixture], opts[:log]]
        ])

      receive do
        {^port, {:data, line}} ->
          {:ok, %{port: port, url: "http://127.0.0.1:#{String.trim(line)}/mcp"}}
      after
        5_000 -> {:stop, :fixture_not_started}
      end
    end

    @impl true
    def handle_call(:endpoint, _, state), do: {:reply, state.url, state}

    def handle_call(:close, _, state) do
      result = stop_port(state.port)
      {:stop, :normal, result, %{state | port: nil}}
    end

    @impl true
    def terminate(_, %{port: port}) when is_port(port), do: stop_port(port)
    def terminate(_, _), do: :ok

    defp stop_port(port) do
      Port.command(port, "\n")

      receive do
        {^port, {:exit_status, code}} -> {:ok, code}
      after
        2_000 ->
          Port.close(port)
          {:error, :fixture_exit_unconfirmed}
      end
    end
  end

  setup %{tmp_dir: dir} do
    log = Path.join(dir, "wire.jsonl")
    File.write!(log, "")
    fixture = Path.expand("../support/mcp_events_http.py", __DIR__)
    server = start_supervised!({Fixture, fixture: fixture, log: log})
    path = Path.join(dir, "root.jsonl")

    on_exit(fn ->
      case Runtime.lookup(dir, :supervisor) do
        nil -> :ok
        pid -> DynamicSupervisor.terminate_child(Sigma.Agent.DynamicSupervisor, pid)
      end
    end)

    assert {:ok, handle} =
             Runtime.get_session(dir, "events",
               cwd: dir,
               transcript_path: path,
               native_tools: true,
               native_memory_root: Path.join(dir, "memories"),
               provider: Provider,
               model: %{id: "events", provider: "events", api: "openai-responses"},
               mcp_servers: %{"events" => %{"type" => "http", "url" => Fixture.endpoint(server)}},
               tools: [],
               hook_specs: [
                 %Spec{
                   event: :post_tool_use,
                   matcher: :any,
                   dialect: :codex,
                   origin: {:user, "/functional"},
                   trusted?: true,
                   handler: %Command{
                     cmd: "cat >> '#{dir}/hooks.jsonl'; printf '\\n' >> '#{dir}/hooks.jsonl'",
                     timeout_ms: 10_000
                   }
                 }
               ],
               options: [test_pid: self()]
             )

    :ok = Sigma.Agent.subscribe(handle.agent)
    assert {:accepted, _} = Sigma.Agent.prompt(handle.agent, "Read configured MCP Events")
    root = provider!("events")
    assert Enum.any?(root.params.context.tools, &(&1.name == "mcp_events"))

    assert {:ok, %{"events" => client}} =
             GenServer.call(handle.agent, {:native_mcp_clients, root.params.turn_id})

    %{
      agent: handle.agent,
      root: root,
      client: client,
      dir: dir,
      path: path,
      log: log,
      fixture: server
    }
  end

  test "raw pages preserve opaque cursors, descriptors, metadata and history without auto-pagination",
       c do
    root = call!(c.root, "mcp_events", %{"server" => "events", "cursor" => @cursor})
    assert value!(root, "mcp_events") == page()
    assert [wire] = Enum.filter(wires(c), &(&1["method"] == "events/list"))
    assert wire["params"]["cursor"] === @cursor
    refute Map.has_key?(wire["params"], "requestState")

    root = call!(root, "mcp_events", %{"server" => "events", "cursor" => @next})

    assert value!(root, "mcp_events") == %{
             "resultType" => "complete",
             "events" => [],
             "_meta" => %{"empty" => true}
           }

    assert length(Enum.filter(wires(c), &(&1["method"] == "events/list"))) == 2
    finish!(root, c.agent)
    messages = Sigma.Agent.messages(c.agent)
    [first, second] = Enum.filter(messages, &(Map.get(&1, :tool_name) == "mcp_events"))
    assert Map.delete(decode!(first), "is_error") == page()
    assert decode!(second)["events"] == []

    assert {:accepted, _} = Sigma.Agent.prompt(c.agent, "Read one MRTR page through real Deno")
    root = provider!("events")
    root = call_events!(root, :deno, "mrtr")
    assert value!(root, "exec")["value"] |> Map.delete("is_error") == page()
    mrtr = Enum.filter(wires(c), &(get_in(&1, ["params", "cursor"]) == "mrtr"))
    assert [first_wire, second_wire] = mrtr
    assert first_wire["id"] != second_wire["id"]
    assert second_wire["params"]["requestState"] == "continue"
    assert Enum.count(wires(c), &(&1["method"] == "server/discover")) == 1
    finish!(root, c.agent)
    retire!(c)

    writer = Runtime.lookup(c.dir, "events", :writer)
    assert {:ok, _} = Writer.flush(writer)
    journal = File.read!(c.path)
    wire_log = File.read!(c.log)
    assert {:ok, saved} = Log.snapshot(c.path)
    assert {:ok, ^saved} = Log.snapshot(c.path)
    assert File.read!(c.path) == journal
    assert File.read!(c.log) == wire_log
    [first, second] = Enum.filter(saved.messages, &(Map.get(&1, :tool_name) == "mcp_events"))
    assert Map.delete(decode!(first), "is_error") == page()
    assert decode!(second)["events"] == []
    [nested] = Enum.filter(saved.messages, &(Map.get(&1, :tool_name) == "exec"))
    assert decode!(nested)["value"] |> Map.delete("is_error") == page()
  end

  for mode <- [:direct, :deno], kind <- [:rpc, :domain] do
    @tag :events_error_fidelity
    @tag events_mode: mode, events_error_kind: kind
    test "an actual #{kind} Events error retains complete #{mode} details and permits a fresh page",
         c do
      cursor = if c.events_error_kind == :rpc, do: "error", else: "domain-error"
      name = if c.events_mode == :deno, do: "exec", else: "mcp_events"

      root =
        if c.events_mode == :direct do
          call_events!(c.root, :direct, cursor)
        else
          call!(c.root, "exec", """
          let failure;
          try { await tools.mcp_events(#{Jason.encode!(%{server: "events", cursor: cursor})}); }
          catch (error) { failure = error.message; }
          if (!failure) throw new Error('Expected an Events error');
          return {failure, page: await tools.mcp_events({server:'events'})};
          """)
        end

      result = result!(root, name)
      assert result.is_error == (c.events_mode == :direct)
      projected = decode!(result)
      assert {:ok, store} = Store.open(path: c.path <> ".runtime")
      assert {:ok, %{run: run}} = Store.load(store, c.root.params.turn_id)

      [native] =
        Enum.filter(Map.values(run.tool_results), fn
          %{error: %Error{class: :execution_failure}} -> true
          _ -> false
        end)

      error = native.error |> Error.to_map() |> Jason.encode!() |> Jason.decode!()
      assert error["class"] == "execution_failure"
      assert error["details"]["server"] == "events"

      if c.events_error_kind == :rpc do
        assert error["details"]["mcp_error"] == rpc_error()
      else
        assert error["details"]["mcp_result"] == domain_error()
      end

      if c.events_mode == :direct do
        assert projected["is_error"] == true
        assert projected["error"] == error
      else
        assert projected["value"]["failure"] == error["message"]
        assert Map.delete(projected["value"]["page"], "is_error") == page()
      end

      root = call_events!(root, c.events_mode, nil)
      value = value!(root, name)
      value = if c.events_mode == :deno, do: Map.delete(value["value"], "is_error"), else: value
      assert value == page()
      finish!(root, c.agent)
      retire!(c)
      assert {:ok, _} = Writer.flush(Runtime.lookup(c.dir, "events", :writer))
      journal = File.read!(c.path)
      wire_log = File.read!(c.log)
      assert {:ok, saved} = Log.snapshot(c.path)

      saved_error =
        Enum.find(saved.messages, &(Map.get(&1, :tool_call_id) == result.tool_call_id))

      assert saved_error
      assert decode!(saved_error) == projected
      assert {:ok, ^saved} = Log.snapshot(c.path)
      assert File.read!(c.path) == journal
      assert File.read!(c.log) == wire_log
    end
  end

  for mode <- [:direct, :deno] do
    @tag events_mode: mode
    test "root #{mode} cancellation retires both MRTR wires and preserves an independent caller",
         c do
      send_events(c.root, c.events_mode, "mrtr-cancel")
      pending = pending!(c)
      {other, other_wire} = other_caller!(c)
      assert {:cancelling, _} = Sigma.Agent.cancel(c.agent)
      assert_receive {:turn_cancelled}, 8_000
      assert_receive {:agent_end, _}, 5_000
      assert Sigma.Agent.status(c.agent).phase == :cancelled
      assert {:ok, store} = Store.open(path: c.path <> ".runtime")
      assert {:ok, snapshot} = Store.load(store, c.root.params.turn_id)
      assert snapshot.run.state == :cancelled
      assert_retirement!(snapshot.run, c, pending, c.events_mode)
      assert_other!(c, other, other_wire)

      assert {:accepted, _} = Sigma.Agent.prompt(c.agent, "Read after actual Events cancellation")
      root = provider!("events")
      root = call_events!(root, :direct, nil)
      assert value!(root, "mcp_events") == page()
      finish!(root, c.agent)
      retire!(c)
    end

    @tag events_mode: mode
    test "managed child #{mode} interruption keeps exact Events proof through full host retirement",
         c do
      send_call(c.root, "spawn_agent", %{
        "task_name" => "events_child",
        "message" => "Read Events",
        "fork_turns" => "none"
      })

      child = provider!(:child)
      root = provider!("events")
      refute result!(root, "spawn_agent").is_error
      assert Enum.any?(child.params.context.tools, &(&1.name == "mcp_events"))
      send_events(child, c.events_mode, "mrtr-cancel")
      pending = pending!(c)
      {other, other_wire} = other_caller!(c)
      host = Runtime.lookup(c.dir, "events", :subagents)

      assert {:ok, %{children: [%{io: io, identity: identity}]}} =
               Subagents.archive_sources(host)

      assert identity.child_session_id == child.params.session_id
      assert {:ok, store} = ChildIO.store(io)

      root = call!(root, "interrupt_agent", %{"target" => "/root/events_child"})
      refute result!(root, "interrupt_agent").is_error
      assert {:ok, snapshot} = Store.load(store, identity.run_id)
      assert snapshot.run.state == :cancelled
      assert_retirement!(snapshot.run, c, pending, c.events_mode)
      assert_other!(c, other, other_wire)

      root = call_events!(root, :direct, nil)
      assert value!(root, "mcp_events") == page()

      send_call(root, "followup_task", %{
        "target" => "/root/events_child",
        "message" => "Read a fresh Events page on the same child"
      })

      next = provider!(child.params.session_id)
      root = provider!("events")
      refute result!(root, "followup_task").is_error
      refute next.params.turn_id == child.params.turn_id
      next = call_events!(next, c.events_mode, nil)
      name = if c.events_mode == :deno, do: "exec", else: "mcp_events"
      value = value!(next, name)
      value = if c.events_mode == :deno, do: Map.delete(value["value"], "is_error"), else: value
      assert value == page()
      send(next.pid, {:events_response, [%{type: :text, text: "Child Events completed"}]})
      root = call!(root, "wait_agent", %{"timeout_ms" => 10_000})
      refute result!(root, "wait_agent").is_error, inspect(result!(root, "wait_agent"))
      assert Enum.count(wires(c), &(&1["method"] == "server/discover")) == 1
      finish!(root, c.agent)
      retire!(c)
    end
  end

  defp retire!(c) do
    assert {:ok, %{status: :confirmed}} = Sigma.Agent.retire_host(c.agent)
    assert {:ok, 0} = Fixture.close(c.fixture)
  end

  defp page do
    %{
      "resultType" => "complete",
      "events" => [
        %{
          "name" => "second",
          "title" => "Changed e\u0301 👩‍💻\r\n",
          "inputSchema" => true,
          "payloadSchema" => false,
          "_meta" => %{"order" => 2}
        },
        %{
          "name" => "first",
          "payloadSchema" => %{"type" => "object", "additionalProperties" => true}
        }
      ],
      "nextCursor" => @next,
      "_meta" => %{"exact" => [2, true, nil, "  Unicode 汉字\r\n第二行\n"]}
    }
  end

  defp rpc_error do
    %{
      "code" => -32603,
      "message" => "actual Events fixture failure 汉字\r\n",
      "data" => %{"exact" => [nil, false, " é 👩‍💻\r\n"], "empty" => %{}}
    }
  end

  defp domain_error do
    %{
      "resultType" => "complete",
      "isError" => true,
      "events" => [],
      "_meta" => %{"cause" => "domain 汉字\r\n", "values" => [true, nil]}
    }
  end

  defp assert_retirement!(run, c, pending, mode) do
    records = records(run.outcome)
    assert [event] = Enum.filter(records, &(&1["record_type"] == "event_request_retirement"))
    assert event["executor_down"] == true
    assert event["resources"] == "confirmed"
    assert event["local_cleanup"] == "confirmed"
    assert event["outcome"] == "unknown"
    receipt = event["cancellation"]["receipt"]
    assert receipt["schema"] == "event_retirement"
    assert receipt["terminal"] == "cancelled"
    assert receipt["local_cleanup"] == "confirmed"

    request_ids =
      wires(c)
      |> Enum.filter(&(get_in(&1, ["params", "cursor"]) == "mrtr-cancel"))
      |> Enum.map(& &1["id"])

    assert [_, _] = request_ids
    assert List.last(request_ids) == pending["id"]
    assert receipt["request_ids"] == request_ids
    cancelled = Enum.filter(wires(c), &(&1["method"] == "notifications/cancelled"))
    assert Enum.map(cancelled, & &1["params"]["requestId"]) == [pending["id"]]

    if mode == :deno do
      assert [outer] = Enum.filter(records, &(&1["record_type"] == "code_mode_retirement"))
      assert Enum.any?(outer["nested"], &(&1["evidence_digest"] == event["retirement_digest"]))
    end
  end

  defp records(%{"record_type" => _} = record), do: [record]
  defp records(map) when is_map(map), do: map |> Map.values() |> Enum.flat_map(&records/1)
  defp records(list) when is_list(list), do: Enum.flat_map(list, &records/1)
  defp records(_), do: []

  defp other_caller!(c) do
    other =
      Task.async(fn ->
        with {:ok, request} <-
               Client.start_read_resource(c.client, "mem://survivor-pending", timeout: 8_000),
             do: Client.await_resource_request(request, :infinity)
      end)

    {other, await_wire!(c, &(&1["event"] == "other_pending"))}
  end

  defp assert_other!(c, other, wire) do
    refute Enum.any?(wires(c), &(get_in(&1, ["params", "requestId"]) == wire["id"]))
    assert {:ok, _} = Client.read_resource(c.client, "mem://release", timeout: 1_000)
    assert {:ok, response} = Task.await(other, 3_000)

    assert response.result["contents"] == [
             %{"uri" => "mem://survivor-pending", "text" => "ready"}
           ]

    assert {:ok, page} = Client.start_list_events(c.client)
    assert {:ok, response} = Client.await_event_request(page, 1_000)
    assert response.result == page()
  end

  defp pending!(c), do: await_wire!(c, &(&1["event"] == "pending"))

  defp wires(c),
    do: c.log |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

  defp await_wire!(c, predicate, attempts \\ 400)

  defp await_wire!(c, _predicate, 0),
    do: flunk("Missing actual Events wire: #{inspect(wires(c))}")

  defp await_wire!(c, predicate, attempts) do
    case Enum.find(wires(c), predicate) do
      nil ->
        Process.sleep(10)
        await_wire!(c, predicate, attempts - 1)

      wire ->
        wire
    end
  end

  defp provider!(session) do
    receive do
      {:events_provider, pid, %{session_id: "child_" <> _} = params} when session == :child ->
        %{pid: pid, params: params}

      {:events_provider, pid, %{session_id: ^session} = params} ->
        %{pid: pid, params: params}

      {:turn_error, error} ->
        flunk("Events turn failed: #{inspect(error)}")
    after
      8_000 -> flunk("Events Provider did not start for #{session}")
    end
  end

  defp send_call(provider, name, arguments) do
    send(
      provider.pid,
      {:events_response,
       [
         %{
           type: :tool_call,
           id: "events-#{System.unique_integer([:positive])}",
           name: name,
           arguments: arguments,
           input_kind: if(is_binary(arguments), do: :custom, else: :function)
         }
       ]}
    )
  end

  defp call!(provider, name, arguments) do
    send_call(provider, name, arguments)
    provider!(provider.params.session_id)
  end

  defp send_events(provider, :direct, cursor),
    do:
      send_call(
        provider,
        "mcp_events",
        Map.reject(%{"server" => "events", "cursor" => cursor}, fn {_, v} -> is_nil(v) end)
      )

  defp send_events(provider, :deno, cursor) do
    arguments = Map.reject(%{server: "events", cursor: cursor}, fn {_, v} -> is_nil(v) end)
    send_call(provider, "exec", "return await tools.mcp_events(#{Jason.encode!(arguments)});")
  end

  defp call_events!(provider, mode, cursor) do
    send_events(provider, mode, cursor)
    provider!(provider.params.session_id)
  end

  defp result!(provider, name),
    do:
      Enum.find(
        Enum.reverse(provider.params.context.messages),
        &(Map.get(&1, :tool_name) == name)
      ) || flunk("Missing #{name} result")

  defp decode!(message),
    do:
      Map.get(message, :metadata, %{})[:structured_result] ||
        Jason.decode!(hd(message.content).text)

  defp value!(provider, name) do
    result = result!(provider, name)
    refute result.is_error, inspect(result)
    Map.delete(decode!(result), "is_error")
  end

  defp finish!(provider, agent) do
    turn_id = Sigma.Agent.status(agent).turn_id
    send(provider.pid, {:events_response, [%{type: :text, text: "Events completed"}]})
    assert_receive {:turn_completed, ^turn_id}, 5_000
    assert_receive {:agent_end, _}, 5_000
    assert Sigma.Agent.status(agent).phase == :completed
  end
end
