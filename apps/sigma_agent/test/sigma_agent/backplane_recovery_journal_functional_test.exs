defmodule Sigma.Agent.BackplaneRecoveryJournalFunctionalTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.Error
  alias Backplane.AgentRuntime.Store, as: RuntimeStore
  alias Sigma.Agent.Backplane.Store

  @moduletag :tmp_dir

  defmodule FaultableFileSystem do
    def ensure_dir(_fault, path), do: Store.FileSystem.ensure_dir(path)
    def read(_fault, path), do: Store.FileSystem.read(path)

    def write_atomic(fault, path, bytes) do
      if Agent.get(fault, & &1),
        do: {:error, :journal_commit_failed},
        else: Store.FileSystem.write_atomic(path, bytes)
    end
  end

  test "exact command input and fences share the authoritative snapshot commit and survive reopening",
       %{tmp_dir: dir} do
    {:ok, store} = Store.open(path: dir)
    run = run("journal")
    input = %{state: :running, original: "  中文\r\n e\u0301\n"}
    assert {:ok, _} = RuntimeStore.store(Store, store, run, %{command: {:admit, 10, input}})
    assert {:ok, before} = Store.load(store, run.run_id)
    assert {:ok, [admit]} = Store.recovery_journal(store, run.run_id)

    assert admit == %{
             "revision" => 1,
             "prior_revision" => 0,
             "prior_incarnation" => 1,
             "incarnation" => 1,
             "kind" => "admit",
             "input" => %{"state" => "running", "original" => input.original}
           }

    assert {:ok, %{revision: 2}} = Store.fence(store, run.run_id, 1, 1, 2)
    assert {:ok, [^admit, fence]} = Store.recovery_journal(store, run.run_id)

    assert fence == %{
             "revision" => 2,
             "prior_revision" => 1,
             "prior_incarnation" => 1,
             "incarnation" => 2,
             "kind" => "fence",
             "input" => %{}
           }

    assert {:ok, after_fence} = Store.load(store, run.run_id)
    assert Map.keys(after_fence) == Map.keys(before)
    assert :ok = Store.retire(store)
    files = files(dir)
    {:ok, reopened} = Store.open(path: dir)
    assert {:ok, ^after_fence} = Store.load(reopened, run.run_id)
    assert {:ok, [^admit, ^fence]} = Store.recovery_journal(reopened, run.run_id)
    assert files(dir) == files
    assert :ok = Store.retire(reopened)
  end

  test "public journal preserves complete host messages and provider failures without changing the commit",
       %{tmp_dir: dir} do
    {:ok, store} = Store.open(path: dir)
    run = run("host-values")
    stop = %Sigma.Ai.ProviderStopReason{reason: :stop, raw: "end_turn"}

    error = %Sigma.Ai.ProviderError{
      kind: :server_error,
      message: "overloaded",
      status: 503,
      code: "server_error",
      retry_after_ms: 1_000,
      retryable: true,
      raw: %{"detail" => [nil, false, 0, "  中文\r\n"]}
    }

    message = %Sigma.Agent.Message{
      id: "original-message",
      role: :assistant,
      content: [%{type: :text, text: "  中文\r\n e\u0301\n"}],
      stop_reason: stop,
      metadata: %{"complete" => [nil, false, 0, ""]}
    }

    input = %{
      context: %{conversation: %{messages: [message]}},
      result: %{terminal: %{stop_reason: stop}, error: error}
    }

    assert {:ok, _} =
             RuntimeStore.store(Store, store, run, %{
               command: {:admit, 10, input}
             })

    bytes = files(dir)
    [path] = Map.keys(bytes)
    raw = :erlang.binary_to_term(bytes[path], [:safe])
    block_path = Path.join(path <> ".journal", raw.recovery_journal.head)
    {:ok, block} = block_path |> File.read!() |> Sigma.Agent.Backplane.StoreJournal.decode()
    assert block.entry["input"] === input
    assert {:ok, [completed]} = Store.recovery_journal(store, run.run_id)
    projected = get_in(completed, ["input", "context", "conversation", "messages", Access.at(0)])
    assert map_size(projected) == map_size(Map.from_struct(message))
    assert projected["id"] == message.id
    assert projected["content"] == [%{"type" => "text", "text" => hd(message.content).text}]
    assert projected["metadata"] === message.metadata
    assert projected["stop_reason"] == %{"reason" => "stop", "raw" => "end_turn"}

    assert get_in(completed, ["input", "result", "terminal", "stop_reason"]) ==
             projected["stop_reason"]

    projected_error = get_in(completed, ["input", "result", "error"])
    assert map_size(projected_error) == map_size(Map.from_struct(error))
    assert projected_error["kind"] == "server_error"
    assert projected_error["message"] == "overloaded"
    assert projected_error["status"] == 503
    assert projected_error["code"] == "server_error"
    assert projected_error["retry_after_ms"] == 1_000
    assert projected_error["retryable"] == true
    assert projected_error["raw"] === error.raw

    assert files(dir) == bytes
    assert :ok = Store.retire(store)
  end

  # An attached but never-prompted run is cancelled before admission, so the
  # journal's genesis entry is `cancel`, not `admit`; later entries must extend it.
  test "a run cancelled before admission keeps an extendable journal", %{tmp_dir: dir} do
    {:ok, store} = Store.open(path: dir)
    run = run("idle-cancel")
    assert {:ok, _} = RuntimeStore.store(Store, store, run, %{command: {:cancel, 10}})
    assert {:ok, %{run: %{state: :cancelling}}} = Store.load(store, run.run_id)

    assert {:ok, [%{"kind" => "cancel", "revision" => 1}]} =
             Store.recovery_journal(store, run.run_id)

    assert {:ok, %{revision: 2}} = Store.fence(store, run.run_id, 1, 1, 2)

    assert {:ok,
            [
              %{"kind" => "cancel", "revision" => 1, "prior_revision" => 0},
              %{"kind" => "fence", "revision" => 2, "prior_revision" => 1}
            ]} = Store.recovery_journal(store, run.run_id)

    assert :ok = Store.retire(store)
  end

  test "failed snapshot persistence cannot acknowledge or append the proposed journal entry",
       %{tmp_dir: dir} do
    {:ok, fault} = Agent.start_link(fn -> false end)
    {:ok, store} = Store.open(path: dir, filesystem: {FaultableFileSystem, fault})
    run = run("failure")
    assert {:ok, _} = RuntimeStore.store(Store, store, run, %{command: {:admit, 10, %{}}})
    assert {:ok, old} = Store.load(store, run.run_id)
    assert {:ok, journal} = Store.recovery_journal(store, run.run_id)
    bytes = files(dir)
    :ok = Agent.update(fault, fn _ -> true end)

    assert {:error, %Error{class: :execution_failure, cause: :journal_commit_failed}} =
             RuntimeStore.store(Store, store, old.run, %{command: {:start, 11}})

    assert {:ok, ^old} = Store.load(store, run.run_id)
    assert {:ok, ^journal} = Store.recovery_journal(store, run.run_id)
    assert files(dir) == bytes
    :ok = Agent.update(fault, fn _ -> false end)
    assert {:ok, _} = RuntimeStore.store(Store, store, old.run, %{command: {:start, 11}})

    assert {:ok, [_, %{"kind" => "start", "revision" => 2}]} =
             Store.recovery_journal(store, run.run_id)

    assert :ok = Store.retire(store)
  end

  test "legacy snapshots remain readable and mutations never fabricate their missing admission prefix",
       %{tmp_dir: dir} do
    {:ok, store} = Store.open(path: dir)
    run = run("legacy")
    assert {:ok, _} = RuntimeStore.store(Store, store, run, %{command: {:admit, 10, %{}}})
    assert {:ok, original} = Store.load(store, run.run_id)
    assert :ok = Store.retire(store)
    [path] = Path.wildcard(Path.join(dir, "*.runtime"))
    raw = path |> File.read!() |> :erlang.binary_to_term([:safe])
    File.write!(path, :erlang.term_to_binary(Map.delete(raw, :recovery_journal)))
    bytes = files(dir)
    {:ok, reopened} = Store.open(path: dir)
    assert {:ok, ^original} = Store.load(reopened, run.run_id)

    assert {:error, %Error{class: :unsupported_capability}} =
             Store.recovery_journal(reopened, run.run_id)

    assert files(dir) == bytes
    assert {:ok, _} = RuntimeStore.store(Store, reopened, original.run, %{command: {:start, 11}})

    assert {:error, %Error{class: :unsupported_capability}} =
             Store.recovery_journal(reopened, run.run_id)

    assert {:ok, %{revision: 2}} = Store.load(reopened, run.run_id)
    assert {:ok, %{revision: 3}} = Store.fence(reopened, run.run_id, 2, 1, 2)

    assert {:error, %Error{class: :unsupported_capability}} =
             Store.recovery_journal(reopened, run.run_id)

    assert :ok = Store.retire(reopened)
  end

  test "large repeated image content survives a commit from a legacy ETF and a cold reopen",
       %{tmp_dir: dir} do
    {:ok, store} = Store.open(path: dir)
    run = run("image-history")
    image = :crypto.strong_rand_bytes(768 * 1024) |> Base.encode64()
    images = List.duplicate(image, 12)
    input = %{state: :running, images: images}
    assert {:ok, _} = RuntimeStore.store(Store, store, run, %{command: {:admit, 10, input}})
    assert {:ok, before} = Store.load(store, run.run_id)
    assert {:ok, [admit]} = Store.recovery_journal(store, run.run_id)
    assert admit["input"]["images"] == images

    [path] = Path.wildcard(Path.join(dir, "*.runtime"))
    frame = File.read!(path)
    assert byte_size(frame) < 2 * byte_size(image)
    raw = frame |> :zstd.decompress() |> IO.iodata_to_binary() |> :erlang.binary_to_term([:safe])
    block_path = Path.join(path <> ".journal", raw.recovery_journal.head)
    {:ok, block} = block_path |> File.read!() |> Sigma.Agent.Backplane.StoreJournal.decode()
    legacy = Map.put(raw, :recovery_journal, %{version: 1, entries: [block.entry]})
    legacy_bytes = :erlang.term_to_binary(legacy, compressed: 6)
    File.write!(path, legacy_bytes)
    assert {:ok, ^before} = Store.load(store, run.run_id)
    assert {:ok, %{revision: 2}} = Store.fence(store, run.run_id, 1, 1, 2)
    assert :ok = Store.retire(store)

    assert Enum.any?(Path.wildcard(path <> ".journal/*"), fn block_path ->
             {:ok, block} =
               block_path |> File.read!() |> Sigma.Agent.Backplane.StoreJournal.decode()

             block[:legacy] == legacy_bytes
           end)

    {:ok, reopened} = Store.open(path: dir)
    assert {:ok, %{revision: 2}} = Store.load(reopened, run.run_id)
    assert {:ok, [^admit, %{"kind" => "fence"}]} = Store.recovery_journal(reopened, run.run_id)
    assert :ok = Store.retire(reopened)
  end

  defp run(id) do
    %{
      run_id: id,
      expected_revision: 0,
      incarnation: 1,
      state: :queued,
      deadline: nil,
      outcome: nil,
      children: []
    }
  end

  defp files(dir),
    do: Map.new(Path.wildcard(Path.join(dir, "*.runtime")), &{&1, File.read!(&1)})
end
