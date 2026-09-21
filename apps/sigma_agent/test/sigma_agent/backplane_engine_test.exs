defmodule Sigma.Agent.BackplaneEngineTest do
  use ExUnit.Case, async: true

  alias Sigma.Agent.Message

  defmodule ToolProvider do
    @behaviour Sigma.Ai.Provider

    @impl true
    def stream(params) do
      send(params.options[:test_pid], {:backplane_provider, params.context.messages})

      {content, stop_reason} =
        case List.last(params.context.messages) do
          %{role: :tool_result} ->
            {[%{type: :text, text: "written"}], :stop}

          _message ->
            call = %{
              type: :tool_call,
              id: "write-1",
              name: "backplane_test_write",
              arguments: %{"path" => params.options[:path], "count" => 1}
            }

            {[call], :tool_use}
        end

      message = %{
        role: :assistant,
        content: content,
        model: "mock-model",
        provider: "mock-provider",
        api: "mock-api",
        usage: %{
          input: 2,
          output: 1,
          cache_read: 0,
          cache_write: 0,
          total_tokens: 3,
          cost: %{total: 0.0}
        },
        stop_reason: stop_reason,
        timestamp: System.system_time(:millisecond)
      }

      [{:start, %{message | content: []}}, {:done, stop_reason, message}]
    end
  end

  defmodule WriteTool do
    @behaviour Sigma.Coding.Tool

    @impl true
    def name, do: "backplane_test_write"
    @impl true
    def description, do: "Writes a deterministic integration-test file"

    @impl true
    def schema do
      %{
        "type" => "object",
        "required" => ["path", "count"],
        "properties" => %{
          "path" => %{"type" => "string"},
          "count" => %{"type" => "integer", "minimum" => 1}
        }
      }
    end

    @impl true
    def metadata,
      do: %{effect: :filesystem, concurrency: :exclusive, default_deadline_ms: 5_000}

    @impl true
    def execute(_id, %{"path" => path, "count" => 1}, _opts) do
      :ok = File.write(path, "backplane")
      {:ok, %{content: [%{type: :text, text: "ok"}], details: %{path: path}}}
    end
  end

  defmodule BlockingProvider do
    @behaviour Sigma.Ai.Provider

    @impl true
    def stream(params) do
      last = List.last(params.context.messages)
      send(params.options[:test_pid], {:backplane_provider_waiting, self(), last.content})

      receive do
        {:release_backplane_provider, text} ->
          message = %{
            role: :assistant,
            content: [%{type: :text, text: text}],
            model: "mock-model",
            provider: "mock-provider",
            api: "mock-api",
            usage: %{input: 1, output: 1, cache_read: 0, cache_write: 0, total_tokens: 2},
            stop_reason: :stop,
            timestamp: System.system_time(:millisecond)
          }

          [{:start, %{message | content: []}}, {:done, :stop, message}]
      end
    end
  end

  @tag :tmp_dir
  test "opt-in prompt runs the provider/tool conversation and keeps Sigma events", %{
    tmp_dir: tmp_dir
  } do
    output_path = Path.join(tmp_dir, "result.txt")

    {:ok, agent} =
      Sigma.Agent.start_link(
        session_id: "backplane-engine-test",
        execution_engine: :backplane,
        backplane_runtime_path: Path.join(tmp_dir, "runtime"),
        model: %{id: "mock-model", api: "mock-api", provider: "mock-provider"},
        provider: ToolProvider,
        tools: [WriteTool],
        options: [test_pid: self(), path: output_path]
      )

    :ok = Sigma.Agent.subscribe(agent)
    assert {:accepted, %{turn_id: turn_id}} = Sigma.Agent.prompt(agent, "write it")

    assert_receive {:agent_start, _cwd}, 5_000
    assert_receive {:message_start, %Message{role: :user, content: "write it"}}, 5_000
    assert_receive {:backplane_provider, [%{role: :user, content: "write it"}]}, 5_000
    assert_receive {:tool_execution_start, "write-1", "backplane_test_write", _}, 5_000
    assert_receive {:tool_execution_end, "write-1", "backplane_test_write", _, false}, 5_000

    assert_receive {:agent_end,
                    [
                      %Message{role: :user},
                      %Message{role: :assistant},
                      %Message{role: :tool_result},
                      %Message{role: :assistant, content: [%{type: :text, text: "written"}]}
                    ]},
                   5_000

    assert_receive {:turn_end, %{role: :assistant}, [%{role: :tool_result}]}
    assert_receive {:metrics, :tool_finished, fact}
    assert is_binary(fact.request_id)
    assert File.read!(output_path) == "backplane"

    assert %{turn_id: ^turn_id, phase: :completed} = Sigma.Agent.status(agent)
  end

  @tag :tmp_dir
  test "steering stays in the active run and follow-up starts a new run", %{tmp_dir: tmp_dir} do
    {:ok, agent} =
      Sigma.Agent.start_link(
        session_id: "backplane-queues-test",
        execution_engine: :backplane,
        backplane_runtime_path: Path.join(tmp_dir, "runtime"),
        model: %{id: "mock-model", api: "mock-api", provider: "mock-provider"},
        provider: BlockingProvider,
        options: [test_pid: self()]
      )

    :ok = Sigma.Agent.subscribe(agent)
    assert {:accepted, %{turn_id: first_turn}} = Sigma.Agent.prompt(agent, "initial")
    assert_receive {:backplane_provider_waiting, first_provider, "initial"}, 5_000

    assert {:queued_as_steering, %{message_id: steering_id, turn_id: ^first_turn}} =
             Sigma.Agent.steer(agent, "steer")

    assert {:queued_as_follow_up, %{message_id: follow_up_id}} =
             Sigma.Agent.follow_up(agent, "follow")

    send(first_provider, {:release_backplane_provider, "initial response"})
    assert_receive {:backplane_provider_waiting, steering_provider, "steer"}, 5_000
    send(steering_provider, {:release_backplane_provider, "steering response"})

    assert_receive {:agent_end, first_messages}, 5_000
    assert Enum.find(first_messages, &(&1.id == steering_id and &1.content == "steer"))

    assert_receive {:backplane_provider_waiting, follow_up_provider, "follow"}, 5_000
    send(follow_up_provider, {:release_backplane_provider, "follow-up response"})
    assert_receive {:agent_end, all_messages}, 5_000
    assert Enum.find(all_messages, &(&1.id == follow_up_id and &1.content == "follow"))
  end

  for action <- [:cancel, :crash] do
    @tag :tmp_dir
    test "#{action} during a provider request closes metrics and classifies the outcome", %{
      tmp_dir: tmp_dir
    } do
      action = Map.get(%{action: unquote(action)}, :action)

      {:ok, agent} =
        Sigma.Agent.start_link(
          execution_engine: :backplane,
          backplane_runtime_path: Path.join(tmp_dir, "runtime"),
          model: %{id: "mock-model", api: "mock-api", provider: "mock-provider"},
          provider: BlockingProvider,
          options: [test_pid: self()]
        )

      :ok = Sigma.Agent.subscribe(agent)
      assert {:accepted, _} = Sigma.Agent.prompt(agent, "initial")
      assert_receive {:backplane_provider_waiting, worker, "initial"}, 5_000
      assert_receive {:metrics, :request_started, started}, 5_000
      if action == :cancel, do: Sigma.Agent.cancel(agent), else: Process.exit(worker, :kill)
      expected = if action == :cancel, do: :cancelled, else: :failed
      assert_receive {:metrics, :request_finished, finished}, 5_000
      assert finished.request_id == started.request_id
      assert finished.status == expected
      assert_receive {:agent_end, _}, 5_000
      assert Sigma.Agent.status(agent).phase == expected
    end
  end

  defmodule UnsupportedTool do
    def name, do: "unsupported"
    def description, do: "Unsupported schema fixture"
    def schema, do: %{"type" => "object", "properties" => %{"mode" => %{"enum" => ["one"]}}}
    def execute(_, _, _), do: raise("unsupported tool must never run")
  end

  @tag :tmp_dir
  test "unsupported schemas fail before starting the provider", %{tmp_dir: dir} do
    {:ok, agent} = start_blocking_agent(dir, tools: [UnsupportedTool])
    Sigma.Agent.subscribe(agent)
    assert {:accepted, _} = Sigma.Agent.prompt(agent, "initial")
    assert_receive {:turn_error, error}, 5_000
    assert inspect(error) =~ "unsupported"
    assert_receive {:agent_end, _}, 5_000
    refute_receive {:backplane_provider_waiting, _, _}
    assert Sigma.Agent.status(agent).phase == :failed
  end

  @tag :tmp_dir
  test "prompt hook context is applied once and preserves image content", %{tmp_dir: dir} do
    {:ok, agent} = start_blocking_agent(dir)
    Sigma.Agent.subscribe(agent)

    # Consume the payload before responding so the fixture cannot exit before Port.command/2.
    spec =
      hook_spec(
        :user_prompt_submit,
        ~S(sh -c 'dd bs=65536 count=1 of=/dev/null 2>/dev/null; echo "{\"hookSpecificOutput\":{\"additionalContext\":\"extra\"}}"')
      )

    :sys.replace_state(agent, &%{&1 | hook_specs: [spec]})
    image = %{type: :image, data: "iVBORw0KGgo=", mime_type: "image/png"}
    assert {:accepted, _} = Sigma.Agent.prompt(agent, [%{type: :text, text: "Describe"}, image])
    assert_receive {:backplane_provider_waiting, worker, content}, 5_000

    assert content == [
             %{type: :text, text: "Describe\n\n[Additional context from hook]\nextra"},
             image
           ]

    send(worker, {:release_backplane_provider, "done"})
    assert_receive {:agent_end, [%{content: ^content}, _]}, 5_000
  end

  @tag :tmp_dir
  test "stop hook continuation is canonical and cannot block recursively", %{tmp_dir: dir} do
    {:ok, agent} = start_blocking_agent(dir)
    Sigma.Agent.subscribe(agent)

    spec =
      hook_spec(
        :stop,
        "sh -c 'dd bs=65536 count=1 of=/dev/null 2>/dev/null; printf continue >&2; exit 2'"
      )

    :sys.replace_state(agent, &%{&1 | hook_specs: [spec]})
    assert {:accepted, _} = Sigma.Agent.prompt(agent, "initial")
    assert_receive {:backplane_provider_waiting, first, "initial"}, 5_000
    send(first, {:release_backplane_provider, "first"})
    assert_receive {:backplane_provider_waiting, second, reason}, 5_000
    assert reason =~ "continue"
    send(second, {:release_backplane_provider, "second"})
    assert_receive {:agent_end, [_, _, %{role: :user, content: ^reason}, _]}, 5_000
    refute_receive {:backplane_provider_waiting, _, _}
  end

  @tag :tmp_dir
  test "a second owner cannot borrow and later lose another agent's sidecar", %{tmp_dir: dir} do
    Process.flag(:trap_exit, true)
    {:ok, first} = start_blocking_agent(dir)
    assert {:error, :backplane_runtime_path_in_use} = start_blocking_agent(dir)
    Sigma.Agent.subscribe(first)
    assert {:accepted, _} = Sigma.Agent.prompt(first, "still running")
    assert_receive {:backplane_provider_waiting, worker, "still running"}, 5_000
    send(worker, {:release_backplane_provider, "done"})
    assert_receive {:agent_end, _}, 5_000
    GenServer.stop(first)
    assert {:ok, _second} = start_blocking_agent(dir)
  end

  @tag :tmp_dir
  test "explicitly injected stores stay alive when an agent stops", %{tmp_dir: dir} do
    {:ok, store} = start_supervised({Sigma.Agent.Backplane.Store, path: Path.join(dir, "shared")})
    {:ok, first} = start_blocking_agent(dir, backplane_store: store)
    {:ok, second} = start_blocking_agent(dir, backplane_store: store)
    GenServer.stop(first)
    assert Process.alive?(store)
    Sigma.Agent.subscribe(second)
    assert {:accepted, _} = Sigma.Agent.prompt(second, "still running")
    assert_receive {:backplane_provider_waiting, worker, "still running"}, 5_000
    send(worker, {:release_backplane_provider, "done"})
    assert_receive {:agent_end, _}, 5_000
  end

  @tag :tmp_dir
  test "invalid engine and unavailable store return explicit start errors", %{tmp_dir: dir} do
    Process.flag(:trap_exit, true)

    assert {:error, {:invalid_execution_engine, :invalid}} =
             Sigma.Agent.start_link(execution_engine: :invalid)

    assert {:error, :backplane_runtime_path_required} =
             Sigma.Agent.start_link(execution_engine: :backplane)

    assert {:error, :invalid_backplane_store} =
             start_blocking_agent(dir, backplane_store: :invalid)

    File.write!(Path.join(dir, "runtime"), "not a directory")
    assert {:error, {:backplane_store_unavailable, _}} = start_blocking_agent(dir)
  end

  defp start_blocking_agent(dir, opts \\ []) do
    Sigma.Agent.start_link(
      Keyword.merge(
        [
          execution_engine: :backplane,
          backplane_runtime_path: Path.join(dir, "runtime"),
          model: %{id: "mock-model", api: "mock-api", provider: "mock-provider"},
          provider: BlockingProvider,
          options: [test_pid: self()]
        ],
        opts
      )
    )
  end

  defp hook_spec(event, cmd) do
    %Sigma.Coding.Hooks.Spec{
      event: event,
      matcher: :any,
      handler: %Sigma.Coding.Hooks.Spec.Command{cmd: cmd, timeout_ms: 1_000},
      origin: {:user, "test"},
      dialect: :claude,
      trusted?: true
    }
  end
end
