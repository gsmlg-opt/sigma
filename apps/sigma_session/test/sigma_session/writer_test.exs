defmodule Sigma.Session.WriterTest do
  use ExUnit.Case, async: true

  alias Sigma.Agent.Message
  alias Sigma.Session.Storage.JsonlFile
  alias Sigma.Session.Writer

  defmodule RecordingStorage do
    @behaviour Sigma.Session.Storage

    @impl true
    def read(storage), do: read_with_diagnostics(storage) |> then(fn {:ok, entries, _} -> {:ok, entries} end)

    @impl true
    def read_with_diagnostics(storage) do
      Agent.get_and_update(storage, fn state ->
        {{:ok, state.entries, Map.get(state, :diagnostics, [])},
         Map.update(state, :read_count, 1, &(&1 + 1))}
      end)
    end

    @impl true
    def append(storage, entry) do
      Agent.get_and_update(storage, fn state ->
        {result, remaining_results} =
          case Map.get(state, :append_results, []) do
            [result | rest] -> {result, rest}
            [] -> {:ok, []}
          end

        entries = if result == :ok, do: state.entries ++ [entry], else: state.entries
        {result, %{state | entries: entries, append_results: remaining_results}}
      end)
    end
  end

  defmodule BlockingStorage do
    @behaviour Sigma.Session.Storage

    @impl true
    def read({_owner, entries}), do: {:ok, entries}

    @impl true
    def read_with_diagnostics({_owner, entries}), do: {:ok, entries, []}

    @impl true
    def append({owner, _entries}, entry) do
      send(owner, {:append_requested, self(), entry})

      receive do
        {:append_result, result} -> result
      end
    end
  end

  defp start_storage(initial \\ %{}) do
    {:ok, storage} =
      Agent.start_link(fn ->
        Map.merge(%{entries: [], append_results: [], diagnostics: [], read_count: 0}, initial)
      end)

    storage
  end

  defp header do
    %{
      "type" => "session",
      "version" => 3,
      "id" => "session-1",
      "timestamp" => "2026-09-01T00:00:00Z",
      "cwd" => "/repo"
    }
  end

  test "appends one header and messages without rereading storage" do
    storage = start_storage()

    {:ok, writer} =
      Writer.start_link(
        storage_id: storage,
        storage_mod: RecordingStorage,
        session_id: "session-1",
        cwd: "/repo"
      )

    assert {:ok, _header_id} = Writer.append(writer, {:agent_start, "/repo"})
    assert :ignored = Writer.append(writer, {:agent_start, "/repo"})
    assert {:ok, first_id} = Writer.append(writer, {:message_end, Message.user("m1", "one")})
    assert {:ok, second_id} = Writer.append(writer, {:message_end, Message.user("m2", "two")})

    assert %{read_count: 1, entries: [written_header, first, second]} = Agent.get(storage, & &1)
    assert written_header["type"] == "session"
    assert first["id"] == first_id
    assert first["parentId"] == nil
    assert second["id"] == second_id
    assert second["parentId"] == first_id
  end

  test "does not advance the active leaf after an append failure" do
    storage =
      start_storage(%{
        entries: [header()],
        append_results: [{:error, :disk_full}, :ok]
      })

    {:ok, writer} =
      Writer.start_link(
        storage_id: storage,
        storage_mod: RecordingStorage,
        session_id: "session-1",
        cwd: "/repo"
      )

    assert {:error, {:storage_append_failed, :disk_full}} =
             Writer.append(writer, {:message_end, Message.user("failed", "not durable")})

    assert {:ok, successful_id} =
             Writer.append(writer, {:message_end, Message.user("saved", "durable")})

    assert %{entries: [_header, successful]} = Agent.get(storage, & &1)
    assert successful["id"] == successful_id
    assert successful["parentId"] == nil
    assert get_in(successful, ["message", "id"]) == "saved"
  end

  @tag :tmp_dir
  test "reconstructs the active leaf after a writer restart", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "restart.jsonl")

    {:ok, writer} = Writer.start_link(storage_id: path, session_id: "session-1", cwd: "/repo")
    assert {:ok, _header_id} = Writer.append(writer, {:agent_start, "/repo"})
    assert {:ok, first_id} = Writer.append(writer, {:message_end, Message.user("m1", "one")})
    GenServer.stop(writer)

    {:ok, restarted} =
      Writer.start_link(storage_id: path, session_id: "session-1", cwd: "/repo")

    assert {:ok, second_id} =
             Writer.append(restarted, {:message_end, Message.user("m2", "two")})

    assert {:ok, [_header, first, second]} = JsonlFile.read(path)
    assert first["id"] == first_id
    assert second["id"] == second_id
    assert second["parentId"] == first_id
  end

  test "serializes concurrent append calls in mailbox order" do
    {:ok, writer} =
      Writer.start_link(
        storage_id: {self(), [header()]},
        storage_mod: BlockingStorage,
        session_id: "session-1",
        cwd: "/repo"
      )

    first = Task.async(fn -> Writer.append(writer, {:message_end, Message.user("m1", "one")}) end)
    assert_receive {:append_requested, ^writer, first_entry}

    second = Task.async(fn -> Writer.append(writer, {:message_end, Message.user("m2", "two")}) end)
    refute_receive {:append_requested, ^writer, _entry}, 50

    send(writer, {:append_result, :ok})
    assert {:ok, first_id} = Task.await(first)
    assert first_entry["id"] == first_id

    assert_receive {:append_requested, ^writer, second_entry}
    assert second_entry["parentId"] == first_id
    send(writer, {:append_result, :ok})
    assert {:ok, second_id} = Task.await(second)
    assert second_entry["id"] == second_id
  end

  test "parents compaction and behavioral state to the last acknowledged entry" do
    storage = start_storage(%{entries: [header()]})

    {:ok, writer} =
      Writer.start_link(
        storage_id: storage,
        storage_mod: RecordingStorage,
        session_id: "session-1",
        cwd: "/repo"
      )

    assert {:ok, message_id} =
             Writer.append(writer, {:message_end, Message.user("m1", "one")})

    assert {:ok, compaction_id} =
             Writer.append(
               writer,
               {:compact,
                %Message{id: "summary", role: :compaction_summary, content: "condensed"},
                message_id}
             )

    assert {:ok, model_id} = Writer.append(writer, {:model_change, "anthropic", "opus"})

    assert %{entries: [_header, message, compaction, model]} = Agent.get(storage, & &1)
    assert message["id"] == message_id
    assert compaction["id"] == compaction_id
    assert compaction["parentId"] == message_id
    assert model["id"] == model_id
    assert model["parentId"] == compaction_id
  end

  test "transient events perform no storage writes" do
    storage = start_storage(%{entries: [header()]})

    {:ok, writer} =
      Writer.start_link(
        storage_id: storage,
        storage_mod: RecordingStorage,
        session_id: "session-1",
        cwd: "/repo"
      )

    assert :ignored = Writer.append(writer, {:turn_start})
    assert :ignored = Writer.append(writer, {:message_start, Message.user("m1", "one")})
    assert :ignored = Writer.append(writer, {:message_update, %{}, %{}})
    assert %{read_count: 1, entries: [_header]} = Agent.get(storage, & &1)
  end

  test "emits bounded append telemetry without message content" do
    storage = start_storage(%{entries: [header()]})
    test_pid = self()
    handler_id = {__MODULE__, self(), :append}

    :telemetry.attach(
      handler_id,
      [:sigma, :session, :writer, :append],
      fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry_event, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    {:ok, writer} =
      Writer.start_link(
        storage_id: storage,
        storage_mod: RecordingStorage,
        session_id: "session-1",
        cwd: "/repo"
      )

    assert {:ok, _entry_id} =
             Writer.append(writer, {:message_end, Message.user("m1", "secret prompt")})

    assert_receive {
      :telemetry_event,
      [:sigma, :session, :writer, :append],
      %{count: 1, duration: duration},
      %{entry_type: :message, result: :ok, session_id: "session-1"} = metadata
    }

    assert is_integer(duration)
    refute inspect(metadata) =~ "secret prompt"
  end
end
