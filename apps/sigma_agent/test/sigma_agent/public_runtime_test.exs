defmodule Sigma.Agent.PublicRuntimeTest do
  use ExUnit.Case, async: false

  alias Sigma.Agent.PublicRuntime
  alias Sigma.Protocol.{Codec, Envelope}

  test "runtime snapshot projection exposes bounded public state" do
    snapshot = %{
      provider_id: "anthropic",
      model_id: "claude-test",
      metrics: %{own_usage: %{input_tokens_total: 4, output_tokens_total: 2}}
    }

    projection =
      PublicRuntime.runtime_snapshot(
        %{status: :turn_running, pid: self()},
        %{
          phase: :streaming_provider,
          turn_id: "turn-1",
          current_request_id: "request-1",
          context_snapshot: %{
            active_leaf: "leaf-1",
            context_revision: 3,
            model: %{id: "claude-test"},
            source: :provider_usage,
            generated_at: "2026-09-09T10:00:00Z",
            stale: false
          },
          context_policy: %{
            check_phase: :before_provider_dispatch,
            overflow: :within_budget
          }
        },
        snapshot,
        42
      )

    assert projection["phase"] == "streaming_provider"
    assert projection["turnId"] == "turn-1"
    assert projection["model"] == %{"providerId" => "anthropic", "modelId" => "claude-test"}
    assert projection["metrics"]["own_usage"]["input_tokens_total"] == 4

    assert projection["metrics"]["activeRequest"] == %{
             "requestId" => "request-1",
             "status" => "running"
           }

    assert projection["contextSnapshot"]["active_leaf"] == "leaf-1"
    assert projection["contextSnapshot"]["context_revision"] == 3
    assert projection["contextPolicy"]["check_phase"] == "before_provider_dispatch"
    assert projection["contextPolicy"]["overflow"] == "within_budget"
    assert projection["watermark"] == 42
    refute inspect(projection) =~ "#PID"
  end

  test "runtime snapshot watermarks are monotonic for successive queries" do
    args = [%{status: :active}, %{phase: :idle, turn_id: nil}, %{}, nil]
    first = apply(PublicRuntime, :runtime_snapshot, args)
    second = apply(PublicRuntime, :runtime_snapshot, args)
    assert second["watermark"] >= first["watermark"]
  end

  defmodule ScriptedProvider do
    @behaviour Sigma.Ai.Provider

    @impl true
    def stream(params) do
      response = Keyword.get(params.options, :response, "headless response")
      message = message(response, :stop)

      [
        {:start, %{message | content: []}},
        {:text_delta, 0, response, message},
        {:done, :stop, message}
      ]
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

  test "drives a complete turn through the direct protocol API for two ordered subscribers",
       context do
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

  test "subscription attach returns an atomic cursor-zero turn snapshot before updates",
       context do
    session_id = "atomic-attach"
    runtime_context = create_session!(context, session_id, provider: ScriptedProvider)
    writer = Sigma.Agent.Runtime.lookup(context.repo, session_id, :writer)

    assert {:ok, _entry_id} =
             Sigma.Session.Writer.append(
               writer,
               {:metrics, :request_finished,
                %{
                  request_id: "persisted-request",
                  session_id: session_id,
                  revision: 1,
                  status: :completed,
                  input_tokens_total: 12,
                  output_tokens_total: 3,
                  elapsed_ms: 100
                }}
             )

    assert {:ok, resume} = Envelope.command("session.resume", session_id)

    assert {:ok, %{payload: %{"metrics" => resumed_metrics}}} =
             PublicRuntime.execute(resume, runtime_context)

    assert resumed_metrics["schemaVersion"] == 1
    assert resumed_metrics["ownUsage"]["total_tokens"] == 15

    assert {:ok, command} =
             Envelope.command("subscription.attach", session_id, %{
               "requiredCapabilities" => ["metrics.v1"]
             })

    assert {:ok,
            %{
              type: "session.snapshot",
              payload: %{
                "subscriptionId" => subscription_id,
                "cursor" => 0,
                "watermark" => 0,
                "protocolVersion" => 1,
                "enabledCapabilities" => ["metrics.v1"],
                "turn" => %{"phase" => "idle", "turnId" => nil},
                "metrics" => attached_metrics
              }
            }} = PublicRuntime.execute(command, runtime_context)

    assert attached_metrics == resumed_metrics

    assert {:ok, prompt} = Envelope.command("prompt.submit", session_id, %{"content" => "go"})
    assert {:ok, _admission} = PublicRuntime.execute(prompt, runtime_context)

    first = receive_type(subscription_id, "prompt.admitted")
    assert first.payload["cursor"] == 1

    metrics_event = receive_type(subscription_id, "metrics.changed")
    assert metrics_event.payload["schemaVersion"] == 1

    assert metrics_event.payload["fact"] in [
             "turn_started",
             "request_started",
             "request_finished"
           ]

    assert Enum.all?(Map.keys(metrics_event.payload["data"]), &is_binary/1)
    assert {:ok, encoded} = Codec.encode(metrics_event)
    assert {:ok, ^metrics_event} = Codec.decode(encoded)
  end

  test "dispatches negotiated Skill commands through the supplied callbacks", context do
    session_id = "skill-command"

    for {type, callback} <- [
          {"skill.invoke", :skill_invoke},
          {"skill.invocation.status", :skill_invocation_status},
          {"skill.invocation.cancel", :skill_invocation_cancel}
        ] do
      assert {:ok, command} =
               Envelope.command(type, session_id, %{
                 "requiredCapabilities" => ["skills.v1"],
                 "invocationId" => "invocation-1"
               })

      context =
        Map.merge(context, %{
          callback => fn payload ->
            send(self(), {callback, payload})
            Envelope.event("skill.invocation.updated", session_id, %{"state" => "queued"})
          end
        })

      assert {:ok, %{type: "skill.invocation.updated"}} = PublicRuntime.execute(command, context)
      assert_receive {^callback, %{"invocationId" => "invocation-1"}}
    end
  end

  test "does not dispatch Skill commands without skills.v1 negotiation", context do
    assert {:ok, command} = Envelope.command("skill.invocation.status", "legacy-client", %{})

    context =
      Map.put(context, :skill_invocation_status, fn _payload ->
        flunk("legacy command reached the Skill callback")
      end)

    assert {:error, %{type: "session.error", error: %{code: "required_capability_missing"}}} =
             PublicRuntime.execute(command, context)
  end

  test "active attach overlays the durable in-flight request at cursor zero", context do
    session_id = "active-request-attach"

    runtime_context =
      create_session!(context, session_id,
        provider: BlockingProvider,
        options: [test_pid: self()]
      )

    assert {:ok, prompt} = Envelope.command("prompt.submit", session_id, %{"content" => "wait"})
    assert {:ok, _admission} = PublicRuntime.execute(prompt, runtime_context)
    assert_receive {:headless_provider_waiting, provider}, 1_000

    assert {:ok, attach} = Envelope.command("subscription.attach", session_id)

    assert {:ok,
            %{
              payload: %{
                "cursor" => 0,
                "turn" => %{"currentRequestId" => request_id},
                "metrics" => durable_metrics,
                "runtimeSnapshot" => %{
                  "watermark" => 0,
                  "metrics" => %{
                    "activeRequest" => %{"requestId" => request_id, "status" => "running"}
                  }
                }
              }
            }} = PublicRuntime.execute(attach, runtime_context)

    assert is_binary(request_id)
    refute Map.has_key?(durable_metrics, "activeRequest")

    assert {:ok, status} =
             Envelope.command("session.status", session_id, %{
               "subscriptionId" => attach.payload["subscriptionId"]
             })

    assert {:ok,
            %{
              payload: %{
                "metrics" => status_metrics,
                "runtimeSnapshot" => %{
                  "metrics" => %{
                    "activeRequest" => %{"requestId" => ^request_id, "status" => "running"}
                  }
                }
              }
            }} = PublicRuntime.execute(status, runtime_context)

    refute Map.has_key?(status_metrics, "activeRequest")

    send(provider, :release_headless_provider)
  end

  test "subscriber disconnect does not stop a running turn and reconnect receives the terminal event",
       context do
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

    assert {:ok, prompt} =
             Envelope.command("prompt.submit", session_id, %{"content" => "use tool"})

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

    assert {:ok, prompt} =
             Envelope.command("prompt.submit", session_id, %{"content" => "use tool"})

    assert {:ok, _admission} = PublicRuntime.execute(prompt, runtime_context)

    event = receive_type(subscription_id, "session.error")
    assert event.error.code == "approval_required"
    refute_receive :safe_tool_executed, 50
  end

  test "a slow subscriber drops intermediate events without blocking the Agent terminal",
       context do
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

  test "subscription cursor preserves a unique snapshot boundary across resync", context do
    session_id = "cursor-resync"
    runtime_context = create_session!(context, session_id, provider: ScriptedProvider)

    subscription_context =
      runtime_context
      |> Map.put(:subscriber, self())
      |> Map.put(:max_subscriber_queue, 0)

    subscription_id = attach!(session_id, subscription_context)
    assert {:ok, prompt} = Envelope.command("prompt.submit", session_id, %{"content" => "gap"})
    assert {:ok, _admission} = PublicRuntime.execute(prompt, runtime_context)

    events = collect_until(subscription_id, "turn.completed", [])
    assert Enum.any?(events, &(&1.type == "session.error" and &1.error.code == "resync_required"))

    cursors =
      events
      |> Enum.map(& &1.payload["cursor"])
      |> Enum.filter(&is_integer/1)

    assert cursors == Enum.to_list(1..length(cursors))
    assert cursors == Enum.uniq(cursors)

    [terminal] = Enum.filter(events, &(&1.type == "turn.completed"))
    assert terminal.payload["cursor"] == List.last(cursors)

    assert {:ok, status} =
             Envelope.command("session.status", session_id, %{
               "subscriptionId" => subscription_id,
               "requiredCapabilities" => ["subscription.resync.v1"]
             })

    assert {:ok,
            %{
              payload: %{
                "cursor" => watermark,
                "watermark" => watermark,
                "metrics" => %{
                  "requestCount" => 1,
                  "ownUsage" => %{"total_tokens" => 2}
                },
                "runtimeSnapshot" => %{"watermark" => watermark}
              }
            }} = PublicRuntime.execute(status, subscription_context)

    assert watermark == terminal.payload["cursor"]
  end

  test "resync snapshot restores an active request and converges after terminal", context do
    session_id = "active-request-resync"

    runtime_context =
      create_session!(context, session_id,
        provider: BlockingProvider,
        options: [test_pid: self()]
      )

    subscription_context = Map.put(runtime_context, :max_subscriber_queue, 0)
    subscription_id = attach!(session_id, subscription_context)
    assert {:ok, prompt} = Envelope.command("prompt.submit", session_id, %{"content" => "wait"})
    assert {:ok, _admission} = PublicRuntime.execute(prompt, runtime_context)
    assert_receive {:headless_provider_waiting, provider}, 1_000

    marker = receive_type(subscription_id, "session.error")
    assert marker.error.code == "resync_required"

    assert {:ok, status} =
             Envelope.command("session.status", session_id, %{
               "subscriptionId" => subscription_id
             })

    assert {:ok,
            %{
              payload: %{
                "cursor" => running_watermark,
                "metrics" => durable_metrics,
                "runtimeSnapshot" => %{
                  "watermark" => running_watermark,
                  "metrics" => %{
                    "activeRequest" => %{
                      "requestId" => request_id,
                      "status" => "running"
                    }
                  }
                }
              }
            }} = PublicRuntime.execute(status, subscription_context)

    refute Map.has_key?(durable_metrics, "activeRequest")
    assert is_binary(request_id)
    send(provider, :release_headless_provider)
    assert :ok = await_phase(context.repo, session_id, :completed, 5_000)

    assert {:ok, terminal_status} =
             Envelope.command("session.status", session_id, %{
               "subscriptionId" => subscription_id
             })

    assert {:ok,
            %{
              payload: %{
                "cursor" => terminal_watermark,
                "metrics" => %{
                  "requestCount" => 1,
                  "ownUsage" => %{"total_tokens" => 2}
                },
                "runtimeSnapshot" => %{"metrics" => terminal_metrics}
              }
            }} = PublicRuntime.execute(terminal_status, subscription_context)

    assert terminal_watermark >= running_watermark
    refute Map.has_key?(terminal_metrics, "activeRequest")
  end

  test "subscription requests resync before a discontinuous metrics revision", context do
    session_id = "revision-resync"
    runtime_context = create_session!(context, session_id, provider: ScriptedProvider)
    subscription_id = attach!(session_id, runtime_context)

    assert [{relay, _sink}] =
             Registry.lookup(Sigma.Agent.ProtocolSubscriptionRegistry, subscription_id)

    fact = %{
      request_id: "request-1",
      session_id: session_id,
      status: :completed,
      input_tokens_total: 1,
      output_tokens_total: 1
    }

    send(relay, {:metrics, :request_finished, Map.put(fact, :revision, 1)})
    first = receive_type(subscription_id, "metrics.changed")
    assert first.payload["cursor"] == 1

    send(relay, {:metrics, :request_usage, Map.put(fact, :revision, 3)})
    marker = receive_type(subscription_id, "session.error")
    assert marker.error.code == "resync_required"
    assert marker.payload["reason"] == "revision_gap"
    assert marker.payload["expectedRevision"] == 2
    assert marker.payload["actualRevision"] == 3
    assert marker.payload["cursor"] == 2

    update = receive_type(subscription_id, "metrics.changed")
    assert update.payload["cursor"] == 3
    assert update.payload["data"]["revision"] == 3

    assert {:ok, status} =
             Envelope.command("session.status", session_id, %{
               "subscriptionId" => subscription_id,
               "requiredCapabilities" => ["subscription.resync.v1"]
             })

    assert {:ok,
            %{
              type: "session.snapshot",
              payload: %{
                "subscriptionId" => ^subscription_id,
                "cursor" => 3,
                "watermark" => 3,
                "runtimeSnapshot" => %{"watermark" => 3}
              }
            }} = PublicRuntime.execute(status, runtime_context)

    next =
      {:metrics, :request_finished,
       fact
       |> Map.put(:request_id, "request-2")
       |> Map.put(:revision, 1)}

    send(relay, next)
    assert receive_type(subscription_id, "metrics.changed").payload["cursor"] == 4
  end

  test "subscription suppresses an identical metrics delivery", context do
    session_id = "duplicate-metrics"
    runtime_context = create_session!(context, session_id, provider: ScriptedProvider)
    subscription_id = attach!(session_id, runtime_context)

    assert [{relay, _sink}] =
             Registry.lookup(Sigma.Agent.ProtocolSubscriptionRegistry, subscription_id)

    event =
      {:metrics, :request_finished,
       %{
         request_id: "request-1",
         session_id: session_id,
         revision: 1,
         status: :completed,
         input_tokens_total: 1,
         output_tokens_total: 1
       }}

    send(relay, event)
    send(relay, event)

    delivered = receive_type(subscription_id, "metrics.changed")
    assert delivered.payload["cursor"] == 1
    refute_receive {:sigma_protocol, ^subscription_id, %{type: "metrics.changed"}}, 100
  end

  test "subscription attach rejects unsupported required capabilities", context do
    session_id = "unsupported-capability"
    runtime_context = create_session!(context, session_id, provider: ScriptedProvider)

    assert {:ok, command} =
             Envelope.command("subscription.attach", session_id, %{
               "requiredCapabilities" => ["future.metrics.v9"]
             })

    assert {:error,
            %{
              error: %{
                code: "unsupported_capabilities",
                details: %{
                  "missing" => ["future.metrics.v9"],
                  "supported" => supported
                }
              }
            }} = PublicRuntime.execute(command, runtime_context)

    assert "metrics.v1" in supported
  end

  test "legacy subscription does not receive capability-gated metrics events", context do
    session_id = "legacy-closed-events"
    runtime_context = create_session!(context, session_id, provider: ScriptedProvider)

    assert {:ok, command} = Envelope.command("subscription.attach", session_id)

    assert {:ok,
            %{
              payload: %{
                "subscriptionId" => subscription_id,
                "enabledCapabilities" => []
              }
            }} = PublicRuntime.execute(command, runtime_context)

    assert [{relay, _sink}] =
             Registry.lookup(Sigma.Agent.ProtocolSubscriptionRegistry, subscription_id)

    send(relay, {:metrics, :request_finished, %{request_id: "request-1", revision: 1}})
    send(relay, {:turn_completed, "turn-1"})

    assert_receive {:sigma_protocol, ^subscription_id,
                    %{type: "turn.completed", payload: %{"cursor" => 1}}}

    refute_receive {:sigma_protocol, ^subscription_id, %{type: "metrics.changed"}}, 100
  end

  test "subscription capability negotiation is deterministic", context do
    session_id = "deduplicated-capabilities"
    runtime_context = create_session!(context, session_id, provider: ScriptedProvider)

    assert {:ok, command} =
             Envelope.command("subscription.attach", session_id, %{
               "requiredCapabilities" => ["metrics.v1", "metrics.v1"]
             })

    assert {:ok, %{payload: %{"enabledCapabilities" => ["metrics.v1"]}}} =
             PublicRuntime.execute(command, runtime_context)
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

  test "protocol fork reuses the command id for duplicate submissions", context do
    runtime_context = create_session!(context, "protocol-source", [])

    assert {:ok, command} =
             Envelope.command(
               "session.fork",
               "protocol-source",
               %{
                 "targetSessionId" => "protocol-fork",
                 "expectedSourceRevision" => 1,
                 "expectedSourceLeaf" => nil
               },
               id: "operation-fork-1"
             )

    assert {:ok, %{type: "session.snapshot"}} = PublicRuntime.execute(command, runtime_context)
    assert {:ok, %{type: "session.snapshot"}} = PublicRuntime.execute(command, runtime_context)
  end

  test "protocol retry executes from the selected turn checkpoint", context do
    session_id = "protocol-retry"
    runtime_context = create_session!(context, session_id, provider: ScriptedProvider)

    assert {:ok, first_command} =
             Envelope.command("prompt.submit", session_id, %{"content" => "first"})

    assert {:ok, %{payload: first_admission}} =
             PublicRuntime.execute(first_command, runtime_context)

    assert :ok = await_phase(context.repo, session_id, :completed, 5_000)

    assert {:ok, second_command} =
             Envelope.command("prompt.submit", session_id, %{"content" => "second"})

    assert {:ok, _event} = PublicRuntime.execute(second_command, runtime_context)
    assert :ok = await_phase(context.repo, session_id, :completed, 5_000)

    path = Path.join(context.sessions_dir, "#{session_id}.jsonl")
    assert {:ok, before} = Sigma.Session.Log.snapshot(path)

    assert {:ok, retry_command} =
             Envelope.command(
               "session.retry",
               session_id,
               %{
                 "messageId" => first_admission["messageId"],
                 "expectedSourceRevision" => length(before.branch_entry_ids) + 1,
                 "expectedSourceLeaf" => before.active_leaf_id
               },
               id: "retry-command-1"
             )

    assert {:ok, %{payload: %{"retry" => retry}}} =
             PublicRuntime.execute(retry_command, runtime_context)

    assert retry["status"] == "accepted"
    assert retry["retryOfTurnId"] == first_admission["turnId"]
    assert retry["turnId"] != first_admission["turnId"]

    assert {:ok, %{payload: %{"retry" => duplicate}}} =
             PublicRuntime.execute(retry_command, runtime_context)

    assert duplicate == retry
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
    assert {:ok, command} =
             Envelope.command("subscription.attach", session_id, %{
               "requiredCapabilities" => ["metrics.v1"]
             })

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

        if event.type == terminal_type,
          do: events,
          else: collect_until(subscription_id, terminal_type, events)
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
