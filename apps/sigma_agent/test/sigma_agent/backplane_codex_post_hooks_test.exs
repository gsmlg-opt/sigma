defmodule Sigma.Agent.BackplaneCodexPostHooksTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Backplane.AgentRuntime.{Codex, Conversation, Error, Plan, ToolEffects}
  alias Backplane.AgentRuntime.Codex.Tools
  alias Sigma.Agent.Backplane.{CodexResources, Provider, Store, ToolCatalog, ToolPostHooks}
  alias Sigma.Coding.Hooks.Discovery
  alias Sigma.Session.{EntryDecoder, EntryEncoder}

  @moduletag :tmp_dir
  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg=="
       )

  defmodule ScriptedProvider do
    def stream(request, %{call: {name, arguments}}) do
      if Enum.any?(request.messages, &(&1.role == :tool)) do
        [%{type: :response_completed, message: %{role: :assistant, content: "Finished"}}]
      else
        [
          %{
            type: :tool_call_completed,
            tool_call: %{id: "post-call", name: name, arguments: arguments}
          },
          %{type: :response_completed, message: %{role: :assistant, content: "Use tool"}}
        ]
      end
    end
  end

  defmodule OutcomeBackend do
    def execute(%{backend_context: %{test: test, outcome: outcome}} = operation) do
      send(test, {:backend_called, operation})

      case outcome do
        {:reject, error} -> ToolEffects.reject(operation, error)
        result -> result
      end
    end
  end

  test "decoration preserves native descriptors and lifecycle field locations before admission",
       %{
         tmp_dir: dir
       } do
    run = start_run!(dir, "descriptors", {"apply_patch", patch()}, post_context(dir, %{}))
    original = run.original.registry.tools["apply_patch"]
    wrapped = run.profile.registry.tools["apply_patch"]

    assert Map.drop(wrapped, [:backend, :backend_context]) ==
             Map.drop(original, [:backend, :backend_context])

    assert wrapped.backend == ToolPostHooks

    assert Map.take(wrapped.backend_context, Map.keys(original.backend_context)) ==
             original.backend_context

    assert run.profile.tools == run.original.tools
    assert run.profile.authority == run.original.authority

    assert {:ok, catalog} =
             ToolCatalog.admit([], run.authority, fn _, _ -> :unused end, profiles: [run.profile])

    assert catalog.registry.tools["apply_patch"].backend == ToolPostHooks
    assert {:error, %Error{class: :validation}} = ToolPostHooks.decorate(run.profile, %{})
  end

  test "native Plan succeeds once and a real command hook observes the committed final input", %{
    tmp_dir: dir
  } do
    test = self()
    input = plan("once")
    context = post_context(dir, feedback("review the plan"), test)
    run = start_run!(dir, "plan", {"update_plan", input}, context)
    [tool] = complete!(run)
    assert {:ok, %{revision: 2, content: %{"plan" => steps}}} = Plan.read(run.context.plan)
    assert steps == input["plan"]
    refute tool.result.is_error
    assert_receive {:feedback, %{arguments: ^input, tool_call_id: "post-call"}, "review the plan"}
    [payload] = hook_payloads(dir)
    assert payload["tool_input"] == input
    assert payload["tool_use_id"] == "post-call"

    assert payload["tool_response"] ==
             Jason.decode!(Jason.encode!(Map.delete(tool.result, :is_error)))

    assert {:ok, persisted} = Store.load(run.store, run.id)
    assert persisted.run.state == :completed
    assert Enum.count(persisted.run.context.conversation.messages, &(&1.role == :tool)) == 1
    assert {:ok, %{status: :confirmed}} = CodexResources.close(run.resources)
  end

  test "raw custom input reaches native patch and hook payload unchanged", %{tmp_dir: dir} do
    raw = patch()
    run = start_run!(dir, "raw", {"apply_patch", raw}, post_context(dir, %{}))
    [tool] = complete!(run)
    refute tool.result.is_error
    assert File.read!(Path.join(dir, "effect.txt")) == "中文 {\"raw\":true}\n"
    assert [payload] = hook_payloads(dir)
    assert payload["tool_input"] == raw

    assert payload["tool_response"] ==
             Jason.decode!(Jason.encode!(Map.delete(tool.result, :is_error)))
  end

  test "decorated Code Mode retains Runtime callbacks and executes a real nested native plan", %{
    tmp_dir: dir
  } do
    code = "return await tools.update_plan({plan: [{step: 'Nested plan', status: 'completed'}]});"

    run =
      start_run!(
        dir,
        "nested-code-mode",
        {"exec", code},
        post_context(
          dir,
          Map.merge(feedback("nested done"), %{"continue" => false, "reason" => "review result"}),
          self()
        ),
        code_mode: true
      )

    [tool] = complete!(run)

    assert %{is_error: false, stopped: true, content: [%{type: :text, text: "review result"}]} =
             tool.result

    assert {:ok, %{revision: 2, content: %{"plan" => [%{"step" => "Nested plan"}]}}} =
             Plan.read(run.context.plan)

    input = plan("Nested plan")

    assert_receive {:feedback, %{tool_name: "update_plan", arguments: ^input}, "nested done"}

    assert_receive {:feedback, %{tool_name: "exec", arguments: ^code}, "nested done"}

    refute_receive {:feedback, _, _}, 0
    assert [nested, outer] = hook_payloads(dir)
    assert nested["tool_name"] == "update_plan"
    assert nested["tool_input"] == input
    assert nested["tool_response"] == %{"revision" => 2, "status" => "updated"}
    assert outer["tool_name"] == "exec"
    assert outer["tool_input"] == code
    assert outer["tool_response"]["value"] == %{"revision" => 2, "status" => "updated"}
    assert {:ok, persisted} = Store.load(run.store, run.id)
    assert [nested_feedback, outer_feedback] = persisted.run.context.conversation.host_feedback
    assert nested_feedback["id"] != outer_feedback["id"]
    assert nested_feedback["correlation"]["tool_name"] == "update_plan"
    assert outer_feedback["correlation"]["tool_name"] == "exec"

    assert nested_feedback["correlation"]["enclosing_invocation_id"] ==
             outer_feedback["correlation"]["invocation_id"]

    nested_id = nested_feedback["correlation"]["invocation_id"]
    outer_id = outer_feedback["correlation"]["invocation_id"]

    assert %{is_error: false, status: :updated, revision: 2} =
             persisted.run.tool_results[nested_id]

    assert %{is_error: false, status: :completed, value: %{"revision" => 2}} =
             persisted.run.tool_results[outer_id]

    for id <- [nested_id, outer_id] do
      assert %{state: :accepted, decision: %{type: :stopped, text: "review result"}} =
               persisted.run.tool_presentations[id]
    end

    assert nested_feedback["text"] == "nested done"
    assert outer_feedback["text"] == "nested done"

    assert {:ok, %{status: :confirmed}} = CodexResources.close(run.resources)
  end

  test "image bytes and canonical replay survive feedback without changing native results", %{
    tmp_dir: dir
  } do
    File.write!(Path.join(dir, "pixel.png"), @png)

    run =
      start_run!(
        dir,
        "image",
        {"view_image", %{"path" => "pixel.png"}},
        post_context(dir, feedback("inspect image"), self())
      )

    [tool] = complete!(run)
    assert tool.result.data == @png
    assert_receive {:feedback, %{tool_name: "view_image"}, "inspect image"}
    [payload] = hook_payloads(dir)
    refute Map.has_key?(payload["tool_response"], "data")
    assert payload["tool_response"]["image_url"] == tool.result.image_url
    [projected] = Provider.normalize_messages([tool])

    assert projected.content == [
             %{type: :image, data: Base.encode64(@png), mime_type: "image/png"}
           ]

    assert {:ok, entry} = EntryEncoder.encode({:message_end, projected}, nil, true)
    assert {:ok, restored} = entry |> Jason.encode!() |> Jason.decode!() |> EntryDecoder.message()
    assert restored.content == projected.content
    assert restored.metadata["structured_result"] == projected.metadata.structured_result
    assert {:ok, persisted} = Store.load(run.store, run.id)
    [saved] = Enum.filter(persisted.run.context.conversation.messages, &(&1.role == :tool))
    assert saved.result == tool.result
  end

  test "native errors remain typed and never invoke success hooks", %{tmp_dir: dir} do
    run =
      start_run!(
        dir,
        "missing-image",
        {"view_image", %{"path" => "missing.png"}},
        post_context(dir, feedback("must not run"), self())
      )

    [tool] = complete!(run)
    assert %{is_error: true, error: %Error{}} = tool.result
    refute File.exists?(Path.join(dir, "hook-payloads.jsonl"))
    refute_receive {:feedback, _, _}, 0
  end

  test "typed backend errors and invocation-bound rejection receipts pass through Runtime", %{
    tmp_dir: dir
  } do
    for {suffix, outcome} <- [
          {"error", {:error, Error.new(:forbidden, "read denied", details: %{scope: "test"})}},
          {"rejected", {:reject, Error.new(:forbidden, "not dispatched")}},
          {"error-map",
           {:ok,
            %{is_error: true, content: [%{type: :text, text: "failed"}], details: %{revision: 7}}}}
        ] do
      workspace = Path.join(dir, suffix)
      File.mkdir!(workspace)

      run =
        start_run!(workspace, suffix, {"clock::curr_time", %{}}, post_context(workspace, %{}),
          backend_outcome: outcome
        )

      [tool] = complete!(run)
      assert tool.result.is_error
      if suffix != "error-map", do: assert(%Error{class: :forbidden} = tool.result.error)
      assert_receive {:backend_called, operation}
      assert operation.backend_context.outcome == outcome
      refute Map.has_key?(operation.backend_context, :sigma_post_hooks)
      assert is_function(operation.backend_context.interact, 1)
      assert is_function(operation.backend_context.nested_dispatch, 1)
      assert is_pid(operation.backend_context.resource_owner_pid)
      refute_receive {:backend_called, _}, 0
      refute File.exists?(Path.join(workspace, "hook-payloads.jsonl"))
    end
  end

  test "unknown outcome remains uncertain and cannot become a successful hook result", %{
    tmp_dir: dir
  } do
    run =
      start_run!(dir, "unknown", {"clock::curr_time", %{}}, post_context(dir, %{}),
        backend_outcome: {:error, Error.new(:unknown_outcome, "unconfirmed effect")}
      )

    assert {:ok, _} = Conversation.prompt(run.conversation, "Use tool")
    id = run.id
    assert_receive {:agent_runtime, ^id, %{type: :run_cancelled, state: :unknown_outcome}}, 5_000

    assert %{
             run: %{state: :unknown_outcome},
             error: %Error{class: :unknown_outcome},
             messages: messages
           } = Conversation.status(run.conversation)

    refute Enum.any?(messages, &(&1.role == :tool))
    assert_receive {:backend_called, _}
    refute_receive {:backend_called, _}, 0
    refute File.exists?(Path.join(dir, "hook-payloads.jsonl"))
  end

  test "Codex block presents a model error while additional context and native success remain separate",
       %{
         tmp_dir: dir
       } do
    output = %{
      "decision" => "block",
      "reason" => "check this",
      "hookSpecificOutput" => %{"hookEventName" => "PostToolUse", "additionalContext" => "detail"}
    }

    run =
      start_run!(dir, "block", {"update_plan", plan("effect")}, post_context(dir, output, self()))

    [tool] = complete!(run)
    assert %{is_error: true, error: %Error{message: "check this"}} = tool.result
    assert_receive {:feedback, _, "detail"}
    assert {:ok, %{revision: 2}} = Plan.read(run.context.plan)
    refute Map.has_key?(tool.result, :content)

    assert {:ok, persisted} = Store.load(run.store, run.id)

    assert %{is_error: false, status: :updated, revision: 2} =
             persisted.run.tool_results[tool.invocation_id]

    assert %{state: :accepted, decision: %{type: :block, text: "check this"}} =
             persisted.run.tool_presentations[tool.invocation_id]

    assert [%{"text" => "detail"}] = persisted.run.context.conversation.host_feedback
  end

  test "decoration defers feedback to the live Runtime context without requiring a sink", %{
    tmp_dir: dir
  } do
    run = start_run!(dir, "no-sink", {"update_plan", plan("untouched")}, %{})

    assert {:ok, decorated} =
             ToolPostHooks.decorate(
               run.original,
               Map.delete(post_context(dir, %{}), :on_hook_context)
             )

    assert decorated.registry.tools["update_plan"].backend == ToolPostHooks
    assert {:ok, %{revision: 1}} = Plan.read(run.context.plan)
  end

  test "failed feedback delivery reports a diagnostic without erasing a completed effect", %{
    tmp_dir: dir
  } do
    context =
      post_context(dir, feedback("feedback"))
      |> Map.put(:on_hook_context, fn _, _ ->
        {:error, Error.new(:execution_failure, "sink unavailable")}
      end)

    run = start_run!(dir, "sink-failure", {"update_plan", plan("retained")}, context)

    log =
      capture_log(fn ->
        [tool] = complete!(run)
        assert tool.result == %{revision: 2, status: :updated, is_error: false}
        assert {:ok, %{revision: 2}} = Plan.read(run.context.plan)
      end)

    assert log =~ "sink unavailable"
  end

  test "async post hooks are refused before native effects", %{tmp_dir: dir} do
    run = start_run!(dir, "async-refused", {"update_plan", plan("untouched")}, %{})
    context = post_context(dir, %{})
    specs = Enum.map(context.hook_specs, &%{&1 | handler: %{&1.handler | async: true}})

    assert {:error, %Error{class: :unsupported_capability}} =
             ToolPostHooks.decorate(run.original, %{context | hook_specs: specs})

    assert {:ok, %{revision: 1}} = Plan.read(run.context.plan)
  end

  test "successful structured siblings remain intact alongside explicit feedback", %{tmp_dir: dir} do
    result = %{
      content: [%{type: :text, text: "native output"}],
      structured: %{exit_code: 0},
      artifacts: [%{path: "artifact.txt"}]
    }

    run =
      start_run!(
        dir,
        "structured",
        {"clock::curr_time", %{}},
        post_context(dir, feedback("follow up"), self()),
        backend_outcome: {:ok, result}
      )

    [tool] = complete!(run)
    assert tool.result == Map.put(result, :is_error, false)
    assert_receive {:feedback, _, "follow up"}
    [projected] = Provider.normalize_messages([tool])
    assert projected.content == result.content
    assert projected.metadata.structured_result["artifacts"] == [%{"path" => "artifact.txt"}]
    assert projected.metadata.structured_result["structured"] == %{"exit_code" => 0}
    assert_receive {:backend_called, _}
    refute_receive {:backend_called, _}, 0
  end

  test "unsafe response values skip JSON hook payloads without rewriting the backend result", %{
    tmp_dir: dir
  } do
    result = %{content: "output", owner: self()}

    run =
      start_run!(dir, "private-output", {"clock::curr_time", %{}}, post_context(dir, %{}),
        backend_outcome: {:ok, result}
      )

    operation = %{
      tool_name: "clock::curr_time",
      tool_call_id: "direct-call",
      arguments: %{},
      backend_context: run.profile.registry.tools["clock::curr_time"].backend_context
    }

    log =
      capture_log(fn ->
        assert {:ok, ^result} = ToolPostHooks.execute(operation)
      end)

    assert log =~ "response is unsafe"
    refute log =~ inspect(self())
    refute File.exists?(Path.join(dir, "hook-payloads.jsonl"))
  end

  test "typed errors retain private causes only at the direct adapter boundary", %{tmp_dir: dir} do
    error = Error.new(:forbidden, "denied", cause: self())

    run =
      start_run!(dir, "private-error", {"clock::curr_time", %{}}, post_context(dir, %{}),
        backend_outcome: {:error, error}
      )

    operation = %{
      tool_name: "clock::curr_time",
      tool_call_id: "direct-call",
      arguments: %{},
      backend_context: run.profile.registry.tools["clock::curr_time"].backend_context
    }

    assert {:error, ^error} = ToolPostHooks.execute(operation)
    assert_receive {:backend_called, _}
    refute_receive {:backend_called, _}, 0
    refute File.exists?(Path.join(dir, "hook-payloads.jsonl"))
  end

  test "unsupported output replacement cannot erase native success", %{
    tmp_dir: dir
  } do
    for {id, output, dialect} <- [
          {"replace-output", %{"hookSpecificOutput" => %{"updatedToolOutput" => "fake output"}},
           :claude}
        ] do
      workspace = Path.join(dir, id)
      File.mkdir!(workspace)
      context = post_context(workspace, output)
      context = %{context | hook_specs: Enum.map(context.hook_specs, &%{&1 | dialect: dialect})}
      run = start_run!(workspace, id, {"update_plan", plan(id)}, context)

      log =
        capture_log(fn ->
          [tool] = complete!(run)
          assert tool.result == %{revision: 2, status: :updated, is_error: false}
        end)

      assert log =~ "control presentation is unsupported"
      assert {:ok, %{revision: 2}} = Plan.read(run.context.plan)
      assert {:ok, persisted} = Store.load(run.store, run.id)

      assert [%{is_error: false, revision: 2, status: :updated}] =
               Map.values(persisted.run.tool_results)

      assert Map.get(persisted.run, :tool_presentations, %{}) == %{}
    end
  end

  test "cancellation during post hook stops its waiter without replaying the native effect", %{
    tmp_dir: dir
  } do
    test = self()

    {:ok, specs} =
      Discovery.parse(
        Jason.encode!(%{
          "hooks" => %{
            "PostToolUse" => [
              %{
                "hooks" => [
                  %{"type" => "mcp_tool", "server" => "test", "tool" => "wait", "timeout" => 20}
                ]
              }
            ]
          }
        }),
        :codex
      )

    specs = Enum.map(specs, &%{&1 | origin: {:user, "test"}, trusted?: true})

    context =
      post_context(dir, %{})
      |> Map.put(:hook_specs, specs)
      |> Map.put(:mcp_hook_executor, fn _, _, _, _ ->
        send(test, {:hook_waiter, self()})
        receive do: (:release -> {:ok, %{exit: 0, stdout: "", stderr: ""}})
      end)

    run = start_run!(dir, "cancel-hook", {"update_plan", plan("once")}, context)
    assert {:ok, _} = Conversation.prompt(run.conversation, "Use tool")
    assert_receive {:hook_waiter, waiter}, 5_000
    monitor = Process.monitor(waiter)
    assert {:ok, %{revision: 2}} = Plan.read(run.context.plan)
    assert :ok = Conversation.cancel(run.conversation)
    id = run.id
    assert_receive {:agent_runtime, ^id, %{type: :run_cancelled}}, 5_000
    assert_receive {:DOWN, ^monitor, :process, ^waiter, _}, 5_000
    refute_receive {:agent_runtime, ^id, %{type: :tool_completed}}, 0
    assert {:ok, %{revision: 2}} = Plan.read(run.context.plan)
    assert {:ok, %{status: :confirmed}} = CodexResources.close(run.resources)
  end

  defp start_run!(dir, id, call, hook_context, opts \\ []) do
    resources =
      start_supervised!({CodexResources, workspace: dir, owner_pid: self()},
        id: {CodexResources, id}
      )

    grants = if opts[:code_mode], do: ["exec", "wait", "update_plan"], else: [elem(call, 0)]
    authority = %{caller: "post-hooks", run_id: id, grants: grants, tool_revision: 1}
    assert {:ok, binding} = CodexResources.bind(resources, authority)
    assert {:ok, context} = CodexResources.context(resources, binding)

    original =
      if opts[:code_mode] do
        deno = System.find_executable("deno")
        assert is_binary(deno), "real decorated Code Mode integration requires Deno"
        contracts = Enum.filter(Tools.contracts(context), &(&1.name == "update_plan"))
        native_context = Map.merge(context, %{deno_path: deno, code_mode_contracts: contracts})
        assert {:ok, profile} = Codex.profile(:code_mode_only, native_context, authority)
        profile
      else
        assert {:ok, profile} =
                 Codex.profile(:pinned_local, context, authority, tools: authority.grants)

        profile
      end

    original =
      case Keyword.fetch(opts, :backend_outcome) do
        {:ok, outcome} ->
          name = elem(call, 0)
          descriptor = original.registry.tools[name]

          descriptor = %{
            descriptor
            | backend: OutcomeBackend,
              backend_context:
                Map.merge(descriptor.backend_context, %{test: self(), outcome: outcome})
          }

          put_in(original.registry.tools[name], descriptor)

        :error ->
          original
      end

    assert {:ok, profile} = ToolPostHooks.decorate(original, hook_context)
    store = start_supervised!({Store, path: Path.join(dir, "runtime")}, id: {Store, id})

    conversation =
      start_supervised!(
        {Conversation,
         run_id: id,
         store: Store,
         context: store,
         provider: ScriptedProvider,
         provider_context: %{call: call},
         registry: profile.registry,
         tools: profile.tools,
         authority: profile.authority,
         session_binding: binding,
         subscriber: self(),
         run_timeout: :infinity,
         effect_timeout: 5_000},
        id: {Conversation, id}
      )

    %{
      id: id,
      conversation: conversation,
      resources: resources,
      store: store,
      context: context,
      original: original,
      profile: profile,
      authority: authority
    }
  end

  defp complete!(run) do
    assert {:ok, _} = Conversation.prompt(run.conversation, "Use tool")
    id = run.id
    assert_receive {:agent_runtime, ^id, %{type: :run_completed}}, 5_000
    Enum.filter(Conversation.status(run.conversation).messages, &(&1.role == :tool))
  end

  defp post_context(dir, output, subscriber \\ nil) do
    payloads = Path.join(dir, "hook-payloads.jsonl")

    command =
      "cat >> '" <>
        payloads <>
        "'; printf '\\n' >> '" <>
        payloads <>
        "'; printf '%s' '" <> String.replace(Jason.encode!(output), "'", "'\\''") <> "'"

    {:ok, specs} =
      Discovery.parse(
        Jason.encode!(%{
          "hooks" => %{
            "PostToolUse" => [
              %{"hooks" => [%{"type" => "command", "command" => command, "timeout" => 2}]}
            ]
          }
        }),
        :codex
      )

    %{
      hook_specs: Enum.map(specs, &%{&1 | origin: {:user, "test"}, trusted?: true}),
      cwd: dir,
      session_id: "post-hooks",
      on_hook_context: fn operation, text ->
        if subscriber, do: send(subscriber, {:feedback, operation, text})
        :ok
      end
    }
  end

  defp hook_payloads(dir),
    do:
      Path.join(dir, "hook-payloads.jsonl")
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)

  defp plan(step), do: %{"plan" => [%{"step" => step, "status" => "completed"}]}
  defp patch, do: "*** Begin Patch\n*** Add File: effect.txt\n+中文 {\"raw\":true}\n*** End Patch\n"

  defp feedback(text),
    do: %{
      "hookSpecificOutput" => %{"hookEventName" => "PostToolUse", "additionalContext" => text}
    }
end
