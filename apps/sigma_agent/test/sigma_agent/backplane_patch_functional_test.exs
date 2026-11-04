defmodule Sigma.Agent.BackplanePatchFunctionalTest do
  use ExUnit.Case, async: false

  alias Sigma.Agent.{Runtime, Subagents}
  alias Sigma.Session.Log

  @moduletag :tmp_dir

  defmodule Provider do
    @behaviour Sigma.Ai.Provider

    def stream(params) do
      send(params.options[:test_pid], {:patch_provider, self(), params})

      receive do
        {:patch_response, content} ->
          reason = if Enum.any?(content, &(&1.type == :tool_call)), do: :tool_use, else: :stop

          message = %{
            role: :assistant,
            content: content,
            stop_reason: reason,
            usage: %{input: 1, output: 1, total_tokens: 2},
            model: "test",
            provider: "test",
            api: "openai-responses",
            timestamp: System.system_time(:millisecond)
          }

          [{:start, %{message | content: []}}, {:done, reason, message}]
      end
    end
  end

  setup %{tmp_dir: dir} do
    on_exit(fn -> stop_repository(dir) end)
    %{dir: dir, path: Path.join(dir, "patch-root.jsonl")}
  end

  test "root multioperation raw patch retains complete results and recreates without replay", c do
    patch = fixture_patch!(c.dir, "root")
    agent = session!(c)
    root = prompt!(agent)
    assert Enum.any?(root.params.context.tools, &(&1.name == "apply_patch"))
    root = call!(root, "apply_patch", patch)
    expected = expected_files(c.dir, "root")
    result = structured!(root, "apply_patch")
    assert result["status"] == "applied"
    assert result["files"] == expected
    assert canonical_result!(agent, "apply_patch") == result
    assert_raw!(root.params.context.messages, patch)
    assert_effects!(c.dir, "root")
    finish_root!(agent, root)

    assert {:ok, saved} = Log.snapshot(c.path)
    assert_raw!(saved.messages, patch)
    assert saved_result!(saved.messages, "apply_patch") == result

    # A subsequent user edit must survive reconstruction of the original tool history.
    target = Path.join(c.dir, "root-added.txt")
    File.write!(target, "user edit after patch\n")
    before = File.stat!(target, time: :posix)
    stop_repository(c.dir)
    restored = session!(c)
    assert File.read!(target) == "user edit after patch\n"
    root = prompt!(restored)
    assert structured!(root, "apply_patch") == result
    assert_raw!(root.params.context.messages, patch)
    assert File.read!(target) == "user edit after patch\n"
    assert File.stat!(target, time: :posix).mtime == before.mtime
    assert File.read!(Path.join(c.dir, "root-after.txt")) == "moved 中文\n"
    finish_root!(restored, root)
    assert {:ok, reopened} = Log.snapshot(c.path)

    assert length(Enum.filter(reopened.messages, &(Map.get(&1, :tool_name) == "apply_patch"))) ==
             1
  end

  @tag timeout: 60_000
  test "root real Deno dispatch preserves the complete native patch result", c do
    assert is_binary(System.find_executable("deno"))
    patch = fixture_patch!(c.dir, "nested-root")
    agent = session!(c)
    root = prompt!(agent)
    root = call!(root, "exec", "return await tools.apply_patch(#{Jason.encode!(patch)});")
    result = structured!(root, "exec")
    assert result["status"] == "completed"

    assert result["value"] == %{
             "status" => "applied",
             "files" => expected_files(c.dir, "nested-root")
           }

    assert canonical_result!(agent, "exec") == result
    assert_effects!(c.dir, "nested-root")
    finish_root!(agent, root)
    assert {:ok, saved} = Log.snapshot(c.path)
    assert saved_result!(saved.messages, "exec") == result
  end

  @tag timeout: 60_000
  test "managed child applies raw and real nested patches and retains results on followup", c do
    assert is_binary(System.find_executable("deno"))
    patch = fixture_patch!(c.dir, "child")
    agent = session!(c)
    host = Runtime.lookup(c.dir, "patch-root", :subagents)
    root = prompt!(agent)

    send_call(root, "spawn_agent", %{
      "task_name" => "patcher",
      "message" => "work",
      "fork_turns" => "none"
    })

    child = provider!(:child)
    root = provider!("patch-root")
    refute result!(root, "spawn_agent").is_error
    assert Enum.any?(child.params.context.tools, &(&1.name == "apply_patch"))

    child = call!(child, "apply_patch", patch)
    direct = structured!(child, "apply_patch")
    assert direct["status"] == "applied"
    assert direct["files"] == expected_files(c.dir, "child")
    assert_raw!(child.params.context.messages, patch)
    assert_effects!(c.dir, "child")

    nested_patch = "*** Begin Patch\n*** Add File: child-nested.txt\n+nested 中文\n*** End Patch"
    code = "return await tools.apply_patch(#{Jason.encode!(nested_patch)});"
    child = call!(child, "exec", code)
    nested = structured!(child, "exec")

    assert nested["status"] == "completed"

    assert nested["value"] == %{
             "status" => "applied",
             "files" => [%{"path" => Path.join(c.dir, "child-nested.txt"), "action" => "added"}]
           }

    assert File.read!(Path.join(c.dir, "child-nested.txt")) == "nested 中文\n"
    finish!(child)
    assert eventually(fn -> roster(host).counts.stopped == 1 end)
    [row] = roster(host).agents
    path = Path.join([c.path <> ".subagents", row.child_session_id, "session.jsonl"])
    assert {:ok, saved} = Log.snapshot(path)
    assert_raw!(saved.messages, patch)
    assert saved_result!(saved.messages, "apply_patch") == direct
    assert saved_result!(saved.messages, "exec") == nested

    target = Path.join(c.dir, "child-nested.txt")
    File.write!(target, "edited after child\n")
    before = File.stat!(target, time: :posix)
    send_call(root, "followup_task", %{"target" => "/root/patcher", "message" => "continue"})
    next = provider!(child.params.session_id)
    root = provider!("patch-root")
    assert structured!(next, "apply_patch") == direct
    assert structured!(next, "exec") == nested
    assert_raw!(next.params.context.messages, patch)
    assert File.read!(target) == "edited after child\n"
    assert File.stat!(target, time: :posix).mtime == before.mtime
    finish!(next)
    assert eventually(fn -> roster(host).counts.stopped == 1 end)
    finish_root!(agent, root)
  end

  defp fixture_patch!(dir, prefix) do
    File.write!(Path.join(dir, prefix <> "-updated.txt"), "before\n")
    File.write!(Path.join(dir, prefix <> "-before.txt"), "move before\n")
    File.write!(Path.join(dir, prefix <> "-deleted.txt"), "remove\n")

    """
    *** Begin Patch
    *** Add File: #{prefix}-added.txt
    +中文 "raw" {json}
    *** Update File: #{prefix}-updated.txt
    @@
    -before
    +after 中文
    *** Update File: #{prefix}-before.txt
    *** Move to: #{prefix}-after.txt
    @@
    -move before
    +moved 中文
    *** Delete File: #{prefix}-deleted.txt
    *** End Patch
    """
  end

  defp expected_files(dir, prefix) do
    [
      %{"path" => Path.join(dir, prefix <> "-added.txt"), "action" => "added"},
      %{"path" => Path.join(dir, prefix <> "-updated.txt"), "action" => "updated"},
      %{
        "from" => Path.join(dir, prefix <> "-before.txt"),
        "path" => Path.join(dir, prefix <> "-after.txt"),
        "action" => "moved"
      },
      %{"path" => Path.join(dir, prefix <> "-deleted.txt"), "action" => "deleted"}
    ]
  end

  defp assert_effects!(dir, prefix) do
    assert File.read!(Path.join(dir, prefix <> "-added.txt")) == "中文 \"raw\" {json}\n"
    assert File.read!(Path.join(dir, prefix <> "-updated.txt")) == "after 中文\n"
    assert File.read!(Path.join(dir, prefix <> "-after.txt")) == "moved 中文\n"
    refute File.exists?(Path.join(dir, prefix <> "-before.txt"))
    refute File.exists?(Path.join(dir, prefix <> "-deleted.txt"))
  end

  defp session!(c) do
    # Runtime callers supply the saved projection, as the Web/Protocol resume
    # hosts do; a transcript path alone only connects the durable Writer.
    assert {:ok, snapshot} = Log.snapshot(c.path)

    assert {:ok, handle} =
             Runtime.get_session(c.dir, "patch-root",
               cwd: c.dir,
               transcript_path: c.path,
               provider: Provider,
               model: %{id: "test", provider: "test", api: "openai-responses"},
               native_tools: true,
               native_memory_root: Path.join(c.dir, "memories"),
               tools: [],
               messages: snapshot.messages,
               context_messages: snapshot.context_messages,
               context_window: snapshot.context_window,
               active_leaf: snapshot.active_leaf_id,
               context_revision: length(snapshot.branch_entry_ids),
               context_source: :journal_replay,
               hook_specs: [],
               options: [test_pid: self()]
             )

    :ok = Sigma.Agent.subscribe(handle.agent)
    handle.agent
  end

  defp stop_repository(dir) do
    case Runtime.lookup(dir, :supervisor) do
      nil -> :ok
      pid -> DynamicSupervisor.terminate_child(Sigma.Agent.DynamicSupervisor, pid)
    end
  end

  defp prompt!(agent) do
    assert {:accepted, _} = Sigma.Agent.prompt(agent, "Apply the requested patch")
    provider!("patch-root")
  end

  defp provider!(session) do
    receive do
      {:patch_provider, pid, %{session_id: "child_" <> _} = params} when session == :child ->
        %{pid: pid, params: params}

      {:patch_provider, pid, %{session_id: id} = params} when id == session ->
        %{pid: pid, params: params}

      {:turn_error, error} ->
        flunk("root failed: #{inspect(error)}")
    after
      10_000 -> flunk("provider did not start for #{session}")
    end
  end

  defp send_call(provider, name, arguments) do
    send(
      provider.pid,
      {:patch_response,
       [
         %{
           type: :tool_call,
           id: "patch-#{System.unique_integer([:positive])}",
           name: name,
           arguments: arguments,
           input_kind: if(is_binary(arguments), do: :custom, else: :function)
         }
       ]}
    )
  end

  defp call!(provider, name, arguments) do
    send_call(provider, name, arguments)
    provider!(provider.params.session_id)
  end

  defp result!(provider, name) do
    result =
      Enum.find(
        Enum.reverse(provider.params.context.messages),
        &(Map.get(&1, :tool_name) == name)
      )

    assert result, "missing #{name} result in next Provider request"
    refute result.is_error
    result
  end

  defp structured!(provider, name) do
    assert [%{type: :text, text: json}] = result!(provider, name).content
    Jason.decode!(json)
  end

  defp canonical_result!(agent, name) do
    result =
      Enum.find(Enum.reverse(Sigma.Agent.messages(agent)), &(Map.get(&1, :tool_name) == name))

    refute result.is_error
    result.metadata.structured_result
  end

  defp saved_result!(messages, name) do
    result = Enum.find(Enum.reverse(messages), &(Map.get(&1, :tool_name) == name))
    result.metadata["structured_result"]
  end

  defp assert_raw!(messages, patch) do
    assert Enum.any?(messages, fn
             %{role: :assistant, content: content} when is_list(content) ->
               Enum.any?(
                 content,
                 &match?(
                   %{
                     type: :tool_call,
                     name: "apply_patch",
                     arguments: ^patch,
                     input_kind: :custom
                   },
                   &1
                 )
               )

             _ ->
               false
           end)
  end

  defp finish!(provider),
    do: send(provider.pid, {:patch_response, [%{type: :text, text: "done"}]})

  defp finish_root!(agent, provider) do
    finish!(provider)
    assert_receive {:agent_end, _}, 10_000
    assert Sigma.Agent.status(agent).phase == :completed
  end

  defp roster(host) do
    assert {:ok, %{available: true, subagents: roster}} = Subagents.snapshot(host)
    roster
  end

  defp eventually(fun, retries \\ 200)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, retries) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, retries - 1)
    end
  end
end
