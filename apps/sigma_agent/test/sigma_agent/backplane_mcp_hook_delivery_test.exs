defmodule Sigma.Agent.BackplaneMcpHookDeliveryTest do
  use ExUnit.Case, async: false

  alias Sigma.Agent.Runtime
  alias Sigma.Agent.Backplane.Store
  alias Sigma.Coding.Hooks.Discovery
  alias Sigma.Session.{Log, Writer}

  @moduletag :tmp_dir
  @tool "mcp__vault__echo"
  @text "  MCP 异步原文\nnext  "

  defmodule Provider do
    @behaviour Sigma.Ai.Provider

    def stream(params) do
      send(params.options[:test_pid], {:mcp_hook_provider, self(), params})

      receive do
        {:respond, content} ->
          reason = if Enum.any?(content, &(&1.type == :tool_call)), do: :tool_use, else: :stop

          message = %{
            role: :assistant,
            model: "mock",
            provider: "mock",
            api: "openai-responses",
            content: content,
            stop_reason: reason,
            usage: %{input: 1, output: 1, total_tokens: 2, cost: %{total: 0.0}},
            timestamp: System.system_time(:millisecond)
          }

          [{:start, %{message | content: []}}, {:done, reason, message}]
      end
    end
  end

  setup %{tmp_dir: dir} do
    python = System.find_executable("python3")
    assert python, "real MCP hook acceptance requires Python"
    script = Path.join(dir, "vault.py")
    File.write!(script, fixture())
    File.write!(Path.join(dir, "mcp-calls.jsonl"), "")
    store = start_supervised!({Store, path: Path.join(dir, "runtime")})

    on_exit(fn ->
      if supervisor = Runtime.lookup(dir, :supervisor),
        do: DynamicSupervisor.terminate_child(Sigma.Agent.DynamicSupervisor, supervisor)
    end)

    %{
      dir: dir,
      store: store,
      servers: %{
        "vault" => %{
          "type" => "stdio",
          "command" => python,
          "args" => ["-u", script, Path.join(dir, "mcp-calls.jsonl")]
        }
      }
    }
  end

  for mode <- [:direct, :code_mode] do
    @tag execution_mode: mode
    test "#{mode} MCP feedback uses the actual settled invocation and active admission once", c do
      agent = session!(c)
      provider = discover!(agent)
      mode = c.execution_mode

      call =
        if mode == :direct,
          do: tool_call(@tool, %{"value" => "direct"}),
          else: tool_call("exec", "text(await tools.mcp__vault__echo({value:'nested'}));")

      send(provider, {:respond, [call]})
      {provider, _request} = provider!()
      await!(fn -> File.exists?(path(c, "hook-runs")) end)
      release!(c)
      await!(fn -> match?([%{"status" => "admitted"}], items(c)) end)
      [item] = items(c)
      assert item["text"] == @text
      assert item["origin"]["tool_name"] == @tool

      if mode == :direct,
        do: assert(item["origin"]["tool_call_id"] == call.id),
        else: refute(item["origin"]["tool_call_id"] == call.id)

      assert {:ok, %{run: run}} = Store.load(c.store, item["origin"]["run_id"])
      intent = run.execution_intents["tool:" <> item["origin"]["invocation_id"]]
      assert intent.status == :consumed
      assert run.tool_results[item["origin"]["invocation_id"]].is_error == false

      for key <-
            ~w(run_id incarnation turn_id step_id attempt_id invocation_id tool_call_id tool_name)a do
        assert intent.operation[key] == item["origin"][Atom.to_string(key)]
      end

      send(provider, {:respond, [%{type: :text, text: "before feedback"}]})
      {provider, request} = provider!()
      assert [message] = feedback(request.context.messages)
      assert message.content == "[Developer context from async hook]\n" <> @text
      await!(fn -> match?([%{"status" => "consumed"}], items(c)) end)
      finish!(provider)
      assert length(calls(c)) == 1
      assert File.read!(path(c, "hook-runs")) == "run\n"
      assert length(json_lines(path(c, "submissions.jsonl"))) == 1
      assert {:ok, snapshot} = Log.snapshot(path(c, "session.jsonl"))
      assert [canonical] = feedback(snapshot.messages)
      [item] = items(c)
      assert item["delivery"]["message_id"] == canonical.id
      refute item["delivery"]["runtime_message_id"] == canonical.id
    end
  end

  test "idle MCP feedback survives host recreation and reaches the next real prompt first", c do
    agent = session!(c)
    provider = discover!(agent)
    send(provider, {:respond, [tool_call(@tool, %{"value" => "idle"})]})
    {provider, _} = provider!()
    finish!(provider)
    release!(c)
    await!(fn -> match?([%{"status" => "received"}], items(c)) end)
    refute_receive {:mcp_hook_provider, _, _}, 100
    [original] = items(c)
    stop_session!(c)
    assert {:ok, snapshot} = Log.snapshot(path(c, "session.jsonl"))
    agent = session!(c, messages: snapshot.messages)
    assert {:accepted, _} = Sigma.Agent.prompt(agent, "real followup")
    {provider, request} = provider!()
    assert [message] = feedback(request.context.messages)
    assert message.content == "real followup\n\n[Developer context from async hook]\n" <> @text
    finish!(provider)
    [recovered] = items(c)
    assert recovered["item_id"] == original["item_id"]
    assert recovered["status"] == "consumed"
    assert length(calls(c)) == 1
    assert File.read!(path(c, "hook-runs")) == "run\n"
  end

  test "a cancelled MCP origin cannot deliver late feedback into the replacement run", c do
    agent = session!(c)
    provider = discover!(agent)
    send(provider, {:respond, [tool_call(@tool, %{"value" => "cancelled"})]})
    {_provider, _} = provider!()
    await!(fn -> File.exists?(path(c, "hook-runs")) end)
    assert {:cancelling, _} = Sigma.Agent.cancel(agent)
    assert_receive {:turn_cancelled}, 5_000
    release!(c)
    await!(fn -> match?([%{"status" => "received"}], items(c)) end)
    assert {:accepted, _} = Sigma.Agent.prompt(agent, "replacement prompt")
    {provider, request} = provider!()
    assert feedback(request.context.messages) == []
    finish!(provider)
    assert [%{"status" => "discarded"}] = items(c)
    assert length(calls(c)) == 1
  end

  test "MCP errors retain their result and do not execute success hooks", c do
    release!(c)

    sync =
      parse_hooks(%{
        "PostToolUse" => [
          %{
            "matcher" => @tool,
            "hooks" => [
              %{
                "type" => "command",
                "command" => "touch " <> quote_path(path(c, "sync-post"))
              }
            ]
          }
        ]
      })

    agent = session!(c, hook_specs: hook_specs(c) ++ sync)
    provider = discover!(agent)
    send(provider, {:respond, [tool_call(@tool, %{"value" => "error"})]})
    {provider, _} = provider!()
    assert Enum.any?(Sigma.Agent.messages(agent), &(&1.role == :tool_result and &1.is_error))
    refute File.exists?(path(c, "sync-post"))
    refute File.exists?(path(c, "hook-runs"))
    assert items(c) == []
    finish!(provider)
    assert length(calls(c)) == 1
  end

  test "Dispatcher permission denial prevents both the remote call and post hooks", c do
    release!(c)
    agent = session!(c, permission_config: %{default: :allow, rules: %{@tool => :deny}})
    provider = discover!(agent)
    send(provider, {:respond, [tool_call(@tool, %{"value" => "denied"})]})
    {provider, _} = provider!()
    assert Enum.any?(Sigma.Agent.messages(agent), &(&1.role == :tool_result and &1.is_error))
    assert calls(c) == []
    assert items(c) == []
    refute File.exists?(path(c, "hook-runs"))
    finish!(provider)
  end

  test "closing the root host cancels detached MCP hooks before retiring its Writer", c do
    agent = session!(c)
    provider = discover!(agent)
    send(provider, {:respond, [tool_call(@tool, %{"value" => "close"})]})
    {provider, _} = provider!()
    await!(fn -> File.exists?(path(c, "hook-runs")) end)
    finish!(provider)
    stop_session!(c)
    release!(c)
    refute_receive {:mcp_hook_provider, _, _}, 100
    assert {:ok, entries} = Sigma.Session.Storage.JsonlFile.read(path(c, "session.jsonl"))
    refute Enum.any?(entries, &(&1["type"] == "hook_feedback"))
    assert length(calls(c)) == 1
    refute File.exists?(path(c, "hook-completed"))
  end

  defp session!(c, extra \\ []) do
    assert {:ok, handle} =
             Runtime.get_session(
               c.dir,
               "mcp-hooks",
               Keyword.merge(
                 [
                   cwd: c.dir,
                   transcript_path: path(c, "session.jsonl"),
                   backplane_store: c.store,
                   native_tools: true,
                   tools: [],
                   mcp_servers: c.servers,
                   provider: Provider,
                   options: [test_pid: self()],
                   hook_specs: hook_specs(c),
                   model: %{
                     id: "mock",
                     provider: "mock",
                     api: "openai-responses",
                     context_window: 100_000
                   }
                 ],
                 extra
               )
             )

    assert :ok = Sigma.Agent.subscribe(handle.agent)
    handle.agent
  end

  defp discover!(agent) do
    assert {:accepted, _} = Sigma.Agent.prompt(agent, "use MCP")
    {provider, _} = provider!()
    send(provider, {:respond, [tool_call("tool_search", %{"query" => "echo value"})]})
    {provider, request} = provider!()
    assert Enum.any?(request.context.tools, &(&1.name == @tool))
    provider
  end

  defp hook_specs(c) do
    output =
      Jason.encode!(%{
        "hookSpecificOutput" => %{
          "hookEventName" => "PostToolUse",
          "additionalContext" => @text
        }
      })

    command =
      "cat >/dev/null; printf 'run\\n' >> " <>
        quote_path(path(c, "hook-runs")) <>
        "; while [ ! -f " <>
        quote_path(path(c, "release")) <>
        " ]; do sleep 0.01; done; printf '%s' " <>
        quote_path(output) <>
        "; touch " <> quote_path(path(c, "hook-completed"))

    submit =
      "cat >> " <>
        quote_path(path(c, "submissions.jsonl")) <>
        "; printf '\\n' >> " <> quote_path(path(c, "submissions.jsonl"))

    parse_hooks(%{
      "UserPromptSubmit" => [%{"hooks" => [%{"type" => "command", "command" => submit}]}],
      "PostToolUse" => [
        %{
          "matcher" => @tool,
          "hooks" => [
            %{"type" => "command", "command" => command, "async" => true, "timeout" => 10}
          ]
        }
      ]
    })
  end

  defp parse_hooks(hooks) do
    assert {:ok, specs} = Discovery.parse(Jason.encode!(%{"hooks" => hooks}), :codex)
    Enum.map(specs, &%{&1 | origin: {:user, "mcp-hook-test"}, trusted?: true})
  end

  defp provider! do
    assert_receive {:mcp_hook_provider, provider, request}, 8_000
    {provider, request}
  end

  defp tool_call(name, arguments),
    do: %{
      type: :tool_call,
      id: "mcp-hook-#{System.unique_integer([:positive])}",
      name: name,
      arguments: arguments,
      input_kind: if(is_binary(arguments), do: :custom, else: :function)
    }

  defp finish!(provider) do
    send(provider, {:respond, [%{type: :text, text: "done"}]})
    assert_receive {:agent_end, _}, 5_000
  end

  defp stop_session!(c) do
    assert :ok =
             DynamicSupervisor.terminate_child(
               Runtime.lookup(c.dir, :sessions),
               Runtime.lookup(c.dir, "mcp-hooks", :supervisor)
             )
  end

  defp items(c) do
    assert {:ok, state} = Writer.hook_feedback_state(Runtime.lookup(c.dir, "mcp-hooks", :writer))
    Map.values(state.projection.items)
  end

  defp feedback(messages),
    do:
      Enum.filter(messages, fn message ->
        message.role == :user and Map.has_key?(Map.get(message, :metadata, %{}), "hook_feedback")
      end)

  defp calls(c), do: json_lines(path(c, "mcp-calls.jsonl"))

  defp json_lines(path),
    do: path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

  defp path(c, name), do: Path.join(c.dir, name)
  defp release!(c), do: File.write!(path(c, "release"), "ready")
  defp quote_path(text), do: "'" <> String.replace(text, "'", "'\\''") <> "'"

  defp await!(condition, attempts \\ 500)
  defp await!(condition, 0), do: assert(condition.())

  defp await!(condition, attempts) do
    if condition.(),
      do: :ok,
      else:
        (
          Process.sleep(10)
          await!(condition, attempts - 1)
        )
  end

  defp fixture do
    ~S"""
    import json, sys
    log = sys.argv[1]
    for line in sys.stdin:
        message = json.loads(line)
        method, ident = message.get("method"), message.get("id")
        if ident is None:
            continue
        if method == "initialize":
            result = {"protocolVersion":"2025-06-18","capabilities":{"tools":{}},"serverInfo":{"name":"vault","version":"1"}}
        elif method == "tools/list":
            result = {"tools":[{"name":"echo","description":"Echo value for hook acceptance","inputSchema":{"type":"object","properties":{"value":{"type":"string"}},"required":["value"],"additionalProperties":False}}]}
        elif method == "tools/call":
            with open(log, "a") as output:
                output.write(json.dumps(message["params"]) + "\n")
            value = message["params"]["arguments"]["value"]
            result = {"content":[{"type":"text","text":"vault:"+value}],"isError":value=="error"}
        else:
            print(json.dumps({"jsonrpc":"2.0","id":ident,"error":{"code":-32601,"message":"not found"}}), flush=True)
            continue
        print(json.dumps({"jsonrpc":"2.0","id":ident,"result":result}), flush=True)
    """
  end
end
