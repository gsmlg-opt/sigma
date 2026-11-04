defmodule Sigma.Agent.BackplaneHistoryFunctionalTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.{ToolRegistry, Codex.Session}
  alias Sigma.Agent.{Message, Subagents}
  alias Sigma.Agent.Backplane.{HistoryResources, Provider}
  alias Sigma.Session.{Writer, Storage.JsonlFile}

  @moduletag :tmp_dir
  @names ~w(history::list_windows history::list_items history::read_item history::search_contents)
  @png "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl2B7sAAAAASUVORK5CYII="

  setup %{tmp_dir: dir} do
    path = Path.join(dir, "history.jsonl")
    writer = start_supervised!({Writer, storage_id: path, session_id: "history", cwd: dir})

    host =
      start_supervised!(
        {Subagents,
         writer: writer,
         repo_path: dir,
         session_id: "history",
         transcript_path: path,
         enabled: false}
      )

    session = start_supervised!({Session, owner_pid: self()})
    authority = %{caller: "history", run_id: "history-test", grants: @names, tool_revision: 1}
    assert {:ok, binding} = Session.bind(session, authority)
    assert :ok = Session.attach(binding, %{authority: authority, registry: %ToolRegistry{}})
    archive = %{host: host, root_transcript: path, agent_name: "/root"}
    %{writer: writer, host: host, path: path, archive: archive, binding: binding}
  end

  test "original messages and stable windows survive compaction and context reset", c do
    first = append(c.writer, Message.user("old", "original before reset"))
    second = append(c.writer, Message.user("kept", "kept after compact"))
    assert {:ok, _} = Writer.append(c.writer, {:compact, %{content: "summary"}, second})

    assert {:ok, boundary} =
             Writer.append(
               c.writer,
               {:context_window_started, %{run_id: "reset", incarnation: 1, window: 2}}
             )

    newest = append(c.writer, Message.user("fresh", "new context"))
    bytes = File.read!(c.path)

    assert {:ok, %{windows: [initial, later]}} = call(c, "list_windows", %{})
    assert initial.ordinal == 1
    assert initial.item_count == 2
    assert later.window_id == boundary
    assert later.ordinal == 2
    assert later.item_count == 1
    assert {:ok, %{items: items}} = call(c, "list_items", %{})
    assert Enum.map(items, & &1.id) == [first, second, newest]
    assert Enum.map(items, & &1.window_id) == [initial.window_id, initial.window_id, boundary]
    assert {:ok, %{content: "original before reset"}} = read(c, hd(items))
    assert {:ok, %{items: [matched]}} = call(c, "search_contents", %{"query" => "before reset"})
    assert matched.id == first
    assert File.read!(c.path) == bytes
  end

  test "persisted item order wins over message timestamps and filters retain exact limits", c do
    first = append(c.writer, Message.user("first", "Needle.one", 9_000))
    second = append(c.writer, Message.user("second", "needle.two", 1_000))

    third =
      append(
        c.writer,
        Message.tool_result("result", %{
          content: [%{type: :text, text: "Needle.three"}],
          tool_name: "notes::read_file",
          tool_call_id: "read-call"
        })
      )

    assert {:ok, %{items: items}} = call(c, "list_items", %{})
    assert Enum.map(items, & &1.id) == [first, second, third]

    assert {:ok, %{items: recent}} =
             call(c, "list_items", %{"limit" => 2, "recent_first" => true})

    assert Enum.map(recent, & &1.id) == [third, second]
    assert {:ok, %{items: matches}} = call(c, "search_contents", %{"query" => "Needle."})
    assert Enum.map(matches, & &1.id) == [first, third]
    assert {:ok, %{items: []}} = call(c, "search_contents", %{"query" => "Needle[.]"})

    assert {:ok, %{items: [tool]}} =
             call(c, "list_items", %{
               "role" => "tool",
               "tool_namespace" => "notes",
               "tool_name" => "read_file"
             })

    assert tool.id == third
    assert tool.canonical_tool_name == "notes::read_file"
    assert {:ok, %{items: []}} = call(c, "list_items", %{"window_id" => "unknown-window"})

    assert {:ok, %{items: []}} =
             call(c, "search_contents", %{"query" => "Needle", "window_id" => "unknown-window"})
  end

  test "preview and read offsets count Unicode scalars and retain image attachments", c do
    append(
      c.writer,
      Message.user("unicode", [
        %{type: :text, text: "á🙂b"},
        %{type: :image, data: @png, mime_type: "image/png"}
      ])
    )

    assert {:ok, %{items: [item]}} = call(c, "list_items", %{"max_chars_per_item" => 2})
    assert item.truncated_content == "á"
    assert item.n_chars == 4
    assert item.image_count == 1
    assert item.truncated
    assert {:ok, result} = read(c, item, %{"offset_chars" => 1, "limit_chars" => 2})
    assert result.content == "́🙂"
    assert result.next_offset_chars == 3
    assert result.truncated
    assert [%{type: :image, data: @png, mime_type: "image/png"}] = result.images

    assert {:ok, %{content: "b", next_offset_chars: nil, truncated: false}} =
             read(c, item, %{"offset_chars" => 3})

    [message] =
      Provider.normalize_messages([
        %{role: :tool, name: "history::read_item", tool_call_id: "archive-read", result: result}
      ])

    refute message.is_error
    assert [%{type: :text, text: json}, %{type: :image, data: @png}] = message.content
    assert Jason.decode!(json)["item"]["id"] == item.id
    assert Jason.decode!(json)["content"] == "́🙂"

    assert message.metadata.structured_result["images"] == [
             %{"type" => "image", "data" => @png, "mime_type" => "image/png"}
           ]

    append(
      c.writer,
      Message.assistant("read-call", %{
        content: [
          %{
            type: :tool_call,
            id: "archive-read",
            name: "history::read_item",
            arguments: %{"item_id" => item.id, "window_id" => item.window_id}
          }
        ]
      })
    )

    entry_id = append(c.writer, message)
    assert is_binary(entry_id)
    assert {:ok, snapshot} = Sigma.Session.Log.snapshot(c.path)
    assert List.last(snapshot.messages).content == message.content
  end

  test "assistant calls become separate stable items with raw custom input preserved", c do
    raw = "*** Begin Patch\n*** Add File: a.txt\n+中文\n*** End Patch"

    id =
      append(
        c.writer,
        Message.assistant("assistant", %{
          content: [
            %{type: :text, text: "two calls"},
            %{
              type: :tool_call,
              id: "patch",
              name: "apply_patch",
              arguments: raw,
              input_kind: :custom
            },
            %{
              type: :tool_call,
              id: "note",
              name: "notes::write_file",
              arguments: %{"path" => "a.md", "text" => "完整"}
            }
          ]
        })
      )

    assert {:ok, %{items: items}} = call(c, "list_items", %{})
    assert Enum.map(items, & &1.id) == [id, id <> ":call:1", id <> ":call:2"]

    assert {:ok, %{items: [patch]}} =
             call(c, "list_items", %{"tool_name" => "apply_patch", "role" => "assistant"})

    assert {:ok, %{content: content}} = read(c, patch)
    assert content == "apply_patch\n" <> raw
    assert {:ok, %{items: [note]}} = call(c, "list_items", %{"tool_namespace" => "notes"})
    assert note.id == id <> ":call:2"
    assert {:ok, %{content: encoded}} = read(c, note)

    assert String.replace_prefix(encoded, "notes::write_file\n", "") |> Jason.decode!() == %{
             "path" => "a.md",
             "text" => "完整"
           }
  end

  test "selected retry ancestry excludes sibling items and persists after its first append", c do
    first = append(c.writer, Message.user("first", "shared"))
    sibling = append(c.writer, Message.user("sibling", "discarded sibling"))
    assert :ok = Writer.checkout(c.writer, first, sibling)
    assert {:ok, %{items: [only]}} = call(c, "list_items", %{})
    assert only.id == first
    selected = append(c.writer, Message.user("retry", "selected retry"))
    assert {:ok, %{items: items}} = call(c, "list_items", %{})
    assert Enum.map(items, & &1.id) == [first, selected]
    bytes = File.read!(c.path)
    assert {:ok, entries} = JsonlFile.read(c.path)
    assert {:ok, reopened} = HistoryResources.project(entries, :latest, "/root")
    assert Enum.map(reopened.items, & &1.id) == [first, selected]
    assert File.read!(c.path) == bytes
  end

  defp append(writer, message) do
    assert {:ok, id} = Writer.append(writer, {:message_end, message})
    id
  end

  defp call(c, name, args) do
    HistoryResources.execute(
      %{
        tool_name: "history::" <> name,
        arguments: args,
        run_id: c.binding.run_id,
        incarnation: c.binding.run_incarnation
      },
      %{},
      %{archive: c.archive, binding: c.binding}
    )
  end

  defp read(c, item, options \\ %{}),
    do:
      call(
        c,
        "read_item",
        Map.merge(%{"item_id" => item.id, "window_id" => item.window_id}, options)
      )
end
