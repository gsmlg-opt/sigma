defmodule Sigma.Agent.BackplaneCodexPreparationTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.{Codex, Conversation, Error, Plan}
  alias Sigma.Agent.Backplane.{CodexResources, PermissionResponder, Store, ToolPreparation}
  alias Sigma.Coding.PermissionPolicy
  alias Sigma.Coding.Hooks.Discovery

  @moduletag :tmp_dir

  defmodule Provider do
    def stream(request, %{call: {name, arguments}}) do
      if Enum.any?(request.messages, &(&1.role == :tool)) do
        [%{type: :response_completed, message: %{role: :assistant, content: "Finished"}}]
      else
        [
          %{
            type: :tool_call_completed,
            tool_call: %{id: "prepared-call", name: name, arguments: arguments}
          },
          %{type: :response_completed, message: %{role: :assistant, content: "Use tool"}}
        ]
      end
    end
  end

  # The real file commit completes before the test holds its acknowledgement.
  # Runtime cannot dispatch the backend until that acknowledgement is released.
  defmodule ObservedStore do
    defdelegate mode(), to: Store
    defdelegate capabilities(), to: Store

    def load(context, id, opts), do: Store.load(context.store, id, opts)

    def store(context, record, meta) do
      result = Store.store(context.store, record, meta)

      if match?({:ok, _}, result) and elem(meta.command, 0) == :cleanup_settled do
        {:ok, persisted} = Store.load(context.store, record.run_id)
        send(context.test, {:cleanup_committed, record.run_id, persisted.run.state})
      end

      if match?({:ok, _}, result) and elem(meta.command, 0) == :tool_invoked do
        {:ok, persisted} = Store.load(context.store, record.run_id)

        for invocation <- Map.values(persisted.run.active_tools) do
          send(context.test, {:invocation_committed, invocation, self()})
        end

        if context.gate, do: receive(do: (:release_commit -> :ok))
      end

      result
    end
  end

  test "full replacement B reaches approval, durable intent and the native Plan", %{tmp_dir: dir} do
    replacement = plan("B")
    test = self()

    permission = fn call ->
      send(test, {:approval, call})
      :allow
    end

    run =
      start_run!(dir, "replacement", {"update_plan", Map.put(plan("A"), "explanation", "old")},
        gate: true,
        permission_request_fn: permission,
        hook_specs: pre_hook(replacement)
      )

    prompt!(run)
    assert_receive {:approval, %{arguments: ^replacement}}, 5_000
    assert_receive {:invocation_committed, invocation, commit}, 5_000
    assert invocation.arguments == replacement
    assert {:ok, persisted} = Store.load(run.store, run.id)
    assert persisted.run.active_tools[invocation.invocation_id].arguments == replacement
    assert {:ok, %{revision: 1}} = Plan.read(run.context.plan)
    send(commit, :release_commit)
    [tool] = complete!(run)
    refute tool.result.is_error
    assert {:ok, %{revision: 2, content: content}} = Plan.read(run.context.plan)
    assert content["plan"] == replacement["plan"]
    assert content["explanation"] == nil
    refute_receive {:approval, _}, 0
  end

  test "legacy input patches merge before approval and approval patches become final input", %{
    tmp_dir: dir
  } do
    replacement = plan("patched")
    final = Map.put(replacement, "explanation", "approved")
    test = self()

    specs =
      hook_specs(
        "PreToolUse",
        %{
          "hookSpecificOutput" => %{
            "permissionDecision" => "allow",
            "updatedInput" => replacement
          }
        },
        :claude
      )

    run =
      start_run!(dir, "patch", {"update_plan", Map.put(plan("A"), "explanation", "retained")},
        gate: true,
        hook_specs: specs,
        permission_request_fn: fn call ->
          send(test, {:approval, call})
          {:allow, %{"explanation" => "approved"}}
        end
      )

    prompt!(run)
    assert_receive {:approval, %{arguments: %{"explanation" => "retained", "plan" => steps}}}
    assert steps == replacement["plan"]
    assert_receive {:invocation_committed, invocation, commit}, 5_000
    assert invocation.arguments == final
    assert {:ok, persisted} = Store.load(run.store, run.id)
    assert persisted.run.active_tools[invocation.invocation_id].arguments == final
    send(commit, :release_commit)
    complete!(run)
    assert {:ok, %{content: content}} = Plan.read(run.context.plan)
    assert content["plan"] == final["plan"]
    assert content["explanation"] == "approved"
  end

  test "hook denial never requests approval or commits a native effect", %{tmp_dir: dir} do
    specs =
      hook_specs("PreToolUse", %{
        "hookSpecificOutput" => %{
          "hookEventName" => "PreToolUse",
          "permissionDecision" => "deny",
          "permissionDecisionReason" => "blocked"
        }
      })

    run =
      start_run!(dir, "denied", {"update_plan", plan("A")},
        hook_specs: specs,
        permission_request_fn: fn _ -> flunk("denied input must not request approval") end
      )

    prompt!(run)
    [tool] = complete!(run)
    assert %{is_error: true, error: %Error{class: :forbidden}} = tool.result
    assert_no_effect!(run)
  end

  test "legacy PermissionRequest patches become final input without another approval", %{
    tmp_dir: dir
  } do
    final = Map.put(plan("permission hook"), "explanation", "retained")

    specs =
      hook_specs(
        "PermissionRequest",
        %{
          "hookSpecificOutput" => %{
            "behavior" => "allow",
            "updatedInput" => plan("permission hook")
          }
        },
        :claude
      )

    run =
      start_run!(
        dir,
        "permission-hook",
        {"update_plan", Map.put(plan("A"), "explanation", "retained")},
        hook_specs: specs,
        permission_request_fn: fn _ -> flunk("hook already allowed this input") end
      )

    prompt!(run)
    [tool] = complete!(run)
    refute tool.result.is_error
    assert_receive {:invocation_committed, %{arguments: ^final}, _}, 0
    assert {:ok, %{content: ^final}} = Plan.read(run.context.plan)
  end

  test "invalid transformed function input fails Runtime validation before any effect", %{
    tmp_dir: dir
  } do
    run =
      start_run!(dir, "invalid", {"update_plan", plan("A")},
        hook_specs: pre_hook(%{"plan" => "invalid"}),
        permission_request_fn: fn _ -> :allow end
      )

    prompt!(run)
    [tool] = complete!(run)
    assert tool.result.is_error
    assert_no_effect!(run)
  end

  test "an explicit permission resolver denial prevents the native Plan effect", %{tmp_dir: dir} do
    test = self()
    final = plan("denied B")

    run =
      start_run!(dir, "resolver-denied", {"update_plan", plan("A")},
        hook_specs: pre_hook(final),
        permission_request_fn: fn call ->
          send(test, {:approval, call})
          {:deny, :denied_once}
        end
      )

    prompt!(run)
    assert_receive {:approval, %{arguments: ^final}}, 5_000
    [tool] = complete!(run)
    assert %{is_error: true, error: %Error{class: :forbidden}} = tool.result
    assert_no_effect!(run)
  end

  test "cancelling a preparation approval wait prevents the native effect", %{tmp_dir: dir} do
    test = self()

    run =
      start_run!(dir, "cancelled", {"update_plan", plan("A")},
        permission_request_fn: fn call ->
          send(test, {:waiting_approval, call, self()})
          receive do: (:approve -> :allow)
        end
      )

    prompt!(run)
    assert_receive {:waiting_approval, _, worker}, 5_000
    assert {:ok, %{revision: 1}} = Plan.read(run.context.plan)
    monitor = Process.monitor(worker)
    assert :ok = Conversation.cancel(run.conversation)
    id = run.id
    assert_receive {:agent_runtime, ^id, %{type: :run_cancelled}}, 5_000
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 5_000
    assert_no_invocation!(run)
  end

  test "custom patch input reaches approval, durable intent and apply_patch byte for byte", %{
    tmp_dir: dir
  } do
    patch = "*** Begin Patch\n*** Add File: effect.txt\n+中文 {\"raw\":true}\n*** End Patch\n"
    test = self()

    run =
      start_run!(dir, "custom", {"apply_patch", patch},
        gate: true,
        permission_request_fn: fn call ->
          send(test, {:approval, call})
          :allow
        end
      )

    prompt!(run)
    assert_receive {:approval, %{arguments: ^patch}}, 5_000
    assert_receive {:invocation_committed, invocation, commit}, 5_000
    assert invocation.arguments === patch
    assert {:ok, persisted} = Store.load(run.store, run.id)
    assert persisted.run.active_tools[invocation.invocation_id].arguments === patch
    refute File.exists?(Path.join(dir, "effect.txt"))
    send(commit, :release_commit)
    [tool] = complete!(run)
    refute tool.result.is_error
    assert File.read!(Path.join(dir, "effect.txt")) == "中文 {\"raw\":true}\n"
  end

  for {label, reply} <- [
        {"map patch", {:allow, %{"input" => "not raw input"}}},
        {"binary replacement unsupported by the existing resolver", {:allow, "replacement"}}
      ] do
    test "custom input rejects #{label} without a file effect", %{tmp_dir: dir} do
      patch = "*** Begin Patch\n*** Add File: effect.txt\n+must not run\n*** End Patch\n"
      reply = unquote(Macro.escape(reply))

      run =
        start_run!(dir, "custom-rejected", {"apply_patch", patch},
          permission_request_fn: fn _ -> reply end
        )

      prompt!(run)
      [tool] = complete!(run)
      assert tool.result.is_error
      refute_receive {:invocation_committed, _, _}, 0
      refute File.exists?(Path.join(dir, "effect.txt"))
    end
  end

  test "Runtime persists additional context without an explicit sink", %{tmp_dir: dir} do
    run =
      start_run!(dir, "context-missing", {"update_plan", plan("A")},
        hook_specs: pre_hook(plan("B"), "retain this context"),
        permission_request_fn: fn _ -> :allow end
      )

    prompt!(run)
    [tool] = complete!(run)
    refute tool.result.is_error
    assert {:ok, %{revision: 2}} = Plan.read(run.context.plan)
    assert {:ok, persisted} = Store.load(run.store, run.id)

    assert [%{"text" => "retain this context", "store_mode" => "durable"}] =
             persisted.run.context.conversation.host_feedback
  end

  test "additional context goes to its sink with final input and never enters raw arguments", %{
    tmp_dir: dir
  } do
    test = self()
    final = plan("B")

    run =
      start_run!(dir, "context-sink", {"update_plan", plan("A")},
        hook_specs: pre_hook(final, "retain this context"),
        permission_request_fn: fn _ -> :allow end,
        on_hook_context: fn invocation, text ->
          send(test, {:hook_context, invocation, text})
          :ok
        end
      )

    prompt!(run)
    assert_receive {:hook_context, %{arguments: ^final}, "retain this context"}, 5_000
    [tool] = complete!(run)
    refute tool.result.is_error
    assert {:ok, %{content: content}} = Plan.read(run.context.plan)
    assert content["plan"] == final["plan"]
    assert content["explanation"] == nil
    refute_receive {:hook_context, _, _}, 0
  end

  test "context-only custom preparation preserves exact binary input", %{tmp_dir: dir} do
    invocation = %{tool_call_id: "raw", tool_name: "apply_patch", arguments: "raw\n"}
    test = self()

    specs =
      hook_specs("PreToolUse", %{
        "hookSpecificOutput" => %{
          "hookEventName" => "PreToolUse",
          "additionalContext" => "context"
        }
      })

    assert :allow =
             ToolPreparation.prepare_tool(invocation, %{
               input_kind: :custom,
               permission_options: [cwd: dir, hook_specs: specs],
               on_hook_context: fn final, text ->
                 send(test, {:context, final, text})
                 :ok
               end
             })

    assert_received {:context, ^invocation, "context"}
  end

  test "Runtime permission interaction suspends deadlines and commits transformed B before execution",
       %{
         tmp_dir: dir
       } do
    agent = permission_agent!(dir)
    final = plan("B")

    run =
      start_run!(dir, "interaction-approved", {"update_plan", plan("A")},
        permission_interaction: true,
        permission_request_fn: question_resolver(agent),
        hook_specs: pre_hook(final),
        gate: true,
        run_timeout: 1_500,
        effect_timeout: 1_000
      )

    prompt!(run)

    assert_receive {:agent_runtime, _,
                    %{type: :interaction_requested, request: %{tool_call: %{id: "prepared-call"}}} =
                      event},
                   5_000

    assert event.request == %{
             kind: :sigma_tool_permission,
             tool_call: %{id: "prepared-call", name: "update_plan", arguments: final}
           }

    assert_receive {:approval_waiter, waiter}, 5_000
    assert_receive {:ask_user_question, question_id, %{arguments: ^final}}, 5_000
    assert {:ok, persisted} = Store.load(run.store, run.id)

    assert persisted.run.context.conversation.pending_interaction == %{
             id: event.interaction_id,
             request: event.request
           }

    # This exceeds both original budgets after the actual wait was checkpointed.
    refute_receive {:agent_runtime, _, %{type: :run_failed}}, 1_600
    assert Conversation.status(run.conversation).phase == :waiting_interaction
    assert Process.alive?(waiter)
    assert_no_effect!(run)
    assert :ok = Sigma.Agent.answer_user_question(agent, question_id, {:ok, "allow_once"})
    assert_receive {:invocation_committed, invocation, commit}, 5_000
    assert invocation.arguments == final
    assert {:ok, committed} = Store.load(run.store, run.id)
    assert committed.run.active_tools[invocation.invocation_id].arguments == final
    assert {:ok, %{revision: 1}} = Plan.read(run.context.plan)
    send(commit, :release_commit)
    [tool] = complete!(run)
    refute tool.result.is_error
    assert {:ok, %{revision: 2, content: content}} = Plan.read(run.context.plan)
    assert content["plan"] == final["plan"]
    assert content["explanation"] == nil
    assert [] = Sigma.Agent.pending_user_questions(agent)
  end

  test "interaction denial prevents the native effect", %{tmp_dir: dir} do
    agent = permission_agent!(dir)

    run =
      start_run!(dir, "interaction-denied", {"update_plan", plan("A")},
        permission_interaction: true,
        permission_request_fn: question_resolver(agent)
      )

    prompt!(run)
    assert_receive {:ask_user_question, question_id, _}, 5_000
    assert :ok = Sigma.Agent.answer_user_question(agent, question_id, {:ok, "deny_once"})
    [tool] = complete!(run)
    assert %{is_error: true, error: %Error{class: :forbidden}} = tool.result
    assert_no_effect!(run)
    assert [] = Sigma.Agent.pending_user_questions(agent)
  end

  test "interaction cancellation stops the resolver, clears Sigma's question and rejects late approval",
       %{
         tmp_dir: dir
       } do
    agent = permission_agent!(dir)

    run =
      start_run!(dir, "interaction-cancelled", {"update_plan", plan("A")},
        permission_interaction: true,
        permission_request_fn: question_resolver(agent)
      )

    prompt!(run)
    assert_receive {:agent_runtime, _, %{type: :interaction_requested, interaction_id: id}}, 5_000
    assert_receive {:approval_waiter, waiter}, 5_000
    assert_receive {:ask_user_question, question_id, _}, 5_000
    monitor = Process.monitor(waiter)
    assert :ok = Conversation.cancel(run.conversation)
    assert_receive {:agent_runtime, _, %{type: :run_cancelled}}, 5_000
    assert_receive {:DOWN, ^monitor, :process, ^waiter, _}, 5_000
    assert_receive {:ask_user_question_resolved, ^question_id}, 5_000
    assert [] = Sigma.Agent.pending_user_questions(agent)
    assert {:error, _} = Sigma.Agent.answer_user_question(agent, question_id, {:ok, "allow_once"})

    assert {:error,
            %Error{class: :resource_conflict, message: "run is not accepting resolutions"}} =
             Conversation.resolve(run.conversation, id, :allow)

    assert_no_effect!(run)
  end

  for shutdown <- [:conversation, :responder, :owner] do
    test "#{shutdown} exit stops the interaction resolver and clears its Sigma question", %{
      tmp_dir: dir
    } do
      agent = permission_agent!(dir)
      owner = spawn(fn -> receive do: (:stop -> :ok) end)
      on_exit(fn -> if Process.alive?(owner), do: Process.exit(owner, :kill) end)

      run =
        start_run!(dir, "interaction-exit", {"update_plan", plan("A")},
          permission_interaction: true,
          permission_request_fn: question_resolver(agent),
          owner_pid: owner
        )

      prompt!(run)

      assert_receive {:agent_runtime, _, %{type: :interaction_requested, interaction_id: id}},
                     5_000

      assert_receive {:approval_waiter, waiter}, 5_000
      assert_receive {:ask_user_question, question_id, _}, 5_000
      monitor = Process.monitor(waiter)

      case unquote(shutdown) do
        :conversation -> GenServer.stop(run.conversation)
        :responder -> stop_supervised!(PermissionResponder)
        :owner -> send(owner, :stop)
      end

      assert_receive {:DOWN, ^monitor, :process, ^waiter, _}, 5_000
      assert_receive {:ask_user_question_resolved, ^question_id}, 5_000
      assert [] = Sigma.Agent.pending_user_questions(agent)

      assert {:error, _} =
               Sigma.Agent.answer_user_question(agent, question_id, {:ok, "allow_once"})

      if unquote(shutdown) != :conversation do
        run_id = run.id
        assert_receive {:cleanup_committed, ^run_id, :cancelled}, 5_000
        assert {:ok, persisted} = Store.load(run.store, run.id)
        assert persisted.run.state == :cancelled
        assert persisted.run.context.conversation.pending_interaction == nil

        assert {:error,
                %Error{class: :resource_conflict, message: "run is not accepting resolutions"}} =
                 Conversation.resolve(run.conversation, id, :allow)
      end

      assert_no_invocation!(run)
    end
  end

  for shutdown <- [:responder, :owner] do
    test "#{shutdown} shutdown cancels an attached idle Conversation", %{tmp_dir: dir} do
      owner = spawn(fn -> receive do: (:stop -> :ok) end)
      on_exit(fn -> if Process.alive?(owner), do: Process.exit(owner, :kill) end)

      run =
        start_run!(dir, "idle-exit", {"update_plan", plan("A")},
          permission_interaction: true,
          permission_request_fn: fn _ -> :allow end,
          owner_pid: owner
        )

      monitor = Process.monitor(run.responder)

      case unquote(shutdown) do
        :responder -> stop_supervised!(PermissionResponder)
        :owner -> send(owner, :stop)
      end

      assert_receive {:DOWN, ^monitor, :process, _, _}, 5_000
      run_id = run.id
      assert_receive {:cleanup_committed, ^run_id, :cancelled}, 5_000
      assert {:ok, persisted} = Store.load(run.store, run.id)
      assert persisted.run.state == :cancelled
      assert_no_invocation!(run)
    end

    test "#{shutdown} shutdown preserves a completed Conversation checkpoint", %{tmp_dir: dir} do
      owner = spawn(fn -> receive do: (:stop -> :ok) end)
      on_exit(fn -> if Process.alive?(owner), do: Process.exit(owner, :kill) end)

      run =
        start_run!(dir, "completed-exit", {"update_plan", plan("A")},
          permission_interaction: true,
          permission_request_fn: fn _ -> :allow end,
          owner_pid: owner
        )

      prompt!(run)
      [_tool] = complete!(run)
      assert {:ok, before} = Store.load(run.store, run.id)
      assert before.run.state == :completed
      monitor = Process.monitor(run.responder)

      case unquote(shutdown) do
        :responder -> stop_supervised!(PermissionResponder)
        :owner -> send(owner, :stop)
      end

      assert_receive {:DOWN, ^monitor, :process, _, _}, 5_000
      assert {:ok, ^before} = Store.load(run.store, run.id)
      refute_receive {:cleanup_committed, _, _}, 0
    end
  end

  test "responder ignores unrelated, malformed, stale and duplicate requests", %{tmp_dir: dir} do
    test = self()

    run =
      start_run!(dir, "interaction-fenced", {"update_plan", plan("A")},
        permission_interaction: true,
        permission_request_fn: fn call ->
          send(test, {:resolver_called, call, self()})
          receive do: (:approve -> :allow)
        end
      )

    invalid = %{
      type: :interaction_requested,
      run_id: run.id,
      incarnation: 1,
      interaction_id: "not-pending",
      request: %{kind: :sigma_tool_permission, tool_call: %{id: "x", name: "x", arguments: %{}}}
    }

    for event <- [
          %{invalid | run_id: "other-run"},
          %{invalid | incarnation: 2},
          %{invalid | request: %{kind: :permission, tool_call: %{}}},
          %{invalid | request: %{kind: :sigma_tool_permission, tool_call: %{name: "missing-id"}}},
          invalid
        ] do
      send(run.responder, {:agent_runtime, event.run_id, event})
    end

    refute_receive {:resolver_called, _, _}, 100
    prompt!(run)

    assert_receive {:agent_runtime, _,
                    %{type: :interaction_requested, request: %{tool_call: %{id: "prepared-call"}}} =
                      event},
                   5_000

    assert_receive {:resolver_called, _, waiter}, 5_000
    send(run.responder, {:agent_runtime, run.id, event})
    refute_receive {:resolver_called, _, _}, 100
    send(waiter, :approve)
    [tool] = complete!(run)
    refute tool.result.is_error
    send(run.responder, {:agent_runtime, run.id, event})
    refute_receive {:resolver_called, _, _}, 100
  end

  test "resolver exceptions deny the interaction instead of leaving it pending", %{tmp_dir: dir} do
    run =
      start_run!(dir, "interaction-error", {"update_plan", plan("A")},
        permission_interaction: true,
        permission_request_fn: fn _ -> raise "resolver failed" end
      )

    prompt!(run)
    [tool] = complete!(run)
    assert %{is_error: true, error: %Error{class: :forbidden}} = tool.result
    assert Conversation.status(run.conversation).conversation.pending_interaction == nil
    assert_no_effect!(run)
  end

  test "normal resolver self-exit denies an interaction that is still pending", %{tmp_dir: dir} do
    run =
      start_run!(dir, "interaction-normal-exit", {"update_plan", plan("A")},
        permission_interaction: true,
        permission_request_fn: fn _ -> Process.exit(self(), :normal) end
      )

    prompt!(run)
    [tool] = complete!(run)
    assert %{is_error: true, error: %Error{class: :forbidden}} = tool.result
    assert Conversation.status(run.conversation).conversation.pending_interaction == nil
    assert_no_effect!(run)
  end

  test "forged terminal and resolved events cannot abandon a current approval wait", %{
    tmp_dir: dir
  } do
    agent = permission_agent!(dir)

    run =
      start_run!(dir, "interaction-forged", {"update_plan", plan("A")},
        permission_interaction: true,
        permission_request_fn: question_resolver(agent)
      )

    prompt!(run)
    assert_receive {:agent_runtime, _, %{type: :interaction_requested} = event}, 5_000
    assert_receive {:approval_waiter, waiter}, 5_000
    assert_receive {:ask_user_question, question_id, _}, 5_000

    for type <- [
          :run_completed,
          :run_failed,
          :run_cancelled,
          :storage_failed,
          :interaction_resolved
        ] do
      send(run.responder, {:agent_runtime, run.id, %{event | type: type}})
      refute_receive {:agent_runtime, _, %{type: ^type}}, 100
      assert Process.alive?(waiter)
      assert [%{id: ^question_id}] = Sigma.Agent.pending_user_questions(agent)
      assert Conversation.status(run.conversation).phase == :waiting_interaction
    end

    assert :ok = Sigma.Agent.answer_user_question(agent, question_id, {:ok, "allow_once"})
    [tool] = complete!(run)
    refute tool.result.is_error
    assert {:ok, %{revision: 2}} = Plan.read(run.context.plan)
  end

  test "a built-in permission event without an interaction ID cannot crash an active responder",
       %{
         tmp_dir: dir
       } do
    agent = permission_agent!(dir)

    run =
      start_run!(dir, "interaction-missing-id", {"update_plan", plan("A")},
        permission_interaction: true,
        permission_request_fn: question_resolver(agent)
      )

    prompt!(run)
    assert_receive {:approval_waiter, waiter}, 5_000
    assert_receive {:ask_user_question, question_id, _}, 5_000
    monitor = Process.monitor(run.responder)

    send(
      run.responder,
      {:agent_runtime, run.id,
       %{
         type: :interaction_requested,
         run_id: run.id,
         incarnation: 1,
         request: %{kind: :permission, operation: %{}}
       }}
    )

    refute_receive {:DOWN, ^monitor, :process, _, _}, 100
    assert Process.alive?(waiter)
    assert [%{id: ^question_id}] = Sigma.Agent.pending_user_questions(agent)
    assert Conversation.status(run.conversation).phase == :waiting_interaction
    assert :ok = Sigma.Agent.answer_user_question(agent, question_id, {:ok, "allow_once"})
    [tool] = complete!(run)
    refute tool.result.is_error
    assert {:ok, %{revision: 2}} = Plan.read(run.context.plan)
  end

  test "interaction opt-in requires Runtime's trusted interact callback" do
    assert {:error, %Error{class: :validation}} =
             ToolPreparation.prepare_tool(
               %{tool_call_id: "x", tool_name: "update_plan", arguments: plan("A")},
               %{input_kind: :function, permission_options: [], permission_interaction: true}
             )
  end

  defp permission_agent!(dir) do
    agent =
      start_supervised!(
        {Sigma.Agent,
         cwd: dir,
         session_id: "permission-ui",
         backplane_runtime_path: Path.join(dir, "permission-ui"),
         hook_specs: [],
         tools: []}
      )

    Sigma.Agent.subscribe(agent)
    agent
  end

  defp question_resolver(agent) do
    test = self()

    fn call ->
      send(test, {:approval_waiter, self()})

      case Sigma.Agent.ask_user_question(agent, %{
             kind: :permission,
             question: "Allow #{call.name}?",
             tool_call_id: call.id,
             arguments: call.arguments,
             options: [
               %{label: "Allow once", value: "allow_once"},
               %{label: "Deny once", value: "deny_once"}
             ],
             allow_freeform: false
           }) do
        {:ok, "allow_once"} -> :allow
        _ -> {:deny, :denied_once}
      end
    end
  end

  defp start_run!(dir, id, call, opts) do
    test = self()
    resources = start_supervised!({CodexResources, workspace: dir, owner_pid: test})

    authority = %{
      caller: "preparation-test",
      run_id: id,
      grants: [elem(call, 0)],
      tool_revision: 1
    }

    assert {:ok, binding} = CodexResources.bind(resources, authority)
    assert {:ok, context} = CodexResources.context(resources, binding)

    assert {:ok, profile} =
             Codex.profile(:pinned_local, context, authority, tools: [elem(call, 0)])

    store = start_supervised!({Store, path: Path.join(dir, "runtime")})
    policy = start_supervised!({PermissionPolicy, default: :ask})

    permission_options =
      [cwd: dir, session_id: id, permission_policy: policy]
      |> Keyword.merge(Keyword.take(opts, [:hook_specs, :permission_request_fn]))

    responder =
      if opts[:permission_interaction] do
        start_supervised!(
          {PermissionResponder,
           run_id: id,
           incarnation: 1,
           owner_pid: opts[:owner_pid] || test,
           subscriber: test,
           permission_request_fn: opts[:permission_request_fn]}
        )
      end

    conversation =
      start_supervised!(
        {Conversation,
         run_id: id,
         store: ObservedStore,
         context: %{store: store, test: test, gate: opts[:gate] == true},
         provider: Provider,
         provider_context: %{
           call: call,
           permission_options: permission_options,
           permission_interaction: opts[:permission_interaction] == true,
           on_hook_context: opts[:on_hook_context]
         },
         hooks: ToolPreparation,
         registry: profile.registry,
         tools: profile.tools,
         authority: profile.authority,
         session_binding: binding,
         subscriber: responder || test,
         run_timeout: opts[:run_timeout] || :infinity,
         effect_timeout: opts[:effect_timeout] || 5_000}
      )

    if responder, do: assert(:ok = PermissionResponder.attach(responder, conversation))

    %{
      id: id,
      conversation: conversation,
      resources: resources,
      context: context,
      store: store,
      responder: responder
    }
  end

  defp prompt!(run), do: assert({:ok, _} = Conversation.prompt(run.conversation, "Prepare tool"))

  defp complete!(run) do
    id = run.id
    assert_receive {:agent_runtime, ^id, %{type: :run_completed}}, 5_000
    %{messages: messages} = Conversation.status(run.conversation)
    Enum.filter(messages, &(&1.role == :tool))
  end

  defp assert_no_effect!(run) do
    assert {:ok, %{revision: 1}} = Plan.read(run.context.plan)
    assert_no_invocation!(run)
  end

  defp assert_no_invocation!(run) do
    refute_receive {:invocation_committed, _, _}, 0
    assert {:ok, persisted} = Store.load(run.store, run.id)
    assert persisted.run.active_tools == %{}

    refute Enum.any?(Map.keys(Map.get(persisted.run, :execution_intents, %{})), fn id ->
             String.starts_with?(id, "tool:")
           end)
  end

  defp plan(step), do: %{"plan" => [%{"step" => step, "status" => "completed"}]}

  defp pre_hook(input, context \\ nil) do
    specific = %{
      "hookEventName" => "PreToolUse",
      "permissionDecision" => "allow",
      "updatedInput" => input
    }

    specific = if context, do: Map.put(specific, "additionalContext", context), else: specific
    hook_specs("PreToolUse", %{"hookSpecificOutput" => specific})
  end

  defp hook_specs(event, output, dialect \\ :codex) do
    command = "printf '%s' '" <> String.replace(Jason.encode!(output), "'", "'\\''") <> "'"

    {:ok, specs} =
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

    Enum.map(specs, &%{&1 | origin: {:user, "test"}, trusted?: true, dialect: dialect})
  end
end
