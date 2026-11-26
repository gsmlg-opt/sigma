defmodule Sigma.Ai.Providers.ActivityTransportTest do
  use ExUnit.Case, async: true

  alias Sigma.Ai.{Provider, ProviderEvent, ProviderRequest}
  alias Sigma.Ai.Providers.{Anthropic, OpenAIResponses}

  for provider <- [Anthropic, OpenAIResponses] do
    @provider provider

    test "#{provider} forwards SSE comments and incomplete frames as activity" do
      for body <- [": keepalive\n\n", "data: {\"type\":"] do
        with_server(body, fn url ->
          request = request(url)

          assert [%ProviderEvent{type: :response_activity} = event] =
                   @provider |> Provider.stream(request) |> Enum.take(1)

          assert event.delta == nil
          assert event.usage == nil
          assert event.message == nil

          # Activity must not claim output or affect time to first token.
          timed =
            request |> ProviderRequest.begin(0) |> ProviderRequest.mark_output(100, :keepalive)

          assert timed.first_output_ms == nil
          assert timed.ttft_ms == nil
        end)
      end
    end

    test "#{provider} does not forward HTTP error bodies as activity" do
      with_server(
        "unavailable",
        fn url ->
          events = @provider |> Provider.stream(request(url)) |> Enum.to_list()
          refute Enum.any?(events, &match?(%ProviderEvent{type: :response_activity}, &1))
          assert [%ProviderEvent{type: :response_failed}] = events
        end,
        400
      )
    end
  end

  defp request(url) do
    ProviderRequest.new(%{
      model: %{id: "test", api: "openai-responses", provider: "test"},
      context: %{messages: [%{role: :user, content: "hello"}], tools: []},
      options: [api_key: "test", base_url: url, receive_timeout: 1_000, retry: false]
    })
  end

  defp with_server(body, fun, status \\ 200) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listener)

    task =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 2_000)
        read_request(socket, "")

        :ok =
          :gen_tcp.send(socket, [
            "HTTP/1.1 #{status} Test\r\ncontent-type: text/event-stream\r\n",
            "content-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n",
            body
          ])

        :gen_tcp.close(socket)
      end)

    try do
      fun.("http://127.0.0.1:#{port}")
      Task.await(task, 5_000)
    after
      Task.shutdown(task, :brutal_kill)
      :gen_tcp.close(listener)
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
