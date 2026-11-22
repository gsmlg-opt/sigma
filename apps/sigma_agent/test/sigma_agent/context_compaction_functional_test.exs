defmodule Sigma.Agent.ContextCompactionFunctionalTest do
  use ExUnit.Case, async: false

  alias Sigma.Agent.Message
  alias Sigma.Agent.ContextPolicy
  alias Sigma.Session.{Log, Writer}

  @moduletag :tmp_dir
  @model %{
    id: "compact-model",
    provider: "fixture",
    api: "fixture",
    context_window: 4096,
    max_output_tokens: 128
  }

  defmodule Provider do
    @behaviour Sigma.Ai.Provider

    def stream(params) do
      send(params.options[:test_pid], {:compact_provider, params})

      cond do
        params.purpose == :compaction and params.options[:fail_summary] ->
          [{:provider_error, Sigma.Ai.ProviderError.from_reason(:summary_failure)}]

        params.purpose == :compaction and params.options[:block_summary] ->
          send(params.options[:test_pid], :summary_waiting)

          receive do
            {:cancel, _ref} ->
              [{:provider_error, Sigma.Ai.ProviderError.from_reason(:cancelled)}]
          end

        true ->
          response(params)
      end
    end

    defp response(params) do
      content =
        cond do
          params.purpose == :compaction ->
            [%{type: :text, text: "Keep working on the original task. Earlier tool completed."}]

          params.options[:large_tool] == true and
            not Enum.any?(params.context.messages, &(&1.role == :tool_result)) and
              not Enum.any?(params.context.messages, &(text(&1) =~ "Earlier tool completed")) ->
            [%{type: :tool_call, id: "large-read", name: "large_read", arguments: %{}}]

          true ->
            [%{type: :text, text: "Finished the original task."}]
        end

      reason = if Enum.any?(content, &(&1.type == :tool_call)), do: :tool_use, else: :stop

      message = %{
        role: :assistant,
        content: content,
        model: params.model.id,
        provider: "fixture",
        usage: %{input: 100, output: 10, total_tokens: 110},
        stop_reason: reason,
        timestamp: System.system_time(:millisecond)
      }

      [{:start, %{message | content: []}}, {:done, reason, message}]
    end

    defp text(%{content: content}) when is_binary(content), do: content

    defp text(%{content: blocks}) when is_list(blocks),
      do: Enum.map_join(blocks, "", &Map.get(&1, :text, ""))
  end

  defmodule LargeRead do
    @behaviour Sigma.Coding.Tool
    def name, do: "large_read"
    def description, do: "Read a large local fixture."
    def schema, do: %{"type" => "object", "properties" => %{}}

    def execute(_id, _arguments, opts) do
      send(opts[:test_pid], :large_read_executed)

      {:ok,
       %{
         content: [%{type: :text, text: String.duplicate("read fixture data\n", 1500)}],
         details: %{}
       }}
    end
  end

  defmodule FailingCompactionStorage do
    @behaviour Sigma.Session.Storage
    defdelegate read(path), to: Sigma.Session.Storage.JsonlFile
    defdelegate read_with_diagnostics(path), to: Sigma.Session.Storage.JsonlFile
    def append(_path, %{"type" => "compaction"}), do: {:error, :disk_full}
    def append(path, entry), do: Sigma.Session.Storage.JsonlFile.append(path, entry)
  end

  defmodule VerboseTool do
    @behaviour Sigma.Coding.Tool
    def name, do: "verbose_fixture"
    def description, do: String.duplicate("descriptive metadata ", 550)
    def schema, do: %{"type" => "object", "properties" => %{}}
    def execute(_id, _arguments, _opts), do: {:ok, %{content: [], details: %{}}}
  end

  defmodule DeferredCompactionStorage do
    @behaviour Sigma.Session.Storage
    defdelegate read(path), to: Sigma.Session.Storage.JsonlFile
    defdelegate read_with_diagnostics(path), to: Sigma.Session.Storage.JsonlFile

    def append(path, %{"type" => "compaction"} = entry) do
      [{:owner, owner}] = :ets.lookup(:sigma_compaction_append_gate, :owner)
      send(owner, {:compaction_append_pending, self()})

      receive do
        :commit_compaction -> Sigma.Session.Storage.JsonlFile.append(path, entry)
      end
    end

    def append(path, entry), do: Sigma.Session.Storage.JsonlFile.append(path, entry)
  end

  test "compaction after an accepted continuation retains a real journal boundary", c do
    call = %{type: :tool_call, id: "lost", name: "read", arguments: %{}}

    assistant =
      Message.assistant("msg_assistant_attempt", %{content: [call], metadata: %{turn_id: "run"}})

    later = for n <- 1..24, do: Message.user("later-#{n}", "Later message #{n}")

    history = [
      Message.user("first", "Original task"),
      assistant,
      continue_after_lost_call() | later
    ]

    agent = start_agent(c, messages: history)

    assert :ok = Sigma.Agent.begin_session_operation(agent)
    assert {:ok, _} = Sigma.Agent.compact(agent)
    assert :ok = Sigma.Agent.end_session_operation(agent)

    assert_receive {:compact, _, "later-5"}
    assert [%{role: :compaction_summary} | kept] = Sigma.Agent.messages(agent)
    assert kept == Enum.drop(later, 4)
    assert_receive {:compact_provider, %{purpose: :compaction, context: %{messages: [prompt]}}}
    [%{text: text}] = prompt.content
    assert text =~ "The read outcome is unknown."
    refute text =~ "tool_call"
  end

  test "a retained Continue points to its original message and projects its notice once", c do
    continue = continue_after_lost_call()
    kept = [continue | Enum.map(1..19, &Message.user("m#{&1}", "Message #{&1}"))]
    agent = start_agent(c, messages: [Message.user("old", "Summarize this") | kept])

    assert :ok = Sigma.Agent.begin_session_operation(agent)
    assert {:ok, _} = Sigma.Agent.compact(agent)
    assert :ok = Sigma.Agent.end_session_operation(agent)
    assert_receive {:compact, _, "continue"}
    assert [summary | ^kept] = Sigma.Agent.messages(agent)

    context = Sigma.Agent.ContextBuilder.build(messages: [summary | kept])

    assert Enum.count(context.messages, &(&1.content == continue.metadata.continuation_notice)) ==
             1
  end

  test "a cold continuation sends hosted search to Responses even when all local calls were lost",
       c do
    frames =
      ~s(data: {"type":"response.completed","response":{"id":"next","status":"completed","output":[]}}) <>
        "\n\n"

    with_http(frames, fn url, capture ->
      alias Sigma.Ai.Providers.OpenAIResponses
      prepared = OpenAIResponses.Hosted.prepare!(@model, %{messages: [], tools: []}, [], url)

      search = %{
        "type" => "web_search_call",
        "id" => "search",
        "status" => "completed",
        "action" => %{"type" => "search", "query" => "example"}
      }

      lost = %{
        "type" => "custom_tool_call",
        "call_id" => "lost",
        "name" => "edit",
        "input" => "patch"
      }

      envelope = %{
        "origin" => prepared.origin,
        "version" => 1,
        "response_id" => "previous",
        "items" => Enum.with_index([search, lost], &%{"output_index" => &2, "item" => &1})
      }

      assistant =
        Message.assistant("msg_assistant_attempt", %{
          content: [
            %{type: :tool_call, id: "lost", name: "edit", input_kind: :custom, arguments: "patch"}
          ],
          metadata: %{"openai_responses_hosted" => envelope, turn_id: "run"}
        })

      path = Path.join(c.tmp_dir, "hosted.jsonl")

      for msg <- [assistant, continue_after_lost_call()],
          do: :ok = Log.persist_event(path, {:message_end, msg})

      original = File.read!(path)
      assert {:ok, messages} = Log.replay(path)
      context = Sigma.Agent.ContextBuilder.build(messages: messages)

      events =
        OpenAIResponses.stream(%{
          model: @model,
          context: context,
          options: [api_key: "fixture", base_url: url]
        })
        |> Enum.to_list()

      assert Enum.any?(events, &match?({:done, _, _}, &1))
      input = Agent.get(capture, & &1["input"]) |> Enum.reject(&(&1["role"] == "system"))
      assert [^search, %{"role" => "user"}, %{"role" => "user"}] = input
      assert File.read!(path) == original
    end)
  end

  defp continue_after_lost_call do
    %{
      Message.user("continue", "Continue")
      | metadata: %{
          continuation_notice: "The read outcome is unknown.",
          continuation_tools: [
            %{"run_id" => "run", "attempt_id" => "attempt", "tool_call_id" => "lost"}
          ]
        }
    }
  end

  test "manual compaction handles fewer than twenty large messages", c do
    agent = start_agent(c, messages: large_history())
    assert :ok = Sigma.Agent.begin_session_operation(agent)
    assert {:ok, _} = Sigma.Agent.compact(agent)
    assert :ok = Sigma.Agent.end_session_operation(agent)
    assert Enum.any?(Sigma.Agent.messages(agent), &(&1.role == :compaction_summary))
    assert_bounded_summary_requests()
  end

  test "overflowing old context is compacted before the same prompt reaches the model", c do
    agent = start_agent(c, messages: large_history())
    assert {:accepted, admission} = Sigma.Agent.prompt(agent, "Continue the original task")
    assert_receive {:agent_end, messages}, 5000
    assert Enum.any?(messages, &(&1.role == :compaction_summary))
    assert Enum.any?(messages, &(&1.role == :user and &1.content == "Continue the original task"))

    assert Enum.any?(
             messages,
             &(&1.role == :assistant and &1.metadata[:turn_id] == admission.turn_id)
           )

    refute_received {:turn_error, _}
    assert_bounded_summary_requests()
    assert_receive {:compact_provider, %{purpose: :turn} = request}

    assert ContextPolicy.snapshot(messages: request.context.messages).next_request_estimated_input_tokens <
             4096
  end

  test "a large completed tool result is summarized and continues without replay", c do
    agent =
      start_agent(c,
        tools: [LargeRead],
        options: [test_pid: self(), large_tool: true],
        dispatcher_opts: [test_pid: self()]
      )

    assert {:accepted, admission} = Sigma.Agent.prompt(agent, "Finish the original task")
    assert_receive :large_read_executed, 5000
    assert_receive {:agent_end, messages}, 5000
    refute_received :large_read_executed
    refute_received {:turn_error, _}
    assert Enum.any?(messages, &(&1.role == :compaction_summary))
    assert List.last(messages).metadata[:turn_id] == admission.turn_id
    assert List.last(messages).content == [%{type: :text, text: "Finished the original task."}]
    assert_bounded_summary_requests()
  end

  test "compaction leaves room for the actual tool catalog and output reserve", c do
    history =
      Enum.flat_map(1..2, fn n ->
        [
          Message.user("catalog-user-#{n}", "Earlier request"),
          Message.assistant("catalog-assistant-#{n}", %{content: String.duplicate("result ", 750)})
        ]
      end)

    agent = start_agent(c, tools: [VerboseTool], messages: history)
    assert {:accepted, _} = Sigma.Agent.prompt(agent, "Continue the task")
    assert_receive {:agent_end, _}, 5000
    refute_received {:turn_error, _}
    assert_receive {:compact_provider, %{purpose: :turn} = request}

    estimate =
      ContextPolicy.snapshot(
        messages: request.context.messages,
        system: request.context.system,
        tools: request.context.tools
      )

    assert estimate.next_request_estimated_input_tokens + @model.max_output_tokens <= 4096
  end

  test "an image prompt reaches the provider intact even when its transport bytes exceed the budget",
       c do
    agent = start_agent(c)
    # A real PNG with a large ancillary text chunk. Its encoded size changes
    # independently of the pixels the model sees.
    png =
      Base.decode64!(
        "iVBORw0KGgoAAAANSUhEUgAAAEEAAAAhAQMAAAC8zVRcAAAAA1BMVEX/AAAZ4gk3AAAADUlEQVQY02NgGAXUAQABSgAB5p5tAwAAAABJRU5ErkJggg=="
      )

    <<body::binary-size(byte_size(png) - 12), iend::binary>> = png
    chunk = "tEXt" <> "Comment" <> <<0>> <> String.duplicate("x", 32_768)

    bytes =
      <<body::binary, byte_size(chunk) - 4::32, chunk::binary, :erlang.crc32(chunk)::32,
        iend::binary>>

    image = %{type: :image, mime_type: "image/png", data: Base.encode64(bytes)}
    content = [%{type: :text, text: "Describe this image"}, image]
    assert {:accepted, _} = Sigma.Agent.prompt(agent, content)
    assert_receive {:agent_end, _}, 5000
    assert_received {:compact_provider, %{purpose: :turn, context: %{messages: messages}}}
    assert List.last(messages).content == content
    refute_received {:compact_provider, %{purpose: :compaction}}
    refute_received {:turn_error, _}
  end

  test "an oversized newest prompt fails without trying to summarize its instructions", c do
    agent = start_agent(c)
    assert {:accepted, _} = Sigma.Agent.prompt(agent, String.duplicate("new instruction ", 2000))
    assert_receive {:turn_error, %Sigma.Ai.ProviderError{kind: :context_limit}}, 3000
    assert_receive {:agent_end, _}, 3000
    refute_received {:compact_provider, _}
    status = Sigma.Agent.status(agent)
    assert status.context_snapshot.next_request_estimated_input_tokens > @model.context_window
    assert status.context_policy.overflow == :hard_overflow
    refute status.context_snapshot.stale
  end

  test "summary failure retains the completed tool and fails without replaying it", c do
    agent =
      start_agent(c,
        tools: [LargeRead],
        options: [test_pid: self(), large_tool: true, fail_summary: true],
        dispatcher_opts: [test_pid: self()]
      )

    assert {:accepted, _} = Sigma.Agent.prompt(agent, "Finish the original task")
    assert_receive :large_read_executed, 5000
    assert_receive {:agent_end, messages}, 5000
    assert_received {:turn_error, %Sigma.Ai.ProviderError{}}
    refute_received :large_read_executed
    assert Enum.count(messages, &(&1.role == :tool_result)) == 1
    refute Enum.any?(messages, &(&1.role == :compaction_summary))
    assert Sigma.Agent.status(agent).phase == :failed
  end

  test "cancellation during summary preserves completed tool history and stops continuation", c do
    agent =
      start_agent(c,
        tools: [LargeRead],
        options: [test_pid: self(), large_tool: true, block_summary: true],
        dispatcher_opts: [test_pid: self()]
      )

    assert {:accepted, _} = Sigma.Agent.prompt(agent, "Finish the original task")
    assert_receive :large_read_executed, 5000
    assert_receive :summary_waiting, 5000
    assert {:cancelling, _} = Sigma.Agent.cancel(agent)
    assert_receive {:agent_end, messages}, 5000
    assert Enum.count(messages, &(&1.role == :tool_result)) == 1
    refute Enum.any?(messages, &(&1.role == :compaction_summary))
    assert drain_provider_calls(0) == 2
    refute_received :large_read_executed
    refute_received :summary_waiting
  end

  test "a failed compaction append retains the original settled batch and starts no continuation",
       c do
    path = Path.join(c.tmp_dir, "failed-append.jsonl")

    assert {:ok, handle} =
             Sigma.Agent.Runtime.get_session(c.tmp_dir, "failed-append",
               model: @model,
               provider: Provider,
               transcript_path: path,
               native_tools: false,
               storage_mod: FailingCompactionStorage,
               system_prompt: "Fixture instructions.",
               hook_specs: [],
               tools: [LargeRead],
               options: [test_pid: self(), large_tool: true],
               dispatcher_opts: [test_pid: self()]
             )

    on_exit(fn ->
      if supervisor = Sigma.Agent.Runtime.lookup(c.tmp_dir, :supervisor),
        do: DynamicSupervisor.terminate_child(Sigma.Agent.DynamicSupervisor, supervisor)
    end)

    Sigma.Agent.subscribe(handle.agent)
    assert {:accepted, _} = Sigma.Agent.prompt(handle.agent, "Finish the original task")
    assert_receive :large_read_executed, 5000
    assert_receive {:turn_failed, _}, 5000
    assert {:ok, _} = Writer.flush(handle.writer)
    assert {:ok, snapshot} = Log.snapshot(path)
    assert snapshot.compaction == nil
    assert Enum.count(snapshot.messages, &(&1.role == :tool_result)) == 1
    assert Enum.count(snapshot.messages, &(&1.role == :assistant)) == 1
    refute_received :large_read_executed
    requests = drain_provider_requests([])
    assert Enum.count(requests, &(&1.purpose == :turn)) == 1
  end

  test "an admitted compaction append settles after cancellation without releasing another request",
       c do
    :ets.new(:sigma_compaction_append_gate, [:named_table, :public])
    :ets.insert(:sigma_compaction_append_gate, {:owner, self()})
    path = Path.join(c.tmp_dir, "deferred.jsonl")

    assert {:ok, handle} =
             Sigma.Agent.Runtime.get_session(c.tmp_dir, "deferred",
               model: @model,
               provider: Provider,
               transcript_path: path,
               native_tools: false,
               storage_mod: DeferredCompactionStorage,
               system_prompt: "Fixture instructions.",
               hook_specs: [],
               tools: [LargeRead],
               options: [test_pid: self(), large_tool: true],
               dispatcher_opts: [test_pid: self()]
             )

    on_exit(fn ->
      if supervisor = Sigma.Agent.Runtime.lookup(c.tmp_dir, :supervisor),
        do: DynamicSupervisor.terminate_child(Sigma.Agent.DynamicSupervisor, supervisor)
    end)

    Sigma.Agent.subscribe(handle.agent)
    assert {:accepted, _} = Sigma.Agent.prompt(handle.agent, "Finish the original task")
    assert_receive :large_read_executed, 5000
    assert_receive {:compaction_append_pending, writer}, 5000
    before = File.read!(path)
    assert {:cancelling, _} = Sigma.Agent.cancel(handle.agent)
    send(writer, :commit_compaction)
    assert_receive {:agent_end, _}, 5000
    assert {:ok, _} = Writer.flush(handle.writer)
    assert {:ok, snapshot} = Log.snapshot(path)
    assert snapshot.diagnostics == []
    assert [%{role: :compaction_summary}] = snapshot.context_messages
    assert String.starts_with?(File.read!(path), before)
    assert Enum.count(drain_provider_requests([]), &(&1.purpose == :turn)) == 1
    refute_received :large_read_executed
  end

  test "a summary of the complete tool batch is durable and cold reads execute nothing", c do
    path = Path.join(c.tmp_dir, "durable.jsonl")

    options = [
      model: @model,
      provider: Provider,
      transcript_path: path,
      native_tools: false,
      system_prompt: "Fixture instructions.",
      hook_specs: [],
      tools: [LargeRead],
      options: [test_pid: self(), large_tool: true],
      dispatcher_opts: [test_pid: self()]
    ]

    assert {:ok, handle} = Sigma.Agent.Runtime.get_session(c.tmp_dir, "durable", options)

    on_exit(fn ->
      if supervisor = Sigma.Agent.Runtime.lookup(c.tmp_dir, :supervisor),
        do: DynamicSupervisor.terminate_child(Sigma.Agent.DynamicSupervisor, supervisor)
    end)

    Sigma.Agent.subscribe(handle.agent)
    assert {:accepted, _} = Sigma.Agent.prompt(handle.agent, "Finish the original task")
    assert_receive :large_read_executed, 5000
    assert_receive {:agent_end, _}, 5000
    assert {:ok, _} = Writer.flush(handle.writer)
    bytes = File.read!(path)
    assert {:ok, entries} = Sigma.Session.Storage.JsonlFile.read(path)

    assert Enum.count(
             entries,
             &(&1["type"] == "message" and
                 get_in(&1, ["message", "role"]) == "tool_result")
           ) == 1

    assert %{"firstKeptEntryId" => nil} = Enum.find(entries, &(&1["type"] == "compaction"))
    assert {:ok, snapshot} = Log.snapshot(path)
    assert snapshot.diagnostics == []
    assert [%{role: :compaction_summary}, %{role: :assistant}] = snapshot.context_messages
    refute_received :large_read_executed
    provider_calls = drain_provider_calls(0)

    assert {:ok, repeated} = Log.snapshot(path)
    assert repeated.context_messages == snapshot.context_messages
    assert File.read!(path) == bytes
    assert provider_calls > 1
    refute_received {:compact_provider, _}

    supervisor = Sigma.Agent.Runtime.lookup(c.tmp_dir, "durable", :supervisor)

    assert :ok =
             DynamicSupervisor.terminate_child(
               Sigma.Agent.Runtime.lookup(c.tmp_dir, :sessions),
               supervisor
             )

    assert {:ok, reopened} =
             Sigma.Agent.Runtime.get_session(
               c.tmp_dir,
               "durable",
               Keyword.merge(options,
                 messages: snapshot.messages,
                 context_messages: snapshot.context_messages,
                 context_window: snapshot.context_window,
                 context_source: :journal_replay
               )
             )

    assert reopened.agent != handle.agent
    assert File.read!(path) == bytes
    refute_received {:compact_provider, _}
    Sigma.Agent.subscribe(reopened.agent)
    assert {:accepted, _} = Sigma.Agent.prompt(reopened.agent, "Continue with the completed read")
    assert_receive {:agent_end, _}, 5000
    assert {:ok, _} = Writer.flush(reopened.writer)
    assert String.starts_with?(File.read!(path), bytes)
    refute_received :large_read_executed
  end

  test "a complete summary carries the task and session instructions to both HTTP providers" do
    summary = %Message{
      id: "complete",
      role: :compaction_summary,
      content: "Original task is to repair the fixture. Earlier read completed."
    }

    context =
      Sigma.Agent.ContextBuilder.build(
        messages: [summary],
        system_prompt: "Fixture system instructions.",
        session_context: Sigma.Agent.SessionContext.new(agents_context: "Workdir guidance.")
      )

    for {provider, frames} <- [
          {Sigma.Ai.Providers.OpenAIResponses,
           "data: " <>
             Formata.JSON.encode!(%{
               type: "response.completed",
               response: %{id: "wire-response", status: "completed", output: []}
             }) <> "\n\n"},
          {Sigma.Ai.Providers.Anthropic,
           Enum.map_join(
             [
               {"message_start",
                %{
                  type: "message_start",
                  message: %{
                    id: "wire-message",
                    role: "assistant",
                    content: [],
                    model: "compact-model",
                    usage: %{input_tokens: 1, output_tokens: 0}
                  }
                }},
               {"message_delta",
                %{
                  type: "message_delta",
                  delta: %{stop_reason: "end_turn"},
                  usage: %{output_tokens: 0}
                }},
               {"message_stop", %{type: "message_stop"}}
             ],
             fn {event, frame} -> "event: #{event}\ndata: #{Formata.JSON.encode!(frame)}\n\n" end
           )}
        ] do
      with_http(frames, fn url, capture ->
        events =
          provider.stream(%{
            model: @model,
            context: context,
            options: [api_key: "fixture", base_url: url, receive_timeout: 2000]
          })
          |> Enum.to_list()

        assert Enum.any?(events, &match?({:done, _, _}, &1))
        request = Agent.get(capture, & &1)
        messages = request["input"] || request["messages"]

        assert [%{"role" => "user", "content" => blocks}] =
                 Enum.reject(messages, &(&1["role"] == "system"))

        text = Enum.map_join(blocks, & &1["text"])
        assert text =~ "Original task is to repair the fixture"
        assert text =~ "Workdir guidance."
      end)
    end
  end

  defp start_agent(c, opts \\ []) do
    agent =
      start_supervised!(
        {Sigma.Agent,
         Keyword.merge(
           [
             model: @model,
             provider: Provider,
             system_prompt: "Fixture instructions.",
             hook_specs: [],
             options: [test_pid: self()],
             backplane_runtime_path: Path.join(c.tmp_dir, "runtime")
           ],
           opts
         )}
      )

    Sigma.Agent.subscribe(agent)
    agent
  end

  defp large_history do
    Enum.flat_map(1..4, fn n ->
      [
        Message.user("old-user-#{n}", "Earlier request #{n}"),
        Message.assistant("old-assistant-#{n}", %{content: String.duplicate("earlier 结果🙂 ", 2000)})
      ]
    end)
  end

  defp assert_bounded_summary_requests do
    requests = drain_summaries([])
    assert requests != []

    for request <- requests do
      input =
        ContextPolicy.snapshot(messages: request.context.messages).next_request_estimated_input_tokens

      assert input + request.options[:max_tokens] <= @model.context_window
    end
  end

  defp drain_summaries(acc) do
    receive do
      {:compact_provider, %{purpose: :compaction} = request} -> drain_summaries([request | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp drain_provider_calls(count) do
    receive do
      {:compact_provider, _} -> drain_provider_calls(count + 1)
    after
      0 -> count
    end
  end

  defp drain_provider_requests(requests) do
    receive do
      {:compact_provider, request} -> drain_provider_requests([request | requests])
    after
      0 -> requests
    end
  end

  defp with_http(frames, fun) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listener)
    {:ok, capture} = Agent.start_link(fn -> nil end)

    {:ok, server} =
      Task.start(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        request = receive_http(socket, "")
        [_headers, body] = String.split(request, "\r\n\r\n", parts: 2)
        Agent.update(capture, fn _ -> Formata.JSON.decode!(body) end)

        :ok =
          :gen_tcp.send(socket, [
            "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\n",
            "content-length: #{byte_size(frames)}\r\nconnection: close\r\n\r\n",
            frames
          ])

        :gen_tcp.close(socket)
      end)

    try do
      fun.("http://127.0.0.1:#{port}", capture)
    after
      :gen_tcp.close(listener)
      if Process.alive?(server), do: Process.exit(server, :kill)
      Agent.stop(capture)
    end
  end

  defp receive_http(socket, bytes) do
    {:ok, chunk} = :gen_tcp.recv(socket, 0, 2000)
    bytes = bytes <> chunk

    case String.split(bytes, "\r\n\r\n", parts: 2) do
      [headers, body] ->
        [_, length] = Regex.run(~r/content-length: (\d+)/i, headers)

        if byte_size(body) >= String.to_integer(length),
          do: bytes,
          else: receive_http(socket, bytes)

      _ ->
        receive_http(socket, bytes)
    end
  end
end
