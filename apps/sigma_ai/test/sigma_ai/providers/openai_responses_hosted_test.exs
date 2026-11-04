defmodule Sigma.Ai.Providers.OpenAIResponsesHostedTest do
  use ExUnit.Case, async: true

  alias Sigma.Ai.{Provider, ProviderError, ProviderRequest}
  alias Sigma.Ai.Providers.{Anthropic, OpenAI, OpenAIResponses}
  alias Sigma.Ai.Providers.OpenAIResponses.Hosted

  @model %{id: "hosted-model", api: "openai", provider: "configured-provider"}
  @enabled %{supported: true, enabled: true, mode: :cached}
  @declaration %{type: "web_search", external_web_access: false}

  test "only explicitly enabled negotiated hosted declarations reach HTTP" do
    for options <- [[], [hosted_web_search: %{supported: true, enabled: false}]],
        tools <- [[@declaration], [@declaration, @declaration]] do
      assert_preflight_error(OpenAIResponses, tools, options)
    end

    assert_preflight_error(OpenAIResponses, [@declaration, @declaration],
      hosted_web_search: @enabled
    )

    assert_preflight_error(OpenAIResponses, [%{type: "web_search", external_web_access: true}],
      hosted_web_search: @enabled
    )

    assert_preflight_error(OpenAIResponses, [%{type: "file_search"}], hosted_web_search: @enabled)
  end

  test "other transports reject hosted declarations and hosted replay before HTTP" do
    for provider <- [OpenAI, Anthropic] do
      assert_preflight_error(provider, [@declaration], hosted_web_search: @enabled)

      message = %{role: :assistant, content: [], metadata: %{"openai_responses_hosted" => %{}}}
      assert_preflight_error(provider, [], [], [message])
    end
  end

  test "streams real hosted observations and preserves actions, citations and native order" do
    output = output()

    frames = [
      frame("response.output_item.added", 0, Map.put(hd(output), "status", "in_progress")),
      frame("response.output_item.done", 0, hd(output)),
      %{"type" => "response.output_text.delta", "delta" => "Found it"},
      terminal(output)
    ]

    with_server(frames, fn base_url, capture ->
      events = stream(base_url)

      assert %{"tools" => [%{"type" => "web_search", "external_web_access" => false}]} =
               Agent.get(capture, & &1)

      hosted = Enum.filter(events, &(&1.type == :provider_hosted_event))
      assert Enum.any?(hosted, &(&1.capability == "web_search"))
      refute Enum.any?(events, &(&1.type in [:tool_call_started, :tool_call_completed]))
      done = Enum.find(events, &(&1.type == :response_completed))
      assert done.message.stop_reason == :stop
      assert [%{type: :text, text: "Found it"}] = done.message.content
      metadata = done.message.metadata["openai_responses_hosted"]
      assert metadata["version"] == 1
      assert metadata["origin"]["provider"] == @model.provider
      assert metadata["origin"]["model"] == @model.id
      assert metadata["origin"]["protocol"] == "openai-responses"
      assert metadata["origin"]["endpoint_sha256"] =~ ~r/^[0-9a-f]{64}$/
      refute Jason.encode!(metadata) =~ base_url

      assert metadata["items"] ==
               Enum.with_index(output, fn item, index ->
                 %{"output_index" => index, "item" => item}
               end)
    end)
  end

  test "terminal-only hosted output reconstructs text and never dispatches a local tool" do
    with_server([terminal(output())], fn base_url, _capture ->
      events = stream(base_url)
      assert Enum.any?(events, &(&1.type == :provider_hosted_event))

      assert %{message: %{content: [%{type: :text, text: "Found it"}]}} =
               Enum.find(events, &(&1.type == :response_completed))

      refute Enum.any?(events, &(&1.type == :tool_call_completed))
    end)
  end

  test "actual hosted HTTP accepts complete near-one-MiB output through the SSE boundary" do
    reasoning = %{
      "type" => "reasoning",
      "id" => "large-reasoning",
      "summary" => [],
      "encrypted_content" => String.duplicate("e", 1_030_000)
    }

    native = [reasoning | output()]

    with_server([terminal(native)], fn base_url, _capture ->
      events = stream(base_url)
      refute Enum.any?(events, &(&1.type == :response_failed))
      assert done = Enum.find(events, &(&1.type == :response_completed))
      metadata = done.message.metadata["openai_responses_hosted"]
      assert byte_size(Jason.encode!(metadata)) > 1_000_000
      assert byte_size(Jason.encode!(metadata)) <= 1_048_576
      assert Enum.map(metadata["items"], & &1["item"]) == native
      assert Hosted.project_metadata(done.message) == {:ok, metadata}
    end)
  end

  test "hosted framing preserves the native aggregate limit and ordinary transport bound" do
    reasoning = %{
      "type" => "reasoning",
      "id" => "too-large",
      "summary" => [],
      "encrypted_content" => String.duplicate("e", 1_048_500)
    }

    with_server([terminal([reasoning | output()])], fn base_url, _capture ->
      events = stream(base_url)
      refute Enum.any?(events, &(&1.type == :response_completed))

      assert Enum.any?(
               events,
               &(&1.type == :response_failed and &1.error.message == "hosted_output_limit")
             )
    end)

    ordinary =
      output()
      |> Enum.take(-1)
      |> put_in([Access.at(0), "content", Access.at(0), "text"], String.duplicate("x", 300_000))

    with_server([terminal(ordinary)], fn base_url, _capture ->
      events = stream(base_url, tools: [], options: [])
      refute Enum.any?(events, &(&1.type == :response_completed))

      assert Enum.any?(
               events,
               &(&1.type == :response_failed and &1.error.message == "invalid_sse")
             )
    end)
  end

  test "terminal-only citations survive when no new search call is emitted" do
    output = [List.last(output())]

    with_server([terminal(output)], fn base_url, _capture ->
      events = stream(base_url)
      done = Enum.find(events, &(&1.type == :response_completed))
      assert [%{type: :text, text: "Found it"}] = done.message.content

      assert [%{"output_index" => 0, "item" => item}] =
               done.message.metadata["openai_responses_hosted"]["items"]

      assert item == hd(output)
      refute Enum.any?(events, &(&1.type in [:tool_call_completed, :provider_hosted_event]))
    end)
  end

  test "streamed annotations bind their item id to the indexed terminal message" do
    annotation =
      get_in(List.last(output()), ["content", Access.at(0), "annotations", Access.at(0)])

    frame = %{
      "type" => "response.output_text.annotation.added",
      "output_index" => 1,
      "content_index" => 0,
      "annotation_index" => 0,
      "item_id" => "msg1",
      "annotation" => annotation
    }

    with_server([frame, terminal(output())], fn base_url, _capture ->
      events = stream(base_url)
      assert Enum.any?(events, &(&1.type == :response_completed))
      refute Enum.any?(events, &(&1.type == :response_failed))
    end)

    for invalid <- [
          Map.put(frame, "item_id", "foreign"),
          Map.delete(frame, "item_id"),
          Map.put(frame, "item_id", 42),
          Map.put(frame, "output_index", 0)
        ] do
      with_server([invalid, terminal(output())], fn base_url, _capture ->
        events = stream(base_url)

        assert %{error: %{kind: :malformed_stream}} =
                 Enum.find(events, &(&1.type == :response_failed))

        refute Enum.any?(events, &(&1.type == :response_completed))
      end)
    end
  end

  test "mixed hosted and actual function calls keep public codec validation and replay order" do
    call = %{
      "type" => "function_call",
      "id" => "fc1",
      "call_id" => "call1",
      "name" => "local",
      "arguments" => "{\"value\":1}",
      "status" => "completed"
    }

    output = [hd(output()), call, List.last(output())]

    with_server([terminal(output)], fn base_url, capture ->
      tools = [@declaration, %{name: "local", parameters: %{"type" => "object"}}]
      events = stream(base_url, tools: tools)
      done = Enum.find(events, &(&1.type == :response_completed))
      assert done.message.stop_reason == :tool_use
      assert Enum.count(events, &(&1.type == :tool_call_completed)) == 1
      assert Enum.any?(Agent.get(capture, & &1["tools"]), &(&1["type"] == "function"))

      prepared =
        Hosted.prepare!(
          @model,
          %{messages: [done.message], tools: []},
          [hosted_web_search: @enabled],
          base_url
        )

      assert Hosted.replay_items!(done.message, prepared) == output
    end)
  end

  test "malformed actual local calls still fail when hosted search is enabled" do
    call = %{
      "type" => "function_call",
      "id" => "fc1",
      "call_id" => "call1",
      "name" => "local",
      "arguments" => "not json",
      "status" => "completed"
    }

    with_server([terminal([hd(output()), call])], fn base_url, _capture ->
      events = stream(base_url)
      assert Enum.any?(events, &(&1.type == :response_failed))
      refute Enum.any?(events, &(&1.type == :response_completed))
    end)
  end

  test "interleaved reasoning survives persistence and the next real HTTP request unchanged" do
    reasoning = %{
      "type" => "reasoning",
      "id" => "reasoning-before-search",
      "status" => "completed",
      "summary" => [%{"type" => "summary_text", "text" => "Search the reference first"}],
      "encrypted_content" => "opaque-before-search"
    }

    later = %{
      reasoning
      | "id" => "reasoning-after-search",
        "summary" => [],
        "encrypted_content" => "opaque-after-search"
    }

    call = %{
      "type" => "function_call",
      "id" => "fc1",
      "call_id" => "call1",
      "name" => "local",
      "arguments" => "{\"value\":1}",
      "status" => "completed"
    }

    output = [reasoning, hd(output()), later, call, List.last(output())]

    with_server([terminal(output)], fn base_url, capture ->
      events = stream(base_url)
      assert %{message: message} = Enum.find(events, &(&1.type == :response_completed))
      assert Enum.count(events, &(&1.type == :tool_call_completed)) == 1
      assert Enum.count(events, &(&1.type == :provider_hosted_event)) == 1

      entries = message.metadata["openai_responses_hosted"]["items"]
      assert entries == Enum.with_index(output, &%{"output_index" => &2, "item" => &1})
      message = %{message | metadata: message.metadata |> Jason.encode!() |> Jason.decode!()}
      assert {:ok, _} = Hosted.project_metadata(message)

      tool_result = %{
        role: :tool_result,
        tool_call_id: "call1",
        content: [%{type: :text, text: "1"}]
      }

      stream(base_url, tools: [], options: [], messages: [message, tool_result])
      body = Agent.get(capture, & &1)
      assert Enum.take(body["input"], length(output)) == output
      assert List.last(body["input"])["type"] == "function_call_output"
      assert body["tools"] == []
      refute Enum.any?(message.content, &(&1.type == :text and &1.text =~ "opaque-"))
    end)
  end

  test "unsupported hosted output is rejected instead of silently dropped" do
    unsupported = %{"type" => "unconfigured_native_result", "id" => "unknown1"}

    for items <- [[hd(output()), unsupported, List.last(output())], [unsupported]] do
      with_server([terminal(items)], fn base_url, _capture ->
        events = stream(base_url)

        assert %{error: %{kind: :malformed_stream}} =
                 Enum.find(events, &(&1.type == :response_failed))

        refute Enum.any?(events, &(&1.type == :response_completed))
      end)
    end
  end

  test "reasoning remains native when an enabled hosted turn emits no search call" do
    reasoning = %{
      "type" => "reasoning",
      "id" => "reasoning-without-search",
      "summary" => [],
      "encrypted_content" => "opaque-reasoning"
    }

    for output <- [[reasoning], [reasoning, List.last(output())]] do
      with_server([terminal(output)], fn base_url, capture ->
        events = stream(base_url)
        assert %{message: message} = Enum.find(events, &(&1.type == :response_completed))
        assert {:ok, _} = Hosted.project_metadata(message)

        assert Enum.map(message.metadata["openai_responses_hosted"]["items"], & &1["item"]) ==
                 output

        refute Enum.any?(events, &(&1.type in [:tool_call_completed, :provider_hosted_event]))
        stream(base_url, tools: [], options: [], messages: [message])
        assert Agent.get(capture, & &1["input"]) == output
      end)
    end
  end

  test "malformed reasoning and duplicate native identities fail without partial completion" do
    reasoning = %{"type" => "reasoning", "id" => "rs1", "summary" => []}

    for invalid <- [
          Map.put(reasoning, "id", 42),
          Map.put(reasoning, "status", "unknown"),
          Map.put(reasoning, "encrypted_content", %{"private" => "invalid"}),
          Map.delete(reasoning, "summary"),
          Map.put(reasoning, "summary", [%{"type" => "summary_text", "text" => 42}]),
          Map.put(reasoning, "summary", [%{"type" => "unexpected", "text" => "text"}]),
          Map.put(reasoning, "content", %{}),
          Map.put(reasoning, "content", [%{"type" => "reasoning_text", "text" => 42}]),
          Map.put(reasoning, "id", "ws1")
        ] do
      with_server([terminal([hd(output()), invalid, List.last(output())])], fn base_url, _ ->
        events = stream(base_url)

        assert %{error: %{kind: :malformed_stream}} =
                 Enum.find(events, &(&1.type == :response_failed))

        refute Enum.any?(events, &(&1.type == :response_completed))
      end)
    end
  end

  test "malformed hosted actions, citations, identities and lifecycle conflicts fail explicitly" do
    bad_search = put_in(hd(output()), ["action", "query"], 42)

    bad_citation =
      put_in(
        List.last(output()),
        ["content", Access.at(0), "annotations", Access.at(0), "url"],
        42
      )

    cases = [
      [terminal([bad_search])],
      [terminal([hd(output()), bad_citation])],
      [terminal([bad_citation])],
      [frame("response.output_item.done", 0, hd(output())), terminal([])],
      [
        frame("response.output_item.done", 0, hd(output())),
        terminal([put_in(hd(output()), ["action", "query"], "changed")])
      ],
      [
        %{"type" => "response.web_search_call.searching", "output_index" => "bad"},
        terminal(output())
      ],
      [
        %{
          "type" => "response.web_search_call.searching",
          "output_index" => 7,
          "item_id" => "unknown"
        },
        terminal(output())
      ],
      [terminal([Map.put(hd(output()), "status", "in_progress")])],
      [terminal([hd(output()), hd(output())])]
    ]

    for frames <- cases do
      with_server(frames, fn base_url, _capture ->
        events = stream(base_url)

        assert %{error: %{kind: :malformed_stream}} =
                 Enum.find(events, &(&1.type == :response_failed))

        refute Enum.any?(events, &(&1.type == :response_completed))
      end)
    end
  end

  test "unsolicited hosted output and conflicting terminal text fail explicitly" do
    with_server([terminal(output())], fn base_url, _capture ->
      events = stream(base_url, tools: [], options: [])
      assert Enum.any?(events, &(&1.type == :response_failed))
    end)

    with_server(
      [%{"type" => "response.output_text.delta", "delta" => "different"}, terminal(output())],
      fn base_url, _capture ->
        assert Enum.any?(stream(base_url), &(&1.type == :response_failed))
      end
    )
  end

  test "replay after JSON persistence restores native items and rejects origin or canonical tampering" do
    with_server([terminal(output())], fn base_url, _capture ->
      message =
        stream(base_url) |> Enum.find(&(&1.type == :response_completed)) |> Map.fetch!(:message)

      metadata = message.metadata |> Jason.encode!() |> Jason.decode!()
      message = %{message | metadata: metadata}
      prepared = Hosted.prepare!(@model, %{messages: [message], tools: []}, [], base_url)
      assert Hosted.replay_items!(message, prepared) == output()

      for {model, endpoint, candidate} <- [
            {%{@model | id: "other"}, base_url, message},
            {%{@model | provider: "other"}, base_url, message},
            {@model, base_url <> "/other", message},
            {@model, base_url, %{message | content: [%{type: :text, text: "edited"}]}},
            {@model, base_url, %{message | metadata: %{"openai_responses_hosted" => %{}}}}
          ] do
        error =
          assert_raise ProviderError, fn ->
            Hosted.prepare!(model, %{messages: [candidate], tools: []}, [], endpoint)
          end

        assert error.kind == :invalid_request
      end
    end)
  end

  test "replay is sent as native input without new hosted execution declarations" do
    with_server([terminal(output())], fn base_url, capture ->
      message =
        stream(base_url) |> Enum.find(&(&1.type == :response_completed)) |> Map.fetch!(:message)

      stream(base_url, tools: [], options: [], messages: [message])
      body = Agent.get(capture, & &1)
      assert body["input"] == output()
      assert body["tools"] == []
    end)
  end

  test "endpoint provenance never retains userinfo, query or fragment secrets" do
    prepared =
      Hosted.prepare!(
        @model,
        %{messages: [], tools: []},
        [],
        "https://user:secret@EXAMPLE.com:443/v1/?token=secret#secret"
      )

    same = Hosted.prepare!(@model, %{messages: [], tools: []}, [], "https://example.com/v1")
    refute prepared.origin == same.origin
    refute inspect(prepared) =~ "secret"
    assert byte_size(prepared.origin["endpoint_sha256"]) == 64
  end

  test "cached, indexed and live declarations preserve the explicitly selected policy" do
    for {mode, access} <- [
          cached: %{external_web_access: false},
          indexed: %{external_web_access: true, indexed_web_access: true},
          live: %{external_web_access: true}
        ] do
      declaration = Map.merge(%{type: "web_search", search_context_size: "high"}, access)
      config = %{supported: true, enabled: true, mode: mode, search_context_size: "high"}

      prepared =
        Hosted.prepare!(
          @model,
          %{messages: [], tools: [declaration]},
          [hosted_web_search: config],
          "https://example.com/v1"
        )

      assert prepared.hosted_tools == [declaration]
      assert prepared.local_tools == []
    end
  end

  test "hosted optional identities and all pinned action variants remain native" do
    actions = [
      %{"type" => "search", "queries" => ["one", "two"]},
      %{"type" => "open_page", "url" => "https://example.com"},
      %{"type" => "find_in_page", "url" => "https://example.com", "pattern" => "one"},
      nil
    ]

    for action <- actions do
      item = %{"type" => "web_search_call", "action" => action}

      with_server([terminal([item])], fn base_url, _capture ->
        events = stream(base_url)
        assert %{message: %{content: []}} = Enum.find(events, &(&1.type == :response_completed))
        refute Enum.any?(events, &(&1.type == :response_failed))
      end)
    end
  end

  test "hosted aggregate guard rejects individually valid incremental SSE frames" do
    calls =
      for index <- 0..31 do
        item =
          hd(output())
          |> Map.put("id", "ws#{index}")
          |> Map.put("action", %{"type" => "search", "query" => String.duplicate("q", 40_000)})

        frame("response.output_item.done", index, item)
      end

    prepared =
      Hosted.prepare!(
        @model,
        %{messages: [], tools: [@declaration]},
        [hosted_web_search: @enabled],
        "https://example.com/v1"
      )

    message = %{role: :assistant, content: [], response_id: nil}

    error =
      assert_raise ProviderError, fn ->
        Enum.reduce(calls, {Backplane.AiProtocol.SSE.new(), Hosted.new(prepared)}, fn frame,
                                                                                      {framer,
                                                                                       state} ->
          # HTTP transports may coalesce records and hit their own buffer limit.
          # Incremental framing isolates the additional cross-record host bound.
          bytes = "data: " <> Jason.encode!(frame) <> "\n\n"
          assert {:ok, framer, [%{data: data}]} = Backplane.AiProtocol.SSE.feed(framer, bytes)
          {_, _, state} = Hosted.observe(state, Jason.decode!(data), message)
          {framer, state}
        end)
      end

    assert error.kind == :malformed_stream
    assert error.message == "hosted_output_limit"
  end

  defp output do
    [
      %{
        "type" => "web_search_call",
        "id" => "ws1",
        "status" => "completed",
        "action" => %{"type" => "search", "query" => "example"}
      },
      %{
        "type" => "message",
        "id" => "msg1",
        "role" => "assistant",
        "status" => "completed",
        "content" => [
          %{
            "type" => "output_text",
            "text" => "Found it",
            "annotations" => [
              %{
                "type" => "url_citation",
                "start_index" => 0,
                "end_index" => 5,
                "url" => "https://example.com/source",
                "title" => "Source"
              }
            ]
          }
        ]
      }
    ]
  end

  defp terminal(output),
    do: %{
      "type" => "response.completed",
      "response" => %{"id" => "resp1", "status" => "completed", "output" => output}
    }

  defp frame(type, index, item), do: %{"type" => type, "output_index" => index, "item" => item}

  defp stream(base_url, opts \\ []) do
    params = %{
      model: @model,
      context: %{
        messages: Keyword.get(opts, :messages, []),
        tools: Keyword.get(opts, :tools, [@declaration])
      },
      options:
        [api_key: "fixture", base_url: base_url, receive_timeout: 2_000] ++
          Keyword.get(opts, :options, hosted_web_search: @enabled)
    }

    Provider.stream(OpenAIResponses, ProviderRequest.from_legacy(params)) |> Enum.to_list()
  end

  defp assert_preflight_error(provider, tools, options, messages \\ []) do
    error =
      assert_raise ProviderError, fn ->
        provider.stream(%{
          model: @model,
          context: %{messages: messages, tools: tools},
          options: [base_url: "http://127.0.0.1:1", api_key: "fixture"] ++ options
        })
      end

    assert error.kind == :invalid_request
    refute error.retryable
  end

  defp with_server(frames, fun) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listener)
    {:ok, capture} = Agent.start_link(fn -> nil end)
    body = Enum.map_join(frames, fn event -> "data: " <> Jason.encode!(event) <> "\n\n" end)
    task = Task.async(fn -> serve(listener, capture, body) end)

    try do
      fun.("http://127.0.0.1:#{port}", capture)
    after
      Task.shutdown(task, :brutal_kill)
      :gen_tcp.close(listener)
      Agent.stop(capture)
    end
  end

  defp serve(listener, capture, body) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        request = receive_request(socket, "")
        [_, request_body] = String.split(request, "\r\n\r\n", parts: 2)
        Agent.update(capture, fn _ -> Jason.decode!(request_body) end)

        :ok =
          :gen_tcp.send(socket, [
            "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\n",
            "content-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n",
            body
          ])

        :gen_tcp.close(socket)
        serve(listener, capture, body)

      {:error, :closed} ->
        :ok
    end
  end

  defp receive_request(socket, acc) do
    {:ok, bytes} = :gen_tcp.recv(socket, 0, 2_000)
    acc = acc <> bytes

    case String.split(acc, "\r\n\r\n", parts: 2) do
      [headers, body] ->
        [_, length] = Regex.run(~r/content-length: (\d+)/i, headers)

        if byte_size(body) >= String.to_integer(length),
          do: acc,
          else: receive_request(socket, acc)

      _ ->
        receive_request(socket, acc)
    end
  end
end
