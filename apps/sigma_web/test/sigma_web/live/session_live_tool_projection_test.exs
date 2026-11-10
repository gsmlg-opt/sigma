defmodule Sigma.Web.SessionLiveToolProjectionTest do
  @moduledoc """
  Tool results must update the owning tool call block instead of becoming
  top-level chat cards, and live events must project exactly like history.
  """
  use Sigma.Web.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Sigma.Agent.Message
  alias Sigma.Session.{ConfigManager, RepoManager}

  @workdir "/tmp/pi-tool-projection-test"

  setup do
    previous_agent_dir = Application.get_env(:sigma_session, :agent_dir)

    agent_dir =
      Path.join(System.tmp_dir!(), "sigma-tool-projection-#{System.unique_integer([:positive])}")

    Application.put_env(:sigma_session, :agent_dir, agent_dir)

    on_exit(fn ->
      File.rm_rf!(@workdir)
      File.rm_rf!(agent_dir)

      if previous_agent_dir,
        do: Application.put_env(:sigma_session, :agent_dir, previous_agent_dir),
        else: Application.delete_env(:sigma_session, :agent_dir)
    end)

    File.mkdir_p!(@workdir)
    File.rm_rf!(ConfigManager.sessions_dir(@workdir))
    {:ok, _repo} = RepoManager.add_repo(@workdir, name: "Repo")
    :ok
  end

  defp open_session(conn) do
    session_id = "projection_#{System.unique_integer([:positive, :monotonic])}"
    key = ConfigManager.repository_key(@workdir)
    {:ok, view, _html} = live(conn, "/repository/#{key}/sessions/#{session_id}")
    render_async(view, 3_000)
    {view, session_id}
  end

  defp drain_snapshots(ref) do
    receive do
      {^ref, {:push_event, "chat:event", %{type: "chat.snapshot"}}} -> drain_snapshots(ref)
    after
      0 -> :ok
    end
  end

  defp snapshot(view, session_id) do
    %{proxy: {ref, _topic, _}} = view
    send(view.pid, :flush_chat)
    render(view)
    drain_snapshots(ref)
    render_hook(view, "chat.sync", %{"id" => "messages", "conversation_id" => session_id})
    assert_push_event(view, "chat:event", %{type: "chat.snapshot"} = snapshot)
    snapshot
  end

  defp assistant(id, content),
    do: %Message{id: id, role: :assistant, content: content, timestamp: 1_000}

  defp call(id, command),
    do: %{type: :tool_call, id: id, name: "bash", arguments: %{"command" => command}}

  defp result(id, call_id, text, opts \\ []) do
    %Message{
      id: id,
      role: :tool_result,
      tool_call_id: call_id,
      tool_name: "bash",
      content: [%{type: :text, text: text}],
      is_error: Keyword.get(opts, :error, false),
      timestamp: 2_000
    }
  end

  defp deliver_result(view, msg) do
    send(view.pid, {:message_start, msg})
    send(view.pid, {:message_end, msg})
  end

  test "T01/T02/T07 tool result updates its call block only, idempotently", %{conn: conn} do
    {view, sid} = open_session(conn)
    parent = assistant("a1", [call("call-1", "ls")])

    send(view.pid, {:message_start, parent})
    send(view.pid, {:message_end, parent})
    res = result("r1", "call-1", "file-a\nfile-b")

    send(view.pid, {:message_start, res})
    # a mid-flight snapshot must not create a card either
    send(view.pid, {:message_update, res, :tool_output})
    send(view.pid, {:message_end, res})
    # replay of the same events
    deliver_result(view, res)

    snap = snapshot(view, sid)
    assert Enum.map(snap.messages, & &1.id) == ["a1"]
    refute Enum.any?(snap.messages, &(&1.author == "Context compaction"))

    assert [%{id: "call-1", status: "success", result: "file-a\nfile-b"}] =
             hd(snap.messages).tools

    assert [%{type: "tool", id: "call-1", result: "file-a\nfile-b"}] = hd(snap.messages).blocks
  end

  test "T03 text, tool, text keep their original block order", %{conn: conn} do
    {view, sid} = open_session(conn)

    parent =
      assistant("a1", [
        %{type: :text, text: "before"},
        call("call-1", "ls"),
        %{type: :text, text: "```elixir\nIO.puts(:ok)\n```"}
      ])

    send(view.pid, {:message_end, parent})
    deliver_result(view, result("r1", "call-1", "out"))

    [message] = snapshot(view, sid).messages

    assert [
             %{type: "text", text: "before"},
             %{type: "tool", id: "call-1", status: "success"},
             %{type: "text", text: "```elixir\nIO.puts(:ok)\n```"}
           ] = message.blocks
  end

  test "T04/T05 parallel calls are attributed by id and keep call order", %{conn: conn} do
    {view, sid} = open_session(conn)

    send(
      view.pid,
      {:message_end, assistant("a1", [call("A", "echo same"), call("B", "echo same")])}
    )

    deliver_result(view, result("rb", "B", "same"))
    [message] = snapshot(view, sid).messages
    assert [%{id: "A", status: "running"}, %{id: "B", status: "success"}] = message.tools

    deliver_result(view, result("ra", "A", "same"))
    [message] = snapshot(view, sid).messages
    assert [%{id: "A", result: "same"}, %{id: "B", result: "same"}] = message.tools
    assert Enum.map(message.blocks, & &1.id) == ["A", "B"]
  end

  test "T06 late result returns to its call, not the newest assistant", %{conn: conn} do
    {view, sid} = open_session(conn)
    send(view.pid, {:message_end, assistant("a1", [call("call-1", "sleep 1")])})
    send(view.pid, {:message_end, assistant("a2", [%{type: :text, text: "next"}])})
    deliver_result(view, result("r1", "call-1", "late"))

    snap = snapshot(view, sid)
    assert Enum.map(snap.messages, & &1.id) == ["a1", "a2"]
    assert [%{result: "late"}] = Enum.at(snap.messages, 0).tools
    assert Enum.at(snap.messages, 1).tools == []
  end

  test "T09 result before its parent is kept and attached once the parent arrives", %{conn: conn} do
    {view, sid} = open_session(conn)
    deliver_result(view, result("r1", "call-1", "early"))
    assert snapshot(view, sid).messages == []

    send(view.pid, {:message_end, assistant("a1", [call("call-1", "ls")])})
    [message] = snapshot(view, sid).messages
    assert [%{id: "call-1", status: "success", result: "early"}] = message.tools
  end

  test "T11 failed tool keeps output and never shows success", %{conn: conn} do
    {view, sid} = open_session(conn)
    send(view.pid, {:message_end, assistant("a1", [call("call-1", "false")])})
    deliver_result(view, result("r1", "call-1", "partial\nexit status 1", error: true))
    # an older non-final start replayed afterwards cannot revive success/running
    send(
      view.pid,
      {:message_start, result("r1", "call-1", "partial\nexit status 1", error: true)}
    )

    [message] = snapshot(view, sid).messages
    assert [%{status: "error", result: "partial\nexit status 1"}] = message.tools
  end

  test "T14 only explicit compaction summaries are labelled as compaction", %{conn: conn} do
    {view, sid} = open_session(conn)

    send(
      view.pid,
      {:message_end, %Message{id: "c1", role: :compaction_summary, content: "sum", timestamp: 1}}
    )

    send(view.pid, {:message_end, Message.system("s1", "notice")})
    send(view.pid, {:message_end, %Message{id: "m1", role: :mystery, content: "?", timestamp: 1}})

    authors = Map.new(snapshot(view, sid).messages, &{&1.id, &1.author})
    assert authors["c1"] == "Context compaction"
    refute authors["s1"] == "Context compaction"
    refute authors["m1"] == "Context compaction"
    assert snapshot(view, sid).messages |> Enum.map(& &1.content) == ["sum", "notice", "?"]
  end

  test "T15 history projection equals the live projection", %{conn: conn} do
    {view, _sid} = open_session(conn)

    messages = [
      assistant("a1", [%{type: :text, text: "hi"}, call("call-1", "ls")]),
      result("r1", "call-1", "out"),
      assistant("a2", [%{type: :text, text: "done"}])
    ]

    for message <- messages do
      send(view.pid, {:message_start, message})
      send(view.pid, {:message_end, message})
    end

    live = :sys.get_state(view.pid).socket.assigns

    {history_messages, history_results, _tool_call_to_msg} =
      Sigma.Web.SessionLive.split_messages(messages)

    assert Enum.map(history_messages, & &1.id) == ["a1", "a2"]
    assert live.chat_order == ["a1", "a2"]
    assert history_results == live.tool_results
  end

  describe "Codex-style chat projection" do
    defp turn(message, turn_id), do: %{message | metadata: %{turn_id: turn_id}}

    test "hook feedback and hook context never render as user turns", %{conn: conn} do
      {view, sid} = open_session(conn)

      prompt =
        turn(
          %Message{
            id: "u1",
            role: :user,
            content:
              "sync with GitHub\n\n[Additional context from hook]\nSession status updated.",
            timestamp: 900
          },
          "t1"
        )

      feedback = %Message{
        id: "f1",
        role: :user,
        content: "[Host feedback] sigma.hooks / PreToolUse\nSession status updated.",
        metadata: %{turn_id: "t1", host_feedback: %{"stage" => "PreToolUse"}},
        timestamp: 950
      }

      context = %Message{
        id: "hook_ctx_1",
        role: :user,
        content: "[Developer context from hook]\nSession status updated.",
        timestamp: 960
      }

      for message <- [
            prompt,
            feedback,
            context,
            turn(assistant("a1", [%{type: :text, text: "done"}]), "t1")
          ] do
        send(view.pid, {:message_end, message})
      end

      messages = snapshot(view, sid).messages
      assert Enum.map(messages, & &1.id) == ["u1", "a1"]
      assert hd(messages).content == "sync with GitHub"
    end

    test "one turn's model messages render as one item acting on the newest message",
         %{conn: conn} do
      {view, sid} = open_session(conn)

      first =
        turn(
          assistant("a1", [
            %{type: :thinking, thinking: "check status"},
            %{
              type: :tool_call,
              id: "c1",
              name: "exec_command",
              arguments: %{"cmd" => "git status"}
            }
          ]),
          "t1"
        )

      send(view.pid, {:message_end, first})

      deliver_result(view, %{
        result("r1", "c1", ~s({"output":"clean\\n","exit_code":0}))
        | tool_name: "exec_command"
      })

      send(
        view.pid,
        {:message_end, turn(assistant("a2", [%{type: :text, text: "All synced."}]), "t1")}
      )

      assert [item] = snapshot(view, sid).messages
      assert item.id == "a1"
      assert item.messageIds == ["a1", "a2"]

      assert [
               %{type: "reasoning", text: "check status"},
               %{
                 type: "tool",
                 title: "Ran",
                 detail: "git status",
                 output: "clean\n",
                 exitCode: 0
               },
               %{type: "text", text: "All synced."}
             ] = item.blocks

      assert Enum.all?(item.actions, &(&1.messageId == "a2"))
    end
  end

  test "tool summaries name the action like Codex" do
    alias Sigma.Web.SessionLive

    assert SessionLive.tool_summary("exec_command", %{"cmd" => ["git", "pull"]}) ==
             {"Ran", "git pull"}

    assert SessionLive.tool_summary("write_stdin", %{"session_id" => 3, "chars" => ""}) ==
             {"Waited for session", "3"}

    assert SessionLive.tool_summary(
             "apply_patch",
             "*** Begin Patch\n*** Update File: lib/a.ex\n*** Add File: b.md\n"
           ) ==
             {"Edited", "lib/a.ex, b.md"}

    assert SessionLive.tool_summary("mcp__github__list_issues", %{}) ==
             {"Called", "github · list_issues"}
  end
end
