defmodule Sigma.Agent.BackplaneChildIOTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.{Conversation, Error}
  alias Sigma.Agent.Backplane.{ChildIO, ChildStore, Provider, Store}
  alias Sigma.Agent.Message
  alias Sigma.Session.{Log, Storage.JsonlFile}

  test "native collaboration results retain complete structured values in model history" do
    for {name, result} <- [
          {"spawn_agent", %{task_name: "/root/a", run_id: "run-a"}},
          {"list_agents", %{agents: [%{task_name: "/root/a", status: :running}]}},
          {"wait_agent", %{timed_out: true, message: "No updates"}}
        ] do
      [message] =
        Provider.normalize_messages([
          %{role: :tool, name: name, tool_call_id: "call-a", result: result}
        ])

      assert %Message{role: :tool_result, tool_name: ^name, is_error: false} = message
      assert [%{type: :text, text: json}] = message.content
      expected = result |> Jason.encode!() |> Jason.decode!()
      assert Jason.decode!(json) == expected
      assert message.metadata.structured_result == expected
    end
  end

  test "nonserializable native tool results cannot expose process handles" do
    [message] =
      Provider.normalize_messages([
        %{role: :tool, name: "spawn_agent", tool_call_id: "call-a", result: %{owner: self()}}
      ])

    assert message.is_error
    assert message.content == [%{type: :text, text: "Error: malformed tool result"}]
    assert message.metadata == %{}
  end

  defmodule ChildProvider do
    @behaviour Sigma.Ai.Provider

    @impl true
    def stream(request) do
      send(request.options[:test_pid], {:child_provider, request})

      message = %{
        role: :assistant,
        content: [%{type: :text, text: "child answer"}],
        usage: %{input: 7, output: 3},
        stop_reason: :stop,
        timestamp: System.system_time(:millisecond)
      }

      [{:start, %{message | content: []}}, {:done, :stop, message}]
    end
  end

  defmodule ToolProvider do
    @behaviour Sigma.Ai.Provider

    @impl true
    def stream(request) do
      case List.last(request.context.messages) do
        %{role: :tool_result} ->
          ChildProvider.stream(request)

        _ ->
          send(request.options[:test_pid], {:child_tool_provider, request})

          message = %{
            role: :assistant,
            content: [
              %{
                type: :tool_call,
                id: request.options[:tool_call_id] || "child-call",
                name: request.options[:tool_name] || "child_echo",
                arguments: request.options[:tool_arguments] || %{"value" => "child tool"}
              }
            ],
            usage: %{input: 7, output: 3},
            stop_reason: :tool_use,
            timestamp: System.system_time(:millisecond)
          }

          [{:start, %{message | content: []}}, {:done, :tool_use, message}]
      end
    end
  end

  defmodule EchoTool do
    @behaviour Sigma.Coding.Tool
    def name, do: "child_echo"
    def description, do: "Echo checked arguments"
    def schema, do: %{"type" => "object", "properties" => %{"value" => %{"type" => "string"}}}
    def metadata, do: %{effect: :read, concurrency: :shared}

    def execute(_id, args, opts) do
      send(opts[:test_pid], {:child_tool, args, opts})
      {:ok, %{content: [%{type: :text, text: args["value"] || "ok"}]}}
    end
  end

  defmodule FailingStorage do
    @behaviour Sigma.Session.Storage
    defdelegate read(path), to: JsonlFile
    defdelegate read_with_diagnostics(path), to: JsonlFile
    def append(_path, _entry), do: {:error, :enospc}
  end

  setup do
    path = Path.join(System.tmp_dir!(), "sigma-child-io-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)

    identity = %{
      agent_id: "generation:child",
      child_session_id: "child-session",
      root_session_id: "root-session",
      run_id: "child-run-1",
      public_run_id: "generation:child-run-1",
      incarnation: 1,
      observer_incarnation: 1,
      agent_path: "/root/child",
      parent_agent_id: "generation:root"
    }

    config = %{
      model: %{id: "mock", provider: "mock", api: "mock"},
      provider: ChildProvider,
      provider_options: [test_pid: self(), api_key: "secret-child-token"],
      cwd: path,
      tools: [EchoTool],
      dispatcher_opts: [test_pid: self()],
      hook_specs: [],
      policy: nil
    }

    opts = [
      config: config,
      identity: identity,
      transcript_path: Path.join(path, "child.jsonl"),
      backplane_store_path: Path.join(path, "child.runtime")
    ]

    %{
      opts: opts,
      identity: identity,
      config: config,
      path: path,
      authority: %{
        caller: "root",
        run_id: "root-run",
        grants: [EchoTool.name()],
        tool_revision: 1
      }
    }
  end

  test "provider handshake finishes through child IO without root Engine participation", ctx do
    io = start_supervised!({ChildIO, ctx.opts})
    assert {:ok, prepared} = ChildIO.prepare(io, ctx.identity, ctx.authority, [])
    options = prepared.options

    request = %{
      run_id: ctx.identity.run_id,
      attempt_id: "independent-attempt",
      messages: [Message.user("question", "hello")],
      tools: options[:tools],
      catalog_revision: 1
    }

    task =
      Task.async(fn -> Provider.stream(request, options[:provider_context]) |> Enum.to_list() end)

    assert [%{type: :response_started}, %{type: :usage_updated}, %{type: :response_completed}] =
             Task.await(task, 5_000)

    assert_receive {:child_provider, request}
    assert request.session_id == ctx.identity.child_session_id
    assert request.log_session_id == ctx.identity.child_session_id
    assert request.turn_id == ctx.identity.public_run_id
    refute_receive {:backplane_provider_boundary, _, _, _}
    assert :ok = ChildIO.validate(io, prepared.key)
    assert {:ok, entries} = JsonlFile.read(ctx.opts[:transcript_path])
    facts = Enum.filter(entries, &(&1["type"] == "metrics"))
    assert Enum.map(facts, & &1["fact"]) == ["request_started", "request_finished"]
    assert Enum.all?(facts, &(&1["data"]["session_id"] == "child-session"))
    assert List.last(facts)["data"]["input_tokens_total"] == 7
    refute File.read!(ctx.opts[:transcript_path]) =~ "secret-child-token"
  end

  test "committed child messages are deduplicated and followups retain history with fresh tools",
       ctx do
    io = start_supervised!({ChildIO, ctx.opts})
    assert {:ok, first} = ChildIO.prepare(io, ctx.identity, ctx.authority, [])
    conversation = start_supervised!({Conversation, first.options ++ [subscriber: self()]})
    assert {:ok, _admission} = Conversation.prompt(conversation, "first prompt")
    assert_terminal(ctx.identity.run_id)
    assert {:ok, snapshot} = Log.snapshot(ctx.opts[:transcript_path])

    assert [%Message{role: :user, content: "first prompt"}, %Message{role: :assistant}] =
             snapshot.messages

    assert :ok = ChildIO.project(io, first.key, snapshot.messages)
    assert {:ok, again} = Log.snapshot(ctx.opts[:transcript_path])
    assert length(again.messages) == 2

    descriptor = first.catalog.registry.tools[EchoTool.name()]

    assert {:ok, _} =
             descriptor.backend_context.execute.(%{
               tool_call_id: "tool-1",
               tool_name: EchoTool.name(),
               arguments: %{}
             })

    assert_receive {:child_tool, %{}, old_opts}
    old_table = old_opts[:tool_state]
    :ets.insert(old_table, {:one_shot_root_grant, true})

    next_identity = %{
      ctx.identity
      | run_id: "child-run-2",
        public_run_id: "generation:child-run-2"
    }

    assert {:ok, second} = ChildIO.prepare(io, next_identity, ctx.authority, [])
    assert length(second.options[:messages]) == 2
    assert second.catalog.authority.run_id == "child-run-2"
    assert {:error, %Error{class: :resource_conflict}} = ChildIO.validate(io, first.key)
    assert :undefined == :ets.info(old_table)

    assert {:ok, _} =
             second.catalog.registry.tools[EchoTool.name()].backend_context.execute.(%{
               tool_call_id: "tool-2",
               tool_name: EchoTool.name(),
               arguments: %{}
             })

    assert_receive {:child_tool, %{}, fresh_opts}
    refute fresh_opts[:tool_state] == old_table
    assert :ets.lookup(fresh_opts[:tool_state], :one_shot_root_grant) == []
    assert fresh_opts[:turn_id] == next_identity.public_run_id
    assert fresh_opts[:session_id] == "child-session"

    followup =
      start_supervised!(
        Supervisor.child_spec({Conversation, second.options ++ [subscriber: self()]},
          id: :followup
        )
      )

    assert {:ok, _} = Conversation.prompt(followup, "followup prompt")
    assert_terminal(next_identity.run_id)
    assert {:ok, followup_snapshot} = Log.snapshot(ctx.opts[:transcript_path])

    assert Enum.map(followup_snapshot.messages, & &1.role) == [
             :user,
             :assistant,
             :user,
             :assistant
           ]

    assert Enum.at(followup_snapshot.messages, 2).content == "followup prompt"
    assert {:ok, metadata} = ChildIO.metadata(io)

    assert Map.keys(metadata) |> Enum.sort() == [
             :backplane_store_path,
             :identity,
             :transcript_path
           ]
  end

  test "child Conversation tools retain the issuing child request ID after provider completion",
       ctx do
    config = %{
      ctx.config
      | provider: ToolProvider,
        dispatcher_opts: [test_pid: self(), request_id: "parent-request"]
    }

    io = start_supervised!({ChildIO, Keyword.put(ctx.opts, :config, config)})
    assert {:ok, prepared} = ChildIO.prepare(io, ctx.identity, ctx.authority, [])
    conversation = start_supervised!({Conversation, prepared.options ++ [subscriber: self()]})
    assert {:ok, _} = Conversation.prompt(conversation, "use the child tool")
    assert_terminal(ctx.identity.run_id)

    assert_receive {:child_tool_provider, issuing_request}
    assert_receive {:child_tool, %{"value" => "child tool"}, tool_opts}
    assert_receive {:child_provider, final_request}
    assert tool_opts[:request_id] == issuing_request.request_id
    refute issuing_request.request_id == "parent-request"
    refute final_request.request_id == issuing_request.request_id

    assert {:ok, entries} = JsonlFile.read(ctx.opts[:transcript_path])
    assert %{"data" => fact} = Enum.find(entries, &(&1["fact"] == "tool_finished"))
    assert fact["request_id"] == issuing_request.request_id
    assert fact["turn_id"] == ctx.identity.public_run_id

    assert Enum.find_index(entries, &(&1["fact"] == "request_finished")) <
             Enum.find_index(entries, &(&1["fact"] == "tool_finished"))
  end

  test "nested catalog attenuates parent authority using cached contracts without calling manager",
       ctx do
    io = start_supervised!({ChildIO, ctx.opts})

    contracts =
      Enum.map(["spawn_agent", "list_agents", "send_message"], fn name ->
        %{
          name: name,
          schema: %{"type" => "object", "properties" => %{}},
          backend: Backplane.AgentRuntime.Codex.Backend,
          backend_context: %{runtime: self(), family: :collaboration, profile: :v2},
          safety: %{read_only: true, retry_safe: false, parallel_safe: false}
        }
      end)

    authority = %{ctx.authority | grants: [EchoTool.name(), "spawn_agent", "list_agents"]}
    assert {:ok, prepared} = ChildIO.prepare(io, ctx.identity, authority, contracts)
    names = Enum.map(prepared.options[:tools], & &1.name) |> Enum.sort()
    assert names == [EchoTool.name(), "list_agents", "spawn_agent"] |> Enum.sort()
    assert Map.keys(prepared.options[:registry].tools) |> Enum.sort() == names
    assert prepared.options[:authority].grants |> Enum.sort() == names
    assert prepared.options[:authority].run_id == ctx.identity.run_id
    refute_receive {:"$gen_call", _, _}
  end

  test "child questions retain exact tool identity and approved arguments through answer projection",
       ctx do
    parent = self()
    policy = start_supervised!({Sigma.Coding.PermissionPolicy, default: :ask})
    tool = Sigma.Coding.Tools.AskUserQuestion
    arguments = %{"question" => "Original question?", "allow_freeform" => false}
    patch = %{"question" => "  Approved question?  ", "options" => ["Proceed", "Wait"]}
    effective_arguments = Map.merge(arguments, patch)

    config = %{
      ctx.config
      | provider: ToolProvider,
        provider_options: [
          test_pid: parent,
          tool_call_id: "child-question-call",
          tool_name: tool.name(),
          tool_arguments: arguments
        ],
        tools: [tool],
        policy: policy
    }

    permission = fn identity, call ->
      send(parent, {:child_question_approval, identity, call})
      {:allow, patch}
    end

    question = fn identity, request, opts ->
      send(parent, {:child_question, self(), identity, request, opts})

      receive do
        {:answer_child, answer} -> {:ok, answer}
      end
    end

    io =
      start_supervised!(
        {ChildIO,
         Keyword.merge(ctx.opts,
           config: config,
           permission_request_fn: permission,
           ask_user_question_fn: question
         )}
      )

    authority = %{ctx.authority | grants: [tool.name()]}
    assert {:ok, prepared} = ChildIO.prepare(io, ctx.identity, authority, [])
    conversation = start_supervised!({Conversation, prepared.options ++ [subscriber: self()]})
    assert {:ok, _} = Conversation.prompt(conversation, "Ask the child question")

    assert_receive {:child_question_approval, identity, call}, 1_000
    assert identity == ctx.identity
    assert call.id == "child-question-call"
    assert call.arguments == arguments

    assert_receive {:child_question, worker, identity, request, tool_opts}, 1_000
    send(worker, {:answer_child, "Proceed"})
    assert identity == ctx.identity
    assert %{tool_call_id: "child-question-call", arguments: ^effective_arguments} = request
    assert request.question == "Approved question?"
    assert tool_opts[:session_id] == ctx.identity.child_session_id
    assert_terminal(ctx.identity.run_id)

    assert_receive {:child_provider, final_request}
    result = Enum.find(final_request.context.messages, &(&1.role == :tool_result))
    assert result.tool_call_id == "child-question-call"
    assert Enum.any?(result.content, &(&1.text == "User answer: Proceed"))

    assert {:ok, snapshot} = Log.snapshot(ctx.opts[:transcript_path])
    persisted_result = Enum.find(snapshot.messages, &(&1.role == :tool_result))
    assert persisted_result.tool_call_id == "child-question-call"
    assert Enum.any?(persisted_result.content, &(&1.text == "User answer: Proceed"))
  end

  test "JSONL failure reports the retained sidecar commit rather than claiming rollback", ctx do
    io = start_supervised!({ChildIO, ctx.opts ++ [storage_mod: FailingStorage]})
    assert {:ok, prepared} = ChildIO.prepare(io, ctx.identity, ctx.authority, [])
    message = Message.user("committed-user", "preserve evidence")

    stage = %{
      run: %{
        run_id: ctx.identity.run_id,
        incarnation: 1,
        expected_revision: 1,
        context: %{conversation: %{messages: [message]}}
      },
      revision: 1,
      transition: %{},
      effects: [],
      outbox: [],
      incarnation: 1
    }

    assert {:error, %Error{class: :execution_failure, details: details}} =
             ChildStore.acknowledge_commit(prepared.options[:context], stage, %{})

    assert details.runtime_committed
    assert details.revision == 1
    assert {:ok, store} = ChildIO.store(io)

    assert {:ok, %{revision: 1, run: %{context: %{conversation: %{messages: [^message]}}}}} =
             Store.load(store, ctx.identity.run_id)

    refute File.exists?(ctx.opts[:transcript_path])
  end

  test "interactive permission routing gets child identity and checked args; inherited root resolver is removed",
       ctx do
    parent = self()
    policy = start_supervised!({Sigma.Coding.PermissionPolicy, default: :ask})

    inherited = fn _call ->
      send(parent, :root_resolver_called)
      :allow
    end

    config = %{
      ctx.config
      | policy: policy,
        dispatcher_opts: [test_pid: parent, permission_request_fn: inherited]
    }

    route = fn identity, call ->
      send(parent, {:child_approval, identity, call})
      {:allow, %{"value" => "approved child"}}
    end

    io =
      start_supervised!(
        {ChildIO, Keyword.merge(ctx.opts, config: config, permission_request_fn: route)}
      )

    assert {:ok, prepared} = ChildIO.prepare(io, ctx.identity, ctx.authority, [])

    assert {:ok, _} =
             prepared.catalog.registry.tools[EchoTool.name()].backend_context.execute.(%{
               tool_call_id: "approval",
               tool_name: EchoTool.name(),
               arguments: %{"value" => "checked"}
             })

    assert_receive {:child_approval, identity, %{arguments: %{"value" => "checked"}}}
    assert identity.agent_id == ctx.identity.agent_id
    assert_receive {:child_tool, %{"value" => "approved child"}, _}
    refute_receive :root_resolver_called
  end

  test "headless permission asks remain observed failures without executing the tool", ctx do
    policy = start_supervised!({Sigma.Coding.PermissionPolicy, default: :ask})
    config = %{ctx.config | policy: policy}
    io = start_supervised!({ChildIO, Keyword.put(ctx.opts, :config, config)})
    assert {:ok, prepared} = ChildIO.prepare(io, ctx.identity, ctx.authority, [])

    assert {:ok, %{is_error: true, content: [%{text: text}]}} =
             prepared.catalog.registry.tools[EchoTool.name()].backend.execute(%{
               tool_call_id: "approval",
               tool_name: EchoTool.name(),
               arguments: %{},
               backend_context: prepared.catalog.registry.tools[EchoTool.name()].backend_context
             })

    assert text =~ "Approval required"
    refute_receive {:child_tool, _, _}
  end

  test "fresh child runs refresh supplied config and clear explicit nil resolvers", ctx do
    parent = self()
    tool = Sigma.Coding.Tools.AskUserQuestion
    policy = start_supervised!({Sigma.Coding.PermissionPolicy, default: :ask})
    config = %{ctx.config | tools: [tool], policy: policy}

    permission = fn identity, _call ->
      send(parent, {:retained_permission, identity.run_id})
      :allow
    end

    question = fn identity, _request, _opts ->
      send(parent, {:retained_question, identity.run_id})
      {:ok, "retained answer"}
    end

    io =
      start_supervised!(
        {ChildIO,
         Keyword.merge(ctx.opts,
           config: config,
           permission_request_fn: permission,
           ask_user_question_fn: question
         )}
      )

    authority = %{ctx.authority | grants: [tool.name(), EchoTool.name()]}
    assert {:ok, _} = ChildIO.prepare(io, ctx.identity, authority, [])
    second_identity = %{ctx.identity | run_id: "child-run-2"}
    assert {:ok, retained} = ChildIO.prepare(io, second_identity, authority, [])

    assert {:ok, _} =
             retained.catalog.registry.tools[tool.name()].backend_context.execute.(%{
               tool_call_id: "retained-question",
               tool_name: tool.name(),
               arguments: %{"question" => "Retained?"}
             })

    assert_receive {:retained_permission, "child-run-2"}
    assert_receive {:retained_question, "child-run-2"}

    :ok = Sigma.Coding.PermissionPolicy.allow_tool(policy, tool.name())

    refreshed_config = %{
      config
      | tools: [tool, EchoTool],
        model: %{ctx.config.model | id: "fresh"}
    }

    third_identity = %{ctx.identity | run_id: "child-run-3"}

    assert {:ok, refreshed} =
             ChildIO.prepare(io, third_identity, authority, [],
               config: refreshed_config,
               permission_request_fn: nil,
               ask_user_question_fn: nil
             )

    assert refreshed.options[:provider_context].host.model.id == "fresh"
    assert Map.has_key?(refreshed.catalog.registry.tools, EchoTool.name())

    assert {:ok, %{is_error: true}} =
             refreshed.catalog.registry.tools[EchoTool.name()].backend_context.execute.(%{
               tool_call_id: "headless-approval",
               tool_name: EchoTool.name(),
               arguments: %{}
             })

    assert {:error, error} =
             refreshed.catalog.registry.tools[tool.name()].backend_context.execute.(%{
               tool_call_id: "headless-question",
               tool_name: tool.name(),
               arguments: %{"question" => "No inherited resolver?"}
             })

    assert error.message =~ "no user question handler"
    refute_receive {:retained_permission, _}
    refute_receive {:retained_question, _}
    refute_receive {:child_tool, _, _}
  end

  defp assert_terminal(run_id) do
    receive do
      {:agent_runtime, ^run_id, %{type: :run_completed}} ->
        :ok

      {:agent_runtime, ^run_id, %{type: type} = event}
      when type in [:run_failed, :storage_failed, :run_cancelled] ->
        flunk(inspect(event))

      {:agent_runtime, ^run_id, _event} ->
        assert_terminal(run_id)
    after
      5_000 -> flunk("child conversation did not complete")
    end
  end
end
