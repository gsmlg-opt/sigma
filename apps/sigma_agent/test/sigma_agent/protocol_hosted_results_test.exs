defmodule Sigma.Agent.ProtocolHostedResultsTest do
  use ExUnit.Case, async: false

  alias Sigma.Agent.{Message, ProtocolHostedResults, Runtime}
  alias Sigma.Session.Writer
  alias Sigma.Session.Storage.JsonlFile

  @moduletag :tmp_dir
  @session "hosted-results-runtime"
  @timestamp "2026-10-25T00:00:00Z"

  defmodule ObservedStorage do
    @behaviour Sigma.Session.Storage

    def read(storage) do
      with {:ok, entries, _diagnostics} <- read_with_diagnostics(storage), do: {:ok, entries}
    end

    def read_with_diagnostics({path, observer, gate}) do
      send(observer, {:hosted_storage_read, self()})

      case :ets.lookup(gate, :gate) do
        [{:gate, key}] ->
          send(observer, {:hosted_storage_waiting, self()})

          receive do
            :release_hosted_read ->
              Registry.unregister(Sigma.Agent.RepositoryRegistry, key)
          after
            5_000 -> raise "hosted storage gate timed out"
          end

        [] ->
          :ok
      end

      JsonlFile.read_with_diagnostics(path)
    end

    def append({path, _observer, _gate}, entry), do: JsonlFile.append(path, entry)
  end

  test "one live Writer capture uses its selected leaf rather than disk latest or supplied path",
       %{
         tmp_dir: dir
       } do
    {writer, path, _gate} = start_writer(dir)
    text = String.duplicate("原文\n", 12_000)
    first = hosted_message("first", text)
    assert {:ok, first_id} = Writer.append(writer, {:message_end, first})
    assert {:ok, sibling_id} = Writer.append(writer, {:message_end, hosted_message("sibling")})
    assert :ok = Writer.checkout(writer, first_id, sibling_id)
    drain_reads()
    before = file_state(path)

    assert {:ok, %{snapshot: snapshot, view: view}} =
             ProtocolHostedResults.load(dir, @session, Path.join(dir, "ignored.jsonl"))

    assert_receive {:hosted_storage_read, ^writer}
    refute_receive {:hosted_storage_read, _}, 20
    assert view.session_id == @session
    assert view.leaf_id == first_id
    assert snapshot.active_leaf_id == first_id
    assert snapshot.session_id != @session
    assert [%{entry_id: ^first_id, message: decoded}] = view.results
    assert decoded.content == first.content
    assert decoded.metadata == first.metadata
    assert byte_size(hd(decoded.content).text) > 32_768
    assert file_state(path) == before

    stop_supervised!(:hosted_writer)
    assert {:ok, %{view: stopped}} = ProtocolHostedResults.load(dir, @session, path)
    assert stopped.leaf_id == sibling_id
    assert Enum.map(stopped.results, & &1.message.id) == ["first", "sibling"]
    assert file_state(path) == before
  end

  test "all selected raw sources survive compaction context reset and the display tail", %{
    tmp_dir: dir
  } do
    {writer, path, _gate} = start_writer(dir)
    assert {:ok, archived_id} = Writer.append(writer, {:message_end, hosted_message("archived")})
    assert {:ok, kept_id} = Writer.append(writer, {:message_end, Message.user("kept", "Keep")})
    assert {:ok, _} = Writer.append(writer, {:compact, %{content: "Summary"}, kept_id})

    assert {:ok, _} =
             Writer.append(
               writer,
               {:context_window_started, %{run_id: "reset", incarnation: 1, window: 2}}
             )

    for index <- 1..7 do
      assert {:ok, _} = Writer.append(writer, {:message_end, hosted_message("later-#{index}")})
    end

    before = file_state(path)

    assert {:ok, %{snapshot: snapshot, view: view}} =
             ProtocolHostedResults.load(dir, @session, path)

    assert hd(view.results).entry_id == archived_id

    assert Enum.map(view.results, & &1.message.id) == [
             "archived" | Enum.map(1..7, &"later-#{&1}")
           ]

    refute Enum.any?(snapshot.messages, &(&1.id == "archived"))
    refute Enum.any?(snapshot.context_messages, &(&1.id == "archived"))
    assert snapshot.context_window == %{run_id: "reset", incarnation: 1, window: 2}
    assert file_state(path) == before
  end

  test "a live Agent without its Writer rejects instead of changing to the disk branch", %{
    tmp_dir: dir
  } do
    path = Path.join(dir, "unhealthy.jsonl")
    write_entries(path, [header(dir), entry("disk", nil, hosted_message("disk"))])

    assert {:ok, _} =
             Registry.register(
               Sigma.Agent.RepositoryRegistry,
               {Path.expand(dir), @session, :agent},
               nil
             )

    assert Runtime.lookup(dir, @session, :agent) == self()
    assert Runtime.lookup(dir, @session, :writer) == nil
    before = file_state(path)
    assert {:error, :session_unavailable} = ProtocolHostedResults.load(dir, @session, path)
    assert file_state(path) == before
  end

  test "stopped selection follows journal ancestry and physical latest rather than timestamps", %{
    tmp_dir: dir
  } do
    path = Path.join(dir, "stopped.jsonl")
    root = entry("root", nil, hosted_message("root"))
    sibling = entry("sibling", "root", hosted_message("sibling"))
    selected = entry("selected", "root", hosted_message("selected"))
    selected = Map.put(selected, "timestamp", "2020-01-01T00:00:00Z")
    write_entries(path, [header(dir), root, sibling, selected])
    before = file_state(path)

    assert {:ok, first} = ProtocolHostedResults.load(dir, @session, path)
    assert first.view.leaf_id == "selected"
    assert first.snapshot.branch_entry_ids == ["root", "selected"]
    assert Enum.map(first.view.results, & &1.entry_id) == ["root", "selected"]
    assert first.view.session_id == @session
    assert first.snapshot.session_id == "independent-header"
    assert {:ok, ^first} = ProtocolHostedResults.load(dir, @session, path)
    assert file_state(path) == before
  end

  test "other runtime sessions and repositories cannot borrow the registered Writer", %{
    tmp_dir: dir
  } do
    {writer, _path, _gate} = start_writer(dir)
    assert {:ok, _} = Writer.append(writer, {:message_end, hosted_message("private-live")})
    fallback = Path.join(dir, "trusted-fallback.jsonl")
    write_entries(fallback, [header(dir), entry("fallback", nil, hosted_message("fallback"))])

    for {repo, session} <- [{dir, "other-session"}, {Path.join(dir, "other-repo"), @session}] do
      assert Runtime.lookup(repo, session, :writer) == nil
      assert {:ok, %{view: view}} = ProtocolHostedResults.load(repo, session, fallback)
      assert view.session_id == session
      assert Enum.map(view.results, & &1.message.id) == ["fallback"]
    end
  end

  test "selected hosted decode failures reject instead of disappearing but siblings stay excluded",
       %{
         tmp_dir: dir
       } do
    path = Path.join(dir, "malformed.jsonl")
    valid = entry("valid", nil, hosted_message("valid"))
    malformed = entry("malformed", "valid", hosted_message("malformed"))
    malformed = put_in(malformed, ["message", "role"], "unsupported-role")
    selected = entry("selected", "valid", Message.user("selected", "Continue"))
    write_entries(path, [header(dir), valid, malformed, selected])

    assert {:ok, %{snapshot: snapshot, view: %{results: [result]}}} =
             ProtocolHostedResults.load(dir, @session, path)

    assert result.entry_id == "valid"
    assert snapshot.active_leaf_id == "selected"

    write_entries(path, [header(dir), valid, malformed])
    before = file_state(path)

    assert {:error, :provider_hosted_payload_rejected} =
             ProtocolHostedResults.load(dir, @session, path)

    assert file_state(path) == before
  end

  test "Writer-compatible nonblocking diagnostics are retained in the complete snapshot", %{
    tmp_dir: dir
  } do
    path = Path.join(dir, "diagnostics.jsonl")
    hosted = entry("hosted", nil, hosted_message("hosted"))
    invalid = entry("ordinary-invalid", "hosted", Message.user("invalid", "Ignored"))
    invalid = put_in(invalid, ["message", "content"], false)
    write_entries(path, [hosted, invalid])

    assert {:ok, %{snapshot: snapshot, view: view}} =
             ProtocolHostedResults.load(dir, @session, path)

    assert Enum.any?(
             snapshot.diagnostics,
             &match?(%{kind: :invalid_header, reason: :missing_header}, &1)
           )

    assert Enum.any?(snapshot.diagnostics, &match?(%{kind: :invalid_payload}, &1))
    assert Enum.map(view.results, & &1.entry_id) == ["hosted"]
  end

  test "storage corruption and structural diagnostics block the read without rewriting bytes", %{
    tmp_dir: dir
  } do
    path = Path.join(dir, "corrupt.jsonl")
    good = [header(dir), entry("hosted", nil, hosted_message("hosted"))]

    for suffix <- ["not-json\n", "{\"torn\":"] do
      write_entries(path, good)
      File.write!(path, suffix, [:append])
      before = file_state(path)

      assert {:error, {:invalid_journal, diagnostics}} =
               ProtocolHostedResults.load(dir, @session, path)

      assert Enum.any?(diagnostics, &(&1.kind in [:invalid_json, :trailing_incomplete_json]))
      assert file_state(path) == before
    end

    write_entries(path, good ++ [List.last(good)])

    assert {:error, {:invalid_journal, diagnostics}} =
             ProtocolHostedResults.load(dir, @session, path)

    assert Enum.any?(diagnostics, &(&1.kind == :duplicate_id))
    assert {:error, :eisdir} = ProtocolHostedResults.load(dir, @session, dir)
  end

  test "a Writer binding removed during its single capture returns session unavailable", %{
    tmp_dir: dir
  } do
    {writer, path, gate} = start_writer(dir)
    assert {:ok, _} = Writer.append(writer, {:message_end, hosted_message("owned")})
    :ets.insert(gate, {:gate, {Path.expand(dir), @session, :writer}})
    before = file_state(path)
    task = Task.async(fn -> ProtocolHostedResults.load(dir, @session, path) end)
    assert_receive {:hosted_storage_waiting, ^writer}
    send(writer, :release_hosted_read)
    assert {:error, :session_unavailable} = Task.await(task)
    assert Runtime.lookup(dir, @session, :writer) == nil
    assert file_state(path) == before
  end

  defp start_writer(dir) do
    path = Path.join(dir, "live.jsonl")
    gate = :ets.new(:hosted_storage_gate, [:set, :public])

    writer =
      start_supervised!(
        {Writer,
         storage_id: {path, self(), gate},
         storage_mod: ObservedStorage,
         session_id: @session,
         cwd: dir,
         name: Runtime.via(dir, @session, :writer)},
        id: :hosted_writer
      )

    assert {:ok, _} = Writer.append(writer, {:agent_start, dir})
    {writer, path, gate}
  end

  defp hosted_message(id, text \\ "Complete 原文\n") do
    metadata = %{
      "version" => 1,
      "origin" => %{
        "protocol" => "openai-responses",
        "provider" => "fixture",
        "model" => "fixture",
        "endpoint_sha256" => String.duplicate("a", 64)
      },
      "response_id" => "response-#{id}",
      "items" => [
        %{
          "output_index" => 0,
          "item" => %{
            "type" => "message",
            "id" => "output-#{id}",
            "role" => "assistant",
            "status" => "completed",
            "content" => [%{"type" => "output_text", "text" => text, "annotations" => []}]
          }
        }
      ]
    }

    Message.assistant(id, %{
      content: [%{type: :text, text: text}],
      provider: "fixture",
      model: "fixture",
      timestamp: 1,
      metadata: %{"openai_responses_hosted" => metadata, "private" => "retained-for-validation"}
    })
  end

  defp header(dir),
    do: %{
      "type" => "session",
      "version" => 3,
      "id" => "independent-header",
      "timestamp" => @timestamp,
      "cwd" => dir
    }

  defp entry(id, parent, message) do
    {:ok, entry} = Sigma.Session.EntryEncoder.encode({:message_end, message}, parent, true)
    entry |> Map.put("id", id) |> Map.put("timestamp", @timestamp)
  end

  defp write_entries(path, entries),
    do: File.write!(path, Enum.map(entries, &[Jason.encode!(&1), "\n"]))

  defp file_state(path) do
    stat = File.stat!(path, time: :posix)
    {File.read!(path), stat.size, stat.mtime, stat.inode}
  end

  defp drain_reads do
    receive do
      {:hosted_storage_read, _writer} -> drain_reads()
    after
      0 -> :ok
    end
  end
end
