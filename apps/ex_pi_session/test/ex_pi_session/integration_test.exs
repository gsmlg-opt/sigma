defmodule PiSession.IntegrationTest do
  use ExUnit.Case, async: false

  alias PiSession.Log
  alias PiSession.Storage.JsonlFile

  @test_dir "tmp/integration_tests"

  setup do
    File.mkdir_p!(@test_dir)

    on_exit(fn ->
      File.rm_rf!(@test_dir)
    end)

    :ok
  end

  defmodule MockProvider do
    def stream(params) do
      prompt = get_last_user_prompt(params.context.messages)
      content = "Response to: #{prompt}"

      initial_msg = %{
        role: :assistant,
        content: [],
        model: "mock-model",
        provider: "mock-provider",
        api: "mock-api",
        usage: %{
          input: 10,
          output: 0,
          cache_read: 0,
          cache_write: 0,
          total_tokens: 10,
          cost: %{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0, total: 0.0}
        },
        stop_reason: nil,
        timestamp: System.system_time(:millisecond)
      }

      delta_msg = %{initial_msg | content: [%{type: :text, text: content}]}

      done_msg = %{
        delta_msg
        | stop_reason: :stop,
          usage: %{delta_msg.usage | output: 1, total_tokens: 11}
      }

      [
        {:start, initial_msg},
        {:text_delta, 0, content, delta_msg},
        {:done, :stop, done_msg}
      ]
    end

    defp get_last_user_prompt(messages) do
      messages
      |> Enum.reverse()
      |> Enum.find(fn m -> m.role == :user end)
      |> case do
        nil ->
          "None"

        m ->
          case m.content do
            [%{text: text} | _] -> text
            text when is_binary(text) -> text
            _ -> "Unknown"
          end
      end
    end
  end

  defp run_turn(agent, storage_id, prompt) do
    PiAgent.prompt(agent, prompt)

    consume_events(storage_id)
  end

  defp consume_events(storage_id) do
    receive do
      {:agent_end, _messages} = event ->
        Log.persist_event(storage_id, event)
        :ok

      event ->
        Log.persist_event(storage_id, event)
        consume_events(storage_id)
    after
      5000 ->
        flunk("Timeout waiting for agent events")
    end
  end

  defp get_content(msg) do
    case msg.content do
      [%{text: text} | _] -> text
      text when is_binary(text) -> text
      _ -> msg.content
    end
  end

  describe "Crash Test" do
    test "agent can resume after a crash" do
      storage_id = Path.join(@test_dir, "crash_test.jsonl")
      model = %{id: "mock-model", api: "mock-api", provider: "mock-provider"}

      # 1. Start agent and perform a turn
      {:ok, agent1} = PiAgent.start_link(model: model, provider: MockProvider)
      PiAgent.subscribe(agent1)
      run_turn(agent1, storage_id, "Hello 1")

      # Stop the agent (simulate crash)
      GenServer.stop(agent1)

      # 2. Replay messages from log
      {:ok, replayed_messages} = Log.replay(storage_id)
      assert length(replayed_messages) == 2
      assert Enum.at(replayed_messages, 0).content == "Hello 1"
      assert get_content(Enum.at(replayed_messages, 1)) == "Response to: Hello 1"

      # 3. Restart new agent with replayed messages
      {:ok, agent2} =
        PiAgent.start_link(
          model: model,
          provider: MockProvider,
          messages: replayed_messages
        )

      PiAgent.subscribe(agent2)

      # 4. Verify it continues correctly
      run_turn(agent2, storage_id, "Hello 2")

      {:ok, final_messages} = Log.replay(storage_id)
      assert length(final_messages) == 4
      assert Enum.at(final_messages, 2).content == "Hello 2"
      assert get_content(Enum.at(final_messages, 3)) == "Response to: Hello 2"
    end
  end

  describe "Branch Test" do
    test "forked sessions advance independently" do
      parent_storage_id = Path.join(@test_dir, "parent.jsonl")
      branch_storage_id = Path.join(@test_dir, "branch.jsonl")
      model = %{id: "mock-model", api: "mock-api", provider: "mock-provider"}

      # 1. Perform 3 turns in a parent session
      {:ok, parent_agent} = PiAgent.start_link(model: model, provider: MockProvider)
      PiAgent.subscribe(parent_agent)
      run_turn(parent_agent, parent_storage_id, "P1")
      run_turn(parent_agent, parent_storage_id, "P2")
      run_turn(parent_agent, parent_storage_id, "P3")

      # Parent should have 6 messages (3 user + 3 assistant)
      {:ok, parent_messages} = Log.replay(parent_storage_id)
      assert length(parent_messages) == 6

      # 2. Fork at index 3 (after 2nd assistant message, which is index 3)
      # Index 0: User P1, 1: Assistant P1, 2: User P2, 3: Assistant P2
      # Replaying entries:
      # Entry 0: Session header
      # Entry 1: Message P1 (user)
      # Entry 2: Message Response P1 (assistant)
      # Entry 3: Message P2 (user)
      # Entry 4: Message Response P2 (assistant)
      # Wait, Log.replay filters out session header for the returned messages.
      # But fork takes index of ALL entries.

      {:ok, _entries} = JsonlFile.read(parent_storage_id)
      # entries: [Header, Msg1, Msg2, Msg3, Msg4, Msg5, Msg6]
      # Let's fork after the 4th message (Msg4), so index 4.
      {:ok, _branch_id} = Log.fork(parent_storage_id, branch_storage_id, 4, "/tmp")

      # 3. Advance both branches independently
      run_turn(parent_agent, parent_storage_id, "P4")

      {:ok, replayed_branch} = Log.replay(branch_storage_id)
      assert length(replayed_branch) == 4

      {:ok, branch_agent} =
        PiAgent.start_link(
          model: model,
          provider: MockProvider,
          messages: replayed_branch
        )

      PiAgent.subscribe(branch_agent)
      run_turn(branch_agent, branch_storage_id, "B3")

      # 4. Verify no cross-contamination
      {:ok, final_parent} = Log.replay(parent_storage_id)
      {:ok, final_branch} = Log.replay(branch_storage_id)

      # Parent: P1, RP1, P2, RP2, P3, RP3, P4, RP4
      assert length(final_parent) == 8
      assert Enum.at(final_parent, 6).content == "P4"

      # Branch: P1, RP1, P2, RP2, B3, RB3
      assert length(final_branch) == 6
      assert Enum.at(final_branch, 4).content == "B3"
      assert get_content(Enum.at(final_branch, 5)) == "Response to: B3"
    end
  end

  describe "Compaction Isolation Test" do
    test "compacting a fork leaves the parent log unchanged" do
      parent_storage_id = Path.join(@test_dir, "parent_compact.jsonl")
      branch_storage_id = Path.join(@test_dir, "branch_compact.jsonl")
      model = %{id: "mock-model", api: "mock-api", provider: "mock-provider"}

      # 1. Fork a session
      {:ok, parent_agent} = PiAgent.start_link(model: model, provider: MockProvider)
      PiAgent.subscribe(parent_agent)
      run_turn(parent_agent, parent_storage_id, "P1")

      {:ok, parent_entries_before} = File.read(parent_storage_id)

      {:ok, _branch_id} = Log.fork(parent_storage_id, branch_storage_id, 2, "/tmp")

      # 2. Compact the fork
      {:ok, branch_messages} = Log.replay(branch_storage_id)
      last_msg_id = List.last(branch_messages).id
      Log.compact(branch_storage_id, "Summary", last_msg_id)

      # 3. Verify the parent log file is unchanged
      {:ok, parent_entries_after} = File.read(parent_storage_id)
      assert parent_entries_before == parent_entries_after

      # Verify branch is compacted
      {:ok, replayed_branch} = Log.replay(branch_storage_id)
      # Should have Summary + Last Message (P1 assistant)
      assert length(replayed_branch) == 2
      assert Enum.at(replayed_branch, 0).role == :compaction_summary
      assert get_content(Enum.at(replayed_branch, 1)) == "Response to: P1"
    end
  end
end
