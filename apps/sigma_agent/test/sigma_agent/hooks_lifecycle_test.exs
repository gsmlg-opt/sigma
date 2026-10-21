defmodule Sigma.Agent.HooksLifecycleTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.Conversation
  alias Sigma.Agent.Backplane.ChildIO
  alias Sigma.Agent.Message
  alias Sigma.Coding.Hooks.Spec
  alias Sigma.Coding.Hooks.Spec.Command

  @moduletag :tmp_dir

  defmodule Provider do
    @behaviour Sigma.Ai.Provider

    @impl true
    def stream(request) do
      send(request.options[:test_pid], {:provider_request, request})

      case request.options[:mode] do
        :raise ->
          raise "request failed"

        :lazy_raise ->
          Stream.concat(
            Enum.take(response(), 1),
            Stream.repeatedly(fn -> raise "stream failed" end)
          )

        :missing_terminal ->
          Enum.take(response(), 1)

        :wait ->
          Stream.repeatedly(fn -> Process.sleep(:infinity) end)

        _ ->
          response()
      end
    end

    defp response do
      message = %{
        role: :assistant,
        content: [%{type: :text, text: "answer"}],
        model: "mock-model",
        provider: "mock-provider",
        api: "mock-api",
        usage: %{input: 7, output: 3, total_tokens: 10},
        stop_reason: :stop,
        timestamp: System.system_time(:millisecond)
      }

      [{:start, %{message | content: []}}, {:done, :stop, message}]
    end
  end

  test "SessionStart waits for a first prompt and stops only that turn", %{tmp_dir: dir} do
    spec =
      capture_hook(dir, :session_start, %{"continue" => false, "stopReason" => "paused"},
        matcher: "startup"
      )

    agent = start_agent(dir, [spec])
    refute File.exists?(capture_path(dir, :session_start))

    Sigma.Agent.prompt(agent, "first")
    assert_receive {:turn_blocked, "paused"}, 3_000
    assert_receive {:agent_end, []}, 3_000
    refute_receive {:provider_request, _}, 50

    Sigma.Agent.prompt(agent, "second")
    assert_receive {:provider_request, _}, 3_000
    assert_receive {:agent_end, _}, 3_000
    assert [%{"source" => "startup"}] = payloads(dir, :session_start)
  end

  test "restored history defaults to resume and explicit source takes precedence", %{tmp_dir: dir} do
    spec = capture_hook(dir, :session_start)
    agent = start_agent(dir, [spec], messages: history())
    Sigma.Agent.prompt(agent, "continue")
    assert_receive {:agent_end, _}, 3_000
    assert [%{"source" => "resume"}] = payloads(dir, :session_start)
    assert :ok = stop_supervised(Sigma.Agent)

    File.rm!(capture_path(dir, :session_start))
    agent = start_agent(dir, [spec], messages: history(), resume_source: :fork)
    Sigma.Agent.prompt(agent, "forked work")
    assert_receive {:agent_end, _}, 3_000
    assert [%{"source" => "fork"}] = payloads(dir, :session_start)
  end

  test "UserPromptSubmit continue false prevents provider dispatch", %{tmp_dir: dir} do
    spec =
      capture_hook(dir, :user_prompt_submit, %{"continue" => false, "stopReason" => "paused"})

    agent = start_agent(dir, [spec])
    Sigma.Agent.prompt(agent, "first")
    assert_receive {:turn_blocked, "paused"}, 3_000
    assert_receive {:agent_end, []}, 3_000
    refute_receive {:provider_request, _}, 50
    assert [%{"prompt" => "first", "turn_id" => turn_id}] = payloads(dir, :user_prompt_submit)
    assert is_binary(turn_id)
  end

  test "Stop may continue repeatedly and exposes the active continuation state", %{tmp_dir: dir} do
    spec = repeating_stop_hook(dir, :stop)
    agent = start_agent(dir, [spec])
    Sigma.Agent.prompt(agent, "first")
    assert_receive {:agent_end, messages}, 5_000
    assert Enum.count(messages, &(&1.role == :assistant)) == 3
    assert Enum.map(payloads(dir, :stop), & &1["stop_hook_active"]) == [false, true, true]
    assert Enum.all?(payloads(dir, :stop), &is_binary(&1["turn_id"]))
  end

  test "compaction hooks bracket a committed summary", %{tmp_dir: dir} do
    agent =
      start_agent(dir, [capture_hook(dir, :pre_compact), capture_hook(dir, :post_compact)],
        messages: history()
      )

    assert :ok = Sigma.Agent.begin_session_operation(agent)
    assert {:ok, _} = Sigma.Agent.compact(agent)
    assert [%{"trigger" => "manual"}] = payloads(dir, :pre_compact)
    assert [%{"trigger" => "manual"}] = payloads(dir, :post_compact)
    assert Enum.any?(:sys.get_state(agent).messages, &(&1.role == :compaction_summary))
  end

  test "PreCompact halt keeps the original history and skips PostCompact", %{tmp_dir: dir} do
    specs = [
      capture_hook(dir, :pre_compact, %{"continue" => false, "stopReason" => "paused"}),
      capture_hook(dir, :post_compact)
    ]

    messages = history()
    agent = start_agent(dir, specs, messages: messages)
    assert :ok = Sigma.Agent.begin_session_operation(agent)
    assert {:error, {:hook_stopped, "paused"}} = Sigma.Agent.compact(agent)
    assert :sys.get_state(agent).messages == messages
    refute File.exists?(capture_path(dir, :post_compact))
    refute_receive {:provider_request, _}, 50
  end

  test "PostCompact halt reports a stopped turn after preserving its committed summary", %{
    tmp_dir: dir
  } do
    spec = capture_hook(dir, :post_compact, %{"continue" => false, "stopReason" => "paused"})
    agent = start_agent(dir, [spec], messages: history())
    assert :ok = Sigma.Agent.begin_session_operation(agent)
    assert {:error, {:hook_stopped, "paused"}} = Sigma.Agent.compact(agent)
    assert Enum.any?(:sys.get_state(agent).messages, &(&1.role == :compaction_summary))
    assert [_] = payloads(dir, :post_compact)
  end

  test "model hooks observe completion without steering the request", %{tmp_dir: dir} do
    specs = [
      capture_hook(dir, :pre_model_request, %{"continue" => false}),
      capture_hook(dir, :post_model_request, %{"decision" => "block", "reason" => "ignored"})
    ]

    agent = start_agent(dir, specs)
    Sigma.Agent.prompt(agent, "first")
    assert_receive {:agent_end, messages}, 3_000
    assert List.last(messages).role == :assistant
    assert [_] = payloads(dir, :pre_model_request)

    assert [%{"status" => "completed", "error" => nil, "token_usage" => usage}] =
             payloads(dir, :post_model_request)

    assert usage["input_tokens"] == 7
    assert usage["output_tokens"] == 3
  end

  test "model hook reports an immediate provider failure once", %{tmp_dir: dir} do
    agent = start_agent(dir, [capture_hook(dir, :post_model_request)], mode: :raise)
    Sigma.Agent.prompt(agent, "first")
    assert_receive {:agent_end, _}, 3_000
    assert [%{"status" => "failed", "error" => error}] = payloads(dir, :post_model_request)
    assert error =~ "request failed"
  end

  test "model hook reports a lazy stream exception as failed once", %{tmp_dir: dir} do
    agent = start_agent(dir, [capture_hook(dir, :post_model_request)], mode: :lazy_raise)
    Sigma.Agent.prompt(agent, "first")
    assert_receive {:agent_end, _}, 3_000
    assert [%{"status" => "failed", "error" => error}] = payloads(dir, :post_model_request)
    assert error =~ "stream failed"
  end

  test "model hook reports a missing terminal event as failed once", %{tmp_dir: dir} do
    agent = start_agent(dir, [capture_hook(dir, :post_model_request)], mode: :missing_terminal)
    Sigma.Agent.prompt(agent, "first")
    assert_receive {:agent_end, _}, 3_000
    assert [%{"status" => "failed", "error" => error}] = payloads(dir, :post_model_request)
    assert error =~ "stream_ended_without_terminal"
  end

  test "cancelled requests receive one PostModelRequest and one root Interrupt", %{tmp_dir: dir} do
    specs = [capture_hook(dir, :post_model_request), capture_hook(dir, :interrupt)]
    agent = start_agent(dir, specs, mode: :wait)
    Sigma.Agent.prompt(agent, "first")
    assert_receive {:provider_request, _}, 3_000
    assert {:cancelling, _} = Sigma.Agent.cancel(agent)
    assert_receive {:turn_cancelled}, 5_000
    eventually(fn -> length(payloads(dir, :post_model_request)) == 1 end)
    assert [%{"status" => "cancelled"}] = payloads(dir, :post_model_request)
    assert [_] = payloads(dir, :interrupt)
  end

  test "normal supervisor shutdown runs SessionEnd with the Codex reason", %{tmp_dir: dir} do
    start_agent(dir, [capture_hook(dir, :session_end, %{}, matcher: "other")])
    assert :ok = stop_supervised(Sigma.Agent)
    assert [%{"reason" => "other"}] = payloads(dir, :session_end)
  end

  test "session shutdown cancels detached hook commands before SessionEnd", %{tmp_dir: dir} do
    started = Path.join(dir, "async-started")
    escaped = Path.join(dir, "async-escaped")

    spec =
      write_hook(
        dir,
        :user_prompt_submit,
        "touch #{quote_shell(started)}; (sleep 0.4; touch #{quote_shell(escaped)}) & wait",
        []
      )

    spec = %{spec | handler: %{spec.handler | async: true, timeout_ms: 5_000}}
    agent = start_agent(dir, [spec, capture_hook(dir, :session_end)])
    runtime = :sys.get_state(agent).hook_async_runtime
    Sigma.Agent.prompt(agent, "first")
    assert_receive {:agent_end, _}, 3_000
    eventually(fn -> File.exists?(started) end)
    assert Process.alive?(runtime)

    assert :ok = stop_supervised(Sigma.Agent)
    refute Process.alive?(runtime)
    assert [_] = payloads(dir, :session_end)
    Process.sleep(500)
    refute File.exists?(escaped)
  end

  test "session shutdown cancels a synchronous PostModelRequest command", %{tmp_dir: dir} do
    started = Path.join(dir, "post-started")
    escaped = Path.join(dir, "post-escaped")

    spec =
      write_hook(
        dir,
        :post_model_request,
        "touch #{quote_shell(started)}; (sleep 0.4; touch #{quote_shell(escaped)}) & wait",
        []
      )

    spec = %{spec | handler: %{spec.handler | timeout_ms: 5_000}}
    agent = start_agent(dir, [spec, capture_hook(dir, :session_end)])
    Sigma.Agent.prompt(agent, "first")
    eventually(fn -> File.exists?(started) end)

    assert :ok = stop_supervised(Sigma.Agent)
    assert [_] = payloads(dir, :session_end)
    Process.sleep(500)
    refute File.exists?(escaped)
  end

  test "child start waits for real prompt and SubagentStop can continue", %{tmp_dir: dir} do
    identity = %{
      agent_id: "child-id",
      child_session_id: "child-session",
      root_session_id: "root",
      run_id: "child-run",
      public_run_id: "child-run",
      incarnation: 1,
      parent_transcript_path: Path.join(dir, "parent.jsonl"),
      agent_type: "worker"
    }

    specs = [
      capture_hook(
        dir,
        :subagent_start,
        %{
          "continue" => false,
          "hookSpecificOutput" => %{
            "hookEventName" => "SubagentStart",
            "additionalContext" => "child context"
          }
        },
        matcher: "worker"
      ),
      repeating_stop_hook(dir, :subagent_stop, matcher: "worker")
    ]

    config = %{
      model: model(),
      provider: Provider,
      provider_options: [test_pid: self()],
      cwd: dir,
      tools: [],
      dispatcher_opts: [],
      hook_specs: specs,
      policy: nil
    }

    path = Path.join(dir, "child.jsonl")

    io =
      start_supervised!(
        {ChildIO,
         config: config,
         identity: identity,
         transcript_path: path,
         backplane_store_path: Path.join(dir, "child.runtime")}
      )

    authority = %{caller: "root", run_id: "root-run", grants: [], tool_revision: 1}
    assert {:ok, prepared} = ChildIO.prepare(io, identity, authority, [])
    refute File.exists?(capture_path(dir, :subagent_start))

    conversation = start_supervised!({Conversation, prepared.options ++ [subscriber: self()]})
    assert {:ok, _} = Conversation.prompt(conversation, "child prompt")
    assert_receive {:provider_request, request}, 3_000
    assert inspect(request.context.messages) =~ "child context"
    eventually(fn -> length(payloads(dir, :subagent_stop)) == 3 end)

    assert [%{"agent_id" => "child-id", "agent_type" => "worker"}] =
             payloads(dir, :subagent_start)

    assert Enum.map(payloads(dir, :subagent_stop), & &1["stop_hook_active"]) == [
             false,
             true,
             true
           ]

    assert Enum.all?(payloads(dir, :subagent_stop), fn payload ->
             payload["transcript_path"] == identity.parent_transcript_path and
               payload["agent_transcript_path"] == path
           end)
  end

  defp start_agent(dir, specs, opts \\ []) do
    agent_opts =
      [
        model: model(),
        provider: Provider,
        session_id: "hooks-test",
        backplane_runtime_path:
          Path.join(dir, "agent-#{System.unique_integer([:positive])}.runtime"),
        cwd: dir,
        hook_specs: specs,
        messages: Keyword.get(opts, :messages, []),
        options: [test_pid: self(), mode: opts[:mode]]
      ] ++ Keyword.take(opts, [:resume_source])

    agent =
      start_supervised!({Sigma.Agent, agent_opts})

    Sigma.Agent.subscribe(agent)
    agent
  end

  defp model, do: %{id: "mock-model", api: "mock-api", provider: "mock-provider"}

  defp history do
    for index <- 1..24 do
      if rem(index, 2) == 1,
        do: Message.user("message-#{index}", "question"),
        else: Message.assistant("message-#{index}", %{content: [%{type: :text, text: "answer"}]})
    end
  end

  defp capture_hook(dir, event, output \\ %{}, opts \\ []) do
    write_hook(dir, event, "printf '%s' #{quote_shell(Jason.encode!(output))}\n", opts)
  end

  defp repeating_stop_hook(dir, event, opts \\ []) do
    path = quote_shell(capture_path(dir, event))

    write_hook(
      dir,
      event,
      """
      if [ "$(wc -l < #{path})" -lt 3 ]; then
        printf '%s' '{"decision":"block","reason":"continue checking"}'
      fi
      """,
      opts
    )
  end

  defp write_hook(dir, event, body, opts) do
    path = capture_path(dir, event)
    script = Path.join(dir, "#{event}.sh")

    File.write!(
      script,
      "cat >> #{quote_shell(path)}\nprintf '\\n' >> #{quote_shell(path)}\n" <> body
    )

    %Spec{
      event: event,
      matcher: Keyword.get(opts, :matcher, :any),
      handler: %Command{cmd: "sh " <> quote_shell(script), timeout_ms: 1_000},
      origin: {:user, dir},
      trusted?: true,
      dialect: :codex
    }
  end

  defp capture_path(dir, event), do: Path.join(dir, "#{event}.jsonl")

  defp payloads(dir, event) do
    case File.read(capture_path(dir, event)) do
      {:ok, bytes} -> bytes |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
      {:error, :enoent} -> []
    end
  end

  defp quote_shell(text), do: "'" <> String.replace(text, "'", "'\\''") <> "'"

  defp eventually(check, attempts \\ 300)
  defp eventually(check, 0), do: assert(check.())

  defp eventually(check, attempts) do
    if check.() do
      :ok
    else
      receive do
      after
        10 -> eventually(check, attempts - 1)
      end
    end
  end
end
