defmodule Sigma.Agent.BackplaneChildHookDeliveryTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.{Conversation, Error}
  alias Sigma.Agent.Backplane.{ChildIO, Store}
  alias Sigma.Coding.Hooks.Discovery
  alias Sigma.Session.Log

  @moduletag :tmp_dir

  defmodule ControlledProvider do
    @behaviour Sigma.Ai.Provider

    def stream(request) do
      send(request.options[:test_pid], {:child_hook_request, self(), request})

      receive do
        {:respond, content, reason} ->
          message = %{
            role: :assistant,
            content: content,
            usage: %{input: 1, output: 1},
            stop_reason: reason,
            timestamp: System.system_time(:millisecond)
          }

          [{:start, %{message | content: []}}, {:done, reason, message}]
      end
    end
  end

  defmodule FailingConsumptionStorage do
    @behaviour Sigma.Session.Storage

    alias Sigma.Session.Storage.JsonlFile

    defdelegate read(path), to: JsonlFile
    defdelegate read_with_diagnostics(path), to: JsonlFile

    def append(path, %{"type" => "hook_feedback", "event" => %{"fact" => "consumed"}}) do
      File.write!(path <> ".failed-consumption", "failed\n", [:append])
      {:error, :enospc}
    end

    defdelegate append(path, entry), to: JsonlFile
  end

  defmodule CheckpointGate do
    @behaviour Backplane.AgentRuntime.Store

    alias Backplane.AgentRuntime.Store
    alias Sigma.Agent.Backplane.ChildStore

    defdelegate mode(), to: ChildStore
    defdelegate capabilities(), to: ChildStore
    defdelegate new(incarnation), to: ChildStore
    defdelegate load(context, run_id, opts), to: ChildStore

    defdelegate fence(context, run_id, revision, current, next), to: ChildStore

    def store(context, record, meta) do
      with {:ok, %{stage: stage}} <- Store.stage(__MODULE__, context, record, meta),
           {:ok, result} <- acknowledge_commit(context, stage, meta) do
        {:ok, Map.put(result, :outbox, stage.outbox)}
      end
    end

    def acknowledge_commit(context, stage, meta) do
      messages = get_in(stage, [:run, :context, :conversation, :messages]) || []

      case :ets.lookup(context.checkpoint_gate, :message_id) do
        [{:message_id, id}] ->
          if Enum.any?(messages, &(Map.get(&1, :id) == id)) and
               :ets.take(context.checkpoint_gate, :armed) != [] do
            send(context.test_pid, {:child_checkpoint_waiting, self(), id})

            receive do
              :release_child_checkpoint -> :ok
            after
              5_000 -> raise "child checkpoint gate was not released"
            end
          end

        [] ->
          :ok
      end

      ChildStore.acknowledge_commit(context, stage, meta)
    end
  end

  test "late child feedback waits for a real followup and enters its first request once", ctx do
    child = child!(ctx.tmp_dir)
    first = prepare!(child, child.identity)
    conversation = conversation!(first, :first)
    assert {:ok, _} = Conversation.prompt(conversation, "first child prompt")
    assert_receive {:child_hook_request, provider, _}, 5_000
    send(provider, {:respond, [plan_call()], :tool_use})
    assert_receive {:child_hook_request, provider, _}, 5_000
    send(provider, {:respond, [%{type: :text, text: "done"}], :stop})
    terminal!(conversation)

    File.write!(child.release, "ready")
    await_file!(child.completed)
    await_feedback!(child.path, "received")
    refute_receive {:child_hook_request, _, _}, 100

    identity = %{child.identity | run_id: "child-run-2", public_run_id: "public-child-run-2"}
    next = prepare!(child, identity)
    followup = conversation!(next, :followup)
    assert {:ok, _} = Conversation.prompt(followup, "real followup")
    assert_receive {:child_hook_request, provider, request}, 5_000
    assert inspect(request.context.messages) =~ "child hook feedback"
    send(provider, {:respond, [%{type: :text, text: "followup done"}], :stop})
    terminal!(followup)
    await_feedback!(child.path, "consumed")

    third = prepare!(child, %{identity | run_id: "child-run-3"})
    third_run = conversation!(third, :third)
    assert {:ok, _} = Conversation.prompt(third_run, "third prompt")
    assert_receive {:child_hook_request, provider, request}, 5_000
    assert length(Regex.scan(~r/child hook feedback/, inspect(request.context.messages))) == 1
    send(provider, {:respond, [%{type: :text, text: "third done"}], :stop})
    terminal!(third_run)
  end

  test "active child feedback skips UserPromptSubmit and persists only in the child journal",
       ctx do
    child = child!(ctx.tmp_dir)
    prepared = prepare!(child, child.identity)
    conversation = conversation!(prepared, :active)
    assert {:ok, _} = Conversation.prompt(conversation, "active child prompt")
    assert_receive {:child_hook_request, provider, _}, 5_000
    send(provider, {:respond, [plan_call()], :tool_use})
    assert_receive {:child_hook_request, provider, _}, 5_000
    File.write!(child.release, "ready")
    await_file!(child.completed)
    await_steering!(conversation)
    refute feedback?(child.path, "consumed")
    send(provider, {:respond, [%{type: :text, text: "before feedback"}], :stop})

    assert_receive {:child_hook_request, provider, request}, 5_000
    assert inspect(request.context.messages) =~ "child hook feedback"
    send(provider, {:respond, [%{type: :text, text: "after feedback"}], :stop})
    terminal!(conversation)
    await_feedback!(child.path, "consumed")
    assert length(submissions(child)) == 1
    assert hd(submissions(child))["prompt"] == "active child prompt"
    assert {:ok, snapshot} = Log.snapshot(child.path)
    assert Enum.any?(snapshot.messages, &Map.has_key?(&1.metadata, "hook_feedback"))
    assert Enum.count(snapshot.messages, &(inspect(&1.content) =~ "child hook feedback")) == 1
    refute File.exists?(Path.join(ctx.tmp_dir, "root.jsonl"))
  end

  test "a failed consumption receipt rejects the triggering checkpoint after its sidecar commit",
       ctx do
    child = child!(ctx.tmp_dir, 1, storage_mod: FailingConsumptionStorage)
    first = prepare!(child, child.identity)
    conversation = conversation!(first, :before_storage_failure)
    assert {:ok, _} = Conversation.prompt(conversation, "first child prompt")
    assert_receive {:child_hook_request, provider, _}, 5_000
    send(provider, {:respond, [plan_call()], :tool_use})
    assert_receive {:child_hook_request, provider, _}, 5_000
    send(provider, {:respond, [%{type: :text, text: "done"}], :stop})
    terminal!(conversation)
    File.write!(child.release, "ready")
    await_feedback!(child.path, "received")

    identity = %{child.identity | run_id: "child-run-storage-failure"}
    next = prepare!(child, identity)
    followup = conversation!(next, :storage_failure)

    assert {:error, %Error{class: :execution_failure, details: details, cause: cause}} =
             Conversation.prompt(followup, "real followup with late feedback")

    assert details.kind == :child_transcript_projection_failed
    assert details.runtime_committed
    assert details.run_id == identity.run_id

    assert %Error{
             message: "child hook delivery failed",
             cause: {:storage_append_failed, :enospc}
           } = cause

    assert Conversation.status(followup).phase == :storage_failed
    assert {:ok, store} = ChildIO.store(child.io)
    assert {:ok, %{revision: revision, run: run}} = Store.load(store, identity.run_id)
    assert revision == details.revision

    assert Enum.any?(
             run.context.conversation.messages,
             &(inspect(&1.content) =~ "child hook feedback")
           )

    assert {:ok, snapshot} = Log.snapshot(child.path)
    assert Enum.any?(snapshot.messages, &Map.has_key?(&1.metadata, "hook_feedback"))
    assert feedback_count(child.path, "received") == 1
    assert feedback_count(child.path, "admitted") == 1
    refute feedback?(child.path, "consumed")
    assert File.read!(child.path <> ".failed-consumption") == "failed\n"
    assert length(submissions(child)) == 2
    refute_receive {:child_hook_request, _, _}, 100
  end

  test "feedback from a cancelled child origin cannot enter a fresh run", ctx do
    child = child!(ctx.tmp_dir)
    prepared = prepare!(child, child.identity)
    conversation = conversation!(prepared, :cancelled)
    assert {:ok, _} = Conversation.prompt(conversation, "cancel this child turn")
    assert_receive {:child_hook_request, provider, _}, 5_000
    send(provider, {:respond, [plan_call()], :tool_use})
    assert_receive {:child_hook_request, _provider, _}, 5_000
    await_file!(child.started)
    assert :ok = Conversation.cancel(conversation)
    terminal!(conversation)
    File.write!(child.release, "ready")
    await_file!(child.completed)
    await_feedback!(child.path, "received")

    next = prepare!(child, %{child.identity | run_id: "child-run-after-cancel"})
    followup = conversation!(next, :after_cancel)
    assert {:ok, _} = Conversation.prompt(followup, "new real prompt")
    assert_receive {:child_hook_request, provider, request}, 5_000
    refute inspect(request.context.messages) =~ "child hook feedback"
    send(provider, {:respond, [%{type: :text, text: "finished"}], :stop})
    terminal!(followup)
    await_feedback!(child.path, "discarded")
  end

  test "real steering checkpoints progress while multiple ready hooks await admission", ctx do
    child = child!(ctx.tmp_dir, 2)
    prepared = prepare!(child, child.identity)
    gate = :ets.new(__MODULE__, [:set, :public])
    :ets.insert(gate, {:armed, true})

    context =
      prepared.options
      |> Keyword.fetch!(:context)
      |> Map.merge(%{checkpoint_gate: gate, test_pid: self()})

    prepared = %{
      prepared
      | options:
          prepared.options
          |> Keyword.put(:store, CheckpointGate)
          |> Keyword.put(:context, context)
    }

    conversation = conversation!(prepared, :concurrent_steering)
    assert {:ok, _} = Conversation.prompt(conversation, "initial child prompt")
    assert_receive {:child_hook_request, provider, _}, 5_000
    send(provider, {:respond, [plan_call()], :tool_use})
    assert_receive {:child_hook_request, provider, _}, 5_000
    await_file!(child.started)

    assert {:ok, %{message_id: real_id}} =
             Conversation.steer(conversation, "real steering prompt")

    :ets.insert(gate, {:message_id, real_id})
    send(provider, {:respond, [%{type: :text, text: "before real steering"}], :stop})
    assert_receive {:child_checkpoint_waiting, checkpoint, ^real_id}, 5_000

    File.write!(child.release, "ready")
    await!(fn -> feedback_count(child.path, "received") == 2 end)
    await_feedback!(child.path, "dispatch_started")
    send(checkpoint, :release_child_checkpoint)

    assert_receive {:child_hook_request, provider, request}, 5_000
    assert Enum.any?(request.context.messages, &(&1.content == "real steering prompt"))
    await!(fn -> feedback_count(child.path, "admitted") == 2 end)
    send(provider, {:respond, [%{type: :text, text: "before first feedback"}], :stop})

    assert_receive {:child_hook_request, provider, _}, 5_000
    send(provider, {:respond, [%{type: :text, text: "before second feedback"}], :stop})
    assert_receive {:child_hook_request, provider, _}, 5_000
    send(provider, {:respond, [%{type: :text, text: "all feedback consumed"}], :stop})
    terminal!(conversation)
    await!(fn -> feedback_count(child.path, "consumed") == 2 end)

    assert Enum.map(submissions(child), & &1["prompt"]) ==
             ["initial child prompt", "real steering prompt"]

    assert {:ok, snapshot} = Log.snapshot(child.path)
    assert Enum.count(snapshot.messages, &(&1.id == real_id)) == 1
    assert Enum.count(snapshot.messages, &Map.has_key?(&1.metadata, "hook_feedback")) == 2
  end

  test "closing child IO cancels its detached hooks before stopping its writer", ctx do
    child = child!(ctx.tmp_dir)
    prepared = prepare!(child, child.identity)
    conversation = conversation!(prepared, :shutdown)
    assert {:ok, _} = Conversation.prompt(conversation, "close this child")
    assert_receive {:child_hook_request, provider, _}, 5_000
    send(provider, {:respond, [plan_call()], :tool_use})
    assert_receive {:child_hook_request, provider, _}, 5_000
    await_file!(child.started)
    send(provider, {:respond, [%{type: :text, text: "done"}], :stop})
    terminal!(conversation)
    assert :ok = stop_supervised(ChildIO)
    File.write!(child.release, "ready")
    refute_receive {:child_hook_request, _, _}, 100
    refute File.exists?(child.completed)
    refute feedback?(child.path, "received")
  end

  test "a rejected real followup leaves late feedback available for the next accepted prompt",
       ctx do
    child = child!(ctx.tmp_dir)
    first = prepare!(child, child.identity)
    conversation = conversation!(first, :before_rejection)
    assert {:ok, _} = Conversation.prompt(conversation, "first child prompt")
    assert_receive {:child_hook_request, provider, _}, 5_000
    send(provider, {:respond, [plan_call()], :tool_use})
    assert_receive {:child_hook_request, provider, _}, 5_000
    send(provider, {:respond, [%{type: :text, text: "done"}], :stop})
    terminal!(conversation)
    File.write!(child.release, "ready")
    await_feedback!(child.path, "received")

    File.write!(child.reject, "block")
    next = prepare!(child, %{child.identity | run_id: "rejected-followup"})
    rejected = conversation!(next, :rejected_followup)

    assert {:error, %Backplane.AgentRuntime.Error{class: :cancelled}} =
             Conversation.prompt(rejected, "reject this real followup")

    terminal!(rejected)
    refute_receive {:child_hook_request, _, _}, 100
    refute feedback?(child.path, "dispatch_started")

    File.rm!(child.reject)
    accepted = prepare!(child, %{child.identity | run_id: "accepted-followup"})
    accepted_run = conversation!(accepted, :accepted_followup)
    assert {:ok, _} = Conversation.prompt(accepted_run, "accept this real followup")
    assert_receive {:child_hook_request, provider, request}, 5_000
    assert inspect(request.context.messages) =~ "child hook feedback"
    send(provider, {:respond, [%{type: :text, text: "finished"}], :stop})
    terminal!(accepted_run)
    await_feedback!(child.path, "consumed")

    assert Enum.map(submissions(child), & &1["prompt"]) ==
             ["first child prompt", "reject this real followup", "accept this real followup"]
  end

  defp child!(dir, hook_count \\ 1, opts \\ []) do
    release = Path.join(dir, "release-hook")
    completed = Path.join(dir, "completed-hook")
    started = Path.join(dir, "started-hook")
    submit_path = Path.join(dir, "user-submissions.jsonl")
    reject = Path.join(dir, "reject-submission")

    output =
      Jason.encode!(%{
        "hookSpecificOutput" => %{
          "hookEventName" => "PostToolUse",
          "additionalContext" => "child hook feedback"
        }
      })

    command =
      "cat >/dev/null; touch '#{started}'; while [ ! -f '#{release}' ]; do sleep 0.01; done; printf '%s' '#{output}'; touch '#{completed}'"

    submit_command =
      "cat >> '#{submit_path}'; printf '\\n' >> '#{submit_path}'; if [ -f '#{reject}' ]; then printf '%s' 'blocked child prompt' >&2; exit 2; fi"

    {:ok, specs} =
      Discovery.parse(
        Jason.encode!(%{
          "hooks" => %{
            "UserPromptSubmit" => [
              %{"hooks" => [%{"type" => "command", "command" => submit_command, "timeout" => 5}]}
            ],
            "PostToolUse" => [
              %{
                "matcher" => "update_plan",
                "hooks" =>
                  List.duplicate(
                    %{"type" => "command", "command" => command, "async" => true, "timeout" => 5},
                    hook_count
                  )
              }
            ]
          }
        }),
        :codex
      )

    identity = %{
      agent_id: "child-#{System.unique_integer([:positive])}",
      child_session_id: "child-session",
      root_session_id: "root-session",
      run_id: "child-run-1",
      public_run_id: "public-child-run-1",
      incarnation: 1,
      observer_incarnation: 1,
      agent_path: "/root/child",
      parent_agent_id: "root"
    }

    path = Path.join(dir, "child.jsonl")

    config = %{
      model: %{id: "mock", provider: "mock", api: "mock"},
      provider: ControlledProvider,
      provider_options: [test_pid: self()],
      cwd: dir,
      tools: [],
      dispatcher_opts: [],
      hook_specs: Enum.map(specs, &%{&1 | origin: {:user, "test"}, trusted?: true}),
      native_tools: true,
      native_memory_root: Path.join(dir, "memories")
    }

    io =
      start_supervised!(
        {ChildIO,
         opts ++
           [
             config: config,
             identity: identity,
             transcript_path: path,
             backplane_store_path: Path.join(dir, "runtime")
           ]}
      )

    %{
      io: io,
      identity: identity,
      path: path,
      release: release,
      completed: completed,
      started: started,
      submit_path: submit_path,
      reject: reject
    }
  end

  defp prepare!(child, identity) do
    assert {:ok, prepared} =
             ChildIO.prepare(
               child.io,
               identity,
               %{caller: "root", run_id: "root-run", grants: ["update_plan"], tool_revision: 1},
               []
             )

    prepared
  end

  defp conversation!(prepared, id),
    do: start_supervised!(Supervisor.child_spec({Conversation, prepared.options}, id: id))

  defp plan_call,
    do: %{
      type: :tool_call,
      id: "child-plan",
      name: "update_plan",
      arguments: %{"plan" => [%{"step" => "child step", "status" => "completed"}]}
    }

  defp terminal!(conversation),
    do: await!(fn -> Conversation.status(conversation).phase == :terminal end)

  defp await_file!(path), do: await!(fn -> File.exists?(path) end)
  defp await_feedback!(path, fact), do: await!(fn -> feedback?(path, fact) end)

  defp feedback?(path, fact) do
    feedback_count(path, fact) > 0
  end

  defp feedback_count(path, fact) do
    case Sigma.Session.Storage.JsonlFile.read(path) do
      {:ok, entries} ->
        Enum.count(entries, &(&1["type"] == "hook_feedback" and &1["event"]["fact"] == fact))

      _ ->
        0
    end
  end

  defp await_steering!(conversation),
    do: await!(fn -> Conversation.status(conversation).conversation.steering != [] end)

  defp submissions(child) do
    child.submit_path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  defp await!(predicate, attempts \\ 500)
  defp await!(_predicate, 0), do: flunk("child hook boundary did not settle")

  defp await!(predicate, attempts) do
    if predicate.(),
      do: :ok,
      else:
        (
          Process.sleep(10)
          await!(predicate, attempts - 1)
        )
  end
end
