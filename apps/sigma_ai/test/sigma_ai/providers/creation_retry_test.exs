defmodule Sigma.Ai.Providers.CreationRetryTest do
  use ExUnit.Case, async: true

  alias Sigma.Ai.{Provider, ProviderEvent, ProviderRequest}
  alias Sigma.Ai.Providers.{Anthropic, OpenAIResponses}

  for provider <- [Anthropic, OpenAIResponses] do
    @provider provider

    test "#{provider} retries ambiguous POST failures and 5xx, with four request retries" do
      for failure <- [:drop, 503] do
        with_server(
          fn socket, attempt ->
            if attempt < 5, do: fail(socket, failure), else: complete(socket, @provider)
          end,
          fn url ->
            events = collect(@provider, url)
            assert Enum.any?(events, &match?(%ProviderEvent{type: :response_completed}, &1))
          end,
          5
        )
      end
    end

    test "#{provider} leaves 429 and explicitly disabled retries terminal" do
      for {failure, options} <- [{429, []}, {503, [retry: false]}, {:drop, [retry: false]}] do
        with_server(
          fn socket, _ -> fail(socket, failure) end,
          fn url ->
            assert %ProviderEvent{type: :response_failed, retry: nil} =
                     List.last(collect(@provider, url, options))
          end,
          1
        )
      end
    end

    test "#{provider} reports exhausted request retries without concealing earlier submissions" do
      with_server(
        fn socket, _ -> fail(socket, 503) end,
        fn url ->
          assert %ProviderEvent{type: :response_failed, retry: %{class: :stream}, error: error} =
                   List.last(collect(@provider, url))

          assert Enum.map(error.raw.submission_attempts, & &1.attempt) == [1, 2, 3, 4, 5]
          assert Enum.all?(error.raw.submission_attempts, &(&1.status == 503))
        end,
        5
      )
    end

    test "#{provider} retains partial output and typed interrupted-stream classification" do
      with_server(
        fn socket, _ -> respond(socket, 200, partial(@provider)) end,
        fn url ->
          events = collect(@provider, url)

          assert %ProviderEvent{type: :response_failed, retry: %{class: :stream}} =
                   List.last(events)

          failure = List.last(events)
          assert Enum.any?(failure.message.content, &match?(%{type: :text, text: "partial"}, &1))
          assert failure.response_id in ["resp_partial", "msg_partial"]
          assert failure.usage.input_tokens == 3
          refute Enum.any?(events, &match?(%ProviderEvent{type: :response_completed}, &1))
        end,
        1
      )
    end
  end

  test "Retry-After delays a retry and cancellation interrupts the delay" do
    for {cancel?, date?} <- [{false, false}, {true, false}, {false, true}] do
      owner = self()
      ref = make_ref()

      with_server(
        fn socket, attempt ->
          if attempt == 1 do
            send(owner, :retrying)

            advice =
              if date?,
                do:
                  Calendar.strftime(
                    DateTime.add(DateTime.utc_now(), 2),
                    "%a, %d %b %Y %H:%M:%S GMT"
                  ),
                else: "1"

            respond(socket, 503, "unavailable", "retry-after: #{advice}\r\n")
          else
            complete(socket, OpenAIResponses)
          end
        end,
        fn url ->
          started = System.monotonic_time(:millisecond)
          task = Task.async(fn -> collect(OpenAIResponses, url, cancellation_ref: ref) end)
          assert_receive :retrying, 1_000
          if cancel?, do: send(task.pid, {:cancel, ref})
          events = Task.await(task, 5_000)
          elapsed = System.monotonic_time(:millisecond) - started

          if cancel? do
            assert %ProviderEvent{type: :response_failed, error: %{kind: :cancelled}} =
                     List.last(events)

            assert elapsed < 900
          else
            assert Enum.any?(events, &match?(%ProviderEvent{type: :response_completed}, &1))
            assert elapsed >= 900
          end
        end,
        if(cancel?, do: 1, else: 2)
      )
    end
  end

  test "failed Responses terminal retains its reported usage and identity without retry" do
    body =
      sse(%{
        "type" => "response.failed",
        "response" => %{
          "id" => "resp_failed",
          "error" => %{"message" => "failed"},
          "usage" => %{"input_tokens" => 3, "output_tokens" => 2}
        }
      })

    with_server(
      fn socket, _ -> respond(socket, 200, body) end,
      fn url ->
        failure = List.last(collect(OpenAIResponses, url))
        assert failure.type == :response_failed
        assert failure.retry == nil
        assert failure.response_id == "resp_failed"
        assert failure.usage.input_tokens == 3
        assert failure.usage.output_tokens == 2
      end,
      1
    )
  end

  defp collect(provider, url, options \\ []) do
    request =
      ProviderRequest.new(%{
        model: %{id: "test", api: "openai-responses", provider: "test"},
        context: %{messages: [%{role: :user, content: "hello"}], tools: []},
        options: options ++ [api_key: "test", base_url: url, receive_timeout: 500, retry_delay: 0]
      })

    provider |> Provider.stream(request) |> Enum.to_list()
  end

  defp fail(_socket, :drop), do: :ok
  defp fail(socket, status), do: respond(socket, status, ~s({"error":{"message":"unavailable"}}))

  defp complete(socket, Anthropic),
    do: respond(socket, 200, sse(%{"type" => "message_stop"}))

  defp complete(socket, OpenAIResponses),
    do:
      respond(
        socket,
        200,
        sse(%{"type" => "response.completed", "response" => %{"status" => "completed"}})
      )

  defp partial(Anthropic) do
    sse(%{
      "type" => "message_start",
      "message" => %{
        "id" => "msg_partial",
        "usage" => %{
          "input_tokens" => 3,
          "output_tokens" => 0,
          "cache_read_input_tokens" => 0,
          "cache_creation_input_tokens" => 0
        }
      }
    }) <>
      sse(%{
        "type" => "content_block_start",
        "index" => 0,
        "content_block" => %{"type" => "text", "text" => ""}
      }) <>
      sse(%{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{"type" => "text_delta", "text" => "partial"}
      })
  end

  defp partial(OpenAIResponses) do
    sse(%{
      "type" => "response.created",
      "response" => %{"id" => "resp_partial", "usage" => %{"input_tokens" => 3}}
    }) <>
      sse(%{"type" => "response.output_text.delta", "delta" => "partial"})
  end

  defp sse(event), do: "data: " <> Formata.JSON.encode!(event) <> "\n\n"

  defp respond(socket, status, body, headers \\ "") do
    :gen_tcp.send(socket, [
      "HTTP/1.1 #{status} Test\r\ncontent-type: text/event-stream\r\n",
      headers,
      "content-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n",
      body
    ])
  end

  defp with_server(reply, fun, expected) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listener)
    task = Task.async(fn -> serve(listener, reply, 0, expected) end)

    try do
      fun.("http://127.0.0.1:#{port}")
      assert Task.await(task, 5_000) == expected
    after
      Task.shutdown(task, :brutal_kill)
      :gen_tcp.close(listener)
    end
  end

  defp serve(listener, reply, count, expected) do
    # Retry-After dates can legitimately delay the next POST for two seconds.
    # Once expected requests arrive, keep listening briefly to detect replays.
    case :gen_tcp.accept(listener, if(count < expected, do: 5_000, else: 300)) do
      {:ok, socket} ->
        read_request(socket, "")
        reply.(socket, count + 1)
        :gen_tcp.close(socket)
        serve(listener, reply, count + 1, expected)

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
