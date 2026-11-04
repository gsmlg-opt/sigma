defmodule Sigma.Agent.BackplaneMessageBoardStoreFunctionalTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.Error
  alias Sigma.Agent.Backplane.MessageBoardState, as: Board
  alias Sigma.Agent.Backplane.MessageBoardStore
  alias Sigma.Agent.Backplane.Store.FileSystem

  @moduletag :tmp_dir
  @moduletag :codex_alignment_functional

  defmodule FaultableFileSystem do
    def ensure_dir(_fault, path), do: FileSystem.ensure_dir(path)
    def read(_fault, path), do: FileSystem.read(path)

    def write_atomic(fault, path, bytes) do
      mode =
        Agent.get_and_update(fault, fn state ->
          {state.mode, %{state | writes: state.writes + 1}}
        end)

      case mode do
        :before_commit ->
          {:error, :injected_commit_failure}

        :after_commit ->
          :ok = FileSystem.write_atomic(path, bytes)
          {:error, :injected_ack_lost}

        :ok ->
          FileSystem.write_atomic(path, bytes)
      end
    end
  end

  setup %{tmp_dir: dir} do
    transcript = Path.join([dir, "unused", "root.jsonl"])
    assert {:ok, resources} = MessageBoardStore.open(root_transcript: transcript, root_id: "tree")

    on_exit(fn ->
      case Registry.lookup(Sigma.Agent.RepositoryRegistry, {:message_board_store, transcript}) do
        [{pid, _}] -> DynamicSupervisor.terminate_child(Sigma.Agent.DynamicSupervisor, pid)
        [] -> :ok
      end
    end)

    %{
      transcript: transcript,
      path: Path.join(transcript <> ".subagents", "message_board.json"),
      resources: resources
    }
  end

  test "opening and empty reads leave the entire unused storage directory absent", c do
    refute File.exists?(Path.dirname(c.transcript))
    assert {:ok, page, []} = call(c, "get_channels", %{}, 1)

    assert page == %{
             "results" => [],
             "n_returned" => 0,
             "has_more" => false,
             "next_cursor" => nil
           }

    assert {:ok, page, []} = call(c, "search_posts", %{}, 2)
    assert page["results"] == []
    assert {:ok, same} = MessageBoardStore.open(root_transcript: c.transcript, root_id: "tree")
    assert same == c.resources
    refute File.exists?(Path.dirname(c.transcript))
  end

  test "root and child share a serialized writer without losing concurrent creates or posts", c do
    results =
      1..16
      |> Task.async_stream(
        fn n ->
          assert {:ok, same} =
                   MessageBoardStore.open(root_transcript: c.transcript, root_id: "tree")

          assert same == c.resources
          agent = if rem(n, 2) == 0, do: "/root/worker", else: "/root"

          assert {:ok, _, []} =
                   call(c, "create_channel", %{"channel_name" => "build-#{n}"}, n, agent)

          call(
            c,
            "post",
            %{"channel_name" => "build-#{n}", "text" => "post #{n}"},
            n + 100,
            agent
          )
        end,
        max_concurrency: 8
      )
      |> Enum.to_list()

    assert Enum.all?(results, &match?({:ok, {:ok, _, []}}, &1))
    stored = Jason.decode!(File.read!(c.path))
    assert map_size(stored["channels"]) == 16
    assert map_size(stored["posts"]) == 16
    assert map_size(stored["accepted_calls"]) == 32
    assert stored["next_sequence"] == 17
    assert {:ok, page, []} = call(c, "search_posts", %{"limit" => 50}, 300)

    assert Enum.sort(Enum.map(page["results"], & &1["text_preview"])) ==
             Enum.sort(Enum.map(1..16, &"post #{&1}"))
  end

  test "close and reopen retain content and exact retry without rewriting or fanout", c do
    args = %{
      "new_channel_name" => "build",
      "text" => "中文\r\nready",
      "agents_to_notify" => ["worker"]
    }

    assert {:ok, result, [%{"recipient_id" => "worker"}]} = call(c, "post", args, 1)
    # A deliberately old timestamp makes an accidental rewrite observable even
    # on filesystems whose stat timestamps only have whole-second resolution.
    File.touch!(c.path, {{2000, 1, 1}, {0, 0, 0}})
    before = snapshot(c.path)
    c = reopen(c)
    assert {:ok, ^result, []} = call(c, "post", args, 1)
    assert snapshot(c.path) == before
    assert {:ok, read, []} = call(c, "read_post", %{"message_id" => result["message_id"]}, 2)
    assert read["text"] == args["text"]
    assert snapshot(c.path) == before
  end

  test "all pages and Unicode scalar chunks preserve complete UTF-8 and CRLF after reopen", c do
    text = String.duplicate("中文 é👩‍💻\r\n", 200)

    for n <- 1..23 do
      assert {:ok, _, []} =
               call(c, "post", %{"new_channel_name" => "channel-#{n}", "text" => text}, n)
    end

    c = reopen(c)
    channels = pages(c, "get_channels", %{"limit" => 7})
    assert length(channels) == 23

    assert MapSet.new(Enum.map(channels, & &1["channel_name"])) ==
             MapSet.new(Enum.map(1..23, &"channel-#{&1}"))

    posts = pages(c, "search_posts", %{"limit" => 50, "max_chars_per_post" => 20_000})
    assert length(posts) == 23
    assert length(Enum.uniq_by(posts, & &1["message_id"])) == 23

    for post <- posts do
      assert read_all(c, post["message_id"], 0, []) == text
    end
  end

  test "subscriptions survive reopen and explicit thread opt-out survives subsequent posting",
       c do
    assert {:ok, root, []} =
             call(c, "post", %{"new_channel_name" => "build", "text" => "root"}, 1)

    thread = root["message_id"]
    assert {:ok, _, []} = call(c, "subscribe", %{"channel_name" => "build"}, 2, "/root/worker")
    c = reopen(c)

    assert {:ok, _, [%{"recipient_id" => "worker"}]} =
             call(c, "post", %{"channel_name" => "build", "text" => "channel update"}, 3)

    assert {:ok, _, []} = call(c, "unsubscribe", %{"thread_id" => thread}, 4, "/root/worker")
    c = reopen(c)

    assert {:ok, _, [%{"recipient_id" => "root"}]} =
             call(
               c,
               "post",
               %{"thread_id" => thread, "text" => "reply while opted out"},
               5,
               "/root/worker"
             )

    assert {:ok, _, []} = call(c, "post", %{"thread_id" => thread, "text" => "no notice"}, 6)
    c = reopen(c)

    assert {:ok, _, [%{"recipient_id" => "worker"}]} =
             call(
               c,
               "post",
               %{
                 "thread_id" => thread,
                 "text" => "explicit ping",
                 "agents_to_notify" => ["worker"]
               },
               7
             )

    assert {:ok, _, []} =
             call(c, "post", %{"thread_id" => thread, "text" => "still opted out"}, 8)

    stored = Jason.decode!(File.read!(c.path))
    assert stored["subscriptions"][Jason.encode!(["thread", thread])]["worker"] == false
  end

  test "a fault before commit preserves existing bytes and returns the original failure without intents",
       c do
    fault = start_supervised!({Agent, fn -> %{mode: :ok, writes: 0} end})
    c = reopen(c, filesystem: {FaultableFileSystem, fault})
    assert {:ok, _, []} = call(c, "create_channel", %{"channel_name" => "build"}, 1)
    before = snapshot(c.path)
    Agent.update(fault, &%{&1 | mode: :before_commit})

    assert {:error, %Error{class: :unknown_outcome, cause: :injected_commit_failure}} =
             call(
               c,
               "post",
               %{
                 "channel_name" => "build",
                 "text" => "uncommitted",
                 "agents_to_notify" => ["worker"]
               },
               2
             )

    assert snapshot(c.path) == before
    assert Agent.get(fault, & &1.writes) == 2
    c = reopen(c)
    assert {:ok, page, []} = call(c, "search_posts", %{}, 3)
    assert page["results"] == []
  end

  test "a real commit with lost acknowledgement recovers its receipt without rewriting or fanout",
       c do
    fault = start_supervised!({Agent, fn -> %{mode: :after_commit, writes: 0} end})
    c = reopen(c, filesystem: {FaultableFileSystem, fault})

    args = %{
      "new_channel_name" => "build",
      "text" => "committed",
      "agents_to_notify" => ["worker"]
    }

    assert {:error, %Error{class: :unknown_outcome, cause: :injected_ack_lost}} =
             call(c, "post", args, 1)

    stored = Jason.decode!(File.read!(c.path))
    [post] = Map.values(stored["posts"])
    original_result = post["metadata"]
    assert post["text"] == "committed"
    File.touch!(c.path, {{2000, 1, 1}, {0, 0, 0}})
    before = snapshot(c.path)
    c = reopen(c, filesystem: {FaultableFileSystem, fault})
    assert {:ok, ^original_result, []} = call(c, "post", args, 1)
    assert snapshot(c.path) == before
    assert Agent.get(fault, & &1.writes) == 1
  end

  test "every call reads actual storage and malformed or unreadable files report typed errors",
       c do
    assert {:ok, _, []} = call(c, "create_channel", %{"channel_name" => "build"}, 1)
    current = Jason.decode!(File.read!(c.path))

    assert {:ok, _, next, []} =
             Board.apply(
               current,
               %{
                 name: "post",
                 arguments: %{"channel_name" => "build", "text" => "external update"}
               },
               host(2)
             )

    File.write!(c.path, Jason.encode!(next))
    assert {:ok, page, []} = call(c, "search_posts", %{}, 3)
    assert [%{"text_preview" => "external update"}] = page["results"]

    for bytes <- ["{", "[]", Jason.encode!(%{next | "posts" => %{"broken" => %{}}})] do
      File.write!(c.path, bytes)
      assert {:error, %Error{class: :malformed_result}} = call(c, "get_channels", %{}, 4)
      assert File.read!(c.path) == bytes
      assert Process.alive?(c.resources)
    end

    File.rm!(c.path)
    File.mkdir!(c.path)

    assert {:error, %Error{class: :execution_failure, cause: :eisdir}} =
             call(c, "get_channels", %{}, 5)

    assert Process.alive?(c.resources)
  end

  defp reopen(c, opts \\ []) do
    :ok = DynamicSupervisor.terminate_child(Sigma.Agent.DynamicSupervisor, c.resources)

    assert {:ok, resources} =
             MessageBoardStore.open([root_transcript: c.transcript, root_id: "tree"] ++ opts)

    %{c | resources: resources}
  end

  defp call(c, name, args, n, agent \\ "/root") do
    MessageBoardStore.execute(c.resources, %{name: name, arguments: args}, host(n, agent))
  end

  defp host(n, path \\ "/root") do
    %{
      root_id: "tree",
      agent_id: if(path == "/root", do: "root", else: "worker"),
      agent_path: path,
      agents: %{"/root" => "root", "/root/worker" => "worker"},
      timestamp: "2026-10-25T00:00:01Z",
      invocation_id: "call-#{n}",
      message_id: "00000000-0000-4000-8000-" <> String.pad_leading(Integer.to_string(n), 12, "0")
    }
  end

  defp snapshot(path) do
    bytes = File.read!(path)
    %{bytes: bytes, sha256: :crypto.hash(:sha256, bytes), mtime: File.stat!(path).mtime}
  end

  defp pages(c, name, args, acc \\ []) do
    assert {:ok, page, []} = call(c, name, args, 1000)
    assert byte_size(Jason.encode!(page)) <= 8000
    assert page["n_returned"] == length(page["results"])
    acc = acc ++ page["results"]

    if page["has_more"] do
      assert page["n_returned"] > 0
      pages(c, name, Map.put(args, "cursor", page["next_cursor"]), acc)
    else
      assert page["next_cursor"] == nil
      acc
    end
  end

  defp read_all(c, message_id, offset, acc) do
    assert {:ok, result, []} =
             call(
               c,
               "read_post",
               %{"message_id" => message_id, "offset_chars" => offset, "limit_chars" => 127},
               1001
             )

    next = result["next_offset_chars"]
    acc = [result["text"] | acc]

    if next < result["n_chars"] do
      assert next > offset
      read_all(c, message_id, next, acc)
    else
      acc |> Enum.reverse() |> IO.iodata_to_binary()
    end
  end
end
