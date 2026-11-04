defmodule Sigma.Agent.Backplane.MessageBoardState do
  @moduledoc """
  Pure, JSON-serializable state for the pinned Codex message-board contract.

  The host supplies authoritative tree/agent identities, clock and logical call
  identity. It must validate membership before calling, atomically persist an
  accepted next state, and only then attempt returned notification intents against
  the recipient's current active turn. Intents are not a durable delivery queue:
  accepted-call retries return no intents. This module performs no I/O and does
  not register tools or claim that notifications were delivered.

  Operations are `%{name: name, arguments: string_keyed_map}`. Host metadata uses
  atom keys: `root_id`, `agent_id`, `agent_path`, `agents` (absolute path to stable
  ID), `timestamp` (RFC3339), `invocation_id`, and `message_id` (post UUID).
  `response_byte_budget` may reduce the fixed 8000-byte ceiling.

  Offset cursors match pinned Codex: concurrent writes may shift subsequent
  pages. Persisting this value alone does not provide a transactional writer.
  """

  import Kernel, except: [apply: 3]
  alias Backplane.AgentRuntime.Error

  @reads ~w(get_channels list_threads search_posts read_thread read_post)
  @writes ~w(create_channel subscribe unsubscribe post)
  @schemas %{
    "create_channel" => {~w(channel_name), ~w(subscribe)},
    "get_channels" => {[], ~w(query recent_first limit cursor)},
    "list_threads" => {~w(channel_name), ~w(sort recent_first limit cursor max_chars_per_post)},
    "search_posts" =>
      {[], ~w(channel_name query after_message_id author limit cursor max_chars_per_post)},
    "read_thread" => {~w(thread_id), ~w(limit cursor max_chars_per_post)},
    "read_post" => {~w(message_id), ~w(offset_chars limit_chars)},
    "subscribe" => {[], ~w(channel_name thread_id target_agent)},
    "unsubscribe" => {[], ~w(channel_name thread_id target_agent)},
    "post" => {~w(text), ~w(channel_name new_channel_name thread_id agents_to_notify)}
  }
  @uuid ~r/\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z/

  def new(root_id) when is_binary(root_id) and byte_size(root_id) > 0 do
    %{
      "version" => 1,
      "root_id" => root_id,
      "deleted" => false,
      "channels" => %{},
      "posts" => %{},
      "subscriptions" => %{},
      "accepted_calls" => %{},
      "next_sequence" => 1
    }
  end

  def tombstone(state), do: Map.put(state, "deleted", true)

  def apply(state, %{name: name, arguments: arguments}, host)
      when is_map(state) and is_map(arguments) and is_map(host) do
    try do
      ensure(state["root_id"] == host[:root_id], "board belongs to another tree", :forbidden)
      ensure(name in (@reads ++ @writes), "unknown message-board operation")
      args = validate_arguments(name, arguments)
      path = absolute_path(host[:agent_path])

      ensure(
        is_binary(host[:agent_id]) and host[:agent_id] != "",
        "missing stable agent identity"
      )

      budget = host[:response_byte_budget] || 8000
      ensure(is_integer(budget) and budget > 0, "invalid response byte budget")
      budget = min(budget, 8000)

      if name in @writes do
        ensure(state["deleted"] != true, "board was permanently deleted", :forbidden)
        mutation(state, name, args, host, path, budget)
      else
        result = bounded_read(state, name, args, host, budget)
        {:ok, result, state, []}
      end
    catch
      {:board_error, error} -> {:error, error}
    end
  end

  def apply(_state, _operation, _host),
    do: {:error, Error.new(:validation, "invalid message-board operation")}

  defp mutation(state, name, args, host, path, budget) do
    target_bytes = byte_size(args["target_agent"] || "")

    ensure(
      budget >= 2048 + byte_size(path) + target_bytes,
      "Output budget is too small to acknowledge a message-board mutation; no change was made.",
      :budget_exceeded
    )

    invocation = host[:invocation_id]

    ensure(
      is_binary(invocation) and byte_size(invocation) in 1..512 and String.valid?(invocation),
      "invalid logical invocation identity"
    )

    key = Jason.encode!([host.agent_id, invocation])
    input = %{"name" => name, "arguments" => receipt_arguments(name, args, path)}

    case state["accepted_calls"][key] do
      %{"input" => ^input, "result" => result} ->
        ensure(
          encoded_size(result) <= budget,
          "mutation acknowledgment exceeds output budget",
          :budget_exceeded
        )

        {:ok, result, state, []}

      nil ->
        {result, next, intents} = write(state, name, args, host, path)

        ensure(
          encoded_size(result) <= budget,
          "mutation acknowledgment exceeds output budget",
          :budget_exceeded
        )

        receipt = %{"input" => input, "result" => result}
        next = put_in(next, ["accepted_calls", key], receipt)
        {:ok, result, next, intents}

      _ ->
        fail(
          "logical invocation identity was already used for different input",
          :resource_conflict
        )
    end
  end

  defp receipt_arguments("post", args, path) do
    # Compare the semantic PostRequest, as Codex does after parsing defaults and
    # resolving AgentPaths. Membership may have changed since an accepted post;
    # resolving stable path syntax here must not perform a fresh agent lookup.
    recipients = Enum.map(Map.get(args, "agents_to_notify", []), &resolve_path(path, &1))
    Map.put(args, "agents_to_notify", recipients)
  end

  defp receipt_arguments(_name, args, _path), do: args

  defp write(state, "create_channel", args, host, path) do
    next = insert_channel(state, args["channel_name"], host, path)

    next =
      if Map.get(args, "subscribe", true),
        do: implicit_subscribe(next, channel_target(args["channel_name"]), host.agent_id),
        else: next

    {channel_summary(next, args["channel_name"]), next, []}
  end

  defp write(state, name, args, host, path) when name in ["subscribe", "unsubscribe"] do
    target_path = resolve_path(path, args["target_agent"] || path)
    agent_id = resolve_agent(host, target_path)
    {target, channel, thread, posts} = subscription_target(state, args)
    enabled = name == "subscribe"
    subscriptions = Map.put(Map.get(state["subscriptions"], target, %{}), agent_id, enabled)
    next = put_in(state, ["subscriptions", target], subscriptions)

    result = %{
      "channel_name" => channel,
      "thread_id" => thread,
      "target_agent" => target_path,
      "enabled" => enabled,
      "last_message_id" => last_message_id(posts)
    }

    {result, next, []}
  end

  defp write(state, "post", args, host, path) do
    text = args["text"]
    ensure(byte_size(text) in 1..65_536, "post text exceeds the board limits")
    notify = Map.get(args, "agents_to_notify", [])
    ensure(length(notify) <= 256, "recipient count exceeds the board limits")

    recipients =
      Enum.map(notify, fn reference -> resolve_agent(host, resolve_path(path, reference)) end)

    id = uuid(host[:message_id])
    ensure(not Map.has_key?(state["posts"], id), "message ID already exists", :resource_conflict)
    {timestamp, micros} = clock(host)

    {next, channel, thread, target} =
      cond do
        args["channel_name"] ->
          channel = args["channel_name"]
          channel_summary(state, channel)
          {state, channel, id, channel_target(channel)}

        args["new_channel_name"] ->
          channel = args["new_channel_name"]
          next = insert_channel(state, channel, host, path)
          next = implicit_subscribe(next, channel_target(channel), host.agent_id)
          {next, channel, id, channel_target(channel)}

        true ->
          root = root_post(state, args["thread_id"])

          {state, root["metadata"]["channel_name"], root["metadata"]["message_id"],
           thread_target(args["thread_id"])}
      end

    subscribers =
      next["subscriptions"]
      |> Map.get(target, %{})
      |> Enum.filter(fn {_, enabled} -> enabled end)
      |> Enum.map(&elem(&1, 0))

    metadata = %{
      "message_id" => id,
      "channel_name" => channel,
      "author" => path,
      "thread_id" => thread,
      "created_at" => timestamp
    }

    post = %{
      "metadata" => metadata,
      "text" => text,
      "timestamp" => micros,
      "sequence" => next["next_sequence"]
    }

    next = put_in(next, ["posts", id], post)
    next = Map.update!(next, "next_sequence", &(&1 + 1))
    next = implicit_subscribe(next, thread_target(thread), host.agent_id)
    # MessageBoardResources resolves each recipient's current public identity
    # after commit and calls MultiAgent.notify_active, never queued send_message.
    intents =
      (recipients ++ subscribers)
      |> Enum.uniq()
      |> Enum.reject(&(&1 == host.agent_id))
      |> Enum.sort()
      |> Enum.map(&%{"recipient_id" => &1, "post" => preview(post, 150)})

    {metadata, next, intents}
  end

  defp insert_channel(state, name, host, path) do
    validate_channel(name)
    ensure(not Map.has_key?(state["channels"], name), "channel already exists")
    {timestamp, micros} = clock(host)

    put_in(state, ["channels", name], %{
      "channel_name" => name,
      "created_at" => timestamp,
      "created_by" => path,
      "timestamp" => micros
    })
  end

  defp implicit_subscribe(state, target, agent_id) do
    subscriptions = Map.get(state["subscriptions"], target, %{}) |> Map.put_new(agent_id, true)
    put_in(state, ["subscriptions", target], subscriptions)
  end

  defp subscription_target(state, %{"channel_name" => channel}) do
    channel_summary(state, channel)
    {channel_target(channel), channel, nil, channel_posts(state, channel)}
  end

  defp subscription_target(state, %{"thread_id" => id}) do
    root = root_post(state, id)
    {thread_target(id), root["metadata"]["channel_name"], id, thread_posts(state, id)}
  end

  defp bounded_read(state, name, args, host, budget) do
    largest =
      case name do
        "get_channels" -> page_limit(args)
        "read_post" -> min(Map.get(args, "limit_chars", 20_000), 20_000)
        _ -> max(page_limit(args), preview_limit(args))
      end

    bounded_read(state, name, args, host, budget, largest, 1)
  end

  defp bounded_read(state, name, args, host, budget, largest, scale) do
    result = read(state, name, args, host, scale)

    if encoded_size(result) <= budget do
      result
    else
      ensure(
        div(largest, scale) > 1,
        "The output budget is too small for this result's metadata.",
        :budget_exceeded
      )

      bounded_read(state, name, args, host, budget, largest, scale * 2)
    end
  end

  defp read(state, "get_channels", args, _host, scale) do
    query = fold(Map.get(args, "query", ""))

    channels =
      state["channels"]
      |> Map.values()
      |> Enum.filter(&String.contains?(fold(&1["channel_name"]), query))
      |> Enum.sort_by(
        fn channel ->
          posts = channel_posts(state, channel["channel_name"])

          activity =
            posts |> Enum.map(& &1["timestamp"]) |> Enum.max(fn -> channel["timestamp"] end)

          {activity, channel["channel_name"]}
        end,
        direction(args)
      )

    page(channels, args, scale, &channel_summary(state, &1["channel_name"]))
  end

  defp read(state, "list_threads", args, _host, scale) do
    channel_summary(state, args["channel_name"])

    roots =
      channel_posts(state, args["channel_name"])
      |> Enum.filter(&root?/1)
      |> Enum.sort_by(
        fn post ->
          timestamp =
            if Map.get(args, "sort", "created") == "activity",
              do:
                state
                |> thread_posts(post["metadata"]["message_id"])
                |> Enum.map(& &1["timestamp"])
                |> Enum.max(),
              else: post["timestamp"]

          {timestamp, post["sequence"]}
        end,
        direction(args)
      )

    count = min(max(length(roots) - offset(args), 0), scaled(page_limit(args), scale))
    chars = min(scaled(preview_limit(args), scale), div(20_000, 2 * max(count, 1)))

    page(roots, args, scale, fn root ->
      replies = thread_posts(state, root["metadata"]["message_id"]) |> Enum.reject(&root?/1)
      latest = List.first(sort_posts(replies))

      %{
        "thread_id" => root["metadata"]["message_id"],
        "root_post" => preview(root, chars),
        "reply_count" => length(replies),
        "last_activity_at" => activity_time(root, latest),
        "latest_reply" => if(latest, do: preview(latest, chars), else: nil)
      }
    end)
  end

  defp read(state, "search_posts", args, host, scale) do
    after_post = if args["after_message_id"], do: load_post(state, args["after_message_id"])
    author = if args["author"], do: resolve_path(host.agent_path, args["author"])

    posts =
      state["posts"]
      |> Map.values()
      |> Enum.filter(fn post ->
        (is_nil(args["channel_name"]) or post["metadata"]["channel_name"] == args["channel_name"]) and
          (is_nil(author) or post["metadata"]["author"] == author) and
          (is_nil(args["query"]) or String.contains?(fold(post["text"]), fold(args["query"]))) and
          (is_nil(after_post) or post_order(post) > post_order(after_post))
      end)
      |> sort_posts()

    count = min(max(length(posts) - offset(args), 0), scaled(page_limit(args), scale))
    chars = min(scaled(preview_limit(args), scale), div(20_000, max(count, 1)))
    page(posts, args, scale, &preview(&1, chars))
  end

  defp read(state, "read_thread", args, _host, scale) do
    root = root_post(state, args["thread_id"])
    replies = state |> thread_posts(args["thread_id"]) |> Enum.reject(&root?/1) |> sort_posts()
    count = min(max(length(replies) - offset(args), 0), scaled(page_limit(args), scale))
    chars = min(scaled(preview_limit(args), scale), div(20_000, count + 1))
    page(replies, args, scale, &preview(&1, chars)) |> Map.put("root_post", preview(root, chars))
  end

  defp read(state, "read_post", args, _host, scale) do
    post = load_post(state, args["message_id"])
    chars = String.to_charlist(post["text"])
    offset = min(Map.get(args, "offset_chars", 0), length(chars))
    limit = scaled(min(Map.get(args, "limit_chars", 20_000), 20_000), scale)
    text = chars |> Enum.drop(offset) |> Enum.take(limit) |> List.to_string()

    Map.merge(post["metadata"], %{
      "text" => text,
      "n_chars" => length(chars),
      "next_offset_chars" => offset + length(String.to_charlist(text))
    })
  end

  defp page(items, args, scale, project) do
    offset = offset(args)
    limit = scaled(page_limit(args), scale)
    selected = items |> Enum.drop(offset) |> Enum.take(limit)
    has_more = length(items) > offset + length(selected)
    next = offset + length(selected)
    ensure(next <= 4_294_967_295, "cursor offset exceeds the board limit")

    %{
      "results" => Enum.map(selected, project),
      "n_returned" => length(selected),
      "has_more" => has_more,
      "next_cursor" =>
        if(has_more, do: Base.url_encode64(<<next::unsigned-big-32>>, padding: false), else: nil)
    }
  end

  defp offset(args) do
    case args["cursor"] do
      nil ->
        0

      cursor ->
        case Base.url_decode64(cursor, padding: false) do
          {:ok, <<offset::unsigned-big-32>>} -> offset
          _ -> fail("invalid cursor")
        end
    end
  end

  defp preview(post, limit) do
    chars = String.to_charlist(post["text"])

    Map.merge(post["metadata"], %{
      "text_preview" => chars |> Enum.take(limit) |> List.to_string(),
      "n_chars" => length(chars),
      "truncated" => length(chars) > limit
    })
  end

  defp channel_summary(state, name) do
    channel = state["channels"][name]
    ensure(not is_nil(channel), "channel not found in this board")
    posts = channel_posts(state, name)

    channel
    |> Map.delete("timestamp")
    |> Map.merge(%{"message_count" => length(posts), "last_message_id" => last_message_id(posts)})
  end

  defp channel_posts(state, channel),
    do:
      state["posts"] |> Map.values() |> Enum.filter(&(&1["metadata"]["channel_name"] == channel))

  defp thread_posts(state, thread),
    do: state["posts"] |> Map.values() |> Enum.filter(&(&1["metadata"]["thread_id"] == thread))

  defp sort_posts(posts), do: Enum.sort_by(posts, &post_order/1, :desc)
  defp post_order(post), do: {post["timestamp"], post["sequence"]}

  defp last_message_id(posts) do
    case List.first(sort_posts(posts)) do
      nil -> nil
      post -> post["metadata"]["message_id"]
    end
  end

  defp root?(post), do: post["metadata"]["message_id"] == post["metadata"]["thread_id"]

  defp root_post(state, id) do
    post = load_post(state, id)
    ensure(root?(post), "thread_id must identify a top-level post")
    post
  end

  defp load_post(state, id) do
    post = state["posts"][id]
    ensure(not is_nil(post), "post not found in this board")
    post
  end

  defp activity_time(root, nil), do: root["metadata"]["created_at"]

  defp activity_time(root, latest),
    do:
      if(root["timestamp"] > latest["timestamp"],
        do: root["metadata"]["created_at"],
        else: latest["metadata"]["created_at"]
      )

  defp channel_target(channel), do: Jason.encode!(["channel", channel])
  defp thread_target(thread), do: Jason.encode!(["thread", thread])
  defp page_limit(args), do: min(Map.get(args, "limit", 20), 50)
  defp preview_limit(args), do: min(Map.get(args, "max_chars_per_post", 1000), 20_000)
  defp scaled(value, scale), do: max(div(value, scale), 1)
  defp direction(args), do: if(Map.get(args, "recent_first", true), do: :desc, else: :asc)
  defp fold(text), do: :unicode.characters_to_binary(:string.casefold(text))
  defp encoded_size(value), do: byte_size(Jason.encode!(value))

  defp validate_arguments(name, args) do
    {required, optional} = @schemas[name]

    ensure(
      Enum.all?(Map.keys(args), &(&1 in (required ++ optional))),
      "unknown message-board argument"
    )

    ensure(
      Enum.all?(required, &(is_binary(args[&1]) and String.valid?(args[&1]))),
      "missing required string argument"
    )

    original_args = args
    args = Map.reject(args, fn {_key, value} -> is_nil(value) end)

    Enum.each(args, fn {key, value} ->
      case key do
        key when key in ~w(limit max_chars_per_post limit_chars) ->
          ensure(
            is_integer(value) and value in 1..4_294_967_295,
            "invalid positive integer argument"
          )

        "offset_chars" ->
          ensure(is_integer(value) and value in 0..4_294_967_295, "invalid scalar offset")

        key when key in ~w(subscribe recent_first) ->
          ensure(is_boolean(value), "invalid boolean argument")

        "agents_to_notify" ->
          ensure(
            is_list(value) and Enum.all?(value, &(is_binary(&1) and String.valid?(&1))),
            "invalid recipient list"
          )

        key when key in ~w(message_id thread_id after_message_id) ->
          uuid(value)

        "sort" ->
          ensure(value in ~w(created activity), "invalid thread sort")

        _ ->
          ensure(is_binary(value) and String.valid?(value), "invalid string argument")
      end
    end)

    ensure(encoded_size(original_args) <= 131_072, "message-board arguments exceed 128 KiB")

    args =
      Map.new(args, fn {key, value} ->
        if key in ~w(message_id thread_id after_message_id),
          do: {key, uuid(value)},
          else: {key, value}
      end)

    if name in ["subscribe", "unsubscribe"], do: exactly_one(args, ~w(channel_name thread_id))
    if name == "post", do: exactly_one(args, ~w(channel_name new_channel_name thread_id))
    args
  end

  defp exactly_one(args, keys),
    do: ensure(Enum.count(keys, &Map.has_key?(args, &1)) == 1, "Supply exactly one destination")

  defp validate_channel(name) do
    ensure(
      is_binary(name) and byte_size(name) in 1..128 and String.trim(name) == name and
        not Enum.any?(String.to_charlist(name), &(&1 in 0..31 or &1 in 127..159)),
      "channel names must contain 1–128 bytes without edge whitespace or control characters"
    )
  end

  defp uuid(value) do
    ensure(is_binary(value) and Regex.match?(@uuid, value), "invalid message UUID")
    String.downcase(value)
  end

  defp clock(host) do
    case DateTime.from_iso8601(host[:timestamp] || "") do
      {:ok, value, _} -> {DateTime.to_iso8601(value), DateTime.to_unix(value, :microsecond)}
      _ -> fail("invalid host timestamp")
    end
  end

  defp absolute_path(path) do
    ensure(
      is_binary(path) and
        (path == "/morpheus" or path == "/root" or
           (String.starts_with?(path, "/root/") and
              valid_segments?(String.replace_prefix(path, "/root/", "")))),
      "invalid agent path"
    )

    path
  end

  defp resolve_path(caller, reference) do
    ensure(is_binary(reference) and reference != "", "invalid agent reference")

    if String.starts_with?(reference, "/") do
      absolute_path(reference)
    else
      ensure(valid_segments?(reference), "invalid relative agent reference")
      absolute_path(caller <> "/" <> reference)
    end
  end

  defp valid_segments?(reference),
    do:
      reference
      |> String.split("/")
      |> Enum.all?(&(Regex.match?(~r/\A[a-z0-9_]+\z/, &1) and &1 != "root"))

  defp resolve_agent(host, path) do
    agent = Map.get(host[:agents] || %{}, path)
    ensure(is_binary(agent) and agent != "", "agent not found in this tree")
    agent
  end

  defp ensure(true, _message, _class), do: :ok
  defp ensure(false, message, class), do: fail(message, class)
  defp ensure(condition, message), do: ensure(condition, message, :validation)
  defp fail(message, class \\ :validation), do: throw({:board_error, Error.new(class, message)})
end
