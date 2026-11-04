defmodule Sigma.Agent.Backplane.MessageBoardStateTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.Error
  alias Sigma.Agent.Backplane.MessageBoardState, as: Board

  test "state round-trips JSON and retries return metadata without replaying fanout" do
    state = Board.new("tree")
    {_, state, []} = ok(state, "create_channel", %{"channel_name" => "build"}, host(1))
    {_, state, []} = ok(state, "subscribe", %{"channel_name" => "build"}, host(2, "/root/worker"))
    args = %{"channel_name" => "build", "text" => "ready"}
    {result, state, intents} = ok(state, "post", args, host(3))
    assert [%{"recipient_id" => "worker", "post" => notice}] = intents
    assert notice["text_preview"] == "ready"
    assert result["author"] == "/root"
    assert result["thread_id"] == result["message_id"]
    assert {:ok, ^result, ^state, []} = call(state, "post", args, host(3))

    assert {:error, %Error{class: :resource_conflict}} =
             call(state, "post", Map.put(args, "text", "changed"), host(3))

    assert Jason.decode!(Jason.encode!(state)) == state
    restored = Jason.decode!(Jason.encode!(state))
    assert {:ok, ^result, ^restored, []} = call(restored, "post", args, host(3))
  end

  test "channel and thread subscriptions differ and posting preserves explicit thread opt-out" do
    {_, state, _} = ok(Board.new("tree"), "create_channel", %{"channel_name" => "build"}, host(1))
    {root, state, _} = ok(state, "post", %{"channel_name" => "build", "text" => "root"}, host(2))
    thread = root["message_id"]
    {_, state, _} = ok(state, "subscribe", %{"channel_name" => "build"}, host(3, "/root/worker"))
    {_, state, []} = ok(state, "post", %{"thread_id" => thread, "text" => "reply"}, host(4))
    {_, state, _} = ok(state, "unsubscribe", %{"thread_id" => thread}, host(5, "/root/worker"))

    {_, state, intents} =
      ok(state, "post", %{"thread_id" => thread, "text" => "joined"}, host(6, "/root/worker"))

    assert Enum.map(intents, & &1["recipient_id"]) == ["root"]
    {_, state, []} = ok(state, "post", %{"thread_id" => thread, "text" => "next"}, host(7))

    {_, state, intents} =
      ok(
        state,
        "post",
        %{"thread_id" => thread, "text" => "ping", "agents_to_notify" => ["worker", "worker"]},
        host(8)
      )

    assert Enum.map(intents, & &1["recipient_id"]) == ["worker"]
    {_, _, []} = ok(state, "post", %{"thread_id" => thread, "text" => "no subscription"}, host(9))
  end

  test "accepted post retries normalize omitted recipients to the empty list" do
    args = %{"new_channel_name" => "build", "text" => "ready"}
    {result, state, []} = ok(Board.new("tree"), "post", args, host(1))
    retry = Map.put(args, "agents_to_notify", [])

    assert {:ok, ^result, ^state, []} = call(state, "post", retry, host(1))
    restored = Jason.decode!(Jason.encode!(state))
    assert {:ok, ^result, ^restored, []} = call(restored, "post", retry, host(1))
  end

  test "accepted post retries normalize paths without looking up departed recipients" do
    args = %{
      "new_channel_name" => "build",
      "text" => "ready",
      "agents_to_notify" => ["worker"]
    }

    {result, state, intents} = ok(Board.new("tree"), "post", args, host(1))
    assert [%{"recipient_id" => "worker"}] = Enum.map(intents, &Map.take(&1, ["recipient_id"]))
    departed = %{host(1) | agents: %{"/root" => "root"}}
    retry = Map.put(args, "agents_to_notify", ["/root/worker"])

    assert {:ok, ^result, ^state, []} = call(state, "post", retry, departed)
    assert {:ok, ^result, ^state, []} = call(state, "post", args, departed)

    assert {:error, %Error{class: :resource_conflict}} =
             call(state, "post", Map.put(retry, "text", "changed"), departed)
  end

  test "Unicode scalar offsets, counts and casefold substring match pinned semantics" do
    {root, state, _} =
      ok(
        Board.new("tree"),
        "post",
        %{"new_channel_name" => "Straße", "text" => "é👩‍💻 STRAẞE"},
        host(1)
      )

    {read, _, _} =
      ok(
        state,
        "read_post",
        %{"message_id" => root["message_id"], "offset_chars" => 1, "limit_chars" => 3},
        host(2)
      )

    assert read["text"] == "́👩‍"
    assert read["n_chars"] == 12
    assert read["next_offset_chars"] == 4

    {page, _, _} =
      ok(state, "search_posts", %{"query" => "strasse", "max_chars_per_post" => 2}, host(3))

    assert [%{"text_preview" => "é", "truncated" => true, "n_chars" => 12}] =
             Enum.map(page["results"], &Map.take(&1, ~w(text_preview truncated n_chars)))

    {channels, _, _} = ok(state, "get_channels", %{"query" => "STRASSE"}, host(4))

    assert [%{"channel_name" => "Straße"}] =
             Enum.map(channels["results"], &Map.take(&1, ["channel_name"]))

    {empty, _, _} =
      ok(
        state,
        "read_post",
        %{"message_id" => root["message_id"], "offset_chars" => 100},
        host(5)
      )

    assert empty["text"] == ""
    assert empty["next_offset_chars"] == 12
  end

  test "timestamps and insertion sequence determine ordering, filters and activity" do
    {a, state, _} =
      ok(Board.new("tree"), "post", %{"new_channel_name" => "a", "text" => "older"}, host(1))

    {b, state, _} =
      ok(state, "post", %{"new_channel_name" => "b", "text" => "newer"}, host(2, "/root/worker"))

    {c, state, _} = ok(state, "post", %{"channel_name" => "a", "text" => "other root"}, host(3))

    {reply, state, _} =
      ok(
        state,
        "post",
        %{"thread_id" => a["message_id"], "text" => "latest"},
        host(4, "/root/worker")
      )

    {channels, _, _} = ok(state, "get_channels", %{}, host(5))
    assert Enum.map(channels["results"], & &1["channel_name"]) == ["a", "b"]
    {created, _, _} = ok(state, "list_threads", %{"channel_name" => "a"}, host(6))
    assert Enum.map(created["results"], & &1["thread_id"]) == [c["message_id"], a["message_id"]]

    {activity, _, _} =
      ok(state, "list_threads", %{"channel_name" => "a", "sort" => "activity"}, host(7))

    assert [first | _] = activity["results"]
    assert first["thread_id"] == a["message_id"]
    assert first["reply_count"] == 1
    assert first["latest_reply"]["message_id"] == reply["message_id"]

    {search, _, _} =
      ok(
        state,
        "search_posts",
        %{"after_message_id" => b["message_id"], "author" => "worker"},
        host(8)
      )

    assert Enum.map(search["results"], & &1["message_id"]) == [reply["message_id"]]
    {thread, _, _} = ok(state, "read_thread", %{"thread_id" => a["message_id"]}, host(9))
    assert thread["root_post"]["message_id"] == a["message_id"]
    assert Enum.map(thread["results"], & &1["message_id"]) == [reply["message_id"]]
  end

  test "bounded pages regenerate matching cursors without skipping items" do
    state =
      Enum.reduce(1..23, Board.new("tree"), fn n, state ->
        {_, state, _} =
          ok(
            state,
            "post",
            %{"new_channel_name" => "channel-#{n}", "text" => String.duplicate("\"", 2000)},
            host(n)
          )

        state
      end)

    {default, _, _} = ok(state, "get_channels", %{}, host(30))
    assert default["n_returned"] == 20
    assert default["has_more"]

    {page, _, _} =
      ok(state, "search_posts", %{"limit" => 50, "max_chars_per_post" => 20000}, host(31))

    assert byte_size(Jason.encode!(page)) <= 8000
    assert page["n_returned"] < 23
    assert page["n_returned"] > 0
    assert page["has_more"]
    count = page["n_returned"]

    assert {:ok, <<^count::unsigned-big-32>>} =
             Base.url_decode64(page["next_cursor"], padding: false)

    {next, _, _} =
      ok(state, "search_posts", %{"limit" => 50, "cursor" => page["next_cursor"]}, host(32))

    ids = Enum.map(page["results"] ++ next["results"], & &1["message_id"])
    assert length(ids) == MapSet.size(MapSet.new(ids))
    expected = Enum.map(23..1//-1, &host(&1).message_id)
    assert ids == Enum.take(expected, length(ids))

    assert {:error, %Error{class: :validation}} =
             call(state, "get_channels", %{"cursor" => "bogus"}, host(33))
  end

  test "post and argument limits are byte limits and mutations preflight acknowledgment" do
    state = Board.new("tree")

    assert {:error, %Error{class: :validation}} =
             call(
               state,
               "post",
               %{"new_channel_name" => "a", "text" => String.duplicate("é", 32769)},
               host(1)
             )

    assert {:error, %Error{class: :validation}} =
             call(state, "get_channels", %{"query" => String.duplicate("x", 131_072)}, host(2))

    assert {:error, %Error{class: :budget_exceeded}} =
             call(
               state,
               "create_channel",
               %{"channel_name" => "a"},
               Map.put(host(3), :response_byte_budget, 100)
             )

    {page, _, _} = ok(state, "get_channels", %{}, host(4))
    assert page["results"] == []

    {post, state, _} =
      ok(
        state,
        "post",
        %{"new_channel_name" => "a", "text" => String.duplicate("é", 32768)},
        host(5)
      )

    {read, _, _} =
      ok(
        state,
        "read_post",
        %{"message_id" => post["message_id"], "limit_chars" => 40000},
        host(6)
      )

    assert read["next_offset_chars"] <= 20000
    assert byte_size(Jason.encode!(read)) <= 8000
  end

  test "strict arguments, destinations, UUIDs and root identity reject invalid requests" do
    state = Board.new("tree")

    for {name, args} <- [
          {"create_channel", %{"channel_name" => " edge"}},
          {"create_channel", %{"channel_name" => "a\n"}},
          {"create_channel", %{"channel_name" => String.duplicate("é", 65)}},
          {"get_channels", %{"limit" => 0}},
          {"get_channels", %{"limit" => 4_294_967_296}},
          {"get_channels", %{"recent_first" => "true"}},
          {"get_channels", %{"unknown" => true}},
          {"list_threads", %{"channel_name" => "a", "sort" => "wrong"}},
          {"read_post", %{"message_id" => "not-uuid"}},
          {"subscribe", %{}},
          {"post", %{"text" => ""}},
          {"post", %{"text" => "a", "channel_name" => "a", "new_channel_name" => "b"}}
        ] do
      assert {:error, %Error{class: :validation}} = call(state, name, args, host(1))
    end

    assert {:error, %Error{class: :forbidden}} =
             call(state, "get_channels", %{}, %{host(1) | root_id: "other"})

    assert {:error, %Error{class: :validation}} =
             call(
               state,
               "subscribe",
               %{"channel_name" => "a", "target_agent" => "../../outside"},
               host(2)
             )
  end

  test "subscriptions resolve tree paths and expose last-message metadata" do
    {root, state, _} =
      ok(Board.new("tree"), "post", %{"new_channel_name" => "a", "text" => "hello"}, host(1))

    {sub, state, _} =
      ok(state, "subscribe", %{"channel_name" => "a", "target_agent" => "worker"}, host(2))

    assert sub == %{
             "channel_name" => "a",
             "thread_id" => nil,
             "target_agent" => "/root/worker",
             "enabled" => true,
             "last_message_id" => root["message_id"]
           }

    {_, state, _} =
      ok(
        state,
        "unsubscribe",
        %{"channel_name" => "a", "target_agent" => "/root"},
        host(3, "/root/worker")
      )

    {_, _, intents} = ok(state, "post", %{"channel_name" => "a", "text" => "next"}, host(4))
    assert Enum.map(intents, & &1["recipient_id"]) == ["worker"]
  end

  test "tombstone survives serialization and rejects late writes and accepted retries" do
    {_, state, _} =
      ok(Board.new("tree"), "post", %{"new_channel_name" => "a", "text" => "hello"}, host(1))

    state = state |> Board.tombstone() |> Jason.encode!() |> Jason.decode!()

    assert {:error, %Error{class: :forbidden}} =
             call(state, "post", %{"new_channel_name" => "a", "text" => "hello"}, host(1))

    assert {:error, %Error{class: :forbidden}} =
             call(state, "create_channel", %{"channel_name" => "b"}, host(2))
  end

  defp call(state, name, arguments, host),
    do: Board.apply(state, %{name: name, arguments: arguments}, host)

  defp ok(state, name, arguments, host) do
    assert {:ok, result, next, intents} = call(state, name, arguments, host)
    {result, next, intents}
  end

  defp host(n, path \\ "/root") do
    %{
      root_id: "tree",
      agent_id: if(path == "/root", do: "root", else: "worker"),
      agent_path: path,
      agents: %{"/root" => "root", "/root/worker" => "worker"},
      timestamp: "2026-10-25T00:00:#{n |> Integer.to_string() |> String.pad_leading(2, "0")}Z",
      invocation_id: "call-#{n}",
      message_id:
        "00000000-0000-4000-8000-#{n |> Integer.to_string() |> String.pad_leading(12, "0")}"
    }
  end
end
