defmodule Sigma.Agent.BackplaneChildArchivesFunctionalTest do
  use ExUnit.Case, async: false

  alias Sigma.Agent.{Runtime, Subagents}
  alias Sigma.Agent.Backplane.{ChildArchives, ChildIO, LifetimeRecovery, Store}
  alias Sigma.Session.Log

  @moduletag :tmp_dir

  defmodule Provider do
    @behaviour Sigma.Ai.Provider
    def output_token_limit(_, _), do: 2_000

    def stream(params) do
      send(params.options[:test_pid], {:archive_provider, self(), params})

      receive do
        {:archive_response, content} ->
          reason = if Enum.any?(content, &(&1.type == :tool_call)), do: :tool_use, else: :stop

          message = %{
            role: :assistant,
            content: content,
            stop_reason: reason,
            usage: params.options[:archive_usage] || %{input: 1, output: 1, total_tokens: 2},
            model: "archive-test",
            provider: "archive-test",
            api: "openai-responses",
            timestamp: System.system_time(:millisecond)
          }

          [{:start, %{message | content: []}}, {:done, reason, message}]
      end
    end
  end

  test "normal child archives survive Runtime rename without replay or an old Store directory", %{
    tmp_dir: dir
  } do
    assert is_binary(System.find_executable("deno"))
    repo = Path.join(dir, "repo")
    sessions = Path.join(repo, "sessions")
    path = Path.join(sessions, "source.jsonl")
    File.mkdir_p!(sessions)

    on_exit(fn ->
      if pid = Runtime.lookup(repo, :supervisor),
        do: DynamicSupervisor.terminate_child(Sigma.Agent.DynamicSupervisor, pid)
    end)

    {:ok, handle} = Runtime.get_session(repo, "source", options(repo, path))
    :ok = Sigma.Agent.subscribe(handle.agent)
    {:accepted, _} = Sigma.Agent.prompt(handle.agent, "Delegate")
    root = provider!("source")

    send_call(root, "spawn_agent", %{
      "task_name" => "archived",
      "message" => "Original task",
      "fork_turns" => "none"
    })

    child = provider!(:child)
    root = provider!("source")
    refute result!(root, "spawn_agent").is_error

    child =
      call!(child, "update_plan", %{
        "plan" => [%{"step" => "Preserved child plan", "status" => "completed"}]
      })

    refute result!(child, "update_plan").is_error
    child = completed_handle_error!(child)
    expired = result!(child, "write_stdin")
    assert expired.is_error
    assert value!(expired)["error"]["class"] == "not_found"

    child =
      call!(child, "exec", """
      const result = await tools.exec_command({
        cmd: "printf 'archive-command-once\\n' >> archive-command-marker; printf 'child-continued'"
      });
      return result.output;
      """)

    refute result!(child, "exec").is_error
    assert value!(result!(child, "exec"))["value"] == "child-continued"
    command_marker = Path.join(repo, "archive-command-marker")
    assert File.read!(command_marker) == "archive-command-once\n"
    marker = "Child history é 👩‍💻\r\n  whitespace\n"
    finish!(child, marker)
    host = Runtime.lookup(repo, "source", :subagents)
    assert eventually(fn -> stopped?(host) end)
    {:ok, %{subagents: %{agents: [before]}}} = Subagents.snapshot(host)
    child_path = Path.join([path <> ".subagents", before.child_session_id, "session.jsonl"])
    assert {:ok, original} = Log.snapshot(child_path)
    original_results = Enum.filter(original.messages, &(&1.role == :tool_result))

    assert Enum.find(original_results, &(&1.tool_call_id == expired.tool_call_id)).metadata[
             "structured_result"
           ] == value!(expired)

    finish!(root, "Root finished")
    assert eventually(fn -> Sigma.Agent.status(handle.agent).phase == :completed end)

    assert {:ok, %{session_id: "renamed"}} =
             Runtime.rename_session(repo, "source", "renamed", sessions)

    refute File.exists?(path <> ".subagents")
    target = Path.join(sessions, "renamed.jsonl")
    archive_path = Path.join(target <> ".subagents", "lifetime-recovery.etf")
    archives_before = File.read!(archive_path)
    {:ok, renamed} = Runtime.get_session(repo, "renamed", options(repo, target))
    :ok = Sigma.Agent.subscribe(renamed.agent)
    refute_receive {:archive_provider, _, _}, 20
    assert File.read!(archive_path) == archives_before
    {:accepted, _} = Sigma.Agent.prompt(renamed.agent, "Continue the original child")
    root = provider!("renamed")
    next_host = Runtime.lookup(repo, "renamed", :subagents)
    {:ok, %{subagents: %{agents: [restored_row]}}} = Subagents.snapshot(next_host)
    assert restored_row.agent_id == before.agent_id
    assert restored_row.run_id == before.run_id
    assert restored_row.child_session_id == before.child_session_id

    send_call(root, "followup_task", %{
      "target" => "/root/archived",
      "message" => "Continue after rename"
    })

    next = provider!(child.params.session_id)
    root = provider!("renamed")
    refute result!(root, "followup_task").is_error
    assert next.params.turn_id != child.params.turn_id

    assert Enum.any?(next.params.context.messages, &has_text?(&1, marker))

    assert Enum.any?(next.params.context.messages, &(Map.get(&1, :tool_name) == "update_plan"))
    assert result!(next, "write_stdin").is_error
    assert value!(result!(next, "write_stdin")) == value!(expired)
    assert File.read!(command_marker) == "archive-command-once\n"
    next_host = Runtime.lookup(repo, "renamed", :subagents)
    {:ok, %{subagents: %{agents: [after_row]}}} = Subagents.snapshot(next_host)
    assert after_row.agent_id == before.agent_id
    assert after_row.child_session_id == before.child_session_id

    assert {:ok, saved} =
             Log.snapshot(
               Path.join([target <> ".subagents", before.child_session_id, "session.jsonl"])
             )

    assert Enum.count(saved.messages, &(Map.get(&1, :tool_name) == "update_plan")) == 1
    assert Enum.filter(saved.messages, &(&1.role == :tool_result)) == original_results

    next =
      call!(next, "exec", """
      const result = await tools.exec_command({cmd: "printf 'archive-child-followup'"});
      return result.output;
      """)

    refute result!(next, "exec").is_error
    assert value!(result!(next, "exec"))["value"] == "archive-child-followup"
    assert File.read!(command_marker) == "archive-command-once\n"
    refute File.exists?(path <> ".subagents")
    finish!(next, "Continued")
    assert eventually(fn -> stopped?(next_host) end)
    finish!(root, "Finished again")
    assert eventually(fn -> Sigma.Agent.status(renamed.agent).phase == :completed end)
    assert {:ok, %{status: :confirmed}} = Sigma.Agent.retire_host(renamed.agent)
    refute File.exists?(path <> ".subagents")
  end

  test "Goal-accounted child archives survive rename and followup without stale Store receipts",
       %{
         tmp_dir: dir
       } do
    repo = Path.join(dir, "goal-repo")
    sessions = Path.join(repo, "sessions")
    path = Path.join(sessions, "goal-source.jsonl")
    File.mkdir_p!(sessions)

    on_exit(fn ->
      if pid = Runtime.lookup(repo, :supervisor),
        do: DynamicSupervisor.terminate_child(Sigma.Agent.DynamicSupervisor, pid)
    end)

    # A known billable charge requires an explicit cache count. Missing cache
    # usage remains unknown in the public Goal contract, rather than zero.
    goal_options =
      options(repo, path)
      |> Keyword.update!(:options, fn opts ->
        Keyword.put(opts, :archive_usage, %{input: 1, cache_read: 0, output: 1, total_tokens: 2})
      end)

    {:ok, handle} = Runtime.get_session(repo, "goal-source", goal_options)
    :ok = Sigma.Agent.subscribe(handle.agent)
    {:accepted, _} = Sigma.Agent.prompt(handle.agent, "Create a Goal and delegate its work")
    root = provider!("goal-source")
    objective = "Preserve accounted child work across the session rename"
    root = call!(root, "create_goal", %{"objective" => objective})
    refute result!(root, "create_goal").is_error

    send_call(root, "spawn_agent", %{
      "task_name" => "goal_child",
      "message" => "Do the delegated Goal work",
      "fork_turns" => "none"
    })

    root = provider!("goal-source")
    spawn_result = result!(root, "spawn_agent")
    refute spawn_result.is_error, inspect(spawn_result)
    child = provider!(:child)

    assert {:ok, %{goal: %{status: :active, tokens_used: before_child}}} =
             Sigma.Agent.goal(handle.agent)

    marker = "Goal child history é 👩‍💻\r\n  preserve all assistant metadata\n"
    finish!(child, marker)
    host = Runtime.lookup(repo, "goal-source", :subagents)
    assert eventually(fn -> stopped?(host) end)

    # Real child delivery must settle its usage and clear its public outbox
    # before retirement exports a Store-revision-pinned archive. Reopening
    # must not perform a later Goal ACK that invalidates that exact archive.
    assert {:ok, %{goal: %{tokens_used: after_child}}} = Sigma.Agent.goal(handle.agent)
    assert after_child == before_child + 2
    assert {:ok, sources} = Subagents.archive_sources(host)

    source =
      Enum.find(sources.children, &(&1.identity.child_session_id == child.params.session_id))

    assert source
    assert {:ok, child_store} = ChildIO.store(source.io)
    assert {:ok, accounted} = Store.load(child_store, source.identity.run_id)
    assert get_in(accounted, [:run, :context, :conversation, :goal_outbox]) == []
    assert {:ok, %{subagents: %{agents: [before]}}} = Subagents.snapshot(host)

    child_path = Path.join([path <> ".subagents", before.child_session_id, "session.jsonl"])
    assert {:ok, original} = Log.snapshot(child_path)
    original_assistants = Enum.filter(original.messages, &(&1.role == :assistant))
    assert Enum.any?(original_assistants, &has_text?(&1, marker))

    assert Enum.all?(original_assistants, fn message ->
             Enum.all?(
               ~w(timestamp usage provider model api stop_reason)a,
               &Map.has_key?(message, &1)
             )
           end)

    root = call!(root, "update_goal", %{"status" => "complete"})
    refute result!(root, "update_goal").is_error
    finish!(root, "Goal and delegated work completed")
    assert eventually(fn -> Sigma.Agent.status(handle.agent).phase == :completed end)

    assert {:ok, %{goal: %{status: :complete, tokens_used: settled_usage}}} =
             Sigma.Agent.goal(handle.agent)

    refute_receive {:archive_provider, _, _}, 20

    assert {:ok, %{session_id: "goal-renamed"}} =
             Runtime.rename_session(repo, "goal-source", "goal-renamed", sessions)

    refute File.exists?(path <> ".subagents")
    target = Path.join(sessions, "goal-renamed.jsonl")

    {:ok, renamed} =
      Runtime.get_session(
        repo,
        "goal-renamed",
        Keyword.put(goal_options, :transcript_path, target)
      )

    :ok = Sigma.Agent.subscribe(renamed.agent)

    assert {:ok, %{goal: %{status: :complete, tokens_used: ^settled_usage}}} =
             Sigma.Agent.goal(renamed.agent)

    refute_receive {:archive_provider, _, _}, 20

    {:accepted, _} = Sigma.Agent.prompt(renamed.agent, "Follow up on the original Goal child")
    root = provider!("goal-renamed")
    next_host = Runtime.lookup(repo, "goal-renamed", :subagents)
    assert {:ok, %{subagents: %{agents: [restored]}}} = Subagents.snapshot(next_host)
    assert restored.agent_id == before.agent_id
    assert restored.run_id == before.run_id
    assert restored.child_session_id == before.child_session_id

    send_call(root, "followup_task", %{
      "target" => "/root/goal_child",
      "message" => "Continue with the accounted history intact"
    })

    root = provider!("goal-renamed")
    followup_result = result!(root, "followup_task")
    refute followup_result.is_error, inspect(followup_result)
    next = provider!(child.params.session_id)
    assert next.params.turn_id != child.params.turn_id
    assert Enum.any?(next.params.context.messages, &has_text?(&1, marker))

    assert {:ok, continued} =
             Log.snapshot(
               Path.join([target <> ".subagents", before.child_session_id, "session.jsonl"])
             )

    assert Enum.take(
             Enum.filter(continued.messages, &(&1.role == :assistant)),
             length(original_assistants)
           ) == original_assistants

    finish!(next, "Goal child followup completed")
    assert eventually(fn -> stopped?(next_host) end)
    finish!(root, "Followup completed")
    assert eventually(fn -> Sigma.Agent.status(renamed.agent).phase == :completed end)
    assert {:ok, %{goal: %{status: :complete}}} = Sigma.Agent.goal(renamed.agent)
    assert {:ok, %{status: :confirmed}} = Sigma.Agent.retire_host(renamed.agent)
    refute File.exists?(path <> ".subagents")
    refute_receive {:archive_provider, _, _}, 20
  end

  test "ordinary repeated root turns retain the same child without an archive restore", %{
    tmp_dir: dir
  } do
    repo = Path.join(dir, "repeat")
    File.mkdir_p!(repo)
    path = Path.join(repo, "root.jsonl")

    on_exit(fn ->
      if pid = Runtime.lookup(repo, :supervisor),
        do: DynamicSupervisor.terminate_child(Sigma.Agent.DynamicSupervisor, pid)
    end)

    {:ok, handle} = Runtime.get_session(repo, "repeat", options(repo, path))
    :ok = Sigma.Agent.subscribe(handle.agent)
    {:accepted, _} = Sigma.Agent.prompt(handle.agent, "First root turn")
    root = provider!("repeat")

    send_call(root, "spawn_agent", %{
      "task_name" => "retained",
      "message" => "First child turn",
      "fork_turns" => "none"
    })

    child = provider!(:child)
    root = provider!("repeat")
    refute result!(root, "spawn_agent").is_error
    finish!(child, "Retained child history")
    host = Runtime.lookup(repo, "repeat", :subagents)
    assert eventually(fn -> stopped?(host) end)
    {:ok, %{subagents: %{agents: [before]}}} = Subagents.snapshot(host)
    finish!(root, "First root finished")
    assert eventually(fn -> Sigma.Agent.status(handle.agent).phase == :completed end)

    {:accepted, _} = Sigma.Agent.prompt(handle.agent, "Second root turn")
    root = provider!("repeat")

    send_call(root, "followup_task", %{
      "target" => "/root/retained",
      "message" => "Second child turn"
    })

    next = provider!(child.params.session_id)
    root = provider!("repeat")
    refute result!(root, "followup_task").is_error
    assert next.params.turn_id != child.params.turn_id

    assert Enum.any?(next.params.context.messages, &has_text?(&1, "Retained child history"))

    {:ok, %{subagents: %{agents: [after_row]}}} = Subagents.snapshot(host)
    assert after_row.agent_id == before.agent_id
    assert after_row.child_session_id == before.child_session_id
    finish!(next, "Second child finished")
    assert eventually(fn -> stopped?(host) end)
    finish!(root, "Second root finished")
    assert eventually(fn -> Sigma.Agent.status(handle.agent).phase == :completed end)
  end

  test "archive evidence selection never rewinds the durable public run", %{tmp_dir: dir} do
    transcript = Path.join(dir, "root.jsonl")
    {:ok, writer} = LifetimeRecovery.start_link(transcript: transcript, root_header_id: "header")
    Process.unlink(writer)
    on_exit(fn -> if Process.alive?(writer), do: LifetimeRecovery.retire(writer) end)

    identity = %{
      attempt_id: "original-attempt",
      run_id: "original-run",
      name: "/root/child",
      run_incarnation: 1
    }

    metadata = %{
      backplane_store_path: Path.join(transcript <> ".subagents", "child/runtime"),
      host_retirement: %{host_lifetime: "host"}
    }

    {:ok, _} = LifetimeRecovery.admit(writer, identity, %{profile: :v2}, [], metadata, %{})

    # This tests evidence storage/selection only. Public export/restore and its
    # complete archive validation are exercised by the lifecycle test above.
    archive = %{
      "child_identity" => %{
        "attempt_id" => "original-attempt",
        "run_id" => "original-run",
        "name" => "/root/child",
        "run_incarnation" => 1
      },
      "host_metadata" => %{
        "sigma_identity" => %{"agent_id" => "public-child", "public_run_id" => "public-run"}
      },
      "messages" => [%{"role" => "assistant", "content" => "  é 👩‍💻\r\n"}]
    }

    assert :ok = ChildArchives.put_archive(writer, archive)
    path = Path.join(transcript <> ".subagents", "lifetime-recovery.etf")
    bytes = File.read!(path)
    assert :ok = ChildArchives.put_archive(writer, archive)
    assert File.read!(path) == bytes

    assert {:ok, %{"/root/child" => ^archive}} =
             ChildArchives.archives(writer, [%{agent_id: "public-child", run_id: "public-run"}])

    assert {:ok, %{}} =
             ChildArchives.archives(writer, [
               %{agent_id: "public-child", run_id: "later-failed-run"}
             ])

    assert File.read!(path) == bytes
    assert :ok = LifetimeRecovery.retire(writer)

    {:ok, reopened} =
      LifetimeRecovery.start_link(transcript: transcript, root_header_id: "header")

    Process.unlink(reopened)
    on_exit(fn -> if Process.alive?(reopened), do: LifetimeRecovery.retire(reopened) end)

    assert {:ok, %{"/root/child" => ^archive}} =
             ChildArchives.archives(reopened, [%{agent_id: "public-child", run_id: "public-run"}])

    assert File.read!(path) == bytes
  end

  defp has_text?(message, text) do
    case Map.get(message, :content) do
      content when is_binary(content) -> content == text
      blocks when is_list(blocks) -> Enum.any?(blocks, &(Map.get(&1, :text) == text))
      _ -> false
    end
  end

  defp completed_handle_error!(provider) do
    provider =
      call!(provider, "exec_command", %{
        "cmd" => "read line; printf '%s' \"$line\"",
        "yield_time_ms" => 20
      })

    started = result!(provider, "exec_command")
    refute started.is_error
    assert %{"status" => "running", "session_id" => handle} = value!(started)

    provider =
      call!(provider, "write_stdin", %{
        "session_id" => handle,
        "chars" => "archive-finished\n",
        "yield_time_ms" => 1_000
      })

    completed = result!(provider, "write_stdin")
    refute completed.is_error
    assert %{"exit_code" => 0, "output" => "archive-finished"} = value!(completed)
    call!(provider, "write_stdin", %{"session_id" => handle, "chars" => "unused\n"})
  end

  defp value!(message) do
    assert [%{type: :text, text: json}] = message.content
    Jason.decode!(json)
  end

  defp options(repo, path),
    do: [
      cwd: repo,
      transcript_path: path,
      provider: Provider,
      model: %{id: "archive-test", provider: "archive-test", api: "openai-responses"},
      native_tools: true,
      native_memory_root: Path.join(repo, "memories"),
      tools: [],
      hook_specs: [],
      options: [test_pid: self()]
    ]

  defp provider!(session) do
    receive do
      {:archive_provider, pid, %{session_id: "child_" <> _} = params} when session == :child ->
        %{pid: pid, params: params}

      {:archive_provider, pid, %{session_id: ^session} = params} ->
        %{pid: pid, params: params}

      {:turn_error, error} ->
        flunk("root failed: #{inspect(error)}")
    after
      8_000 -> flunk("Provider did not start for #{session}")
    end
  end

  defp call!(provider, name, arguments) do
    send_call(provider, name, arguments)
    provider!(provider.params.session_id)
  end

  defp send_call(provider, name, arguments),
    do:
      send(
        provider.pid,
        {:archive_response,
         [
           %{
             type: :tool_call,
             id: "archive-#{System.unique_integer([:positive])}",
             name: name,
             arguments: arguments,
             input_kind: if(is_binary(arguments), do: :custom, else: :function)
           }
         ]}
      )

  defp finish!(provider, text),
    do: send(provider.pid, {:archive_response, [%{type: :text, text: text}]})

  defp result!(provider, name),
    do:
      Enum.find(
        Enum.reverse(provider.params.context.messages),
        &(Map.get(&1, :tool_name) == name)
      ) || flunk("Missing #{name} result")

  defp stopped?(host) do
    match?({:ok, %{subagents: %{counts: %{stopped: 1}}}}, Subagents.snapshot(host))
  end

  defp eventually(fun, attempts \\ 300)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    if fun.(),
      do: true,
      else:
        (
          Process.sleep(10)
          eventually(fun, attempts - 1)
        )
  end
end
