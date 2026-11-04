defmodule Sigma.Agent.BackplanePostHookPresentationFunctionalTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.Conversation
  alias Sigma.Agent.Runtime
  alias Sigma.Agent.Backplane.{ChildIO, PlanProjection, Store}
  alias Sigma.Coding.Hooks.Discovery
  alias Sigma.Session.Log

  @moduletag :tmp_dir
  @reason "review the completed plan"
  @context "independent post hook context"

  defmodule ControlledProvider do
    @behaviour Sigma.Ai.Provider

    def stream(request) do
      send(request.options[:test_pid], {:presentation_provider, self(), request})

      receive do
        {:respond, content} ->
          reason = if Enum.any?(content, &(&1.type == :tool_call)), do: :tool_use, else: :stop

          message = %{
            role: :assistant,
            content: content,
            stop_reason: reason,
            model: "test",
            provider: "test",
            api: "openai-responses",
            response_model: nil,
            response_id: nil,
            error_message: nil,
            usage: %{
              input: 1,
              output: 1,
              cache_read: 0,
              cache_write: 0,
              total_tokens: 2,
              cost: %{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0, total: 0.0}
            },
            timestamp: System.system_time(:millisecond)
          }

          [{:start, %{message | content: []}}, {:done, reason, message}]
      end
    end
  end

  for host <- [:root, :child], control <- [:block, :stopped], mode <- [:direct, :nested] do
    test "#{host} #{mode} #{control} preserves settlement, presentation and canonical Plan",
         ctx do
      assert_presentation_lifecycle(ctx, unquote(host), unquote(control), unquote(mode))
    end
  end

  for host <- [:root, :child], mode <- [:direct, :nested] do
    @tag :empty_stopped_functional
    test "#{host} #{mode} explicit empty stopped preserves settlement, presentation and canonical Plan",
         ctx do
      assert_presentation_lifecycle(ctx, unquote(host), :stopped, unquote(mode), "")
    end
  end

  defp assert_presentation_lifecycle(ctx, host, control, mode, reason \\ @reason) do
    if mode == :nested, do: assert(is_binary(System.find_executable("deno")))
    specs = hook_specs(ctx.tmp_dir, control, reason)
    owner = owner!(host, ctx.tmp_dir, specs)
    run = prompt!(owner, "update the plan")
    {provider, _request} = provider!()
    send(provider, {:respond, [tool_call(mode, control)]})
    {provider, request} = provider!()
    projected = last_tool!(request.context.messages)
    assert_presentation(projected, mode, control, reason)
    assert_context(request.context.messages)

    assert {:ok, %{run: saved}} = Store.load(owner.store, run.run_id)

    {invocation_id, _intent} =
      Enum.find(saved.execution_intents, fn {_id, intent} ->
        get_in(intent, [:operation, :tool_name]) == "update_plan"
      end)

    invocation_id = String.replace_prefix(invocation_id, "tool:", "")

    assert %{is_error: false, revision: 2, status: :updated} =
             saved.tool_results[invocation_id]

    assert %{state: :accepted, decision: %{type: ^control, text: ^reason}} =
             saved.tool_presentations[invocation_id]

    if mode == :nested do
      actual =
        Enum.find_value(saved.execution_intents, fn {_id, intent} ->
          operation = Map.get(intent, :operation, %{})
          if operation[:tool_name] == "exec", do: saved.tool_results[operation.invocation_id]
        end)

      if control == :block do
        assert %{is_error: false, value: %{"caught" => true}} = actual
      else
        assert %{is_error: false, value: %{"revision" => 2, "status" => "updated"}} = actual
      end
    end

    finish!(run, provider)
    assert {:ok, snapshot} = Log.snapshot(owner.path)
    confirmed = PlanProjection.latest(snapshot.messages)
    assert confirmed["plan"] == [%{"step" => "Completed once", "status" => "completed"}]
    assert confirmed["source_tool"] == if(mode == :direct, do: "update_plan", else: "exec")
    canonical = last_tool!(snapshot.messages)
    assert_presentation(canonical, mode, control, reason)
    assert_canonical_presentation(canonical, control)
    assert length(hook_payloads(ctx.tmp_dir)) == 1

    followup = prompt!(owner, "continue without another tool")
    {provider, request} = provider!()
    assert_presentation(last_tool!(request.context.messages), mode, control, reason)
    assert_context(request.context.messages)
    finish!(followup, provider)
    assert length(hook_payloads(ctx.tmp_dir)) == 1

    recreated = recreate!(owner)
    restarted = prompt!(recreated, "resume after resource recreation")
    {provider, request} = provider!()
    assert_presentation(last_tool!(request.context.messages), mode, control, reason)
    assert_context(request.context.messages)
    assert length(hook_payloads(ctx.tmp_dir)) == 1

    # A hydrated fresh Plan starts at revision 2. The next actual update must
    # advance it to 3, proving recreation restored the selected confirmed Plan.
    send(provider, {:respond, [tool_call(:direct, control)]})
    {provider, request} = provider!()
    assert_presentation(last_tool!(request.context.messages), :direct, control, reason)
    assert {:ok, %{run: saved}} = Store.load(recreated.store, restarted.run_id)

    assert Enum.any?(saved.tool_results, fn {_id, result} ->
             match?(%{revision: 3, status: :updated, is_error: false}, result)
           end)

    finish!(restarted, provider)
    assert length(hook_payloads(ctx.tmp_dir)) == 2
    assert {:ok, snapshot} = Log.snapshot(owner.path)
    assert PlanProjection.latest(snapshot.messages)["plan"] == confirmed["plan"]
    assert_presentation(last_tool!(snapshot.messages), :direct, control, reason)
  end

  defp owner!(:root, dir, specs) do
    store = start_supervised!({Store, path: Path.join(dir, "root-runtime")})
    path = Path.join(dir, "root.jsonl")

    owner = %{
      kind: :root,
      dir: dir,
      specs: specs,
      store: store,
      path: path,
      sequence: :atomics.new(1, signed: false)
    }

    on_exit(fn -> stop_repository(dir) end)
    start_root!(owner)
  end

  defp owner!(:child, dir, specs) do
    identity = %{
      agent_id: "presentation-child",
      child_session_id: "presentation-child-session",
      root_session_id: "presentation-root-session",
      run_id: "presentation-child-run",
      public_run_id: "presentation-child-public-run",
      incarnation: 1,
      observer_incarnation: 1,
      agent_path: "/root/presentation_child",
      parent_agent_id: "root"
    }

    owner = %{
      kind: :child,
      dir: dir,
      specs: specs,
      identity: identity,
      path: Path.join(dir, "child.jsonl"),
      sequence: :atomics.new(1, signed: false)
    }

    start_child!(owner)
  end

  defp start_root!(owner) do
    assert {:ok, snapshot} = Log.snapshot(owner.path)

    assert {:ok, handle} =
             Runtime.get_session(owner.dir, "presentation",
               cwd: owner.dir,
               transcript_path: owner.path,
               provider: ControlledProvider,
               model: %{id: "test", provider: "test", api: "openai-responses"},
               native_tools: true,
               native_memory_root: Path.join(owner.dir, "memories"),
               backplane_store: owner.store,
               tools: [],
               messages: snapshot.messages,
               hook_specs: owner.specs,
               options: [test_pid: self()]
             )

    :ok = Sigma.Agent.subscribe(handle.agent)
    Map.put(owner, :agent, handle.agent)
  end

  defp start_child!(owner) do
    config = %{
      model: %{id: "test", provider: "test", api: "openai-responses"},
      provider: ControlledProvider,
      provider_options: [test_pid: self()],
      cwd: owner.dir,
      tools: [],
      dispatcher_opts: [],
      hook_specs: owner.specs,
      native_tools: true,
      native_memory_root: Path.join(owner.dir, "memories")
    }

    io =
      start_supervised!(
        {ChildIO,
         config: config,
         identity: owner.identity,
         transcript_path: owner.path,
         backplane_store_path: Path.join(owner.dir, "child-runtime")}
      )

    assert {:ok, store} = ChildIO.store(io)
    Map.merge(owner, %{io: io, store: store})
  end

  defp prompt!(%{kind: :root} = owner, text) do
    assert {:accepted, %{turn_id: run_id}} = Sigma.Agent.prompt(owner.agent, text)
    %{kind: :root, run_id: run_id}
  end

  defp prompt!(%{kind: :child} = owner, text) do
    number = :atomics.add_get(owner.sequence, 1, 1)
    identity = %{owner.identity | run_id: "child-run-#{number}"}

    authority = %{
      caller: "root",
      run_id: "root",
      grants: ~w(update_plan exec wait),
      tool_revision: 1
    }

    assert {:ok, prepared} = ChildIO.prepare(owner.io, identity, authority, [])

    conversation =
      start_supervised!(
        Supervisor.child_spec({Conversation, prepared.options}, id: {:presentation_run, number})
      )

    assert {:ok, _} = Conversation.prompt(conversation, text)

    %{
      kind: :child,
      run_id: identity.run_id,
      conversation: conversation,
      supervisor_id: {:presentation_run, number}
    }
  end

  defp finish!(%{kind: :root}, provider) do
    send(provider, {:respond, [%{type: :text, text: "done"}]})
    assert_receive {:agent_end, _}, 5_000
  end

  defp finish!(%{kind: :child} = run, provider) do
    send(provider, {:respond, [%{type: :text, text: "done"}]})
    await_terminal!(run.conversation)
    assert :ok = stop_supervised(run.supervisor_id)
  end

  defp recreate!(%{kind: :root} = owner) do
    stop_repository(owner.dir)
    start_root!(owner)
  end

  defp recreate!(%{kind: :child} = owner) do
    assert :ok = stop_supervised(ChildIO)
    start_child!(owner)
  end

  defp stop_repository(dir) do
    case Runtime.lookup(dir, :supervisor) do
      nil -> :ok
      pid -> DynamicSupervisor.terminate_child(Sigma.Agent.DynamicSupervisor, pid)
    end
  end

  defp provider! do
    assert_receive {:presentation_provider, provider, request}, 8_000
    {provider, request}
  end

  defp tool_call(:direct, _control) do
    %{
      type: :tool_call,
      id: "plan-#{System.unique_integer([:positive])}",
      name: "update_plan",
      arguments: %{"plan" => [%{"step" => "Completed once", "status" => "completed"}]}
    }
  end

  defp tool_call(:nested, control) do
    code =
      if control == :block do
        """
        try {
          await tools.update_plan({plan: [{step: 'Completed once', status: 'completed'}]});
          return {caught: false};
        } catch (error) {
          return {caught: true, message: String(error)};
        }
        """
      else
        "return await tools.update_plan({plan: [{step: 'Completed once', status: 'completed'}]});"
      end

    %{
      type: :tool_call,
      id: "exec-#{System.unique_integer([:positive])}",
      name: "exec",
      arguments: code,
      input_kind: :custom
    }
  end

  defp assert_presentation(result, :nested, :block, reason) do
    refute result.is_error
    assert %{"value" => %{"caught" => true, "message" => message}} = structured(result)
    assert message =~ reason
  end

  defp assert_presentation(result, :direct, :block, reason) do
    assert result.is_error
    assert %{"error" => %{"message" => ^reason}} = structured(result)
  end

  defp assert_presentation(result, _mode, :stopped, reason) do
    refute result.is_error
    assert result.content == [%{type: :text, text: reason}]
  end

  defp assert_canonical_presentation(result, :stopped),
    do: assert(%{"stopped" => true} = structured(result))

  defp assert_canonical_presentation(_result, :block), do: :ok

  defp structured(result) do
    metadata = Map.get(result, :metadata, %{})

    case metadata[:structured_result] || metadata["structured_result"] do
      nil ->
        result.content
        |> Enum.map_join("", fn %{type: :text, text: text} -> text end)
        |> Jason.decode!()

      value ->
        value
    end
  end

  defp last_tool!(messages) do
    result = messages |> Enum.reverse() |> Enum.find(&(&1.role == :tool_result))
    assert result
    result
  end

  defp assert_context(messages) do
    feedback =
      for %{role: :user, content: content} <- messages,
          block <- List.wrap(content),
          text = if(is_map(block), do: Map.get(block, :text), else: block),
          is_binary(text),
          String.starts_with?(text, "[Host feedback] "),
          do: text

    assert length(feedback) == 1
    assert hd(feedback) =~ @context
    refute hd(feedback) =~ @reason
  end

  defp hook_specs(dir, control, reason) do
    output =
      case control do
        :block -> %{"decision" => "block", "reason" => reason}
        :stopped -> %{"continue" => false, "stopReason" => reason}
      end
      |> Map.put("hookSpecificOutput", %{
        "hookEventName" => "PostToolUse",
        "additionalContext" => @context
      })

    payloads = shell_quote(Path.join(dir, "hook-payloads.jsonl"))

    command =
      "cat >> " <>
        payloads <>
        "; printf '\\n' >> " <>
        payloads <>
        "; printf '%s' " <> shell_quote(Jason.encode!(output))

    assert {:ok, specs} =
             Discovery.parse(
               Jason.encode!(%{
                 "hooks" => %{
                   "PostToolUse" => [
                     %{
                       "matcher" => "update_plan",
                       "hooks" => [%{"type" => "command", "command" => command, "timeout" => 5}]
                     }
                   ]
                 }
               }),
               :codex
             )

    Enum.map(specs, &%{&1 | origin: {:user, "test"}, trusted?: true, dialect: :codex})
  end

  defp hook_payloads(dir),
    do: dir |> Path.join("hook-payloads.jsonl") |> File.read!() |> String.split("\n", trim: true)

  defp shell_quote(text), do: "'" <> String.replace(text, "'", "'\\''") <> "'"

  defp await_terminal!(conversation, attempts \\ 500)
  defp await_terminal!(_conversation, 0), do: flunk("child did not reach terminal state")

  defp await_terminal!(conversation, attempts) do
    if Conversation.status(conversation).phase != :terminal do
      Process.sleep(10)
      await_terminal!(conversation, attempts - 1)
    end
  end
end
