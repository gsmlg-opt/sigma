defmodule Sigma.Agent.BackplaneHistoryNotesIntegrationTest do
  use ExUnit.Case, async: false

  alias Sigma.Agent.{Runtime, Subagents}
  alias Sigma.Agent.Backplane.NativeTools
  alias Sigma.Session.Log

  @moduletag :tmp_dir
  @root "archive-root"
  @archive ~w(history::list_windows history::list_items history::read_item history::search_contents notes::list_files_by_prefix notes::read_file notes::search_contents notes::append_to_file notes::write_file)

  defmodule Provider do
    @behaviour Sigma.Ai.Provider

    def stream(params) do
      send(params.options[:test_pid], {:archive_provider, self(), params})

      receive do
        {:archive_response, content} ->
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
    path = Path.join(dir, @root <> ".jsonl")
    memory_root = Path.join(dir, "memories")
    File.mkdir_p!(memory_root)

    on_exit(fn ->
      stop_repository(dir)
      stop_resource({:memory_resources, memory_root})
      stop_resource({:notes_resources, path})
    end)

    %{dir: dir, path: path, memory_root: memory_root}
  end

  test "root directly uses all nine archive tools with complete normalized results", c do
    agent = session!(c)
    root = prompt!(agent, "Root archive marker 中文")
    names = Enum.map(root.params.context.tools, & &1.name)
    assert Enum.sort(NativeTools.archive_names()) == Enum.sort(@archive)
    assert Enum.all?(@archive, &(&1 in names))

    text = "# Journal\r\n" <> String.duplicate("完整 中文 🧭 {json}\n", 90)
    root = call!(root, "notes::write_file", %{"path" => "journal.md", "text" => text})
    created = structured!(root, "notes::write_file")
    assert created["path"] == "/root/notes/journal.md"
    assert created["size_bytes"] == byte_size(text)

    suffix = "last matching line\n"
    root = call!(root, "notes::append_to_file", %{"path" => "journal.md", "text" => suffix})
    appended = structured!(root, "notes::append_to_file")
    assert appended["created_at"] == created["created_at"]
    assert appended["updated_at"] > created["updated_at"]
    assert appended["size_bytes"] == byte_size(text <> suffix)

    root = call!(root, "notes::read_file", %{"path" => "journal.md"})
    read = structured!(root, "notes::read_file")
    assert read["contents"] == text <> suffix
    assert read["n_lines"] == 92
    assert canonical_result!(agent, "notes::read_file") == read

    root = call!(root, "notes::list_files_by_prefix", %{"prefix" => "journal"})

    assert structured!(root, "notes::list_files_by_prefix")["files"] == [
             Map.delete(appended, "is_error")
           ]

    root = call!(root, "notes::search_contents", %{"query" => "last matching"})

    assert [%{"path" => "/root/notes/journal.md", "matches" => matches}] =
             structured!(root, "notes::search_contents")["files"]

    assert matches == [%{"line" => "last matching line", "line_number" => 92}]

    root = call!(root, "history::list_windows", %{})

    assert [%{"window_id" => window_id, "ordinal" => 1}] =
             structured!(root, "history::list_windows")["windows"]

    writer = Runtime.lookup(c.dir, @root, :writer)
    assert {:ok, selected} = Sigma.Session.Writer.selected_journal(writer)
    assert Enum.find(selected.entries, &(&1["type"] == "session"))["id"] == window_id

    # One assistant message has ordinary text and two distinct tool-call items.
    send_response(root, [
      %{type: :text, text: "Assistant archive annotation"},
      tool_call("notes::read_file", %{"path" => "journal.md", "start_line" => 1, "stop_line" => 1}),
      tool_call("notes::read_file", %{"path" => "journal.md", "start_line" => -1})
    ])

    root = provider!(@root)
    root = call!(root, "history::list_items", %{"role" => "assistant", "limit" => 100})
    items = structured!(root, "history::list_items")["items"]
    annotation = Enum.find(items, &(&1["truncated_content"] == "Assistant archive annotation"))
    assert annotation

    for index <- 1..2 do
      item = Enum.find(items, &(&1["id"] == annotation["id"] <> ":call:#{index}"))
      assert item["tool_namespace"] == "notes"
      assert item["tool_name"] == "read_file"
      assert item["canonical_tool_name"] == "notes::read_file"
      assert item["window_id"] == window_id
    end

    root = call!(root, "history::read_item", item_arguments(annotation))
    historical = structured!(root, "history::read_item")
    assert historical["content"] == "Assistant archive annotation"
    assert historical["item"]["id"] == annotation["id"]
    refute Map.has_key?(historical, "images")
    assert canonical_result!(agent, "history::read_item")["images"] == []
    assert historical["offset_chars"] == 0
    assert historical["next_offset_chars"] == nil
    assert historical["truncated"] == false
    assert historical["n_chars"] == String.length(historical["content"])

    root =
      call!(root, "history::search_contents", %{
        "query" => "Root archive marker",
        "role" => "user"
      })

    assert [%{"truncated_content" => "Root archive marker 中文"}] =
             structured!(root, "history::search_contents")["items"]

    finish_root!(agent, root)
    assert {:ok, saved} = Log.snapshot(c.path)
    assert saved_result!(saved.messages, "notes::read_file")["contents"] == suffix
  end

  test "cross-turn reconstruction and new_context retain old archives without replaying notes",
       c do
    agent = session!(c)
    marker = "Original archived prompt 中文 🧭"
    root = prompt!(agent, marker)
    root = call!(root, "notes::write_file", %{"path" => "durable.md", "text" => "first\r\n"})

    root =
      call!(root, "notes::append_to_file", %{"path" => "durable.md", "text" => "second 中文\n"})

    root = call!(root, "history::list_items", %{"role" => "user"})
    assert [old_item] = structured!(root, "history::list_items")["items"]
    root = call!(root, "history::read_item", item_arguments(old_item))
    original = structured!(root, "history::read_item")
    assert original["content"] == marker
    finish_root!(agent, root)
    before = notes_signature(c)

    root = prompt!(agent, "Read the prior note on another turn")
    root = call!(root, "notes::read_file", %{"path" => "durable.md"})
    assert structured!(root, "notes::read_file")["contents"] == "first\r\nsecond 中文\n"
    finish_root!(agent, root)
    stop_repository(c.dir)

    restored = session!(c)
    root = prompt!(restored, "Continue the saved archive")
    assert structured!(root, "history::read_item") == original
    send_call(root, "new_context", %{})
    root = provider!(@root)
    refute inspect(root.params.context.messages) =~ marker
    root = call!(root, "history::read_item", item_arguments(old_item))
    assert structured!(root, "history::read_item") == original
    root = call!(root, "history::list_windows", %{})
    windows = structured!(root, "history::list_windows")["windows"]
    assert length(windows) == 2
    assert hd(windows)["window_id"] == old_item["window_id"]
    root = call!(root, "notes::read_file", %{"path" => "durable.md"})
    assert structured!(root, "notes::read_file")["contents"] == "first\r\nsecond 中文\n"
    assert notes_signature(c) == before
    finish_root!(restored, root)

    assert {:ok, saved} = Log.snapshot(c.path)

    for name <- ~w(notes::write_file notes::append_to_file) do
      assert Enum.count(saved.messages, &(Map.get(&1, :tool_name) == name)) == 1
    end

    assert notes_signature(c) == before
  end

  @tag timeout: 60_000
  test "managed-child notes and terminal history remain readable after a cold root reconstruction",
       c do
    agent = session!(c)
    host = Runtime.lookup(c.dir, @root, :subagents)
    root = prompt!(agent, "Keep the managed archivist transcript")

    send_call(root, "spawn_agent", %{
      "task_name" => "archivist",
      "message" => "Child archive marker 中文",
      "fork_turns" => "none"
    })

    child = provider!(:child)
    child_id = child.params.session_id
    root = provider!(@root)
    result!(root, "spawn_agent")

    assert Enum.all?(
             @archive,
             &(&1 in Enum.map(child.params.context.tools, fn tool -> tool.name end))
           )

    child =
      call!(child, "notes::write_file", %{"path" => "child.md", "text" => "child original\n"})

    assert structured!(child, "notes::write_file")["path"] == "/root/archivist/notes/child.md"
    child = call!(child, "notes::read_file", %{"path" => "child.md"})
    assert structured!(child, "notes::read_file")["contents"] == "child original\n"

    child =
      call!(child, "history::search_contents", %{
        "query" => "Child archive marker",
        "role" => "user"
      })

    child_history = structured!(child, "history::search_contents")
    assert child_history["agent_name"] == "/root/archivist"
    assert [child_item] = child_history["items"]
    child = call!(child, "history::read_item", item_arguments(child_item))
    original = structured!(child, "history::read_item")
    assert original["content"] =~ "Child archive marker"
    finish!(child, "Child terminal archive marker")
    assert eventually(fn -> roster(host).counts.stopped == 1 end)

    root = call!(root, "notes::read_file", %{"path" => "/root/archivist/notes/child.md"})
    assert structured!(root, "notes::read_file")["contents"] == "child original\n"

    root =
      call!(
        root,
        "history::read_item",
        Map.put(item_arguments(child_item), "agent_name", "/root/archivist")
      )

    assert structured!(root, "history::read_item") == original

    send_call(root, "followup_task", %{
      "target" => "/root/archivist",
      "message" => "Append to the saved note"
    })

    child = provider!(child_id)
    root = provider!(@root)
    result!(root, "followup_task")
    child = call!(child, "notes::append_to_file", %{"path" => "child.md", "text" => "followup\n"})
    finish!(child, "Child followup terminal marker")
    assert eventually(fn -> roster(host).counts.stopped == 1 end)

    root =
      call!(root, "history::search_contents", %{
        "agent_name" => "/root/archivist",
        "role" => "assistant",
        "query" => "Child followup terminal marker"
      })

    assert [terminal] = structured!(root, "history::search_contents")["items"]

    root =
      call!(
        root,
        "history::read_item",
        Map.put(item_arguments(terminal), "agent_name", "/root/archivist")
      )

    terminal_read = structured!(root, "history::read_item")
    assert terminal_read["content"] == "Child followup terminal marker"
    assert {:ok, sources} = Subagents.archive_sources(host)
    source = Enum.find(sources.children, &(&1.identity.child_session_id == child_id))
    assert source
    assert Process.alive?(source.io)
    assert :ok = GenServer.stop(source.io, :normal)
    refute Process.alive?(source.io)

    root =
      call!(
        root,
        "history::read_item",
        Map.put(item_arguments(terminal), "agent_name", "/root/archivist")
      )

    assert structured!(root, "history::read_item") == terminal_read
    assert [row] = roster(host).agents
    assert row.child_session_id == child_id
    finish_root!(agent, root)
    before = notes_signature(c)
    stop_repository(c.dir)

    restored = session!(c)
    cold_host = Runtime.lookup(c.dir, @root, :subagents)
    root = prompt!(restored, "Read the stopped archivist without starting it")

    root =
      call!(
        root,
        "history::read_item",
        Map.put(item_arguments(terminal), "agent_name", "/root/archivist")
      )

    assert structured!(root, "history::read_item") == terminal_read

    root =
      call!(
        root,
        "history::read_item",
        Map.put(item_arguments(child_item), "agent_name", "/root/archivist")
      )

    assert structured!(root, "history::read_item") == original
    root = call!(root, "notes::read_file", %{"path" => "/root/archivist/notes/child.md"})
    assert structured!(root, "notes::read_file")["contents"] == "child original\nfollowup\n"
    assert [cold_row] = roster(cold_host).agents
    assert cold_row.child_session_id == child_id
    refute_receive {:archive_provider, _, %{session_id: ^child_id}}, 100
    assert notes_signature(c) == before
    finish_root!(restored, root)
  end

  @tag timeout: 60_000
  test "a reused child name selects the newest registered Session before and after cold reconstruction",
       c do
    agent = session!(c)
    host = Runtime.lookup(c.dir, @root, :subagents)
    root = prompt!(agent, "Start the first archivist generation")

    send_call(root, "spawn_agent", %{
      "task_name" => "reused",
      "message" => "old generation archive marker",
      "fork_turns" => "none"
    })

    old_child = provider!(:child)
    old_id = old_child.params.session_id
    root = provider!(@root)
    result!(root, "spawn_agent")
    finish!(old_child, "old generation complete")
    assert eventually(fn -> roster(host).counts.stopped == 1 end)

    # The older Session deliberately has the greater incarnation. Registration
    # order, rather than incarnation, must select the later same-name Session.
    send_call(root, "followup_task", %{
      "target" => "/root/reused",
      "message" => "Advance the old Session incarnation"
    })

    old_child = provider!(old_id)
    root = provider!(@root)
    result!(root, "followup_task")
    finish!(old_child, "old followup complete")
    assert eventually(fn -> roster(host).counts.stopped == 1 end)
    assert [old_row] = roster(host).agents
    finish_root!(agent, root)
    assert {:ok, %{status: :confirmed}} = Subagents.close(host)

    root = prompt!(agent, "Start a new archivist generation with the same name")

    send_call(root, "spawn_agent", %{
      "task_name" => "reused",
      "message" => "new generation archive marker",
      "fork_turns" => "none"
    })

    new_child = provider!(:child)
    new_id = new_child.params.session_id
    refute new_id == old_id
    root = provider!(@root)
    result!(root, "spawn_agent")
    new_row = Enum.find(roster(host).agents, &(&1.child_session_id == new_id))
    assert new_row
    assert old_row.incarnation > new_row.incarnation

    new_child = call!(new_child, "history::list_items", %{"role" => "user"})
    current = structured!(new_child, "history::list_items")
    assert current["agent_name"] == "/root/reused"
    assert [new_item] = current["items"]
    assert new_item["truncated_content"] =~ "new generation archive marker"
    refute new_item["truncated_content"] =~ "old generation archive marker"
    new_child = call!(new_child, "history::read_item", item_arguments(new_item))
    new_read = structured!(new_child, "history::read_item")
    assert new_read["content"] =~ "new generation archive marker"
    refute new_read["content"] =~ "old generation archive marker"

    root =
      call!(root, "history::search_contents", %{
        "agent_name" => "reused",
        "role" => "user",
        "query" => "generation archive marker"
      })

    assert structured!(root, "history::search_contents")["items"] == [new_item]

    root =
      call!(root, "history::read_item", Map.put(item_arguments(new_item), "agent_name", "reused"))

    assert structured!(root, "history::read_item") == new_read
    finish!(new_child, "new generation complete")
    assert eventually(fn -> roster(host).counts.executing == 0 end)
    finish_root!(agent, root)
    stop_repository(c.dir)

    restored = session!(c)
    cold_host = Runtime.lookup(c.dir, @root, :subagents)
    root = prompt!(restored, "Read the newest reused-name archive")

    root =
      call!(root, "history::search_contents", %{
        "agent_name" => "reused",
        "role" => "user",
        "query" => "generation archive marker"
      })

    assert structured!(root, "history::search_contents")["items"] == [new_item]

    root =
      call!(root, "history::read_item", Map.put(item_arguments(new_item), "agent_name", "reused"))

    assert structured!(root, "history::read_item") == new_read

    assert Enum.sort(Enum.map(roster(cold_host).agents, & &1.child_session_id)) ==
             Enum.sort([old_id, new_id])

    refute_receive {:archive_provider, _, %{session_id: ^old_id}}, 50
    refute_receive {:archive_provider, _, %{session_id: ^new_id}}, 50
    finish_root!(restored, root)
  end

  test "mixed user text and a real PNG survive history reads, JSONL and reconstruction", c do
    png =
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg=="

    image = %{type: :image, data: png, mime_type: "image/png"}
    text = "Original mixed image prompt 中文 🧭"
    agent = session!(c)
    root = prompt!(agent, [%{type: :text, text: text}, image])
    root = call!(root, "history::list_items", %{"role" => "user"})
    assert [item] = structured!(root, "history::list_items")["items"]
    assert item["truncated_content"] == text
    assert item["image_count"] == 1
    root = call!(root, "history::read_item", item_arguments(item))
    read = result!(root, "history::read_item")
    assert [%{type: :text, text: json}, ^image] = read.content
    model_result = Jason.decode!(json)
    assert model_result["content"] == text
    assert model_result["item"]["id"] == item["id"]
    assert model_result["truncated"] == false
    assert model_result["offset_chars"] == 0
    assert model_result["next_offset_chars"] == nil
    refute Map.has_key?(model_result, "images")

    canonical = canonical_result!(agent, "history::read_item")

    assert canonical["images"] == [
             %{"type" => "image", "data" => png, "mime_type" => "image/png"}
           ]

    assert Map.delete(canonical, "images") == model_result
    finish_root!(agent, root)
    assert {:ok, saved} = Log.snapshot(c.path)
    assert saved_result!(saved.messages, "history::read_item") == canonical

    saved_read =
      Enum.find(saved.messages, &(Map.get(&1, :tool_name) == "history::read_item"))

    assert saved_read.content == read.content
    assert File.read!(c.path) =~ png
    stop_repository(c.dir)

    restored = session!(c)
    root = prompt!(restored, "Continue from the saved image read")
    assert result!(root, "history::read_item").content == read.content
    assert saved_result!(Sigma.Agent.messages(restored), "history::read_item") == canonical
    finish_root!(restored, root)
    assert {:ok, reopened} = Log.snapshot(c.path)

    assert Enum.count(reopened.messages, &(Map.get(&1, :tool_name) == "history::read_item")) == 1
    assert saved_result!(reopened.messages, "history::read_item") == canonical
  end

  @tag timeout: 60_000
  test "real Code Mode lists model-only archive tools separately while Skills and Memory execute",
       c do
    assert is_binary(System.find_executable("deno"))
    agent = session!(c)
    root = prompt!(agent, "Inspect the Code Mode tool catalog")

    code = """
    const skills = await tools.skills__list({authority: 'executor'});
    const memories = await tools.memories__list({});
    return {skills, memories, names: ALL_TOOLS.map(tool => tool.tool_name)};
    """

    root = call!(root, "exec", code)
    result = structured!(root, "exec")
    assert result["status"] == "completed"
    assert is_list(result["value"]["skills"]["skills"])
    assert is_map(result["value"]["memories"])
    names = result["value"]["names"]
    assert "skills::list" in names
    assert "memories::list" in names
    assert Enum.all?(@archive, &(&1 not in names))
    assert canonical_result!(agent, "exec") == result
    finish_root!(agent, root)
  end

  defp session!(c) do
    assert {:ok, snapshot} = Log.snapshot(c.path)

    assert {:ok, handle} =
             Runtime.get_session(c.dir, @root,
               cwd: c.dir,
               transcript_path: c.path,
               provider: Provider,
               model: %{id: "test", provider: "test", api: "openai-responses"},
               native_tools: true,
               native_memory_root: c.memory_root,
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

  defp prompt!(agent, text) do
    assert {:accepted, _} = Sigma.Agent.prompt(agent, text)
    provider!(@root)
  end

  defp provider!(session) do
    receive do
      {:archive_provider, pid, %{session_id: "child_" <> _} = params} when session == :child ->
        %{pid: pid, params: params}

      {:archive_provider, pid, %{session_id: id} = params} when id == session ->
        %{pid: pid, params: params}

      {:turn_error, error} ->
        flunk("root failed: #{inspect(error)}")
    after
      10_000 -> flunk("provider did not start for #{session}")
    end
  end

  defp tool_call(name, arguments) do
    %{
      type: :tool_call,
      id: "archive-#{System.unique_integer([:positive])}",
      name: name,
      arguments: arguments,
      input_kind: if(is_binary(arguments), do: :custom, else: :function)
    }
  end

  defp send_response(provider, content), do: send(provider.pid, {:archive_response, content})

  defp send_call(provider, name, arguments),
    do: send_response(provider, [tool_call(name, arguments)])

  defp call!(provider, name, arguments) do
    send_call(provider, name, arguments)
    next = provider!(provider.params.session_id)
    result!(next, name)
    next
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

  defp item_arguments(item), do: %{"item_id" => item["id"], "window_id" => item["window_id"]}

  defp notes_signature(c) do
    path = Path.join(c.path <> ".subagents", "notes.json")
    {:crypto.hash(:sha256, File.read!(path)), File.stat!(path, time: :posix).mtime}
  end

  defp finish!(provider, text \\ "done"),
    do: send_response(provider, [%{type: :text, text: text}])

  defp finish_root!(agent, provider) do
    finish!(provider)
    assert_receive {:agent_end, _}, 10_000
    assert Sigma.Agent.status(agent).phase == :completed
  end

  defp roster(host) do
    assert {:ok, %{available: true, subagents: roster}} = Subagents.snapshot(host)
    roster
  end

  defp stop_repository(dir) do
    case Runtime.lookup(dir, :supervisor) do
      nil -> :ok
      pid -> DynamicSupervisor.terminate_child(Sigma.Agent.DynamicSupervisor, pid)
    end
  end

  defp stop_resource(key) do
    case Registry.lookup(Sigma.Agent.RepositoryRegistry, key) do
      [] -> :ok
      [{pid, _}] -> DynamicSupervisor.terminate_child(Sigma.Agent.DynamicSupervisor, pid)
    end
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
