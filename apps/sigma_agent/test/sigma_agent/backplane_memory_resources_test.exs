defmodule Sigma.Agent.Backplane.MemoryResourcesTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.{Error, InputSchema, ToolRegistry}
  alias Backplane.AgentRuntime.Codex.{ExtensionRuntime, Session}
  alias Sigma.Agent.Backplane.MemoryResources

  @moduletag :tmp_dir
  @filename "2026-10-25T12-30-00-explicit-preference.md"
  @tools ~w(memories::add_ad_hoc_note memories::list memories::read memories::search)

  defmodule UncertainFileSystem do
    def create_exclusive(owner, path, contents) do
      send(owner, :exclusive_write_attempt)
      File.write!(path, contents, [:exclusive])
      {:error, Error.new(:unknown_outcome, "injected sync failure after creation")}
    end
  end

  defmodule WriteThenKillFileSystem do
    def create_exclusive(_context, path, contents) do
      File.write!(path, contents, [:exclusive])
      Process.exit(self(), :kill)
    end
  end

  setup %{tmp_dir: dir} do
    root = Path.join(dir, "sigma-memory")
    resources = start_supervised!({MemoryResources, root: root}, restart: :temporary)
    binding = binding!("memory-first")
    {:ok, root: root, resources: resources, binding: binding, dir: dir}
  end

  test "the add/list/read public schemas match Codex arguments and reject extras" do
    runtime =
      start_supervised!(
        {ExtensionRuntime,
         scope: %{host_id: "host", caller_id: "caller", run_id: "run", project_id: "project"}}
      )

    contracts = ExtensionRuntime.contracts(%{extension_runtime: runtime})

    schemas =
      Map.new(
        contracts,
        &{if(&1.namespace, do: &1.namespace <> "::" <> &1.name, else: &1.name), &1.schema}
      )

    for {name, args} <- [
          {"memories::add_ad_hoc_note", %{"filename" => @filename, "note" => "Remember this"}},
          {"memories::list", %{"path" => "folder", "cursor" => "opaque", "max_results" => 2}},
          {"memories::read", %{"path" => "MEMORY.md", "line_offset" => 2, "max_lines" => 3}}
        ] do
      assert {:ok, ^args} = InputSchema.validate(schemas[name], args)

      assert {:error, %Error{}} =
               InputSchema.validate(schemas[name], Map.put(args, "root", "/elsewhere"))
    end

    assert {:error, %Error{}} =
             InputSchema.validate(schemas["memories::read"], %{"path" => "a", "line_offset" => 0})

    assert {:error, %Error{}} =
             InputSchema.validate(schemas["memories::list"], %{"max_results" => 0})
  end

  test "read operations never create an absent store and startup has one owner per root", ctx do
    refute File.exists?(ctx.root)
    assert {:error, %Error{class: :not_found}} = call(ctx, "memories::list", %{})

    assert {:error, %Error{class: :not_found}} =
             call(ctx, "memories::read", %{"path" => "MEMORY.md"})

    refute File.exists?(ctx.root)
    assert {:error, {:already_started, pid}} = MemoryResources.start_link(root: ctx.root)
    assert pid == ctx.resources
    assert {:ok, ^pid} = MemoryResources.open(root: ctx.root)
    assert {:error, %Error{class: :validation}} = MemoryResources.start_link(root: "relative")
  end

  test "explicit note requests create one durable verbatim append-only file", ctx do
    note = "# User request\n\nKeep UTF-8: 中文 😀\r\n"

    assert {:ok, %{}} =
             call(ctx, "memories::add_ad_hoc_note", %{"filename" => @filename, "note" => note})

    path = Path.join([ctx.root, "extensions", "ad_hoc", "notes", @filename])
    assert File.read!(path) == note
    assert {:ok, %{mode: file_mode}} = File.stat(path)
    assert :erlang.band(file_mode, 0o777) == 0o600

    for directory <- [
          ctx.root,
          Path.join(ctx.root, "extensions"),
          Path.join(ctx.root, "extensions/ad_hoc"),
          Path.join(ctx.root, "extensions/ad_hoc/notes")
        ] do
      assert {:ok, %{mode: mode}} = File.stat(directory)
      assert :erlang.band(mode, 0o777) == 0o700
    end

    assert {:error, %Error{class: :resource_conflict}} =
             call(ctx, "memories::add_ad_hoc_note", %{
               "filename" => @filename,
               "note" => "Overwrite"
             })

    assert File.read!(path) == note
    GenServer.stop(ctx.resources)
    reopened = start_supervised!({MemoryResources, root: ctx.root}, id: :reopened_memory)

    assert {:ok, %{content: ^note, truncated: false}} =
             call(%{ctx | resources: reopened}, "memories::read", %{
               "path" => "extensions/ad_hoc/notes/" <> @filename
             })
  end

  test "existing user directories retain their modes when a note creates descendant directories",
       ctx do
    File.mkdir_p!(Path.join(ctx.root, "extensions"))
    File.chmod!(ctx.root, 0o750)
    File.chmod!(Path.join(ctx.root, "extensions"), 0o755)

    assert {:ok, %{}} =
             call(ctx, "memories::add_ad_hoc_note", %{
               "filename" => @filename,
               "note" => "Explicit"
             })

    assert {:ok, %{mode: root_mode}} = File.stat(ctx.root)
    assert {:ok, %{mode: extensions_mode}} = File.stat(Path.join(ctx.root, "extensions"))
    assert :erlang.band(root_mode, 0o777) == 0o750
    assert :erlang.band(extensions_mode, 0o777) == 0o755
    assert {:ok, %{mode: mode}} = File.stat(Path.join(ctx.root, "extensions/ad_hoc/notes"))
    assert :erlang.band(mode, 0o777) == 0o700
  end

  test "note validation rejects paths, invalid filenames, whitespace and invalid UTF-8", ctx do
    for filename <- [
          "../" <> @filename,
          String.replace(@filename, "explicit", "UPPER"),
          "2026-10-25T12-30-00--leading.md",
          "not-a-note.md"
        ] do
      assert {:error, %Error{class: :validation}} =
               call(ctx, "memories::add_ad_hoc_note", %{"filename" => filename, "note" => "Value"})
    end

    for note <- [" \r\n\t", <<255>>] do
      assert {:error, %Error{class: :validation}} =
               call(ctx, "memories::add_ad_hoc_note", %{"filename" => @filename, "note" => note})
    end

    refute File.exists?(ctx.root)
  end

  test "list returns visible immediate typed entries and singleton files", ctx do
    File.mkdir_p!(Path.join(ctx.root, "directory/deep"))
    File.mkdir_p!(Path.join(ctx.root, ".hidden-directory"))
    File.write!(Path.join(ctx.root, "directory/deep/item.md"), "Nested")
    File.write!(Path.join(ctx.root, "MEMORY.md"), "Root")
    File.write!(Path.join(ctx.root, ".hidden.md"), "Hidden")
    File.ln_s!(Path.join(ctx.root, "MEMORY.md"), Path.join(ctx.root, "alias.md"))

    assert {:ok, %{path: nil, entries: entries, next_cursor: nil, truncated: false}} =
             call(ctx, "memories::list", %{})

    assert entries == [
             %{path: "MEMORY.md", entry_type: "file"},
             %{path: "directory", entry_type: "directory"}
           ]

    assert {:ok,
            %{path: "directory", entries: [%{path: "directory/deep", entry_type: "directory"}]}} =
             call(ctx, "memories::list", %{"path" => "directory"})

    assert {:ok, %{entries: [%{path: "MEMORY.md", entry_type: "file"}]}} =
             call(ctx, "memories::list", %{"path" => "MEMORY.md"})
  end

  test "opaque list cursors fence directory revision, query and Session scope", ctx do
    File.mkdir_p!(ctx.root)
    for name <- ~w(a.md b.md c.md), do: File.write!(Path.join(ctx.root, name), name)
    assert {:ok, first} = call(ctx, "memories::list", %{"max_results" => 1})
    assert first.entries == [%{path: "a.md", entry_type: "file"}]
    assert first.truncated and is_binary(first.next_cursor)
    refute first.next_cursor == "1"

    assert {:ok, second} =
             call(ctx, "memories::list", %{"max_results" => 1, "cursor" => first.next_cursor})

    assert second.entries == [%{path: "b.md", entry_type: "file"}]

    assert {:ok, ^second} =
             call(ctx, "memories::list", %{"max_results" => 1, "cursor" => first.next_cursor})

    assert {:error, %Error{class: :validation}} =
             call(ctx, "memories::list", %{
               "max_results" => 1,
               "cursor" => first.next_cursor <> "A"
             })

    assert {:error, %Error{class: :validation}} =
             call(ctx, "memories::list", %{"max_results" => 2, "cursor" => first.next_cursor})

    foreign = %{ctx | binding: binding!("memory-second")}

    assert {:error, %Error{class: :forbidden}} =
             call(foreign, "memories::list", %{"max_results" => 1, "cursor" => first.next_cursor})

    File.write!(Path.join(ctx.root, "d.md"), "New revision")

    assert {:error, %Error{class: :resource_conflict}} =
             call(ctx, "memories::list", %{"max_results" => 1, "cursor" => second.next_cursor})

    assert {:error, %Error{class: :validation}} = call(ctx, "memories::list", %{"cursor" => "1"})
  end

  test "read preserves line endings and distinguishes skipped prefixes from truncated suffixes",
       ctx do
    File.mkdir_p!(ctx.root)
    File.write!(Path.join(ctx.root, "lines.md"), "甲\r\n乙\n丙\n")

    assert {:ok, %{path: "lines.md", start_line_number: 2, content: "乙\n", truncated: true}} =
             call(ctx, "memories::read", %{
               "path" => "lines.md",
               "line_offset" => 2,
               "max_lines" => 1
             })

    assert {:ok, %{content: "丙\n", truncated: false}} =
             call(ctx, "memories::read", %{"path" => "lines.md", "line_offset" => 3})

    assert {:ok, %{content: "", truncated: false}} =
             call(ctx, "memories::read", %{"path" => "lines.md", "line_offset" => 4})

    assert {:error, %Error{class: :validation}} =
             call(ctx, "memories::read", %{"path" => "lines.md", "line_offset" => 5})

    File.write!(Path.join(ctx.root, "empty.md"), "")

    assert {:ok, %{content: "", truncated: false}} =
             call(ctx, "memories::read", %{"path" => "empty.md"})
  end

  test "read applies pinned middle truncation on UTF-8 boundaries and rejects invalid UTF-8",
       ctx do
    File.mkdir_p!(ctx.root)
    contents = String.duplicate("甲", 30_000)
    File.write!(Path.join(ctx.root, "large.md"), contents)

    assert {:ok, %{content: read, truncated: true}} =
             call(ctx, "memories::read", %{"path" => "large.md"})

    assert String.valid?(read)

    assert read ==
             String.duplicate("甲", 13_333) <>
               "…2500 tokens truncated…" <> String.duplicate("甲", 13_333)

    File.write!(Path.join(ctx.root, "invalid.bin"), <<255, 0>>)

    assert {:error, %Error{class: :execution_failure}} =
             call(ctx, "memories::read", %{"path" => "invalid.bin"})

    File.write!(Path.join(ctx.root, "nul.md"), <<0>>)
    assert {:ok, %{content: <<0>>}} = call(ctx, "memories::read", %{"path" => "nul.md"})
  end

  test "paths stay inside trusted root and symlink components never redirect reads or writes",
       ctx do
    File.mkdir_p!(ctx.root)
    File.write!(Path.join(ctx.dir, "secret.md"), "Outside")
    File.ln_s!(ctx.dir, Path.join(ctx.root, "escape"))
    File.mkdir_p!(Path.join(ctx.root, ".hidden"))
    File.write!(Path.join(ctx.root, ".hidden/private.md"), "Hidden")

    for path <- ["../secret.md", Path.join(ctx.dir, "secret.md"), "escape/secret.md"] do
      assert {:error, %Error{class: :validation}} = call(ctx, "memories::read", %{"path" => path})
    end

    assert {:error, %Error{class: :not_found}} =
             call(ctx, "memories::read", %{"path" => ".hidden/private.md"})

    File.ln_s!(ctx.dir, Path.join(ctx.root, "extensions"))

    assert {:error, %Error{class: :validation}} =
             call(ctx, "memories::add_ad_hoc_note", %{
               "filename" => @filename,
               "note" => "Explicit"
             })

    refute File.exists?(Path.join(ctx.dir, "ad_hoc"))
    root_alias = Path.join(ctx.dir, "root-alias")
    File.ln_s!(ctx.root, root_alias)
    assert {:error, %Error{class: :validation}} = MemoryResources.start_link(root: root_alias)
  end

  test "all sessions share persisted root while detached and stale invocations are fenced", ctx do
    assert {:ok, %{}} =
             call(ctx, "memories::add_ad_hoc_note", %{
               "filename" => @filename,
               "note" => "Shared across sessions"
             })

    second = %{ctx | binding: binding!("another-session")}
    path = "extensions/ad_hoc/notes/" <> @filename

    assert {:ok, %{content: "Shared across sessions"}} =
             call(second, "memories::read", %{"path" => path})

    assert {:error, %Error{class: :forbidden}} =
             MemoryResources.execute(
               operation(ctx.binding, "memories::read", %{"path" => path})
               |> Map.put(:incarnation, 999),
               %{},
               %{resources: ctx.resources, binding: ctx.binding}
             )

    assert :ok = Session.prepare_detach(ctx.binding)
    assert {:ok, _} = Session.detach(ctx.binding)
    assert {:error, %Error{class: :forbidden}} = call(ctx, "memories::read", %{"path" => path})

    assert {:ok, %{content: "Shared across sessions"}} =
             call(second, "memories::read", %{"path" => path})
  end

  test "uncertain note creation is never retried or silently overwritten", ctx do
    GenServer.stop(ctx.resources)

    resources =
      start_supervised!(
        {MemoryResources, root: ctx.root, filesystem: {UncertainFileSystem, self()}},
        id: :uncertain_memory
      )

    ctx = %{ctx | resources: resources}
    args = %{"filename" => @filename, "note" => "Possibly persisted"}

    assert {:error, %Error{class: :unknown_outcome}} =
             call(ctx, "memories::add_ad_hoc_note", args)

    assert_receive :exclusive_write_attempt
    refute_receive :exclusive_write_attempt

    assert File.read!(Path.join([ctx.root, "extensions/ad_hoc/notes", @filename])) ==
             "Possibly persisted"

    assert {:error, %Error{class: :resource_conflict}} =
             call(ctx, "memories::add_ad_hoc_note", %{args | "note" => "Retry overwrite"})

    refute_receive :exclusive_write_attempt
  end

  test "in-flight write dispatch exits remain unknown after the note was created", ctx do
    GenServer.stop(ctx.resources)

    resources =
      start_supervised!(
        {MemoryResources, root: ctx.root, filesystem: {WriteThenKillFileSystem, nil}},
        id: :killed_memory,
        restart: :temporary
      )

    monitor = Process.monitor(resources)

    assert {:error, %Error{class: :unknown_outcome}} =
             call(%{ctx | resources: resources}, "memories::add_ad_hoc_note", %{
               "filename" => @filename,
               "note" => "Persisted before host exit"
             })

    assert_receive {:DOWN, ^monitor, :process, ^resources, :killed}

    assert File.read!(Path.join([ctx.root, "extensions/ad_hoc/notes", @filename])) ==
             "Persisted before host exit"
  end

  test "list cursor capacity returns a typed error and retains existing pagination", ctx do
    File.mkdir_p!(ctx.root)
    for name <- ~w(a.md b.md), do: File.write!(Path.join(ctx.root, name), name)

    cursor =
      Enum.reduce(1..256, nil, fn _index, _previous ->
        assert {:ok, %{next_cursor: cursor}} = call(ctx, "memories::list", %{"max_results" => 1})
        cursor
      end)

    assert {:error, %Error{class: :overloaded}} =
             call(ctx, "memories::list", %{"max_results" => 1})

    assert Process.alive?(ctx.resources)

    assert {:ok, %{entries: [%{path: "b.md", entry_type: "file"}], next_cursor: nil}} =
             call(ctx, "memories::list", %{"max_results" => 1, "cursor" => cursor})
  end

  test "tagged search reads the shared persistent memory contents", ctx do
    File.mkdir_p!(ctx.root)
    File.write!(Path.join(ctx.root, "search.md"), "a test memory\n")

    assert {:ok,
            %{
              match_mode: %{"type" => "all_on_same_line"},
              matches: [%{path: "search.md", match_line_number: 1, content: "a test memory"}]
            }} =
             call(ctx, "memories::search", %{
               "queries" => ["test", "memory"],
               "match_mode" => %{"type" => "all_on_same_line"}
             })
  end

  test "an admitted traversal can finish when every cursor slot is occupied", ctx do
    File.mkdir_p!(ctx.root)

    expected =
      for index <- 1..258 do
        name = index |> Integer.to_string() |> String.pad_leading(3, "0")
        File.write!(Path.join(ctx.root, name), name)
        name
      end

    cursors =
      for _ <- 1..256 do
        assert {:ok, %{next_cursor: cursor}} = call(ctx, "memories::list", %{"max_results" => 1})
        cursor
      end

    {paths, cursor} =
      Enum.reduce(2..258, {[hd(expected)], hd(cursors)}, fn _index, {paths, cursor} ->
        assert {:ok, %{entries: [%{path: path}], next_cursor: next}} =
                 call(ctx, "memories::list", %{"max_results" => 1, "cursor" => cursor})

        {paths ++ [path], next}
      end)

    assert paths == expected
    assert cursor == nil

    assert {:ok, %{entries: [%{path: "002"}]}} =
             call(ctx, "memories::list", %{"max_results" => 1, "cursor" => List.last(cursors)})
  end

  defp binding!(run_id) do
    session = start_supervised!({Session, owner_pid: self()}, id: make_ref())
    authority = %{caller: "memory-test", run_id: run_id, grants: @tools, tool_revision: 1}
    assert {:ok, binding} = Session.bind(session, authority)
    assert :ok = Session.attach(binding, %{authority: authority, registry: %ToolRegistry{}})
    binding
  end

  defp call(ctx, name, args),
    do:
      MemoryResources.execute(operation(ctx.binding, name, args), %{}, %{
        resources: ctx.resources,
        binding: ctx.binding
      })

  defp operation(binding, name, args),
    do: %{
      tool_name: name,
      arguments: args,
      run_id: binding.run_id,
      incarnation: binding.run_incarnation
    }
end
