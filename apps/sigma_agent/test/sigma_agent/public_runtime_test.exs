defmodule Sigma.Agent.PublicRuntimeTest do
  use ExUnit.Case, async: false

  alias Sigma.Agent.PublicRuntime
  alias Sigma.Protocol.{Codec, Envelope}

  defmodule ScriptedProvider do
    @behaviour Sigma.Ai.Provider

    @impl true
    def stream(params) do
      response = Keyword.get(params.options, :response, "headless response")
      message = message(response, :stop)
      [{:start, %{message | content: []}}, {:text_delta, 0, response, message}, {:done, :stop, message}]
    end

    def message(text, stop_reason) do
      %{
        role: :assistant,
        content: [%{type: :text, text: text}],
        model: "mock-model",
        provider: "mock-provider",
        api: "mock-api",
        usage: %{
          input: 1,
          output: 1,
          cache_read: 0,
          cache_write: 0,
          total_tokens: 2,
          cost: %{total: 0.0}
        },
        stop_reason: stop_reason,
        timestamp: System.system_time(:millisecond)
      }
    end
  end

  defmodule BlockingProvider do
    @behaviour Sigma.Ai.Provider

    @impl true
    def stream(params) do
      test_pid = Keyword.fetch!(params.options, :test_pid)
      cancellation_ref = Keyword.fetch!(params.options, :cancellation_ref)

      Stream.resource(
        fn -> :waiting end,
        fn
          :done ->
            {:halt, :done}

          :waiting ->
            send(test_pid, {:headless_provider_waiting, self()})

            receive do
              :release_headless_provider ->
                message = ScriptedProvider.message("released", :stop)
                {[{:start, %{message | content: []}}, {:done, :stop, message}], :done}

              {:cancel, ^cancellation_ref} ->
                {[{:provider_error, Sigma.Ai.ProviderError.from_reason(:cancelled)}], :done}
            end
        end,
        fn _state -> :ok end
      )
    end
  end

  defmodule ToolProvider do
    @behaviour Sigma.Ai.Provider

    @impl true
    def stream(params) do
      last = List.last(params.context.messages)

      {content, reason} =
        if last && last.role == :tool_result do
          {[%{type: :text, text: "tool complete"}], :stop}
        else
          {[%{type: :tool_call, id: "safe-call", name: "safe", arguments: %{}}], :tool_use}
        end

      message = ScriptedProvider.message("", reason)
      message = %{message | content: content}
      [{:start, %{message | content: []}}, {:done, reason, message}]
    end
  end

  defmodule SafeTool do
    @behaviour Sigma.Coding.Tool

    @impl true
    def name, do: "safe"
    @impl true
    def description, do: "safe deterministic tool"
    @impl true
    def schema, do: %{}
    @impl true
    def metadata, do: %{effect: :read, concurrency: :parallel, default_deadline_ms: 1_000}

    @impl true
    def execute(_id, _params, opts) do
      send(Keyword.fetch!(opts, :test_pid), :safe_tool_executed)
      {:ok, %{content: [%{type: :text, text: "safe result"}], details: %{}}}
    end
  end

  setup context do
    root =
      Path.join(
        System.tmp_dir!(),
        "sigma-public-runtime-#{context.test}-#{System.unique_integer([:positive])}"
      )

    repo = Path.join(root, "repo")
    sessions_dir = Path.join(root, "sessions")
    File.mkdir_p!(repo)
    File.mkdir_p!(sessions_dir)

    on_exit(fn ->
      stop_repository(repo)
      File.rm_rf!(root)
    end)

    {:ok, repo: repo, sessions_dir: sessions_dir}
  end

  test "drives a complete turn through the direct protocol API for two ordered subscribers", context do
    session_id = "direct-turn"
    runtime_context = create_session!(context, session_id, provider: ScriptedProvider)
    sub1 = attach!(session_id, runtime_context)
    sub2 = attach!(session_id, runtime_context)

    assert {:ok, command} =
             Envelope.command("prompt.submit", session_id, %{"content" => "hello"})

    assert {:ok, %{type: "prompt.admitted", payload: %{"status" => "accepted"}}} =
             PublicRuntime.execute(command, runtime_context)

    events1 = collect_until(sub1, "turn.completed", [])
    events2 = collect_until(sub2, "turn.completed", [])
    types1 = Enum.map(events1, & &1.type)
    types2 = Enum.map(events2, & &1.type)

    assert types1 == types2
    assert "message.delta" in types1
    assert List.last(types1) == "turn.completed"

    for event <- events1 ++ events2 do
      assert {:ok, encoded} = Codec.encode(event)
      refute encoded =~ "#PID"
      refute encoded =~ "#Reference"
    end
  end

  test "subscriber disconnect does not stop a running turn and reconnect receives the terminal event", context do
    session_id = "disconnect-turn"

    runtime_context =
      create_session!(context, session_id,
        provider: BlockingProvider,
        options: [test_pid: self()]
      )

    parent = self()

    sink =
      spawn(fn ->
        receive_loop = fn receive_loop ->
          receive do
            message ->
              send(parent, {:disconnected_sink_event, message})
              receive_loop.(receive_loop)
          end
        end

        receive_loop.(receive_loop)
      end)

    _disconnected_sub = attach!(session_id, Map.put(runtime_context, :subscriber, sink))
    surviving_sub = attach!(session_id, runtime_context)

    assert {:ok, prompt} = Envelope.command("prompt.submit", session_id, %{"content" => "wait"})
    assert {:ok, _admission} = PublicRuntime.execute(prompt, runtime_context)
    assert_receive {:headless_provider_waiting, provider}, 1_000

    Process.exit(sink, :kill)
    Process.sleep(20)

    assert {:ok, status} = Envelope.command("session.status", session_id)
    assert {:ok, %{payload: %{"turn" => %{"phase" => "streaming_provider"}}}} =
             PublicRuntime.execute(status, runtime_context)

    send(provider, :release_headless_provider)
    events = collect_until(surviving_sub, "turn.completed", [])
    assert List.last(events).type == "turn.completed"
  end

  test "interactive headless permission resolves only the matching request", context do
    session_id = "permission-turn"

    runtime_context =
      create_session!(context, session_id,
        provider: ToolProvider,
        tools: [SafeTool],
        dispatcher_opts: [test_pid: self()],
        permission_config: %{default: :allow, rules: %{"safe" => :ask}}
      )

    subscription_id = attach!(session_id, runtime_context)

    assert {:ok, prompt} = Envelope.command("prompt.submit", session_id, %{"content" => "use tool"})

    assert {:ok, _admission} =
             PublicRuntime.execute(prompt, Map.put(runtime_context, :interactive_approvals, true))

    permission_event = receive_type(subscription_id, "permission.required")
    request_id = permission_event.payload["requestId"]

    assert {:ok, wrong} =
             Envelope.command("permission.resolve", session_id, %{
               "requestId" => "wrong-request",
               "decision" => "allow"
             })

    assert {:error, %{error: %{code: "not_found"}}} =
             PublicRuntime.execute(wrong, runtime_context)

    refute_receive :safe_tool_executed, 50

    assert {:ok, resolve} =
             Envelope.command("permission.resolve", session_id, %{
               "requestId" => request_id,
               "decision" => "allow"
             })

    assert {:ok, _status} = PublicRuntime.execute(resolve, runtime_context)
    assert_receive :safe_tool_executed, 1_000
    events = collect_until(subscription_id, "turn.completed", [])
    assert List.last(events).type == "turn.completed"
  end

  test "headless ask policy without a resolver emits typed approval_required", context do
    session_id = "approval-required"

    runtime_context =
      create_session!(context, session_id,
        provider: ToolProvider,
        tools: [SafeTool],
        dispatcher_opts: [test_pid: self()],
        permission_config: %{default: :allow, rules: %{"safe" => :ask}}
      )

    subscription_id = attach!(session_id, runtime_context)
    assert {:ok, prompt} = Envelope.command("prompt.submit", session_id, %{"content" => "use tool"})
    assert {:ok, _admission} = PublicRuntime.execute(prompt, runtime_context)

    event = receive_type(subscription_id, "session.error")
    assert event.error.code == "approval_required"
    refute_receive :safe_tool_executed, 50
  end

  test "a slow subscriber drops intermediate events without blocking the Agent terminal", context do
    session_id = "slow-subscriber"
    runtime_context = create_session!(context, session_id, provider: ScriptedProvider)
    parent = self()

    slow_sink =
      spawn(fn ->
        receive do
          :drain -> drain_sink(parent, [])
        end
      end)

    send(slow_sink, :backlog)

    subscription_context =
      runtime_context
      |> Map.put(:subscriber, slow_sink)
      |> Map.put(:max_subscriber_queue, 1)

    subscription_id = attach!(session_id, subscription_context)
    assert {:ok, prompt} = Envelope.command("prompt.submit", session_id, %{"content" => "fast"})
    assert {:ok, _admission} = PublicRuntime.execute(prompt, runtime_context)

    assert :ok = await_phase(context.repo, session_id, :completed, 5_000)
    send(slow_sink, :drain)
    assert_receive {:slow_sink_messages, messages}, 5_000

    assert Enum.any?(messages, fn
             {:sigma_protocol, ^subscription_id, %{type: "turn.completed"}} -> true
             _message -> false
           end)
  end

  test "protocol file commands cannot escape trusted repository roots", context do
    session_id = "protocol-path-boundary"
    runtime_context = create_session!(context, session_id, provider: ScriptedProvider)
    outside_path = Path.join(context.sessions_dir, "outside-dump.json")

    assert {:ok, dump} =
             Envelope.command("session.dump", session_id, %{"outputPath" => outside_path})

    assert {:error, %{error: %{code: "artifact_path_outside_root"}}} =
             PublicRuntime.execute(dump, runtime_context)

    refute File.exists?(outside_path)

    assert {:ok, create} =
             Envelope.command("session.create", "outside-cwd", %{
               "cwd" => context.sessions_dir,
               "metadata" => %{}
             })

    assert {:error, %{error: %{code: "cwd_outside_repository"}}} =
             PublicRuntime.execute(create, runtime_context)
  end

  test "failed session creation publishes no journal or metadata", context do
    assert {:ok, create} =
             Envelope.command("session.create", "missing-runtime-options", %{
               "cwd" => context.repo,
               "metadata" => %{}
             })

    invalid_context = %{repo_path: context.repo, sessions_dir: context.sessions_dir}

    assert {:error, %{error: %{code: "runtime_session_options_required"}}} =
             PublicRuntime.execute(create, invalid_context)

    refute File.exists?(Path.join(context.sessions_dir, "missing-runtime-options.jsonl"))
    refute File.exists?(Path.join(context.sessions_dir, "missing-runtime-options.meta.json"))
  end

  defp create_session!(context, session_id, session_opts) do
    runtime_context = %{
      repo_path: context.repo,
      sessions_dir: context.sessions_dir,
      session_opts:
        Keyword.merge(
          [
            model: %{id: "mock-model", api: "mock-api", provider: "mock-provider"},
            provider: ScriptedProvider
          ],
          session_opts
        )
    }

    assert {:ok, command} =
             Envelope.command("session.create", session_id, %{
               "cwd" => context.repo,
               "metadata" => %{"cwd" => context.repo}
             })

    assert {:ok, %{type: "session.snapshot"}} = PublicRuntime.execute(command, runtime_context)
    runtime_context
  end

  defp attach!(session_id, context) do
    assert {:ok, command} = Envelope.command("subscription.attach", session_id)
    assert {:ok, %{payload: %{"subscriptionId" => subscription_id}}} =
             PublicRuntime.execute(command, context)

    subscription_id
  end

  defp receive_type(subscription_id, type) do
    receive do
      {:sigma_protocol, ^subscription_id, %{type: ^type} = event} -> event
      {:sigma_protocol, ^subscription_id, _other_event} -> receive_type(subscription_id, type)
    after
      5_000 -> flunk("timed out waiting for #{type}")
    end
  end

  defp collect_until(subscription_id, terminal_type, acc) do
    receive do
      {:sigma_protocol, ^subscription_id, event} ->
        events = acc ++ [event]
        if event.type == terminal_type, do: events, else: collect_until(subscription_id, terminal_type, events)
    after
      5_000 -> flunk("timed out waiting for #{terminal_type}")
    end
  end

  defp drain_sink(parent, acc) do
    receive do
      message -> drain_sink(parent, [message | acc])
    after
      10 -> send(parent, {:slow_sink_messages, Enum.reverse(acc)})
    end
  end

  defp await_phase(repo, session_id, phase, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_phase(repo, session_id, phase, deadline)
  end

  defp do_await_phase(repo, session_id, phase, deadline) do
    agent = Sigma.Agent.Runtime.lookup(repo, session_id, :agent)

    if is_pid(agent) and Sigma.Agent.status(agent).phase == phase do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        {:error, :timeout}
      else
        Process.sleep(10)
        do_await_phase(repo, session_id, phase, deadline)
      end
    end
  end

  defp stop_repository(repo) do
    case Sigma.Agent.Runtime.lookup(repo, :supervisor) do
      supervisor when is_pid(supervisor) ->
        DynamicSupervisor.terminate_child(Sigma.Agent.DynamicSupervisor, supervisor)

      nil ->
        :ok
    end
  end
end
