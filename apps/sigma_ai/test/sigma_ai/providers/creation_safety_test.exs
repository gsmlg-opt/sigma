defmodule Sigma.Ai.Providers.CreationSafetyTest do
  use ExUnit.Case, async: true

  alias Sigma.Ai.{CreationRequest, ProviderError}
  alias Sigma.Ai.Providers.{Anthropic, OpenAI, OpenAIResponses}

  test "only proven pre-submission failures can be retried, regardless of caller policy" do
    for option <- [:transient, fn _, _ -> true end] do
      policy = CreationRequest.retry_policy(retry: option)

      for reason <- [:econnrefused, :nxdomain] do
        assert policy.(nil, %Sigma.Ai.HTTP.TransportError{reason: reason})
        assert CreationRequest.submission_error(%{reason: reason}).retryable
      end

      for reason <- [:timeout, :closed, :econnreset] do
        refute policy.(nil, %Sigma.Ai.HTTP.TransportError{reason: reason})
      end

      for status <- [408, 429, 500, 502, 503, 504] do
        refute policy.(nil, %{status: status})
      end
    end

    assert CreationRequest.retry_policy(retry: false) == false
  end

  for provider <- [Anthropic, OpenAI, OpenAIResponses] do
    @provider provider
    test "#{provider} does not resubmit after the upstream reads the POST and drops headers" do
      with_server(fn _socket -> :ok end, fn url ->
        error = assert_raise ProviderError, fn -> collect(@provider, url) end
        assert error.kind == :submission_uncertain
        refute error.retryable
      end)
    end

    test "#{provider} does not resubmit when accepted request headers time out" do
      with_server(fn _socket -> Process.sleep(250) end, fn url ->
        error = assert_raise ProviderError, fn -> collect(@provider, url) end
        assert error.kind == :submission_uncertain
        refute error.retryable
      end)
    end

    test "#{provider} preserves HTTP failures without replaying the creation POST" do
      for status <- [307, 408, 429, 503] do
        with_server(
          fn socket -> respond(socket, status, ~s({"error":{"message":"unavailable"}})) end,
          fn url ->
            error = assert_raise ProviderError, fn -> collect(@provider, url) end
            assert error.status == status
            refute error.retryable
          end
        )
      end
    end
  end

  test "Responses rejects partial text, reasoning, item completion, and bare DONE as completion" do
    for event <- [
          %{"type" => "response.output_text.delta", "delta" => "partial"},
          %{"type" => "response.reasoning_summary_text.delta", "delta" => "thinking"},
          %{"type" => "response.output_text.done", "text" => "one item"}
        ],
        suffix <- ["", "data: [DONE]\n\n", "data: {broken}\n\n", "data: {broken"] do
      body = created() <> sse(event) <> suffix

      with_server(fn socket -> respond(socket, 200, body) end, fn url ->
        events = collect(OpenAIResponses, url)
        refute Enum.any?(events, &match?({:done, _, _}, &1))

        assert [{:provider_error, %ProviderError{kind: :malformed_stream, retryable: false}}] =
                 Enum.filter(events, &match?({:provider_error, _}, &1))
      end)
    end
  end

  test "Responses transport interruption retains response ID without creating another response" do
    body = created() <> sse(%{"type" => "response.output_text.delta", "delta" => "partial"})

    with_server(fn socket -> respond(socket, 200, body, byte_size(body) + 100) end, fn url ->
      error = assert_raise ProviderError, fn -> collect(OpenAIResponses, url) end
      assert error.kind == :stream_interrupted
      assert error.raw.response_id == "resp_existing"
      refute error.retryable
    end)
  end

  test "Responses stops a batch at malformed JSON, before subsequent completion or tool events" do
    body =
      created() <>
        "data: {broken}\n\n" <>
        sse(%{"type" => "response.completed", "response" => %{"status" => "completed"}})

    with_server(fn socket -> respond(socket, 200, body) end, fn url ->
      events = collect(OpenAIResponses, url)
      refute Enum.any?(events, &match?({:done, _, _}, &1))
      assert [{:provider_error, _}] = events
    end)
  end

  test "Responses emits exactly one completion for duplicate terminal frames" do
    terminal = sse(%{"type" => "response.completed", "response" => %{"status" => "completed"}})

    with_server(
      fn socket ->
        respond(socket, 200, created() <> terminal <> terminal <> "data: [DONE]\n\n")
      end,
      fn url ->
        assert [{:done, :stop, _}] = collect(OpenAIResponses, url)
      end
    )
  end

  test "Responses failure, cancellation and nonterminal done status cannot complete" do
    for event <- [
          %{"type" => "response.failed", "response" => %{"error" => %{"message" => "failed"}}},
          %{"type" => "response.cancelled"},
          %{"type" => "response.done", "response" => %{"status" => "in_progress"}},
          %{"type" => "response.done", "response" => %{"status" => "failed"}}
        ] do
      body = created() <> sse(event)

      with_server(fn socket -> respond(socket, 200, body) end, fn url ->
        assert [{:provider_error, %ProviderError{retryable: false}}] =
                 collect(OpenAIResponses, url)
      end)
    end
  end

  test "native Codec and Hosted streams cannot complete through EOF or bare DONE" do
    modes = [
      {%{catalog_revision: 0}, []},
      {%{tools: [%{type: "web_search", external_web_access: false}]},
       [hosted_web_search: %{supported: true, enabled: true, mode: :cached}]}
    ]

    for {context, options} <- modes,
        suffix <- ["", "data: [DONE]\n\n", "data: {broken}\n\n", "data: {broken"] do
      body =
        created() <>
          sse(%{"type" => "response.output_text.delta", "delta" => "partial"}) <> suffix

      with_server(fn socket -> respond(socket, 200, body) end, fn url ->
        events = collect(OpenAIResponses, url, context, options)
        refute Enum.any?(events, &match?({:done, _, _}, &1))

        assert [{:provider_error, %ProviderError{retryable: false}}] =
                 Enum.filter(events, &match?({:provider_error, _}, &1))
      end)
    end
  end

  test "completed namespaced custom item still requires response completion" do
    item = %{
      "type" => "custom_tool_call",
      "id" => "item1",
      "call_id" => "call1",
      "namespace" => "functions",
      "name" => "apply_patch",
      "input" => "raw patch\n",
      "status" => "completed"
    }

    body =
      created() <>
        sse(%{"type" => "response.output_item.added", "item" => Map.put(item, "input", "")}) <>
        sse(%{"type" => "response.output_item.done", "item" => item})

    with_server(fn socket -> respond(socket, 200, body) end, fn url ->
      events = collect(OpenAIResponses, url, %{catalog_revision: 0})

      assert {:toolcall_end, _, %{input_kind: :custom, name: "functions::apply_patch"}, _} =
               Enum.find(events, &match?({:toolcall_end, _, _, _}, &1))

      refute Enum.any?(events, &match?({:done, _, _}, &1))
      assert {:provider_error, %ProviderError{kind: :malformed_stream}} = List.last(events)
    end)
  end

  defp collect(provider, url, context \\ %{}, options \\ []) do
    provider.stream(%{
      model: %{id: "test", api: "openai-responses", provider: "test"},
      context: Map.merge(%{messages: [%{role: :user, content: "hello"}], tools: []}, context),
      options:
        options ++
          [
            api_key: "test",
            base_url: url,
            receive_timeout: 100,
            retry: :transient,
            retry_delay: fn _ -> 0 end
          ]
    })
    |> Enum.to_list()
  end

  defp created,
    do:
      sse(%{
        "type" => "response.created",
        "sequence_number" => 0,
        "response" => %{"id" => "resp_existing"}
      })

  defp sse(event), do: "data: " <> Jason.encode!(event) <> "\n\n"

  defp respond(socket, status, body, size \\ nil) do
    :gen_tcp.send(socket, [
      "HTTP/1.1 #{status} Test\r\nlocation: /redirected\r\ncontent-type: text/event-stream\r\ncontent-length: #{size || byte_size(body)}\r\nconnection: close\r\n\r\n",
      body
    ])
  end

  # Read the entire POST before simulating failure. Keep listening afterward so
  # a replay is observable, rather than hidden by a refused second connection.
  defp with_server(reply, fun) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listener)
    task = Task.async(fn -> serve(listener, reply, 0) end)

    try do
      fun.("http://127.0.0.1:#{port}")
      assert Task.await(task, 5_000) == 1
    after
      Task.shutdown(task, :brutal_kill)
      :gen_tcp.close(listener)
    end
  end

  defp serve(listener, reply, count) do
    case :gen_tcp.accept(listener, 300) do
      {:ok, socket} ->
        read_request(socket, "")
        reply.(socket)
        :gen_tcp.close(socket)
        serve(listener, reply, count + 1)

      {:error, :timeout} ->
        count
    end
  end

  defp read_request(socket, buffer) do
    case String.split(buffer, "\r\n\r\n", parts: 2) do
      [headers, body] ->
        [_, size] = Regex.run(~r/content-length: (\d+)/i, headers)
        if byte_size(body) < String.to_integer(size), do: read_more(socket, buffer)

      _ ->
        read_more(socket, buffer)
    end
  end

  defp read_more(socket, buffer) do
    {:ok, bytes} = :gen_tcp.recv(socket, 0, 1_000)
    read_request(socket, buffer <> bytes)
  end
end
