defmodule Sigma.Ai.Providers.OpenAIResponsesImageFunctionalTest do
  use ExUnit.Case, async: true

  alias Sigma.Ai.Providers.OpenAIResponses
  alias Sigma.Ai.Providers.OpenAIResponses.Hosted

  @moduletag :responses_image_functional
  @png "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jR9sAAAAASUVORK5CYII="
  @uri "data:image/png;base64," <> @png
  @model %{id: "image-model", provider: "image-fixture", api: "openai-responses"}

  test "Responses sends the requested reasoning effort and preserves the provider default" do
    messages = [%{role: :user, content: "Review the changes"}]

    with_server(fn url, capture ->
      assert_finished!(url, messages, reasoning_effort: "high")
      assert Agent.get(capture, & &1["reasoning"]) == %{"effort" => "high"}

      assert_finished!(url, messages)
      refute Agent.get(capture, &Map.has_key?(&1, "reasoning"))
    end)
  end

  test "large inline user images reach Responses as image data" do
    encoded = Base.encode64(:binary.copy(<<0>>, 800_000))
    image = %{type: :image, mime_type: "image/png", data: encoded}
    messages = [%{role: :user, content: [%{type: :text, text: "Look"}, image]}]

    with_server(fn url, capture ->
      assert_finished!(url, messages)

      assert [
               %{
                 "content" => [
                   %{"text" => "Look"},
                   %{"type" => "input_image", "image_url" => uri}
                 ]
               }
             ] =
               Agent.get(capture, & &1["input"])

      assert uri == "data:image/png;base64," <> encoded
    end)
  end

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

  test "native Codex projection preserves local schemas and canonical streamed calls with hosted replay" do
    schema = %{
      "type" => "object",
      "properties" => %{
        "query" => %{"type" => "string"},
        "limit" => %{"type" => "integer", "minimum" => 1}
      },
      "required" => ["query"],
      "additionalProperties" => false
    }

    tools = [
      %{name: "collaboration::get_channels", parameters: %{"type" => "object"}},
      %{name: "history::search_contents", parameters: schema},
      %{name: "notes::list_files_by_prefix", parameters: %{"type" => "object"}},
      %{type: "web_search", external_web_access: false}
    ]

    item = %{
      "type" => "function_call",
      "id" => "board-item",
      "call_id" => "board-call",
      "namespace" => "agent_message_board",
      "name" => "get_channels",
      "arguments" => "{}",
      "status" => "completed"
    }

    reasoning = %{
      "type" => "reasoning",
      "id" => "retained-reasoning",
      "summary" => [],
      "encrypted_content" => "opaque-fixture"
    }

    response = %{
      "type" => "response.completed",
      "response" => %{
        "id" => "board-response",
        "status" => "completed",
        "output" => [reasoning, item]
      }
    }

    with_server(
      fn url, capture ->
        options = [
          api_key: "projection-fixture",
          base_url: url,
          receive_timeout: 2_000,
          hosted_web_search: %{supported: true, enabled: true, mode: :cached}
        ]

        events =
          OpenAIResponses.stream(%{
            model: @model,
            context: %{
              catalog_revision: "native-fixture",
              native_tools: true,
              messages: [
                %{
                  role: :assistant,
                  content: [
                    %{
                      type: :tool_call,
                      id: "previous-search",
                      name: "history::search_contents",
                      arguments: %{"query" => "query-fixture"}
                    }
                  ]
                },
                %{role: :tool_result, tool_call_id: "previous-search", content: "[]"}
              ],
              tools: tools
            },
            options: options
          })
          |> Enum.to_list()

        refute Enum.any?(events, &match?({:provider_error, _}, &1))
        assert {:done, :tool_use, message} = List.last(events)
        assert [%{name: "collaboration::get_channels"}] = message.content
        wire = Agent.get(capture, & &1)
        assert Enum.any?(wire["tools"], &(&1["name"] == "agent_message_board"))
        refute Map.has_key?(wire, "client_metadata")
        assert Enum.any?(wire["tools"], &(&1["name"] == "local_notes"))

        assert [%{"namespace" => "local_history"}, %{"type" => "function_call_output"}] =
                 wire["input"]

        history = Enum.find(wire["tools"], &(&1["name"] == "local_history"))
        [history_tool] = history["tools"]

        assert history_tool["parameters"] == schema

        envelope = message.metadata["openai_responses_hosted"]
        assert Enum.map(envelope["items"], & &1["item"]) == [reasoning, item]
        assert envelope["codex_history_notes"] == "local"

        message = %{
          message
          | metadata: Formata.JSON.decode!(Formata.JSON.encode!(message.metadata))
        }

        assert Hosted.project_metadata(message) == {:ok, envelope}

        replay =
          OpenAIResponses.stream(%{
            model: @model,
            context: %{
              catalog_revision: "next-native-fixture",
              native_tools: true,
              messages: [
                message,
                %{role: :tool_result, tool_call_id: "board-call", content: "[]"}
              ],
              tools: []
            },
            options: options
          })
          |> Enum.to_list()

        refute Enum.any?(replay, &match?({:provider_error, _}, &1))

        assert [^reasoning, ^item, %{"type" => "function_call_output"}] =
                 Agent.get(capture, & &1["input"])
      end,
      [response]
    )
  end

  test "ordinary Runtime tools retain their provider identity despite a catalog revision" do
    with_server(fn url, capture ->
      events =
        OpenAIResponses.stream(%{
          model: @model,
          context: %{
            catalog_revision: "ordinary-runtime-fixture",
            native_tools: false,
            messages: [],
            tools: [
              %{name: "collaboration::get_channels", parameters: %{"type" => "object"}},
              %{
                name: "history::search_contents",
                parameters: %{
                  "type" => "object",
                  "properties" => %{"query" => %{"type" => "string"}}
                }
              }
            ]
          },
          options: [api_key: "ordinary-fixture", base_url: url, receive_timeout: 2_000]
        })
        |> Enum.to_list()

      assert Enum.any?(events, &match?({:done, :stop, _}, &1))

      assert [%{"name" => "collaboration"}, %{"name" => "history", "tools" => [search]}] =
               Agent.get(capture, & &1["tools"])

      assert search["parameters"] == %{
               "type" => "object",
               "properties" => %{"query" => %{"type" => "string"}}
             }

      refute Map.has_key?(Agent.get(capture, & &1), "client_metadata")
    end)
  end

  defp assert_finished!(url, messages, options \\ []) do
    events =
      OpenAIResponses.stream(%{
        model: @model,
        context: %{messages: messages, tools: []},
        options: [api_key: "image-fixture", base_url: url, receive_timeout: 2_000] ++ options
      })
      |> Enum.to_list()

    assert Enum.any?(events, &match?({:done, :stop, _}, &1))
    refute Enum.any?(events, &match?({:provider_error, _}, &1))
  end

  defp with_server(fun, events \\ []) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listener)
    {:ok, capture} = Agent.start_link(fn -> nil end)
    task = Task.async(fn -> serve(listener, capture, events) end)

    try do
      fun.("http://127.0.0.1:#{port}", capture)
    after
      :gen_tcp.close(listener)
      Task.shutdown(task, :brutal_kill)
      Agent.stop(capture)
    end
  end

  defp serve(listener, capture, events) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        try do
          request = receive_request(socket, "")
          [_, body] = String.split(request, "\r\n\r\n", parts: 2)
          Agent.update(capture, fn _ -> Formata.JSON.decode!(body) end)

          terminal = %{
            "type" => "response.completed",
            "response" => %{"id" => "image-response", "status" => "completed", "output" => []}
          }

          frames = if events == [], do: [terminal], else: events
          response = Enum.map_join(frames, &("data: " <> Formata.JSON.encode!(&1) <> "\n\n"))

          :ok =
            :gen_tcp.send(socket, [
              "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\n",
              "content-length: #{byte_size(response)}\r\nconnection: close\r\n\r\n",
              response
            ])
        after
          :gen_tcp.close(socket)
        end

        serve(listener, capture, events)

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
