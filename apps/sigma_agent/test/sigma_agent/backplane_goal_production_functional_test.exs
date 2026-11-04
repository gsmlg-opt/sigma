defmodule Sigma.Agent.BackplaneGoalProductionFunctionalTest do
  use ExUnit.Case, async: false

  alias Sigma.Agent.{Runtime, Subagents}
  alias Sigma.Agent.Backplane.{ChildIO, GoalDescendants, GoalStore, Store}
  alias Sigma.Session.{Log, Writer}

  @moduletag :tmp_dir
  @moduletag :goal_production_functional
  @session "goal-production"

  defmodule Provider do
    @behaviour Sigma.Ai.Provider

    def output_token_limit(_model, _options), do: 2_000

    def stream(params) do
      send(params.options[:test_pid], {:goal_provider, self(), params})

      receive do
        {:goal_response, content} ->
          reason = if Enum.any?(content, &(&1.type == :tool_call)), do: :tool_use, else: :stop

          message = %{
            role: :assistant,
            content: content,
            stop_reason: reason,
            usage: %{input: 15, cache_read: 5, output: 3, total_tokens: 18},
            model: "goal-functional",
            provider: "goal-functional",
            api: "openai-responses",
            timestamp: System.system_time(:millisecond)
          }

          [{:start, %{message | content: []}}, {:done, reason, message}]
      end
    end
  end

  setup %{tmp_dir: dir} do
    path = Path.join(dir, "root.jsonl")

    assert {:ok, handle} =
             Runtime.get_session(dir, @session,
               cwd: dir,
               transcript_path: path,
               native_tools: true,
               native_memory_root: Path.join(dir, "memories"),
               provider: Provider,
               model: %{
                 id: "goal-functional",
                 provider: "goal-functional",
                 api: "openai-responses",
                 context_window: 200_000
               },
               tools: [],
               hook_specs: [],
               permission_config: %{default: :allow, rules: %{}},
               options: [test_pid: self()]
             )

    assert :ok = Sigma.Agent.subscribe(handle.agent)

    on_exit(fn ->
      case Runtime.lookup(dir, :supervisor) do
        nil -> :ok
        pid -> DynamicSupervisor.terminate_child(Sigma.Agent.DynamicSupervisor, pid)
      end
    end)

    %{
      dir: dir,
      path: path,
      agent: handle.agent,
      writer: Runtime.lookup(dir, @session, :writer),
      host: Runtime.lookup(dir, @session, :subagents)
    }
  end

  test "ordinary root Engine exposes durable Goal3 and preserves the exact requesting user", c do
    original = "  创建目标：完成真实工作\r\n保留原文\n"
    root = prompt!(c.agent, original)
    assert Enum.all?(~w(get_goal create_goal update_goal), &(&1 in names(root)))
    root = call!(root, "get_goal", %{})
    refute result!(root, "get_goal").is_error
    assert structured!(root, "get_goal")["goal"] == nil
    root = create!(root)
    root = call!(root, "get_goal", %{})
    refute result!(root, "get_goal").is_error
    assert structured!(root, "get_goal")["goal"]["status"] == "active"
    root = complete!(root)
    finish!(root, c)

    assert {:ok, %{goal: %{status: :complete, objective: "Finish the actual requested work"}}} =
             Sigma.Agent.goal(c.agent)

    assert {:ok, _} = Writer.flush(c.writer)
    assert {:ok, selected} = Writer.selected_journal(c.writer)
    [%{"id" => thread}] = Enum.filter(selected.entries, &(&1["type"] == "session"))
    root_dir = Path.join(c.path <> ".subagents", "goal")
    assert {:ok, goal_store} = GoalStore.open(path: root_dir)

    assert {:ok, %{thread_id: ^thread, goal: %{status: :complete}}} =
             GoalStore.load(goal_store, thread)

    assert {:ok, snapshot} = Log.snapshot(c.path)
    assert Enum.count(snapshot.messages, &(&1.role == :user and &1.content == original)) == 1

    assert Enum.count(
             snapshot.messages,
             &(&1.role == :tool_result and &1.tool_name == "create_goal")
           ) == 1

    refute_receive {:goal_provider, _, _}, 100
  end

  test "an active Goal starts a new ordinary run and completion stops further continuations", c do
    root = c.agent |> prompt!("Create a Goal and continue the requested work") |> create!()
    first_run = root.params.turn_id
    finish!(root, c)
    automatic = provider!(@session)
    refute automatic.params.turn_id == first_run

    assert Enum.any?(automatic.params.context.messages, fn message ->
             message.role == :user and get_in(message, [:metadata, :goal_continuation]) == true
           end)

    automatic = automatic |> call!("get_goal", %{}) |> complete!()
    finish!(automatic, c)
    assert {:ok, %{goal: %{status: :complete}}} = Sigma.Agent.goal(c.agent)
    assert {:ok, _} = Writer.flush(c.writer)
    assert {:ok, snapshot} = Log.snapshot(c.path)

    automatic_users =
      Enum.filter(
        snapshot.messages,
        &(&1.role == :user and &1.metadata["goal_continuation"] == true)
      )

    assert length(automatic_users) == 1
    assert hd(automatic_users).content =~ "Finish the actual requested work"
    refute_receive {:goal_provider, _, _}, 100
  end

  test "a real prompt resumes the same Goal after an automatic pre-Runtime preparation failure",
       c do
    root = c.agent |> prompt!("Create a Goal and continue the requested work") |> create!()
    assert {:ok, %{goal: %{thread_id: thread_id}}} = Sigma.Agent.goal(c.agent)
    model = %{id: "goal-functional", provider: "goal-functional", api: "openai-responses"}

    assert :ok =
             Sigma.Agent.set_provider(c.agent, Provider, model,
               test_pid: self(),
               hosted_web_search: %{supported: true, enabled: true}
             )

    finish!(root, c)
    assert_receive {:turn_failed, automatic_id}, 8_000
    assert_receive {:turn_error, error}, 8_000
    assert error.message =~ "provider-hosted"
    assert_receive {:agent_end, _}, 8_000
    refute_receive {:goal_provider, _, _}, 0
    assert {:ok, store} = Store.open(path: c.path <> ".runtime")

    assert {:error, %Backplane.AgentRuntime.Error{class: :not_found}} =
             Store.load(store, automatic_id)

    settled = settled_preparation!(c, thread_id, automatic_id)
    assert settled.goal.status == :active
    assert settled.continuation_deferral == nil

    assert :ok = Sigma.Agent.set_provider(c.agent, Provider, model, test_pid: self())
    root = prompt!(c.agent, "Continue the same Goal after correcting the Provider configuration")
    refute root.params.turn_id == automatic_id
    root = call!(root, "get_goal", %{})
    assert structured!(root, "get_goal")["goal"]["thread_id"] == thread_id

    assert structured!(root, "get_goal")["goal"]["objective"] ==
             "Finish the actual requested work"

    root = complete!(root)
    finish!(root, c)
    assert {:ok, %{goal: %{status: :complete, thread_id: ^thread_id}}} = Sigma.Agent.goal(c.agent)
    refute_receive {:goal_provider, _, _}, 100
  end

  test "a released configuration failure settles after executor exit and permits the next automatic admission",
       c do
    root = c.agent |> prompt!("Continue the requested Goal automatically") |> create!()
    assert {:ok, %{goal: %{thread_id: thread_id}}} = Sigma.Agent.goal(c.agent)
    model = %{id: "goal-functional", provider: "goal-functional", api: "openai-responses"}

    assert :ok =
             Sigma.Agent.set_provider(c.agent, Provider, model,
               test_pid: self(),
               hosted_web_search: %{supported: true, enabled: true}
             )

    finish!(root, c)
    assert_receive {:turn_failed, failed_run}, 8_000
    assert_receive {:turn_error, error}, 8_000
    assert error.message =~ "provider-hosted"
    assert_receive {:agent_end, _}, 8_000
    settled = settled_preparation!(c, thread_id, failed_run)
    assert {:ok, store} = Store.open(path: c.path <> ".runtime")
    assert {:error, %{class: :not_found}} = Store.load(store, failed_run)
    refute_receive {:goal_provider, _, _}, 50

    # A real user mutation resumes this same active Goal through ordinary
    # two-phase idle admission, without a replacement prompt or Goal.restore.
    assert :ok = Sigma.Agent.set_provider(c.agent, Provider, model, test_pid: self())

    assert {:ok, %{goal: %{status: :active, thread_id: ^thread_id}}} =
             Sigma.Agent.set_goal(c.agent, %{status: :active}, %{
               text: "Continue after fixing config"
             })

    automatic = provider!(@session)
    refute automatic.params.turn_id == failed_run

    assert Enum.any?(
             automatic.params.context.messages,
             &get_in(&1, [:metadata, :goal_continuation])
           )

    automatic = automatic |> call!("get_goal", %{}) |> complete!()
    finish!(automatic, c)
    assert {:ok, %{goal: %{status: :complete, thread_id: ^thread_id}}} = Sigma.Agent.goal(c.agent)
    assert {:ok, goal_store} = GoalStore.open(path: Path.join(c.path <> ".subagents", "goal"))
    assert {:ok, final} = GoalStore.load(goal_store, thread_id)
    assert final.admission_settlements == settled.admission_settlements
    refute_receive {:goal_provider, _, _}, 50
  end

  test "real Deno Goal3 uses the current root binding and persists the exact completed Goal", c do
    root = prompt!(c.agent, "Create, inspect and complete the requested Goal through Code Mode")

    root =
      call!(root, "exec", """
      const created = await tools.create_goal({objective:"Finish the actual requested work"});
      const current = await tools.get_goal({});
      const completed = await tools.update_goal({status:"complete"});
      return {created,current,completed};
      """)

    refute result!(root, "exec").is_error
    nested = structured!(root, "exec")
    assert nested["status"] == "completed"
    assert nested["value"]["created"]["goal"]["status"] == "active"
    assert nested["value"]["current"]["goal"] == nested["value"]["created"]["goal"]
    assert nested["value"]["completed"]["goal"]["status"] == "complete"
    thread = nested["value"]["completed"]["goal"]["thread_id"]
    assert is_binary(thread)
    root = call!(root, "get_goal", %{})
    assert structured!(root, "get_goal")["goal"]["thread_id"] == thread
    assert structured!(root, "get_goal")["goal"]["status"] == "complete"
    finish!(root, c)
    assert {:ok, %{goal: %{thread_id: ^thread, status: :complete}}} = Sigma.Agent.goal(c.agent)
    assert {:ok, _} = Writer.flush(c.writer)
    assert {:ok, goal_store} = GoalStore.open(path: Path.join(c.path <> ".subagents", "goal"))

    assert {:ok, %{goal: %{thread_id: ^thread, status: :complete, goal_id: goal_id}}} =
             GoalStore.load(goal_store, thread)

    assert is_binary(goal_id)
    assert {:ok, snapshot} = Log.snapshot(c.path)

    nested_result =
      Enum.find(snapshot.messages, &(&1.role == :tool_result and &1.tool_name == "exec"))

    assert nested_result
    assert [%{type: :text, text: json}] = nested_result.content
    assert Jason.decode!(json) == nested
    refute_receive {:goal_provider, _, _}, 100
  end

  test "actual managed-child usage contributes to the root Goal without exposing root Goal3", c do
    root = c.agent |> prompt!("Create a Goal and ask a child to do ordinary work") |> create!()

    send_call(root, "spawn_agent", %{
      "task_name" => "contributor",
      "message" => "Do ordinary child work",
      "fork_turns" => "none"
    })

    child = provider!(:child)
    root = provider!(@session)
    refute result!(root, "spawn_agent").is_error
    refute Enum.any?(~w(get_goal create_goal update_goal), &(&1 in names(child)))
    assert {:ok, %{goal: %{tokens_used: before}}} = Sigma.Agent.goal(c.agent)
    finish!(child, c)
    assert {:ok, %{goal: %{tokens_used: after_child}}} = Sigma.Agent.goal(c.agent)
    assert after_child == before + 13

    assert {:ok, sources} = Subagents.archive_sources(c.host)

    source =
      Enum.find(sources.children, &(&1.identity.child_session_id == child.params.session_id))

    assert source
    assert {:ok, archive} = ChildIO.archive_source(source.io)
    assert {:ok, _} = Writer.flush(archive.writer)
    root = complete!(root)
    finish!(root, c)
    refute_receive {:goal_provider, _, _}, 100
  end

  test "host Goal instructions are durably recorded verbatim before ordinary automatic admission",
       c do
    original = "  按原文继续\r\n第一行\n"

    assert {:ok, %{goal: %{status: :active}}} =
             Sigma.Agent.set_goal(c.agent, %{objective: "Finish the actual requested work"}, %{
               text: original
             })

    automatic = provider!(@session)

    assert Enum.count(automatic.params.context.messages, fn message ->
             message.role == :user and message.content == original
           end) == 1

    automatic = complete!(automatic)
    finish!(automatic, c)
    assert {:ok, _} = Writer.flush(c.writer)
    assert {:ok, snapshot} = Log.snapshot(c.path)

    assert [recorded] =
             Enum.filter(snapshot.messages, &(&1.role == :user and &1.content == original))

    assert recorded.metadata["goal_instruction"] == true
    refute_receive {:goal_provider, _, _}, 100
  end

  test "a real running child without Goal receipts requires no Goal binding or settlement", c do
    root = prompt!(c.agent, "Ask a child to perform ordinary work without creating a Goal")

    send_call(root, "spawn_agent", %{
      "task_name" => "ordinary_contributor",
      "message" => "Do ordinary child work without a Goal",
      "fork_turns" => "none"
    })

    child = provider!(:child)
    root = provider!(@session)
    refute result!(root, "spawn_agent").is_error
    assert {:ok, %{admissions: admissions}} = Writer.subagent_state(c.writer)

    admission =
      Enum.find_value(admissions, fn {_id, admission} ->
        if admission.intent.child_session_id == child.params.session_id and
             admission.intent.run_id == child.params.turn_id,
           do: admission
      end)

    assert admission
    assert admission.intent.child_session_id == child.params.session_id
    assert Enum.any?(admission.receipts, & &1.process_started)
    runtime_id = admission.intent.metadata["runtime_run_id"]
    assert is_binary(runtime_id)
    path = Path.join([c.path <> ".subagents", child.params.session_id, "runtime"])
    assert {:error, {:already_started, store}} = Store.start_link(path: path)
    assert {:ok, snapshot} = Store.load(store, runtime_id)
    assert snapshot.run.state == :running
    assert get_in(snapshot, [:run, :context, :conversation, :goal_outbox]) in [nil, []]
    assert {:ok, []} = GoalDescendants.load(c.writer, c.path, [], nil)
    assert {:ok, ^snapshot} = Store.load(store, runtime_id)
    finish!(child, c)
    finish!(root, c)
    assert {:ok, %{goal: nil}} = Sigma.Agent.goal(c.agent)
    refute_receive {:goal_provider, _, _}, 100
  end

  test "public Goal empty-turn audits stop three empty automatic runs", c do
    root = c.agent |> prompt!("Create a Goal and retain its full objective") |> create!()
    finish!(root, c, [])

    for _ <- 1..3 do
      automatic = provider!(@session)
      finish!(automatic, c, [])
    end

    assert {:ok, %{goal: %{status: :blocked, objective: "Finish the actual requested work"}}} =
             Sigma.Agent.goal(c.agent)

    refute_receive {:goal_provider, _, _}, 100
  end

  test "cancelling an actual automatic run defers the active Goal until a real user returns", c do
    root = c.agent |> prompt!("Create a Goal and continue ordinary work") |> create!()
    finish!(root, c)
    automatic = provider!(@session)
    assert {:cancelling, run_id} = Sigma.Agent.cancel(c.agent)
    assert run_id == automatic.params.turn_id
    assert_receive {:agent_end, _}, 8_000
    assert {:ok, %{goal: %{status: :active}}} = Sigma.Agent.goal(c.agent)
    refute_receive {:goal_provider, _, _}, 100

    root = prompt!(c.agent, "Resume the same Goal and complete the requested work")
    root = complete!(root)
    finish!(root, c)
    assert {:ok, %{goal: %{status: :complete}}} = Sigma.Agent.goal(c.agent)
    refute_receive {:goal_provider, _, _}, 100
  end

  defp settled_preparation!(c, thread_id, run_id) do
    assert {:ok, store} = GoalStore.open(path: Path.join(c.path <> ".subagents", "goal"))

    # agent_end must already join the coordinator's actual executor DOWN and
    # durable settlement; no polling may hide that cross-process ordering.
    assert {:ok, record} = GoalStore.load(store, thread_id)
    assert map_size(record.admission_settlements) == 1
    [receipt] = Map.values(record.admission_settlements)
    assert receipt.admission.run_id == run_id
    assert receipt.reason == :preparation_failed
    assert receipt.response == {:settled, :preparation_failed}

    assert receipt.attestation == %{
             admission: receipt.admission,
             executor: :confirmed_down,
             runtime_admission: :never_started,
             future_start: :fenced,
             effects: :none_dispatched
           }

    record
  end

  defp prompt!(agent, content) do
    assert {:accepted, _} = Sigma.Agent.prompt(agent, content)
    provider!(@session)
  end

  defp create!(provider) do
    provider =
      call!(provider, "create_goal", %{"objective" => "Finish the actual requested work"})

    refute result!(provider, "create_goal").is_error
    assert structured!(provider, "create_goal")["goal"]["status"] == "active"
    provider
  end

  defp complete!(provider) do
    provider = call!(provider, "update_goal", %{"status" => "complete"})
    refute result!(provider, "update_goal").is_error
    assert structured!(provider, "update_goal")["goal"]["status"] == "complete"
    provider
  end

  defp provider!(session) do
    receive do
      {:goal_provider, pid, %{session_id: "child_" <> _} = params} when session == :child ->
        %{pid: pid, params: params}

      {:goal_provider, pid, %{session_id: ^session} = params} ->
        %{pid: pid, params: params}

      {:turn_error, error} ->
        flunk("ordinary Goal Engine failed: #{inspect(error)}")
    after
      8_000 -> flunk("ordinary Goal Provider did not start for #{session}")
    end
  end

  defp call!(provider, name, arguments) do
    send_call(provider, name, arguments)
    provider!(provider.params.session_id)
  end

  defp send_call(provider, name, arguments) do
    send(
      provider.pid,
      {:goal_response,
       [
         %{
           type: :tool_call,
           id: "goal-#{System.unique_integer([:positive])}",
           name: name,
           arguments: arguments,
           input_kind: if(is_binary(arguments), do: :custom, else: :function)
         }
       ]}
    )
  end

  defp result!(provider, name) do
    Enum.find(Enum.reverse(provider.params.context.messages), &(&1[:tool_name] == name)) ||
      flunk("missing #{name} result in the actual Provider context")
  end

  defp structured!(provider, name) do
    result = result!(provider, name)
    assert [%{type: :text, text: json}] = result.content
    Jason.decode!(json)
  end

  defp names(provider), do: Enum.map(provider.params.context.tools, & &1.name)

  defp finish!(provider, c, content \\ [%{type: :text, text: "ordinary work complete"}]) do
    send(provider.pid, {:goal_response, content})

    case provider.params.session_id do
      "child_" <> _ = child ->
        assert eventually(fn ->
                 assert {:ok, %{subagents: roster}} = Subagents.snapshot(c.host)

                 Enum.any?(
                   roster.agents,
                   &(&1.child_session_id == child and
                       &1.run_id == provider.params.turn_id and &1.status == :completed)
                 )
               end)

      @session ->
        assert_receive {:agent_end, _}, 8_000
    end
  end

  defp eventually(fun, attempts \\ 400)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end
end
