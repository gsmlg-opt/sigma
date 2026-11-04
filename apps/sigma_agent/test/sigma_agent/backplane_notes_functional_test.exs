defmodule Sigma.Agent.BackplaneNotesFunctionalTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.ToolRegistry
  alias Backplane.AgentRuntime.Codex.Session
  alias Sigma.Agent.Backplane.NotesResources

  @moduletag :tmp_dir
  @names ~w(notes::list_files_by_prefix notes::read_file notes::search_contents notes::append_to_file notes::write_file)

  setup %{tmp_dir: dir} do
    transcript = Path.join(dir, "root.jsonl")
    assert {:ok, resources} = NotesResources.open(root_transcript: transcript)

    on_exit(fn ->
      for root <- [transcript, transcript <> ".renamed"] do
        case Registry.lookup(Sigma.Agent.RepositoryRegistry, {:notes_resources, root}) do
          [{pid, _}] -> DynamicSupervisor.terminate_child(Sigma.Agent.DynamicSupervisor, pid)
          [] -> :ok
        end
      end
    end)

    %{
      transcript: transcript,
      store: Path.join(transcript <> ".subagents", "notes.json"),
      resources: resources,
      binding: binding!(),
      agent_name: "/root"
    }
  end

  test "opening and listing an unused store does not create its directory", c do
    assert {:ok, %{files: []}} = call(c, "list_files_by_prefix", %{})
    assert {:ok, %{files: []}} = call(c, "search_contents", %{"query" => "anything"})
    refute File.exists?(Path.dirname(c.store))
    assert {:ok, same} = NotesResources.open(root_transcript: c.transcript)
    assert same == c.resources
  end

  test "create append replace and empty text retain exact UTF-8 and file metadata", c do
    assert {:ok, created} = write(c, "draft.md", "中文\r\n")
    assert created.path == "/root/notes/draft.md"
    assert created.size_bytes == byte_size("中文\r\n")
    assert created.created_at == created.updated_at

    assert {:ok, appended} = append(c, "draft.md", "no newline")
    assert appended.created_at == created.created_at
    assert appended.updated_at > created.updated_at
    assert appended.size_bytes == byte_size("中文\r\nno newline")
    assert {:ok, read} = read(c, "draft.md")
    assert read.contents == "中文\r\nno newline"
    assert read.n_lines == 2
    assert Map.take(read, Map.keys(appended)) == appended

    assert {:ok, replaced} = write(c, "draft.md", "replacement\n")
    assert replaced.created_at == created.created_at
    assert replaced.updated_at > appended.updated_at
    assert {:ok, %{contents: "replacement\n"}} = read(c, "draft.md")
    assert {:ok, empty} = write(c, "draft.md", "")
    assert empty.created_at == created.created_at
    assert empty.size_bytes == 0
    assert {:ok, %{contents: "", n_lines: 0}} = read(c, "draft.md")
    assert {:ok, unchanged} = append(c, "draft.md", "")
    assert unchanged.size_bytes == 0

    assert {:ok, first_append} = append(c, "new.md", "first")
    assert first_append.size_bytes == 5
    assert {:ok, %{contents: "first"}} = read(c, "new.md")
  end

  test "relative notes use the current agent and absolute virtual paths address other agents",
       c do
    child = %{c | binding: binding!(), agent_name: "/root/reviewer"}
    assert {:ok, _} = write(c, "same.md", "root note")
    assert {:ok, _} = write(child, "same.md", "child note")
    assert {:ok, %{contents: "root note"}} = read(child, "/root/notes/same.md")
    assert {:ok, %{contents: "child note"}} = read(c, "/root/reviewer/notes/same.md")
    assert {:ok, _} = append(c, "/root/reviewer/notes/same.md", " plus root")
    assert {:ok, %{contents: "child note plus root"}} = read(child, "same.md")
    assert {:ok, root_files} = call(c, "list_files_by_prefix", %{})
    assert Enum.map(root_files.files, & &1.path) == ["/root/notes/same.md"]
    assert {:ok, child_files} = call(child, "list_files_by_prefix", %{})
    assert Enum.map(child_files.files, & &1.path) == ["/root/reviewer/notes/same.md"]
    assert {:ok, _} = write(child, "~/literal.md", "tilde is literal")
    assert {:ok, %{contents: "tilde is literal"}} = read(child, "~/literal.md")
  end

  test "inclusive positive and negative line ranges preserve original line endings", c do
    text = "α\r\nbeta\n尾\r\n"
    assert {:ok, _} = write(c, "lines.md", text)
    assert {:ok, %{contents: ^text, n_lines: 3}} = read(c, "lines.md")

    assert {:ok, %{contents: "α\r\nbeta\n", n_lines: 3}} =
             read(c, "lines.md", %{"start_line" => 1, "stop_line" => 2})

    assert {:ok, %{contents: "尾\r\n"}} =
             read(c, "lines.md", %{"start_line" => -1})

    assert {:ok, %{contents: "beta\n尾\r\n"}} =
             read(c, "lines.md", %{"start_line" => -2, "stop_line" => -1})

    assert {:ok, %{contents: ""}} =
             read(c, "lines.md", %{"start_line" => 3, "stop_line" => 1})

    assert {:ok, %{contents: ""}} = read(c, "lines.md", %{"start_line" => 20})
    assert {:ok, _} = write(c, "tail.md", "first\r\nlast")

    assert {:ok, %{contents: "last", n_lines: 2}} =
             read(c, "tail.md", %{"start_line" => -1})
  end

  test "the full one-million-byte UTF-8 file is retained across append and replace", c do
    almost = String.duplicate("中", 333_333)
    assert byte_size(almost) == 999_999
    assert {:ok, %{size_bytes: 999_999}} = write(c, "large.md", almost)
    assert {:ok, %{size_bytes: 1_000_000}} = append(c, "large.md", "a")
    expected = almost <> "a"
    assert {:ok, %{contents: ^expected, size_bytes: 1_000_000}} = read(c, "large.md")
    replacement = String.duplicate("b", 1_000_000)
    assert {:ok, %{size_bytes: 1_000_000}} = write(c, "large.md", replacement)
    assert {:ok, %{contents: ^replacement}} = read(c, "large.md")
  end

  test "lists order by name creation and update with explicit prefix and result limits", c do
    assert {:ok, first} = write(c, "folder/z.md", "first")
    assert {:ok, second} = write(c, "folder/a.md", "second")
    assert {:ok, _} = write(c, "outside.md", "other")
    assert {:ok, updated} = append(c, "folder/z.md", " changed")
    assert updated.created_at == first.created_at
    assert updated.updated_at > second.updated_at
    prefix = %{"prefix" => "folder"}
    assert paths(c, prefix) == ["/root/notes/folder/a.md", "/root/notes/folder/z.md"]

    assert paths(c, Map.put(prefix, "file_order", "descending")) ==
             ["/root/notes/folder/z.md", "/root/notes/folder/a.md"]

    assert paths(c, Map.put(prefix, "file_order_by", "created_at")) ==
             ["/root/notes/folder/z.md", "/root/notes/folder/a.md"]

    assert paths(c, Map.put(prefix, "file_order_by", "updated_at")) ==
             ["/root/notes/folder/a.md", "/root/notes/folder/z.md"]

    assert paths(
             c,
             Map.merge(prefix, %{
               "file_order_by" => "created_at",
               "file_order" => "descending",
               "max_results" => 1
             })
           ) ==
             ["/root/notes/folder/a.md"]
  end

  test "search is literal case-sensitive and recent-file ordering uses creation time", c do
    assert {:ok, _} = write(c, "a.md", "Needle.one\r\nneedle.two\nNeedle.three\n")
    assert {:ok, _} = write(c, "z.md", "Needle.new\n")
    assert {:ok, _} = append(c, "a.md", "Needle.updated\n")
    assert {:ok, result} = call(c, "search_contents", %{"query" => "Needle."})
    assert Enum.map(result.files, & &1.path) == ["/root/notes/a.md", "/root/notes/z.md"]

    assert hd(result.files).matches == [
             %{line: "Needle.one", line_number: 1},
             %{line: "Needle.three", line_number: 3},
             %{line: "Needle.updated", line_number: 4}
           ]

    assert {:ok, recent} =
             call(c, "search_contents", %{
               "query" => "Needle.",
               "recent_file_first" => true,
               "max_files" => 1
             })

    assert Enum.map(recent.files, & &1.path) == ["/root/notes/z.md"]

    assert {:ok, limited} =
             call(c, "search_contents", %{
               "query" => "Needle.",
               "path_prefix" => "a",
               "max_matches_per_file" => 1
             })

    assert [%{matches: [%{line: "Needle.one", line_number: 1}]}] = limited.files
    assert {:ok, %{files: []}} = call(c, "search_contents", %{"query" => "Needle[.]"})
  end

  test "omitted limits and explicit larger limits are not silently reduced", c do
    text = Enum.map_join(1..25, "\n", &"match #{&1}")

    for number <- 1..105 do
      assert {:ok, _} = write(c, "many/#{String.pad_leading(to_string(number), 3, "0")}.md", text)
    end

    assert {:ok, listed} = call(c, "list_files_by_prefix", %{})
    assert length(listed.files) == 105
    assert {:ok, explicit} = call(c, "list_files_by_prefix", %{"max_results" => 104})
    assert length(explicit.files) == 104
    assert {:ok, found} = call(c, "search_contents", %{"query" => "match"})
    assert length(found.files) == 105
    assert Enum.all?(found.files, &(length(&1.matches) == 25))

    assert {:ok, explicit_search} =
             call(c, "search_contents", %{
               "query" => "match",
               "max_files" => 104,
               "max_matches_per_file" => 24
             })

    assert length(explicit_search.files) == 104
    assert Enum.all?(explicit_search.files, &(length(&1.matches) == 24))
  end

  test "a reopened application writer reads persisted data without rewriting it", c do
    assert {:ok, metadata} = write(c, "durable.md", "saved 中文\r\n")
    bytes = File.read!(c.store)
    stat = File.stat!(c.store, time: :posix)
    assert :ok = DynamicSupervisor.terminate_child(Sigma.Agent.DynamicSupervisor, c.resources)
    assert {:ok, reopened} = NotesResources.open(root_transcript: c.transcript)
    c = %{c | resources: reopened, binding: binding!()}
    assert {:ok, note} = read(c, "durable.md")
    assert note.contents == "saved 中文\r\n"
    assert Map.take(note, Map.keys(metadata)) == metadata
    assert File.read!(c.store) == bytes
    assert File.stat!(c.store, time: :posix).mtime == stat.mtime
  end

  test "moving a rollout subtree and reusing its old path never returns cached notes", c do
    assert {:ok, _} = write(c, "old.md", "moved contents")
    target = c.transcript <> ".renamed"
    assert :ok = File.rename(c.transcript <> ".subagents", target <> ".subagents")
    assert {:ok, moved} = NotesResources.open(root_transcript: target)
    assert {:ok, %{contents: "moved contents"}} = read(%{c | resources: moved}, "old.md")
    assert {:ok, %{files: []}} = call(c, "list_files_by_prefix", %{})
    refute File.exists?(c.transcript <> ".subagents")
    assert {:ok, _} = write(c, "fresh.md", "new rollout at old path")
    assert paths(c, %{}) == ["/root/notes/fresh.md"]
    assert paths(%{c | resources: moved}, %{}) == ["/root/notes/old.md"]
  end

  test "concurrent successful appends share one serialized writer", c do
    assert {:ok, _} = write(c, "append.md", "")

    results =
      1..40
      |> Task.async_stream(fn number -> append(c, "append.md", "entry #{number}\n") end,
        max_concurrency: 8,
        ordered: false
      )
      |> Enum.to_list()

    assert Enum.all?(results, &match?({:ok, {:ok, _}}, &1))
    assert {:ok, note} = read(c, "append.md")
    assert note.n_lines == 40
    assert note.size_bytes == byte_size(note.contents)

    assert Enum.sort(String.split(note.contents, "\n", trim: true)) ==
             Enum.sort(Enum.map(1..40, &"entry #{&1}"))
  end

  defp binding! do
    session = start_supervised!({Session, owner_pid: self()}, id: make_ref())

    authority = %{
      caller: "notes-test",
      run_id: "notes-#{System.unique_integer([:positive])}",
      grants: @names,
      tool_revision: 1
    }

    assert {:ok, binding} = Session.bind(session, authority)
    assert :ok = Session.attach(binding, %{authority: authority, registry: %ToolRegistry{}})
    binding
  end

  defp call(c, name, args) do
    NotesResources.execute(
      %{
        tool_name: "notes::" <> name,
        arguments: args,
        run_id: c.binding.run_id,
        incarnation: c.binding.run_incarnation
      },
      %{},
      Map.take(c, [:resources, :binding, :agent_name])
    )
  end

  defp write(c, path, text), do: call(c, "write_file", %{"path" => path, "text" => text})
  defp append(c, path, text), do: call(c, "append_to_file", %{"path" => path, "text" => text})
  defp read(c, path, range \\ %{}), do: call(c, "read_file", Map.put(range, "path", path))

  defp paths(c, args) do
    assert {:ok, %{files: files}} = call(c, "list_files_by_prefix", args)
    Enum.map(files, & &1.path)
  end
end
