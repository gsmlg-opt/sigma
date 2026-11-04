defmodule Sigma.Ai.Providers.OpenAIResponsesImageFunctionalTest do
  use ExUnit.Case, async: true

  alias Sigma.Ai.Providers.OpenAIResponses

  @moduletag :responses_image_functional
  @png "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jR9sAAAAASUVORK5CYII="
  @uri "data:image/png;base64," <> @png
  @model %{id: "image-model", provider: "image-fixture", api: "openai-responses"}

  test "actual HTTP preserves ordered function and custom image outputs through the public codec" do
    content =
      [%{type: :text, text: "  image caption 中文\r\n"}] ++
        Enum.map(~w(auto low high original), fn detail ->
          %{
            type: :image,
            data: if(detail in ~w(low original), do: @uri, else: @png),
            mime_type: "image/png",
            detail: detail
          }
        end)

    expected =
      [%{"type" => "input_text", "text" => "  image caption 中文\r\n"}] ++
        Enum.map(~w(auto low high original), fn detail ->
          %{"type" => "input_image", "image_url" => @uri, "detail" => detail}
        end)

    for kind <- [:function, :custom] do
      call = %{
        type: :tool_call,
        id: "image-call",
        name: "image_fixture",
        input_kind: kind,
        arguments: if(kind == :custom, do: "read image\n", else: %{})
      }

      messages = [
        %{role: :user, content: "Read the image"},
        %{role: :assistant, content: [call]},
        %{role: :tool_result, tool_call_id: call.id, content: content}
      ]

      with_server(fn url, capture ->
        assert_finished!(url, messages)
        body = Agent.get(capture, & &1)
        type = if kind == :custom, do: "custom_tool_call_output", else: "function_call_output"

        assert %{"type" => ^type, "call_id" => "image-call", "output" => ^expected} =
                 List.last(body["input"])
      end)
    end
  end

  test "existing user image input preserves a complete data URI and explicit detail" do
    messages = [
      %{
        role: :user,
        content: [
          %{type: :text, text: "Describe both"},
          %{type: :image, data: @png, mime_type: "image/png"},
          %{type: :image, data: @uri, mime_type: "image/png", detail: "low"}
        ]
      }
    ]

    with_server(fn url, capture ->
      assert_finished!(url, messages)

      assert [%{"role" => "user", "content" => blocks}] = Agent.get(capture, & &1["input"])

      assert blocks == [
               %{"type" => "input_text", "text" => "Describe both"},
               %{"type" => "input_image", "image_url" => @uri},
               %{"type" => "input_image", "image_url" => @uri, "detail" => "low"}
             ]
    end)
  end

  defp assert_finished!(url, messages) do
    events =
      OpenAIResponses.stream(%{
        model: @model,
        context: %{messages: messages, tools: []},
        options: [api_key: "image-fixture", base_url: url, receive_timeout: 2_000]
      })
      |> Enum.to_list()

    assert Enum.any?(events, &match?({:done, :stop, _}, &1))
    refute Enum.any?(events, &match?({:provider_error, _}, &1))
  end

  defp with_server(fun) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listener)
    {:ok, capture} = Agent.start_link(fn -> nil end)
    task = Task.async(fn -> serve(listener, capture) end)

    try do
      fun.("http://127.0.0.1:#{port}", capture)
    after
      :gen_tcp.close(listener)
      Task.shutdown(task, :brutal_kill)
      Agent.stop(capture)
    end
  end

  defp serve(listener, capture) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        try do
          request = receive_request(socket, "")
          [_, body] = String.split(request, "\r\n\r\n", parts: 2)
          Agent.update(capture, fn _ -> Jason.decode!(body) end)

          terminal = %{
            "type" => "response.completed",
            "response" => %{"id" => "image-response", "status" => "completed", "output" => []}
          }

          response = "data: " <> Jason.encode!(terminal) <> "\n\n"

          :ok =
            :gen_tcp.send(socket, [
              "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\n",
              "content-length: #{byte_size(response)}\r\nconnection: close\r\n\r\n",
              response
            ])
        after
          :gen_tcp.close(socket)
        end

        serve(listener, capture)

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
