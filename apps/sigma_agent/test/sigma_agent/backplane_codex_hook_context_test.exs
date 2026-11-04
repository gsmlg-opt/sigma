defmodule Sigma.Agent.BackplaneCodexHookContextTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Backplane.AgentRuntime.{Codex, Conversation, Error, Plan}
  alias Sigma.Agent.Backplane.{CodexResources, Provider, Store, ToolPostHooks, ToolPreparation}
  alias Sigma.Agent.Message
  alias Sigma.Ai.ProviderEvent
  alias Sigma.Coding.Hooks.Discovery

  @moduletag :tmp_dir

  defmodule ControlledProvider do
    def stream_normalized(request) do
      send(request.options[:test], {:model_request, request})

      if Enum.any?(request.context.messages, &(&1.role == :tool_result)) do
        [%ProviderEvent{type: :response_completed, message: %{role: :assistant, content: []}}]
      else
        [
          %ProviderEvent{
            type: :tool_call_completed,
            tool_call: %{id: "hook-call", name: "update_plan", arguments: plan("original")}
          },
          %ProviderEvent{type: :response_completed, message: %{role: :assistant, content: []}}
        ]
      end
    end

    defp plan(step), do: %{"plan" => [%{"step" => step, "status" => "completed"}]}
  end

  defmodule ObservedPreparation do
    def prepare_tool(invocation, context) do
      append = context.append_feedback

      context =
        Map.put(context, :append_feedback, fn payload ->
          result = append.(payload)
          send(context.test, {:feedback_append, invocation, payload, result, append})

          if context[:check_conflict] do
            conflict = append.(Map.put(payload, :text, "conflicting feedback"))
            send(context.test, {:feedback_conflict, conflict})
          end

          result
        end)

      result = ToolPreparation.prepare_tool(invocation, context)

      if context[:retry_preparation] do
        assert_same = ToolPreparation.prepare_tool(invocation, context)
        send(context.test, {:preparation_retry, result, assert_same})
      end

      if context[:hold_preparation] do
        send(context.test, {:preparation_waiter, self()})
        receive do: (:release -> :ok)
      end

      result
    end
  end

  defmodule FeedbackStore do
    defdelegate mode(), to: Store
    defdelegate capabilities(), to: Store
    def load(context, id, opts), do: Store.load(context.store, id, opts)

    def store(context, record, meta) do
      # Store callbacks receive the previous run plus a transition command.
      # Inspect the public staged candidate to fail the feedback checkpoint
      # itself, before it is acknowledged or persisted by the real file Store.
      with {:ok, %{stage: stage}} <-
             Backplane.AgentRuntime.Store.stage(Store, context.store, record, meta) do
        feedback = Map.get(stage.run.context.conversation, :host_feedback, [])

        if Enum.any?(feedback, &(&1["stage"] == context[:fail_stage])) do
          send(context.test, {:feedback_commit_failed, context.fail_stage})
          {:error, Error.new(:execution_failure, "feedback checkpoint unavailable")}
        else
          Store.store(context.store, record, meta)
        end
      end
    end
  end

  test "pre and post context reach the next Sigma provider request once with durable correlation",
       %{
         tmp_dir: dir
       } do
    run = start_run!(dir, post: true, retry_preparation: true, check_conflict: true)
    complete!(run)
    assert_receive {:model_request, first}
    assert [%Message{role: :user}] = first.context.messages
    assert_receive {:model_request, next}

    assert [
             %Message{role: :user},
             %Message{role: :assistant},
             %Message{role: :tool_result, metadata: %{structured_result: result}},
             %Message{role: :user, metadata: %{host_feedback: pre}} = pre_message,
             %Message{role: :user, metadata: %{host_feedback: post}} = post_message
           ] = next.context.messages

    assert pre_message.content == "[Host feedback] sigma.hooks / PreToolUse\npre feedback"
    assert post_message.content == "[Host feedback] sigma.hooks / PostToolUse\npost feedback"
    assert pre_message.id == "msg_host_feedback_" <> pre["id"]
    assert post_message.id == "msg_host_feedback_" <> post["id"]
    assert pre["id"] != post["id"]
    assert result == %{"revision" => 2, "status" => "updated", "is_error" => false}

    assert {:ok, %{revision: 2, content: %{"plan" => [%{"step" => "final"}]}}} =
             Plan.read(run.native.plan)

    assert_receive {:feedback_append, invocation, payload, {:ok, receipt}, append}
    assert_receive {:feedback_append, ^invocation, ^payload, {:ok, ^receipt}, _}
    assert_receive {:preparation_retry, {:allow, final}, {:allow, final}}
    assert_receive {:feedback_conflict, {:error, %Error{class: :resource_conflict}}}
    assert_receive {:feedback_conflict, {:error, %Error{class: :resource_conflict}}}
    assert final == plan("final")
    assert receipt.store_mode == :durable
    assert receipt.correlation.invocation_id == invocation.invocation_id
    assert pre["correlation"]["invocation_id"] == invocation.invocation_id
    assert post["correlation"] == pre["correlation"]

    assert {:ok, persisted} = Store.load(run.store, run.id)
    assert [saved_pre, saved_post] = persisted.run.context.conversation.host_feedback
    assert saved_pre["projected"] and saved_post["projected"]
    assert saved_pre["revision"] == receipt.revision
    assert saved_pre["store_mode"] == "durable"
    assert {:error, %Error{class: :resource_conflict}} = append.(payload)
    refute_receive {:model_request, _}, 0
  end

  test "provider normalization preserves canonical feedback and stable identity", %{tmp_dir: _dir} do
    metadata = %{"id" => "feedback-id", "source" => "sigma.hooks", "stage" => "PreToolUse"}

    message = %{
      role: :user,
      content: "[Host feedback] sigma.hooks / PreToolUse\nhello",
      host_feedback: metadata
    }

    assert [%Message{id: "msg_host_feedback_feedback-id", role: :user} = normalized] =
             Provider.normalize_messages([message])

    assert normalized.content == message.content
    assert normalized.metadata.host_feedback == metadata
    assert Provider.normalize_messages([normalized]) == [normalized]
  end

  test "stopped post feedback reaches the next provider without cancelling the completed effect",
       %{
         tmp_dir: dir
       } do
    run =
      start_run!(dir,
        pre: false,
        post: true,
        post_output: %{
          "continue" => false,
          "reason" => "  检查已完成的计划  ",
          "stopReason" => "lower priority"
        }
      )

    complete!(run)
    assert_receive {:model_request, _first}
    assert_receive {:model_request, next}

    assert [
             %Message{role: :user},
             %Message{role: :assistant},
             %Message{role: :tool_result, metadata: %{structured_result: result}},
             %Message{role: :user, metadata: %{host_feedback: feedback}} = message
           ] = next.context.messages

    assert result == %{
             "is_error" => false,
             "stopped" => true,
             "content" => [%{"type" => "text", "text" => "检查已完成的计划"}]
           }

    assert message.content == "[Host feedback] sigma.hooks / PostToolUse\npost feedback"

    assert feedback["stage"] == "PostToolUse"

    assert {:ok, %{revision: 2, content: %{"plan" => [%{"step" => "original"}]}}} =
             Plan.read(run.native.plan)

    assert {:ok, %{run: %{state: :completed}} = persisted} = Store.load(run.store, run.id)

    assert [%{"text" => "post feedback", "projected" => true}] =
             persisted.run.context.conversation.host_feedback

    assert [tool] = Enum.filter(persisted.run.context.conversation.messages, &(&1.role == :tool))

    assert %{is_error: false, status: :updated, revision: 2} =
             persisted.run.tool_results[tool.invocation_id]

    assert %{state: :accepted, decision: %{type: :stopped, text: "检查已完成的计划"}} =
             persisted.run.tool_presentations[tool.invocation_id]

    refute_receive {:agent_runtime, _, %{type: :run_cancelled}}, 0
    refute_receive {:model_request, _}, 0
  end

  test "observer refusal after durable pre acceptance prevents dispatch and retains accepted context",
       %{
         tmp_dir: dir
       } do
    test = self()

    observer = fn _, _ ->
      send(test, :observer_called)
      {:error, Error.new(:forbidden, "observer refused")}
    end

    run = start_run!(dir, observer: observer)
    complete!(run)
    assert_receive :observer_called
    assert_receive {:feedback_append, _, _, {:ok, %{store_mode: :durable}}, _}
    assert {:ok, %{revision: 1}} = Plan.read(run.native.plan)
    assert {:ok, persisted} = Store.load(run.store, run.id)

    assert [%{"stage" => "PreToolUse", "text" => "pre feedback"}] =
             persisted.run.context.conversation.host_feedback

    assert [%{result: %{is_error: true, error: %Error{class: :forbidden}}}] =
             Enum.filter(persisted.run.context.conversation.messages, &(&1.role == :tool))
  end

  test "failed pre feedback commit prevents the native effect and observer delivery", %{
    tmp_dir: dir
  } do
    test = self()

    run =
      start_run!(dir,
        fail_stage: "PreToolUse",
        observer: fn _, _ ->
          send(test, :observer_called)
          :ok
        end
      )

    assert {:ok, _} = Conversation.prompt(run.conversation, "Use tool")
    assert_receive {:feedback_commit_failed, "PreToolUse"}, 5_000
    assert_receive {:agent_runtime, _, %{type: :storage_failed}}, 5_000
    assert {:ok, %{revision: 1}} = Plan.read(run.native.plan)
    assert {:ok, persisted} = Store.load(run.store, run.id)
    assert persisted.run.context.conversation.host_feedback == []
    refute_receive {:feedback_append, _, _, {:ok, _}, _}, 0
    refute_receive :observer_called, 0
  end

  test "post observer failure retains native success and the accepted durable feedback", %{
    tmp_dir: dir
  } do
    observer = fn _, _ -> {:error, Error.new(:execution_failure, "observer unavailable")} end
    run = start_run!(dir, pre: false, post: true, observer: observer)

    log = capture_log(fn -> complete!(run) end)
    assert log =~ "observer unavailable"
    assert {:ok, %{revision: 2}} = Plan.read(run.native.plan)
    assert {:ok, persisted} = Store.load(run.store, run.id)

    assert [%{"stage" => "PostToolUse", "text" => "post feedback"}] =
             persisted.run.context.conversation.host_feedback

    assert [%{result: %{revision: 2, status: :updated, is_error: false}}] =
             Enum.filter(persisted.run.context.conversation.messages, &(&1.role == :tool))
  end

  test "cancelled preparation fences the captured append callback without replaying a tool", %{
    tmp_dir: dir
  } do
    run = start_run!(dir, hold_preparation: true)
    assert {:ok, _} = Conversation.prompt(run.conversation, "Use tool")
    assert_receive {:feedback_append, _, payload, {:ok, receipt}, append}, 5_000
    assert_receive {:preparation_waiter, waiter}, 5_000
    monitor = Process.monitor(waiter)
    assert :ok = Conversation.cancel(run.conversation)
    assert_receive {:agent_runtime, _, %{type: :run_cancelled}}, 5_000
    assert_receive {:DOWN, ^monitor, :process, ^waiter, _}, 5_000
    assert {:error, %Error{class: :resource_conflict}} = append.(payload)
    assert {:ok, %{revision: 1}} = Plan.read(run.native.plan)
    assert {:ok, persisted} = Store.load(run.store, run.id)
    assert [%{"revision" => revision}] = persisted.run.context.conversation.host_feedback
    assert revision == receipt.revision
  end

  defp start_run!(dir, opts) do
    test = self()
    id = "durable-hooks"
    resources = start_supervised!({CodexResources, workspace: dir, owner_pid: test})

    authority = %{
      caller: "hook-context-test",
      run_id: id,
      grants: ["update_plan"],
      tool_revision: 1
    }

    assert {:ok, binding} = CodexResources.bind(resources, authority)
    assert {:ok, native} = CodexResources.context(resources, binding)

    assert {:ok, profile} =
             Codex.profile(:pinned_local, native, authority, tools: ["update_plan"])

    context = %{
      cwd: dir,
      session_id: id,
      hook_specs: hook_specs("PostToolUse", "post feedback", Keyword.get(opts, :post_output, %{}))
    }

    context =
      if opts[:observer], do: Map.put(context, :on_hook_context, opts[:observer]), else: context

    profile = if opts[:post], do: decorate!(profile, context), else: profile
    store = start_supervised!({Store, path: Path.join(dir, "runtime")})
    owner = spawn_link(fn -> provider_owner() end)
    on_exit(fn -> if Process.alive?(owner), do: send(owner, :stop) end)

    host = %{
      model: %{id: "fixture", api: "fixture", provider: "fixture"},
      provider: ControlledProvider,
      provider_options: [test: test],
      session_id: id,
      log_session_id: id,
      build_context: fn messages -> %{messages: messages, system: [], tools: []} end,
      context_error: fn _ -> nil end
    }

    pre_specs =
      if Keyword.get(opts, :pre, true), do: hook_specs("PreToolUse", "pre feedback"), else: []

    conversation =
      start_supervised!(
        {Conversation,
         run_id: id,
         store: FeedbackStore,
         context: %{store: store, test: test, fail_stage: opts[:fail_stage]},
         provider: Provider,
         provider_context: %{
           host: host,
           owner: owner,
           test: test,
           permission_options: [cwd: dir, hook_specs: pre_specs],
           on_hook_context: opts[:observer],
           retry_preparation: opts[:retry_preparation],
           check_conflict: opts[:check_conflict],
           hold_preparation: opts[:hold_preparation]
         },
         hooks: ObservedPreparation,
         registry: profile.registry,
         tools: profile.tools,
         authority: profile.authority,
         session_binding: binding,
         subscriber: test,
         run_timeout: :infinity,
         effect_timeout: 5_000}
      )

    %{id: id, conversation: conversation, store: store, native: native}
  end

  defp decorate!(profile, context) do
    assert {:ok, decorated} = ToolPostHooks.decorate(profile, context)
    decorated
  end

  defp complete!(run) do
    assert {:ok, _} = Conversation.prompt(run.conversation, "Use tool")
    id = run.id
    assert_receive {:agent_runtime, ^id, %{type: :run_completed}}, 5_000
  end

  defp provider_owner do
    receive do
      {:backplane_request_started, worker, ref, _, _} ->
        send(worker, {:backplane_request_ready, ref, :ok})
        provider_owner()

      {:backplane_provider_boundary, worker, ref, _} ->
        send(worker, {:backplane_provider_continue, ref})
        provider_owner()

      :stop ->
        :ok

      _ ->
        provider_owner()
    end
  end

  defp hook_specs(event, text, controls \\ %{}) do
    specific = %{"hookEventName" => event, "additionalContext" => text}

    specific =
      if event == "PreToolUse",
        do:
          Map.merge(specific, %{"permissionDecision" => "allow", "updatedInput" => plan("final")}),
        else: specific

    output = Jason.encode!(Map.put(controls, "hookSpecificOutput", specific))
    command = "printf '%s' '" <> String.replace(output, "'", "'\\''") <> "'"

    assert {:ok, specs} =
             Discovery.parse(
               Jason.encode!(%{
                 "hooks" => %{
                   event => [
                     %{"hooks" => [%{"type" => "command", "command" => command, "timeout" => 2}]}
                   ]
                 }
               }),
               :codex
             )

    Enum.map(specs, &%{&1 | origin: {:user, "test"}, trusted?: true})
  end

  defp plan(step), do: %{"plan" => [%{"step" => step, "status" => "completed"}]}
end
