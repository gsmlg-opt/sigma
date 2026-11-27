defmodule Sigma.Agent.Backplane.StoreJournalStorageTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.Store, as: RuntimeStore
  alias Sigma.Agent.Backplane.Store

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "sigma-store-journal-test-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "checkpoint history does not multiply the ordinary snapshot record", %{root: root} do
    sizes =
      for count <- [16, 32, 64] do
        dir = Path.join(root, "case-#{count}")
        File.mkdir_p!(dir)
        {:ok, store} = Store.open(path: dir)
        {snapshot, inputs} = checkpoints(store, count)

        assert {:ok, [_admit | entries]} = Store.recovery_journal(store, snapshot.run.run_id)
        assert Enum.map(entries, & &1["input"]) === inputs

        [record] = Path.wildcard(Path.join(dir, "*.runtime"))
        raw_size = record |> File.read!() |> uncompressed_size()
        snapshot_size = :erlang.external_size(snapshot)
        GenServer.stop(store)

        assert raw_size < snapshot_size * 2,
               "#{count} checkpoints stored #{raw_size} bytes for a #{snapshot_size}-byte snapshot"

        raw_size
      end

    for [smaller, larger] <- Enum.chunk_every(sizes, 2, 1, :discard) do
      assert larger < smaller * 2.2
    end
  end

  defmodule ObservedFileSystem do
    def ensure_dir(_control, path), do: Store.FileSystem.ensure_dir(path)

    def read(control, path) do
      options = Agent.get(control, & &1)

      cond do
        Map.get(options, :fail_read, false) and String.ends_with?(path, ".runtime") ->
          {:error, :record_read_failed}

        MapSet.member?(options.forbidden, path) ->
          {:error, :old_journal_was_read}

        true ->
          Store.FileSystem.read(path)
      end
    end

    def write_atomic(control, path, bytes) do
      options = Agent.get(control, & &1)

      cond do
        options.fail_snapshot and String.ends_with?(path, ".runtime") ->
          {:error, :snapshot_publication_failed}

        Map.get(options, :fail_block, false) and String.contains?(path, ".runtime.journal/") ->
          {:error, :block_publication_failed}

        true ->
          Store.FileSystem.write_atomic(path, bytes)
      end
    end
  end

  test "ordinary load and next commit never read old journal blocks", %{root: root} do
    {:ok, control} = Agent.start_link(fn -> %{forbidden: MapSet.new(), fail_snapshot: false} end)
    {:ok, store} = Store.open(path: root, filesystem: {ObservedFileSystem, control})
    {snapshot, _inputs} = checkpoints(store, 3)
    blocks = Path.wildcard(Path.join(root, "*.journal/*")) |> MapSet.new()
    Agent.update(control, &%{&1 | forbidden: blocks})
    assert {:ok, ^snapshot} = Store.load(store, snapshot.run.run_id)
    assert {:ok, _} = RuntimeStore.store(Store, store, snapshot.run, %{command: {:start, 100}})
    assert :ok = Store.retire(store)
  end

  test "failed snapshot publication leaves the acknowledged pair exact and retry reuses its block",
       %{root: root} do
    {:ok, control} = Agent.start_link(fn -> %{forbidden: MapSet.new(), fail_snapshot: false} end)
    {:ok, store} = Store.open(path: root, filesystem: {ObservedFileSystem, control})
    {snapshot, _inputs} = checkpoints(store, 2)
    assert {:ok, journal} = Store.recovery_journal(store, snapshot.run.run_id)
    [path] = Path.wildcard(Path.join(root, "*.runtime"))
    original = File.read!(path)
    count = length(Path.wildcard(path <> ".journal/*"))
    Agent.update(control, &%{&1 | fail_snapshot: true})

    assert {:error, %{cause: :snapshot_publication_failed}} =
             RuntimeStore.store(Store, store, snapshot.run, %{command: {:start, 100}})

    assert File.read!(path) == original
    assert {:ok, ^snapshot} = Store.load(store, snapshot.run.run_id)
    assert {:ok, ^journal} = Store.recovery_journal(store, snapshot.run.run_id)
    assert length(Path.wildcard(path <> ".journal/*")) == count + 1
    Agent.update(control, &%{&1 | fail_snapshot: false})
    assert {:ok, _} = RuntimeStore.store(Store, store, snapshot.run, %{command: {:start, 100}})
    assert length(Path.wildcard(path <> ".journal/*")) == count + 1
    assert {:ok, entries} = Store.recovery_journal(store, snapshot.run.run_id)
    assert Enum.drop(entries, -1) == journal
    assert List.last(entries)["kind"] == "start"
    assert :ok = Store.retire(store)
  end

  test "legacy codecs migrate only on mutation and preserve their original prefix bytes", %{
    root: root
  } do
    for codec <- [:raw, :compressed, :zstd] do
      dir = Path.join(root, Atom.to_string(codec))
      {:ok, store} = Store.open(path: dir)
      {snapshot, _inputs} = checkpoints(store, 2)
      assert {:ok, journal} = Store.recovery_journal(store, snapshot.run.run_id)
      assert :ok = Store.retire(store)
      [path] = Path.wildcard(Path.join(dir, "*.runtime"))
      entries = raw_entries(path)
      legacy = Map.put(snapshot, :recovery_journal, %{version: 1, entries: entries})

      bytes =
        case codec do
          :raw -> :erlang.term_to_binary(legacy)
          :compressed -> :erlang.term_to_binary(legacy, compressed: 6)
          :zstd -> legacy |> :erlang.term_to_binary() |> :zstd.compress() |> IO.iodata_to_binary()
        end

      File.write!(path, bytes)
      before = tree(dir)
      {:ok, reopened} = Store.open(path: dir)
      assert {:ok, ^snapshot} = Store.load(reopened, snapshot.run.run_id)
      assert {:ok, ^snapshot} = Store.load(reopened, snapshot.run.run_id)
      assert {:ok, ^journal} = Store.recovery_journal(reopened, snapshot.run.run_id)
      assert tree(dir) == before

      assert {:ok, _} =
               RuntimeStore.store(Store, reopened, snapshot.run, %{command: {:start, 100}})

      assert {:ok, extended} = Store.recovery_journal(reopened, snapshot.run.run_id)
      assert Enum.drop(extended, -1) == journal

      assert Enum.any?(Path.wildcard(path <> ".journal/*"), fn item ->
               {:ok, block} = item |> File.read!() |> Sigma.Agent.Backplane.StoreJournal.decode()
               block[:legacy] == bytes
             end)

      assert :ok = Store.retire(reopened)
    end
  end

  test "recursive copies retain exact snapshot and public journal without rewriting files", %{
    root: root
  } do
    source = Path.join(root, "source")
    {:ok, store} = Store.open(path: source)
    {snapshot, _inputs} = checkpoints(store, 3)
    assert {:ok, journal} = Store.recovery_journal(store, snapshot.run.run_id)
    assert :ok = Store.retire(store)
    destination = Path.join(root, "copy")
    File.cp_r!(source, destination)
    File.rm_rf!(source)
    refute File.exists?(source)
    before = tree(destination)
    {:ok, reopened} = Store.open(path: destination)
    assert {:ok, ^snapshot} = Store.load(reopened, snapshot.run.run_id)
    assert {:ok, ^journal} = Store.recovery_journal(reopened, snapshot.run.run_id)
    assert tree(destination) == before
    assert :ok = Store.retire(reopened)
  end

  test "block publication failure does not change the selected snapshot or public journal", %{
    root: root
  } do
    {:ok, control} = Agent.start_link(fn -> %{forbidden: MapSet.new(), fail_snapshot: false} end)
    {:ok, store} = Store.open(path: root, filesystem: {ObservedFileSystem, control})
    {snapshot, _inputs} = checkpoints(store, 2)
    assert {:ok, journal} = Store.recovery_journal(store, snapshot.run.run_id)
    before = tree(root)
    Agent.update(control, &Map.put(&1, :fail_block, true))

    assert {:error, %{cause: :block_publication_failed}} =
             RuntimeStore.store(Store, store, snapshot.run, %{command: {:start, 100}})

    assert tree(root) == before
    assert {:ok, ^snapshot} = Store.load(store, snapshot.run.run_id)
    assert {:ok, ^journal} = Store.recovery_journal(store, snapshot.run.run_id)
    assert :ok = Store.retire(store)
  end

  test "failed fence publication exposes neither its journal entry nor a completed fence", %{
    root: root
  } do
    {:ok, control} = Agent.start_link(fn -> %{forbidden: MapSet.new(), fail_snapshot: false} end)
    {:ok, store} = Store.open(path: root, filesystem: {ObservedFileSystem, control})
    {snapshot, _inputs} = checkpoints(store, 2)
    assert {:ok, journal} = Store.recovery_journal(store, snapshot.run.run_id)
    Agent.update(control, &%{&1 | fail_snapshot: true})

    assert {:error, %{cause: :snapshot_publication_failed}} =
             Store.fence(store, snapshot.run.run_id, snapshot.revision, 1, 2)

    assert {:ok, ^snapshot} = Store.load(store, snapshot.run.run_id)
    assert {:ok, ^journal} = Store.recovery_journal(store, snapshot.run.run_id)
    assert {:ok, []} = Store.recovery_fences(store, snapshot.run.run_id)
    Agent.update(control, &%{&1 | fail_snapshot: false})
    assert {:ok, _} = Store.fence(store, snapshot.run.run_id, snapshot.revision, 1, 2)
    assert {:ok, entries} = Store.recovery_journal(store, snapshot.run.run_id)
    assert Enum.drop(entries, -1) == journal
    assert List.last(entries)["kind"] == "fence"
    assert {:ok, [_fence]} = Store.recovery_fences(store, snapshot.run.run_id)
    assert :ok = Store.retire(store)
  end

  test "unavailable or damaged history fails journal reads while the selected snapshot remains readable",
       %{root: root} do
    for damage <- [:missing, :malformed, :hash_mismatch] do
      dir = Path.join(root, Atom.to_string(damage))
      {:ok, store} = Store.open(path: dir)
      {snapshot, _inputs} = checkpoints(store, 2)
      [path] = Path.wildcard(Path.join(dir, "*.runtime"))
      {:ok, raw} = path |> File.read!() |> Sigma.Agent.Backplane.StoreJournal.decode()
      block_path = Path.join(path <> ".journal", raw.recovery_journal.head)

      case damage do
        :missing ->
          File.rm!(block_path)

        :malformed ->
          File.write!(block_path, "broken record")

        :hash_mismatch ->
          {:ok, block} = block_path |> File.read!() |> Sigma.Agent.Backplane.StoreJournal.decode()
          bytes = put_in(block.entry["input"], %{}) |> Sigma.Agent.Backplane.StoreJournal.encode()
          File.write!(block_path, bytes)
      end

      before = tree(dir)
      assert {:ok, ^snapshot} = Store.load(store, snapshot.run.run_id)
      assert {:error, _} = Store.recovery_journal(store, snapshot.run.run_id)
      assert tree(dir) == before
      assert :ok = Store.retire(store)
    end
  end

  test "legacy cached snapshots never mask changed or unreadable authoritative bytes", %{
    root: root
  } do
    {:ok, control} = Agent.start_link(fn -> %{forbidden: MapSet.new(), fail_snapshot: false} end)
    {:ok, store} = Store.open(path: root, filesystem: {ObservedFileSystem, control})
    {snapshot, _inputs} = checkpoints(store, 2)
    [path] = Path.wildcard(Path.join(root, "*.runtime"))
    entries = raw_entries(path)
    legacy = Map.put(snapshot, :recovery_journal, %{version: 1, entries: entries})
    bytes = :erlang.term_to_binary(legacy, compressed: 6)
    File.write!(path, bytes)
    assert {:ok, ^snapshot} = Store.load(store, snapshot.run.run_id)
    Agent.update(control, &Map.put(&1, :fail_read, true))
    assert {:error, %{cause: :record_read_failed}} = Store.load(store, snapshot.run.run_id)
    Agent.update(control, &Map.put(&1, :fail_read, false))
    File.rm!(path)
    assert {:error, %{class: :not_found}} = Store.load(store, snapshot.run.run_id)
    File.write!(path, "changed unreadable bytes")
    assert {:error, %{class: :malformed_result}} = Store.load(store, snapshot.run.run_id)
    changed = put_in(legacy.run.state, :cancelling)
    File.write!(path, :erlang.term_to_binary(changed, compressed: 6))
    assert {:ok, loaded} = Store.load(store, snapshot.run.run_id)
    assert loaded.run.state == :cancelling
    refute loaded == snapshot
    assert :ok = Store.retire(store)
  end

  test "a fresh BEAM reads the exact snapshot and journal without starting runtime applications",
       %{root: root} do
    dir = Path.join(root, "store")
    {:ok, store} = Store.open(path: dir)
    {snapshot, _inputs} = checkpoints(store, 3)
    assert {:ok, journal} = Store.recovery_journal(store, snapshot.run.run_id)
    assert :ok = Store.retire(store)
    before = tree(dir)
    result = Path.join(root, "cold-result.etf")

    script = ~S'''
    [dir, run_id, result] = System.argv()
    if :code.is_loaded(Backplane.AgentRuntime.Kernel), do: raise("Runtime was already loaded")
    {:ok, _registry} = Registry.start_link(keys: :unique, name: Sigma.Agent.RepositoryRegistry)
    {:ok, store} = Sigma.Agent.Backplane.Store.open(path: dir)
    {:ok, snapshot} = Sigma.Agent.Backplane.Store.load(store, run_id)
    {:ok, journal} = Sigma.Agent.Backplane.Store.recovery_journal(store, run_id)
    :ok = Sigma.Agent.Backplane.Store.retire(store)
    for name <- [Sigma.Agent.Supervisor, Sigma.Coding.Supervisor] do
      if Process.whereis(name), do: raise("Store read started a Runtime application")
    end
    File.write!(result, :erlang.term_to_binary({snapshot, journal}))
    IO.puts("COLD_JOURNAL_OK")
    '''

    paths = Enum.flat_map(:code.get_path(), &["-pa", List.to_string(&1)])

    executable =
      System.find_executable("elixir") || raise "Elixir is required for cold Store tests"

    {output, status} =
      System.cmd(
        executable,
        ["--erl", "+S 2:2"] ++ paths ++ ["-e", script, "--", dir, snapshot.run.run_id, result],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output =~ "COLD_JOURNAL_OK"
    assert :erlang.binary_to_term(File.read!(result), [:safe]) === {snapshot, journal}
    assert tree(dir) == before
  end

  defp raw_entries(path) do
    {:ok, raw} = path |> File.read!() |> Sigma.Agent.Backplane.StoreJournal.decode()
    raw_entries(path, raw.recovery_journal, [])
  end

  defp raw_entries(_path, nil, entries), do: entries

  defp raw_entries(path, descriptor, entries) do
    block_path = Path.join(path <> ".journal", descriptor.head)
    {:ok, block} = block_path |> File.read!() |> Sigma.Agent.Backplane.StoreJournal.decode()
    raw_entries(path, block.previous, [block.entry | entries])
  end

  defp tree(root) do
    Path.wildcard(Path.join(root, "**/*"))
    |> Enum.reject(&File.dir?/1)
    |> Map.new(&{Path.relative_to(&1, root), File.read!(&1)})
  end

  defp checkpoints(store, count) do
    id = "journal-growth-#{count}"

    initial = %{
      run_id: id,
      expected_revision: 0,
      incarnation: 1,
      state: :queued,
      deadline: nil,
      outcome: nil,
      children: []
    }

    assert {:ok, _} =
             RuntimeStore.store(Store, store, initial, %{
               command: {:admit, 0, %{state: :running}}
             })

    assert {:ok, admitted} = Store.load(store, id)

    {_run, inputs} =
      Enum.reduce(1..count, {admitted.run, []}, fn index, {run, inputs} ->
        messages =
          for item <- 1..index,
              do: %{
                "id" => "message-#{item}",
                "role" => "tool",
                "text" => String.duplicate("x", 2_048)
              }

        input = %{
          "run_id" => id,
          "incarnation" => 1,
          "conversation" => %{"messages" => messages}
        }

        command = {:conversation_updated, index, input}
        assert {:ok, staged} = RuntimeStore.stage(Store, store, run, %{command: command})

        assert {:ok, _} =
                 RuntimeStore.acknowledge_commit(Store, store, staged.stage, %{command: command})

        {staged.stage.run, [input | inputs]}
      end)

    assert {:ok, snapshot} = Store.load(store, id)
    {snapshot, Enum.reverse(inputs)}
  end

  defp uncompressed_size(<<0x28, 0xB5, 0x2F, 0xFD, _::binary>> = bytes),
    do: bytes |> :zstd.decompress() |> IO.iodata_length()

  defp uncompressed_size(bytes),
    do: bytes |> :erlang.binary_to_term([:safe]) |> :erlang.external_size()
end
