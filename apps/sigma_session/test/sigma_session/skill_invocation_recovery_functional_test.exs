defmodule Sigma.Session.SkillInvocationRecoveryFunctionalTest do
  use ExUnit.Case, async: true

  alias Sigma.Session.{SessionFiles, SkillInvocationStore}

  @moduletag :tmp_dir

  test "recovering an absent invocation ledger leaves it absent", %{tmp_dir: root} do
    path = ledger_path(root)

    assert {:ok, []} = SkillInvocationStore.recover(root, "session-1")
    refute File.exists?(path)
    assert {:ok, []} = SkillInvocationStore.recover(root, "session-1")
    refute File.exists?(path)
  end

  test "empty and terminal ledgers retain their exact bytes and file identity", %{tmp_dir: root} do
    path = ledger_path(root)
    records = Enum.map(~w(completed failed cancelled interrupted), &record/1)

    for {bytes, expected} <- [
          {"[\r\n]\n", []},
          {Jason.encode!(records, pretty: true) <> "\r\n", records}
        ] do
      File.write!(path, bytes)
      before = snapshot(path)

      assert {:ok, ^expected} = SkillInvocationStore.recover(root, "session-1")
      assert snapshot(path) == before
      assert {:ok, ^expected} = SkillInvocationStore.recover(root, "session-1")
      assert snapshot(path) == before
    end
  end

  test "pending records are interrupted once while preserving order and original fields", %{
    tmp_dir: root
  } do
    path = ledger_path(root)
    records = Enum.map(~w(completed preparing queued running cancelled), &record/1)
    File.write!(path, Jason.encode!(records))

    expected =
      Enum.map(records, fn record ->
        if record["state"] in ~w(preparing queued running),
          do: Map.put(record, "state", "interrupted"),
          else: record
      end)

    assert {:ok, ^expected} = SkillInvocationStore.recover(root, "session-1")
    assert {:ok, ^expected} = SkillInvocationStore.list(root, "session-1")
    recovered = snapshot(path)
    assert {:ok, ^expected} = SkillInvocationStore.recover(root, "session-1")
    assert snapshot(path) == recovered
  end

  test "a completed caller exiting does not interrupt another session's recovery", %{
    tmp_dir: root
  } do
    supervisor = start_supervised!(Task.Supervisor)
    parent = self()

    owner =
      Task.Supervisor.async_nolink(supervisor, fn ->
        result = SkillInvocationStore.reserve(root, "other-session", record("completed"))
        send(parent, {:reserved, self(), result})

        receive do
          :finish -> :ok
        end
      end)

    owner_pid = owner.pid
    assert_receive {:reserved, ^owner_pid, {:ok, _}}, 1_000
    path = ledger_path(root)
    {_output, 0} = System.cmd("mkfifo", [path])

    reader =
      Task.Supervisor.async_nolink(supervisor, fn ->
        SkillInvocationStore.recover(root, "session-1")
      end)

    writer =
      Task.Supervisor.async_nolink(supervisor, fn ->
        # Pair the FIFO outside the file server blocked by recover/2's read.
        {:ok, file} = File.open(path, [:write, :raw])

        try do
          send(parent, {:reader_opened, self()})

          receive do
            :write -> :file.write(file, "[]")
          end
        after
          File.close(file)
        end
      end)

    writer_pid = writer.pid
    assert_receive {:reader_opened, ^writer_pid}, 1_000
    send(owner_pid, :finish)
    assert Task.await(owner) == :ok
    send(writer_pid, :write)
    assert Task.await(writer) == :ok
    assert Task.yield(reader, 1_000) == {:ok, {:ok, []}}
    assert {:ok, %{type: :other}} = File.stat(path)
  end

  defp record(state) do
    %{
      "invocationId" => "inv-" <> state,
      "requestKey" => "request-" <> state,
      "fingerprint" => "fingerprint-" <> state,
      "state" => state,
      "arguments" => "  中文 é 👩‍💻\r\n第二行\n",
      "result" => %{"items" => [nil, true, 3], "text" => "original result\r\n"}
    }
  end

  defp ledger_path(root) do
    {:ok, path} = SessionFiles.jsonl_path(root, "session-1")
    path <> ".skill-invocations.json"
  end

  defp snapshot(path) do
    stat = File.stat!(path, time: :posix)
    {File.read!(path), Map.take(stat, [:inode, :mtime, :size])}
  end
end
