defmodule Sigma.Agent.BackplaneMessageBoardProductionFunctionalTest do
  use ExUnit.Case, async: false

  alias Sigma.Agent.Backplane.{ChildIO, MessageBoardStore}
  alias Sigma.Agent.{Runtime, Subagents}
  alias Sigma.Session.{Log, Writer}

  @moduletag :tmp_dir
  @moduletag :message_board_production_functional
  @root "board-production-root"
  @board_names ~w(create_channel get_channels list_threads search_posts read_thread read_post subscribe unsubscribe post)

  defmodule Provider do
    @behaviour Sigma.Ai.Provider

    def output_token_limit(_model, _options), do: 2_000

    def stream(params) do
      send(params.options[:test_pid], {:board_provider, self(), params})

      receive do
        {:board_response, content} ->
          reason = if Enum.any?(content, &(&1.type == :tool_call)), do: :tool_use, else: :stop

          message = %{
            role: :assistant,
            content: content,
            stop_reason: reason,
            usage: %{input: 1, output: 1, total_tokens: 2, cost: %{total: 0.0}},
            model: "board-production",
            provider: "board-production",
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
             Runtime.get_session(dir, @root,
               cwd: dir,
               transcript_path: path,
               native_tools: true,
               native_memory_root: Path.join(dir, "memories"),
               provider: Provider,
               model: %{
                 id: "board-production",
                 provider: "board-production",
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

      assert :ok = MessageBoardStore.retire(path)
    end)

    %{
      dir: dir,
      path: path,
      board: path <> ".subagents/message_board.json",
      agent: handle.agent,
      host: Runtime.lookup(dir, @root, :subagents)
    }
  end

  test "root exposes all nine tools and retains complete direct and Deno results through turns and read-only journal recovery",
       c do
    root = prompt!(c.agent)
    assert_board_tools!(root)
    root = board!(root, "create_channel", %{"channel_name" => "开发", "subscribe" => false})
    assert data!(root, "create_channel")["channel_name"] == "开发"
    root = board!(root, "subscribe", %{"channel_name" => "开发"})
    assert data!(root, "subscribe")["enabled"] == true
    root = board!(root, "unsubscribe", %{"channel_name" => "开发"})
    assert data!(root, "unsubscribe")["enabled"] == false

    text = long_text()
    root = board!(root, "post", %{"channel_name" => "开发", "text" => text})
    original = data!(root, "post")
    assert original["author"] == "/root"
    refute Map.has_key?(original, "text")
    root = board!(root, "post", %{"thread_id" => original["thread_id"], "text" => "回复一\r\n"})
    reply1 = data!(root, "post")
    root = board!(root, "post", %{"thread_id" => original["thread_id"], "text" => "回复二\r\n"})
    reply2 = data!(root, "post")
    root = board!(root, "post", %{"channel_name" => "开发", "text" => "第二主题"})
    second = data!(root, "post")
    {root, nested} = nested_post!(root, "Deno频道", "Deno 完整内容\r\n  e\u0301 👩‍💻\n")
    previous = result!(root, "exec")
    assert nested["posted"]["author"] == "/root"
    before_reads = file_state(c.board)

    {root, channels} = pages!(root, "get_channels", %{"limit" => 1, "recent_first" => false})
    assert Enum.sort(Enum.map(channels, & &1["channel_name"])) == ["Deno频道", "开发"]

    {root, threads} =
      pages!(root, "list_threads", %{
        "channel_name" => "开发",
        "limit" => 1,
        "recent_first" => false,
        "max_chars_per_post" => 20
      })

    assert Enum.map(threads, & &1["thread_id"]) == [original["thread_id"], second["thread_id"]]
    assert hd(threads)["reply_count"] == 2
    assert hd(threads)["root_post"]["truncated"] == true

    {root, posts} = pages!(root, "search_posts", %{"channel_name" => "开发", "limit" => 1})

    assert MapSet.new(Enum.map(posts, & &1["message_id"])) ==
             MapSet.new(Enum.map([original, reply1, reply2, second], & &1["message_id"]))

    {root, replies} =
      pages!(root, "read_thread", %{"thread_id" => original["thread_id"], "limit" => 1})

    assert MapSet.new(Enum.map(replies, & &1["message_id"])) ==
             MapSet.new([reply1["message_id"], reply2["message_id"]])

    assert data!(root, "read_thread")["root_post"]["message_id"] == original["message_id"]
    {root, complete} = read_complete!(root, original["message_id"])
    assert complete == text
    assert file_state(c.board) == before_reads
    finish!(root, c)

    next = prompt!(c.agent)
    assert_previous!(next, previous)
    {next, complete} = read_complete!(next, original["message_id"])
    assert complete == text
    assert file_state(c.board) == before_reads
    finish!(next, c)

    assert {:ok, _} = Writer.flush(Runtime.lookup(c.dir, @root, :writer))
    restored = journal_reads!(c.path, c.board)
    assert_previous_message!(restored.messages, previous)
    reads = Enum.filter(restored.messages, &(field(&1, :tool_name) == "collaboration::read_post"))
    assert Enum.any?(reads, &(structured!(&1)["n_chars"] == length(String.to_charlist(text))))
    assert file_state(c.board) == before_reads
    refute_receive {:board_provider, _, _}, 0
  end

  test "real child shares the board and expires only unconsumed active notices while retaining queued messages and Deno history",
       c do
    root = prompt!(c.agent)
    root = board!(root, "create_channel", %{"channel_name" => "shared", "subscribe" => false})

    send_call(root, "spawn_agent", %{
      "task_name" => "board_reader",
      "message" => "Read and publish the complete shared board",
      "fork_turns" => "none"
    })

    child = provider!(:child)
    child_id = child.params.session_id
    root = provider!(@root)
    refute result!(root, "spawn_agent").is_error
    assert_board_tools!(child)
    child = board!(child, "subscribe", %{"channel_name" => "shared"})
    assert data!(child, "subscribe")["target_agent"] == "/root/board_reader"
    nested_text = "  子代理 Deno 全文\r\ne\u0301 👩‍💻\n" <> String.duplicate("完整尾部\r\n", 45)
    {child, nested} = nested_post!(child, "child-published", nested_text)
    previous = result!(child, "exec")
    assert nested["posted"]["author"] == "/root/board_reader"
    {root, shared_text} = read_complete!(root, nested["posted"]["message_id"])
    assert shared_text == nested_text

    # The child is held inside its actual Provider when the active notice commits.
    root = board!(root, "post", %{"channel_name" => "shared", "text" => "notice-consumed-first"})
    consumed = data!(root, "post")
    child = call!(child, "clock::curr_time", %{})
    assert notice_ids(child.params.context.messages) == [consumed["message_id"]]
    assert notice_text(child.params.context.messages) =~ "notice-consumed-first"
    finish!(child, c)

    send_call(root, "followup_task", %{
      "target" => "/root/board_reader",
      "message" => "Second board turn"
    })

    second = provider!(child_id)
    root = provider!(@root)
    refute result!(root, "followup_task").is_error
    assert_previous!(second, previous)
    assert notice_ids(second.params.context.messages) == [consumed["message_id"]]

    root =
      board!(root, "post", %{"channel_name" => "shared", "text" => "notice-unconsumed-second"})

    unconsumed = data!(root, "post")
    # Terminal response has no subsequent Provider boundary to consume this notice.
    finish!(second, c)

    root = board!(root, "post", %{"channel_name" => "shared", "text" => "notice-idle-third"})
    idle = data!(root, "post")
    refute_receive {:board_provider, _, %{session_id: ^child_id}}, 100

    root =
      call!(root, "send_message", %{
        "target" => "/root/board_reader",
        "message" => "ordinary-queued-board-message"
      })

    refute result!(root, "send_message").is_error
    refute_receive {:board_provider, _, %{session_id: ^child_id}}, 100

    send_call(root, "followup_task", %{
      "target" => "/root/board_reader",
      "message" => "Third board turn"
    })

    third = provider!(child_id)
    root = provider!(@root)
    refute result!(root, "followup_task").is_error
    assert_previous!(third, previous)
    assert notice_ids(third.params.context.messages) == [consumed["message_id"]]
    assert all_text(third.params.context.messages) =~ "ordinary-queued-board-message"
    refute all_text(third.params.context.messages) =~ "notice-unconsumed-second"
    refute all_text(third.params.context.messages) =~ "notice-idle-third"
    before_reads = file_state(c.board)
    {third, unconsumed_text} = read_complete!(third, unconsumed["message_id"])
    assert unconsumed_text == "notice-unconsumed-second"
    {third, idle_text} = read_complete!(third, idle["message_id"])
    assert idle_text == "notice-idle-third"
    assert file_state(c.board) == before_reads
    finish!(third, c)

    assert {:ok, sources} = Subagents.archive_sources(c.host)
    source = Enum.find(sources.children, &(&1.identity.child_session_id == child_id))
    assert source
    assert {:ok, archive} = ChildIO.archive_source(source.io)
    assert {:ok, _} = Writer.flush(archive.writer)
    restored = journal_reads!(archive.transcript_path, c.board)
    assert_previous_message!(restored.messages, previous)
    assert notice_ids(restored.messages) == [consumed["message_id"]]
    assert all_text(restored.messages) =~ "ordinary-queued-board-message"
    assert file_state(c.board) == before_reads
    finish!(root, c)
    refute_receive {:board_provider, _, _}, 0
  end

  test "child notices to the root retain consumed history and ordinary queued input across root turns",
       c do
    root = prompt!(c.agent)
    root = board!(root, "create_channel", %{"channel_name" => "upward", "subscribe" => false})
    {child, root} = spawn!(root, "upward_writer")

    child =
      board!(child, "post", %{
        "channel_name" => "upward",
        "text" => "root-notice-consumed",
        "agents_to_notify" => ["/root"]
      })

    consumed = data!(child, "post")
    root = call!(root, "clock::curr_time", %{})
    assert notice_ids(root.params.context.messages) == [consumed["message_id"]]
    assert notice_text(root.params.context.messages) =~ "root-notice-consumed"

    child =
      board!(child, "post", %{
        "channel_name" => "upward",
        "text" => "root-notice-unconsumed",
        "agents_to_notify" => ["/root"]
      })

    unconsumed = data!(child, "post")
    finish!(root, c)

    child =
      board!(child, "post", %{
        "channel_name" => "upward",
        "text" => "root-notice-idle",
        "agents_to_notify" => ["/root"]
      })

    idle = data!(child, "post")
    refute_receive {:board_provider, _, %{session_id: @root}}, 100

    child =
      call!(child, "send_message", %{
        "target" => "/root",
        "message" => "ordinary-queued-upward-message"
      })

    refute result!(child, "send_message").is_error
    refute_receive {:board_provider, _, %{session_id: @root}}, 100
    root = prompt!(c.agent)
    assert notice_ids(root.params.context.messages) == [consumed["message_id"]]
    assert all_text(root.params.context.messages) =~ "ordinary-queued-upward-message"
    refute all_text(root.params.context.messages) =~ "root-notice-unconsumed"
    refute all_text(root.params.context.messages) =~ "root-notice-idle"
    {root, text} = read_complete!(root, unconsumed["message_id"])
    assert text == "root-notice-unconsumed"
    {root, text} = read_complete!(root, idle["message_id"])
    assert text == "root-notice-idle"
    finish!(child, c)
    finish!(root, c)
    assert {:ok, _} = Writer.flush(Runtime.lookup(c.dir, @root, :writer))
    restored = journal_reads!(c.path, c.board)
    assert notice_ids(restored.messages) == [consumed["message_id"]]
    assert all_text(restored.messages) =~ "ordinary-queued-upward-message"
    refute_receive {:board_provider, _, _}, 0
  end

  test "sibling notices expire at the reader turn boundary without dropping consumed notices or ordinary queued messages",
       c do
    root = prompt!(c.agent)
    root = board!(root, "create_channel", %{"channel_name" => "siblings", "subscribe" => false})
    {sender, root} = spawn!(root, "sibling_writer")
    {reader, root} = spawn!(root, "sibling_reader")
    reader_id = reader.params.session_id
    target = "/root/sibling_reader"

    sender =
      board!(sender, "post", %{
        "channel_name" => "siblings",
        "text" => "sibling-notice-consumed",
        "agents_to_notify" => [target]
      })

    consumed = data!(sender, "post")
    reader = call!(reader, "clock::curr_time", %{})
    assert notice_ids(reader.params.context.messages) == [consumed["message_id"]]
    assert notice_text(reader.params.context.messages) =~ "sibling-notice-consumed"
    finish!(reader, c)

    send_call(root, "followup_task", %{"target" => target, "message" => "Second sibling turn"})
    reader = provider!(reader_id)
    root = provider!(@root)
    refute result!(root, "followup_task").is_error
    assert notice_ids(reader.params.context.messages) == [consumed["message_id"]]

    sender =
      board!(sender, "post", %{
        "channel_name" => "siblings",
        "text" => "sibling-notice-unconsumed",
        "agents_to_notify" => [target]
      })

    unconsumed = data!(sender, "post")
    finish!(reader, c)

    sender =
      board!(sender, "post", %{
        "channel_name" => "siblings",
        "text" => "sibling-notice-idle",
        "agents_to_notify" => [target]
      })

    idle = data!(sender, "post")
    refute_receive {:board_provider, _, %{session_id: ^reader_id}}, 100

    sender =
      call!(sender, "send_message", %{
        "target" => target,
        "message" => "ordinary-queued-sibling-message"
      })

    refute result!(sender, "send_message").is_error
    refute_receive {:board_provider, _, %{session_id: ^reader_id}}, 100

    send_call(root, "followup_task", %{"target" => target, "message" => "Third sibling turn"})
    reader = provider!(reader_id)
    root = provider!(@root)
    refute result!(root, "followup_task").is_error
    assert notice_ids(reader.params.context.messages) == [consumed["message_id"]]
    assert all_text(reader.params.context.messages) =~ "ordinary-queued-sibling-message"
    refute all_text(reader.params.context.messages) =~ "sibling-notice-unconsumed"
    refute all_text(reader.params.context.messages) =~ "sibling-notice-idle"
    {reader, text} = read_complete!(reader, unconsumed["message_id"])
    assert text == "sibling-notice-unconsumed"
    {reader, text} = read_complete!(reader, idle["message_id"])
    assert text == "sibling-notice-idle"
    finish!(reader, c)
    finish!(sender, c)
    assert {:ok, sources} = Subagents.archive_sources(c.host)
    source = Enum.find(sources.children, &(&1.identity.child_session_id == reader_id))
    assert {:ok, archive} = ChildIO.archive_source(source.io)
    assert {:ok, _} = Writer.flush(archive.writer)
    restored = journal_reads!(archive.transcript_path, c.board)
    assert notice_ids(restored.messages) == [consumed["message_id"]]
    assert all_text(restored.messages) =~ "ordinary-queued-sibling-message"
    finish!(root, c)
    refute_receive {:board_provider, _, _}, 0
  end

  test "production tools retain the renamed board and give a fork an independent writable board",
       c do
    source = native_session!(c, "native_source")
    root = prompt!(source.agent, source.id)

    root =
      board!(root, "post", %{
        "new_channel_name" => "lifecycle",
        "text" => "source before rename\r\n完整"
      })

    original = data!(root, "post")
    finish!(root, source)
    assert {:ok, _} = Writer.flush(Runtime.lookup(c.dir, source.id, :writer))
    original_board = file_state(source.board)

    assert {:ok, %{session_id: "renamed"}} =
             Runtime.rename_session(c.dir, source.id, "renamed", c.dir)

    refute File.exists?(source.path)
    refute File.exists?(source.board)

    assert file_state(Path.join(c.dir, "renamed.jsonl.subagents/message_board.json")) ==
             original_board

    renamed = native_session!(c, "renamed")
    root = prompt!(renamed.agent, renamed.id)
    assert_board_tools!(root)
    {root, text} = read_complete!(root, original["message_id"])
    assert text == "source before rename\r\n完整"
    root = board!(root, "post", %{"channel_name" => "lifecycle", "text" => "source after rename"})
    renamed_post = data!(root, "post")
    {root, text} = read_complete!(root, renamed_post["message_id"])
    assert text == "source after rename"
    finish!(root, renamed)
    assert {:ok, _} = Writer.flush(Runtime.lookup(c.dir, renamed.id, :writer))
    assert {:ok, checkpoint} = Log.snapshot(renamed.path)
    source_board = file_state(renamed.board)

    assert {:ok, %{session_id: "forked"}} =
             Runtime.fork_session(c.dir, renamed.id, "forked", c.dir, :all,
               operation_id: "board-production-fork",
               expected_source_leaf: checkpoint.active_leaf_id,
               expected_source_revision: length(checkpoint.branch_entry_ids) + 1
             )

    forked = native_session!(c, "forked")
    refute File.exists?(forked.board)
    assert {:ok, fork_snapshot} = Log.snapshot(forked.path)
    refute fork_snapshot.session_id == checkpoint.session_id
    assert fork_snapshot.parent_session_id == checkpoint.session_id
    fork = prompt!(forked.agent, forked.id)
    fork = board!(fork, "get_channels", %{})
    assert data!(fork, "get_channels")["results"] == []
    refute File.exists?(forked.board)
    fork = board!(fork, "post", %{"new_channel_name" => "lifecycle", "text" => "fork only\r\n独立"})
    fork_post = data!(fork, "post")
    {fork, text} = read_complete!(fork, fork_post["message_id"])
    assert text == "fork only\r\n独立"
    finish!(fork, forked)
    assert file_state(renamed.board) == source_board
    fork_board = file_state(forked.board)

    root = prompt!(renamed.agent, renamed.id)
    {root, text} = read_complete!(root, original["message_id"])
    assert text == "source before rename\r\n完整"
    {root, text} = read_complete!(root, renamed_post["message_id"])
    assert text == "source after rename"
    root = board!(root, "post", %{"channel_name" => "lifecycle", "text" => "source after fork"})
    source_post = data!(root, "post")
    {root, text} = read_complete!(root, source_post["message_id"])
    assert text == "source after fork"
    finish!(root, renamed)
    assert file_state(forked.board) == fork_board
    assert {:ok, _} = Writer.flush(Runtime.lookup(c.dir, renamed.id, :writer))
    assert {:ok, _} = Writer.flush(Runtime.lookup(c.dir, forked.id, :writer))
    _ = journal_reads!(renamed.path, renamed.board)
    _ = journal_reads!(forked.path, forked.board)
    refute_receive {:board_provider, _, _}, 0
  end

  defp native_session!(c, id) do
    path = Path.join(c.dir, id <> ".jsonl")

    snapshot_opts =
      if File.exists?(path) do
        assert {:ok, snapshot} = Log.snapshot(path)

        [
          messages: snapshot.messages,
          context_messages: snapshot.context_messages,
          context_window: snapshot.context_window,
          active_leaf: snapshot.active_leaf_id,
          context_revision: length(snapshot.branch_entry_ids),
          context_source: :journal_replay
        ]
      else
        []
      end

    assert {:ok, handle} =
             Runtime.get_session(
               c.dir,
               id,
               [
                 cwd: c.dir,
                 transcript_path: path,
                 native_tools: true,
                 native_memory_root: Path.join(c.dir, "memories"),
                 provider: Provider,
                 model: %{
                   id: "board-production",
                   provider: "board-production",
                   api: "openai-responses",
                   context_window: 200_000
                 },
                 tools: [],
                 hook_specs: [],
                 permission_config: %{default: :allow, rules: %{}},
                 options: [test_pid: self()]
               ] ++ snapshot_opts
             )

    assert :ok = Sigma.Agent.subscribe(handle.agent)
    on_exit(fn -> assert :ok = MessageBoardStore.retire(path) end)

    %{
      c
      | path: path,
        board: path <> ".subagents/message_board.json",
        agent: handle.agent,
        host: Runtime.lookup(c.dir, id, :subagents)
    }
    |> Map.put(:id, id)
  end

  defp spawn!(root, name) do
    send_call(root, "spawn_agent", %{
      "task_name" => name,
      "message" => "Use the shared message board",
      "fork_turns" => "none"
    })

    child = provider!(:child)
    root = provider!(root.params.session_id)
    refute result!(root, "spawn_agent").is_error
    {child, root}
  end

  defp nested_post!(provider, channel, text) do
    provider =
      call!(provider, "exec", """
      const posted = await tools["collaboration::post"]({new_channel_name:#{Jason.encode!(channel)},text:#{Jason.encode!(text)}});
      const read = await tools["collaboration::read_post"]({message_id:posted.message_id,limit_chars:20000});
      return {posted,read};
      """)

    result = result!(provider, "exec")
    refute result.is_error
    nested = structured!(result)
    assert nested["status"] == "completed"
    assert nested["value"]["read"]["text"] == text
    assert nested["value"]["read"]["n_chars"] == length(String.to_charlist(text))
    {provider, nested["value"]}
  end

  defp pages!(provider, name, args, collected \\ []) do
    provider = board!(provider, name, args)
    page = data!(provider, name)
    assert page["n_returned"] == length(page["results"])
    assert page["n_returned"] == 1
    collected = collected ++ page["results"]

    if page["has_more"] do
      assert is_binary(page["next_cursor"])
      pages!(provider, name, Map.put(args, "cursor", page["next_cursor"]), collected)
    else
      assert is_nil(page["next_cursor"])
      {provider, collected}
    end
  end

  defp read_complete!(provider, id, offset \\ 0, chunks \\ []) do
    provider =
      board!(provider, "read_post", %{
        "message_id" => id,
        "offset_chars" => offset,
        "limit_chars" => 700
      })

    page = data!(provider, "read_post")
    assert page["message_id"] == id
    assert page["next_offset_chars"] == offset + length(String.to_charlist(page["text"]))
    assert byte_size(Jason.encode!(page)) <= 8000
    chunks = [page["text"] | chunks]

    if page["next_offset_chars"] < page["n_chars"] do
      assert page["next_offset_chars"] > offset
      read_complete!(provider, id, page["next_offset_chars"], chunks)
    else
      text = chunks |> Enum.reverse() |> Enum.join()
      assert length(String.to_charlist(text)) == page["n_chars"]
      {provider, text}
    end
  end

  defp journal_reads!(path, board) do
    journal_before = file_state(path)
    board_before = file_state(board)
    assert {:ok, first} = Log.snapshot(path)
    assert {:ok, second} = Log.snapshot(path)
    assert first.messages == second.messages
    assert file_state(path) == journal_before
    assert file_state(board) == board_before
    second
  end

  defp file_state(path), do: {File.read!(path), File.stat!(path, time: :posix).mtime}
  defp long_text, do: String.duplicate("  完整原文 e\u0301 👩‍💻\r\n下一行\n", 150)

  defp notice_ids(messages) do
    messages
    |> Enum.flat_map(fn message ->
      case field(field(message, :metadata) || %{}, :collaboration) do
        envelope when is_map(envelope) ->
          if field(envelope, :kind) in [:notification, "notification"] do
            metadata = field(envelope, :metadata) || %{}
            post = field(metadata, :message_board) || %{}
            [field(post, :message_id)]
          else
            []
          end

        _ ->
          []
      end
    end)
  end

  defp notice_text(messages) do
    messages
    |> Enum.filter(fn message ->
      envelope = field(field(message, :metadata) || %{}, :collaboration) || %{}
      field(envelope, :kind) in [:notification, "notification"]
    end)
    |> all_text()
  end

  defp all_text(messages) do
    Enum.map_join(messages, "\n", fn message ->
      case field(message, :content) do
        text when is_binary(text) -> text
        blocks when is_list(blocks) -> Enum.map_join(blocks, "\n", &(field(&1, :text) || ""))
        nil -> ""
      end
    end)
  end

  defp assert_previous!(provider, previous),
    do: assert_previous_message!(provider.params.context.messages, previous)

  defp assert_previous_message!(messages, previous) do
    restored = Enum.find(messages, &(field(&1, :tool_call_id) == previous.tool_call_id))
    assert restored
    assert field(restored, :content) == previous.content
    assert field(restored, :is_error) == previous.is_error
    assert structured!(restored) == structured!(previous)
  end

  defp assert_board_tools!(provider) do
    names = Enum.map(provider.params.context.tools, & &1.name)
    assert Enum.all?(@board_names, &(("collaboration::" <> &1) in names))
  end

  defp board!(provider, name, args) do
    next = call!(provider, "collaboration::" <> name, args)
    refute result!(next, "collaboration::" <> name).is_error
    next
  end

  defp data!(provider, name), do: structured!(result!(provider, "collaboration::" <> name))

  defp result!(provider, name) do
    Enum.find(Enum.reverse(provider.params.context.messages), &(field(&1, :tool_name) == name)) ||
      flunk("missing #{name} result in next actual Provider request")
  end

  defp structured!(message) do
    field(field(message, :metadata) || %{}, :structured_result) ||
      message
      |> field(:content)
      |> Enum.find(&(field(&1, :type) in [:text, "text"]))
      |> field(:text)
      |> Jason.decode!()
  end

  defp field(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp prompt!(agent, session \\ @root) do
    assert {:accepted, _} = Sigma.Agent.prompt(agent, "Read the complete message board")
    provider!(session)
  end

  defp provider!(session) do
    receive do
      {:board_provider, pid, %{session_id: "child_" <> _} = params} when session == :child ->
        %{pid: pid, params: params}

      {:board_provider, pid, %{session_id: id} = params} when id == session ->
        %{pid: pid, params: params}

      {:turn_error, error} ->
        flunk("message-board root failed: #{inspect(error)}")
    after
      8_000 -> flunk("message-board Provider did not start for #{session}")
    end
  end

  defp call!(provider, name, input) do
    send_call(provider, name, input)
    provider!(provider.params.session_id)
  end

  defp send_call(provider, name, input) do
    send(
      provider.pid,
      {:board_response,
       [
         %{
           type: :tool_call,
           id: "board-#{System.unique_integer([:positive])}",
           name: name,
           arguments: input,
           input_kind: if(is_binary(input), do: :custom, else: :function)
         }
       ]}
    )
  end

  defp finish!(provider, c) do
    send(provider.pid, {:board_response, [%{type: :text, text: "done"}]})

    case provider.params.session_id do
      "child_" <> _ = id ->
        assert eventually(fn ->
                 assert {:ok, %{subagents: roster}} = Subagents.snapshot(c.host)

                 Enum.any?(
                   roster.agents,
                   &(&1.child_session_id == id and
                       &1.run_id == provider.params.turn_id and &1.status == :completed)
                 )
               end)

      _root_session ->
        assert_receive {:agent_end, _}, 8_000
        assert Sigma.Agent.status(c.agent).phase == :completed
    end
  end

  defp eventually(fun, attempts \\ 400)
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
