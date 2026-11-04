defmodule Sigma.Ai.Providers.ResponsesRecoveryTest do
  use ExUnit.Case, async: true
  alias Sigma.Ai.{ProviderError, ResponsesRecovery}
  alias Sigma.Ai.Providers.OpenAIResponses

  @recovery %{capability: :openai_background_stream_v1, delay_ms: 0, max_attempts: 2}

  test "explicit capability and background creation are required before HTTP" do
    for opts <- [
          [responses_recovery: true],
          [responses_recovery: @recovery],
          [background: true, responses_recovery: %{capability: :unknown}]
        ] do
      assert_raise ProviderError, fn -> stream("http://127.0.0.1:1", %{}, opts) end
    end
  end

  test "cold ID/cursor import is rejected rather than silently creating a new response" do
    for opts <- [
          [response_id: "resp_old"],
          [starting_after: 2],
          [background: true, responses_recovery: @recovery, response_id: "resp_old"]
        ] do
      assert_raise ProviderError, fn -> stream("http://127.0.0.1:1", %{}, opts) end
    end
  end

  test "other adapters reject recovery rather than silently ignoring the option" do
    for provider <- [Sigma.Ai.Providers.OpenAI, Sigma.Ai.Providers.Anthropic] do
      assert_raise ProviderError, fn ->
        provider.stream(%{
          model: %{id: "test", api: "test", provider: "test"},
          context: %{messages: [], tools: []},
          options: recovery_options()
        })
      end
    end
  end

  test "terminal failure and cancellation do not trigger recovery" do
    for type <- ["response.failed", "response.cancelled"] do
      body =
        created() <>
          frame(%{
            "type" => type,
            "sequence_number" => 1,
            "response" => %{"id" => "resp_resume", "error" => %{"message" => "stopped"}}
          })

      with_server([{200, body}], fn url, requests ->
        events = stream(url, %{}, recovery_options()) |> Enum.to_list()
        assert {:provider_error, %ProviderError{retryable: false}} = List.last(events)
        assert length(Agent.get(requests, & &1)) == 1
      end)
    end
  end

  test "same ID GET resumes partial frames, skips keepalive and deduplicates before every reducer" do
    modes = [
      {%{}, []},
      {%{catalog_revision: 0}, []},
      {%{tools: [%{type: "web_search", external_web_access: false}]},
       [hosted_web_search: %{supported: true, enabled: true, mode: :cached}]}
    ]

    first =
      created() <>
        text(1, "hello") <>
        frame(%{"type" => "keepalive", "sequence_number" => 999}) <>
        "data: {\"type\":\"response.output_text.delta\",\"sequence_number\":2,\"delta\":\" cut"

    second = text(1, "hello") <> text(2, " world") <> completed(3, "hello world")

    for {context, opts} <- modes do
      with_server([{200, first}, {200, second}], fn url, requests ->
        events = stream(url, context, recovery_options() ++ opts) |> Enum.to_list()
        assert {:done, :stop, %{content: [%{text: "hello world"}]}} = List.last(events)
        assert ["hello", " world"] == for({:text_delta, _, delta, _} <- events, do: delta)
        [post, get] = Agent.get(requests, & &1)
        assert post.method == "POST"
        assert post.body["background"] == true
        assert post.body["store"] == false
        assert get.method == "GET"
        assert get.target == "/responses/resp_resume?stream=true&starting_after=1"
      end)
    end
  end

  test "native custom tool completion is not emitted twice across reconnection" do
    item = %{
      "type" => "custom_tool_call",
      "id" => "item1",
      "call_id" => "call1",
      "namespace" => "functions",
      "name" => "apply_patch",
      "input" => "patch\n",
      "status" => "completed"
    }

    added =
      frame(%{
        "type" => "response.output_item.added",
        "sequence_number" => 1,
        "item" => Map.put(item, "input", "")
      })

    done = frame(%{"type" => "response.output_item.done", "sequence_number" => 2, "item" => item})

    terminal =
      frame(%{
        "type" => "response.completed",
        "sequence_number" => 3,
        "response" => %{"id" => "resp_resume", "status" => "completed", "output" => [item]}
      })

    with_server([{200, created() <> added <> done}, {200, done <> terminal}], fn url, requests ->
      events = stream(url, %{catalog_revision: 0}, recovery_options()) |> Enum.to_list()

      assert [{:toolcall_end, _, %{name: "functions::apply_patch", arguments: "patch\n"}, _}] =
               Enum.filter(events, &match?({:toolcall_end, _, _, _}, &1))

      assert {:done, :tool_use, _} = List.last(events)
      assert length(Agent.get(requests, & &1)) == 2
    end)
  end

  test "transport disconnect after ID resumes from the last applied event" do
    with_server(
      [{200, created() <> text(1, "hello"), :truncated_http}, {200, completed(2, "hello")}],
      fn url, requests ->
        assert {:done, :stop, _} =
                 stream(url, %{}, recovery_options()) |> Enum.to_list() |> List.last()

        assert length(Agent.get(requests, & &1)) == 2
      end
    )
  end

  test "Hosted observations and native replay metadata survive a duplicate replay" do
    item = %{
      "type" => "web_search_call",
      "id" => "ws1",
      "status" => "completed",
      "action" => %{"type" => "search", "query" => "example"}
    }

    added =
      frame(%{
        "type" => "response.output_item.added",
        "sequence_number" => 1,
        "output_index" => 0,
        "item" => Map.put(item, "status", "in_progress")
      })

    done =
      frame(%{
        "type" => "response.output_item.done",
        "sequence_number" => 2,
        "output_index" => 0,
        "item" => item
      })

    terminal =
      frame(%{
        "type" => "response.completed",
        "sequence_number" => 3,
        "response" => %{"id" => "resp_resume", "status" => "completed", "output" => [item]}
      })

    context = %{tools: [%{type: "web_search", external_web_access: false}]}

    opts =
      recovery_options() ++ [hosted_web_search: %{supported: true, enabled: true, mode: :cached}]

    with_server([{200, created() <> added <> done}, {200, done <> terminal}], fn url, _ ->
      events = stream(url, context, opts) |> Enum.to_list()

      assert length(
               Enum.filter(
                 events,
                 &match?(%Sigma.Ai.ProviderEvent{type: :provider_hosted_event}, &1)
               )
             ) == 2

      assert {:done, :stop, message} = List.last(events)

      assert [%{"output_index" => 0, "item" => ^item}] =
               message.metadata["openai_responses_hosted"]["items"]

      refute Enum.any?(events, &match?({:toolcall_end, _, _, _}, &1))
    end)
  end

  test "expired response GET fails without a second creation" do
    with_server([{200, created()}, {404, ~s({"error":{"message":"response expired"}})}], fn url,
                                                                                            requests ->
      error =
        assert_raise ProviderError, fn ->
          stream(url, %{}, recovery_options()) |> Enum.to_list()
        end

      assert error.status == 404
      assert error.raw.response_id == "resp_resume"
      refute error.retryable
      assert ["POST", "GET"] == Enum.map(Agent.get(requests, & &1), & &1.method)
    end)
  end

  test "recovery mode never retries a creation whose response headers were lost" do
    with_server([:drop_headers], fn url, requests ->
      error =
        assert_raise ProviderError, fn ->
          stream(url, %{}, recovery_options()) |> Enum.to_list()
        end

      assert error.kind == :submission_uncertain
      refute error.retryable
      assert length(Agent.get(requests, & &1)) == 1
    end)
  end

  test "missing checkpoint, wrong ID, invalid complete JSON and unconfirmed background fail closed" do
    cases = [
      "",
      created() <> frame(%{"type" => "response.output_text.delta", "delta" => "missing cursor"}),
      created() <> "data: {broken}\n\n",
      frame(%{
        "type" => "response.created",
        "sequence_number" => 0,
        "response" => %{"id" => "resp_resume", "background" => false}
      }),
      created() <>
        frame(%{
          "type" => "response.in_progress",
          "sequence_number" => 1,
          "response" => %{"id" => "other"}
        })
    ]

    for body <- cases do
      with_server([{200, body}], fn url, requests ->
        events = stream(url, %{}, recovery_options()) |> Enum.to_list()
        assert {:provider_error, %ProviderError{retryable: false}} = List.last(events)
        refute Enum.any?(events, &match?({:done, _, _}, &1))
        assert length(Agent.get(requests, & &1)) == 1
      end)
    end
  end

  test "GET attempts are bounded even when upstream returns only old events" do
    with_server([{200, created()}, {200, created()}, {200, created()}], fn url, requests ->
      events = stream(url, %{}, recovery_options()) |> Enum.to_list()

      assert {:provider_error, %ProviderError{raw: %{reason: :attempts_exhausted}}} =
               List.last(events)

      assert ["POST", "GET", "GET"] == Enum.map(Agent.get(requests, & &1), & &1.method)
    end)
  end

  test "deadline and cancellation prevent a reconnect" do
    state =
      ResponsesRecovery.new(recovery_options())
      |> Map.merge(%{
        id: "resp_resume",
        cursor: 0,
        deadline: System.monotonic_time(:millisecond) - 1
      })

    assert {:error, %ProviderError{raw: %{reason: :recovery_expired}}} =
             ResponsesRecovery.next_attempt(state)

    with_server([{200, created() <> text(1, "hello")}], fn url, requests ->
      ref = make_ref()

      events =
        stream(url, %{}, recovery_options() ++ [cancellation_ref: ref])
        |> Stream.map(fn event ->
          if match?({:text_delta, _, _, _}, event), do: send(self(), {:cancel, ref})
          event
        end)
        |> Enum.to_list()

      assert {:provider_error, %ProviderError{kind: :cancelled}} = List.last(events)
      assert length(Agent.get(requests, & &1)) == 1
    end)
  end

  test "worker loss does not spawn a replacement POST or a cursor-only cold resume" do
    with_server([{200, created() <> text(1, "hello")}], fn url, requests ->
      parent = self()

      worker =
        Task.async(fn ->
          stream(url, %{}, recovery_options())
          |> Enum.each(fn event ->
            if match?({:text_delta, _, _, _}, event) do
              send(parent, :output_applied)

              receive do
                :never -> :ok
              end
            end
          end)
        end)

      assert_receive :output_applied, 1_000
      Task.shutdown(worker, :brutal_kill)

      assert_raise ProviderError, fn ->
        stream(url, %{}, recovery_options() ++ [response_id: "resp_resume", starting_after: 1])
      end

      assert length(Agent.get(requests, & &1)) == 1
    end)
  end

  defp recovery_options, do: [background: true, responses_recovery: @recovery]

  defp stream(url, context, opts) do
    OpenAIResponses.stream(%{
      model: %{id: "test", api: "openai-responses", provider: "test"},
      context: Map.merge(%{messages: [], tools: []}, context),
      options: opts ++ [base_url: url, api_key: "fixture", receive_timeout: 500]
    })
  end

  defp frame(event), do: "data: " <> Jason.encode!(event) <> "\n\n"

  defp created,
    do:
      frame(%{
        "type" => "response.created",
        "sequence_number" => 0,
        "response" => %{"id" => "resp_resume", "background" => true, "status" => "in_progress"}
      })

  defp text(n, text),
    do: frame(%{"type" => "response.output_text.delta", "sequence_number" => n, "delta" => text})

  defp completed(n, text),
    do:
      frame(%{
        "type" => "response.completed",
        "sequence_number" => n,
        "response" => %{
          "id" => "resp_resume",
          "status" => "completed",
          "output" => [
            %{
              "type" => "message",
              "id" => "msg1",
              "role" => "assistant",
              "status" => "completed",
              "content" => [%{"type" => "output_text", "text" => text, "annotations" => []}]
            }
          ]
        }
      })

  defp with_server(replies, fun) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listener)
    {:ok, requests} = Agent.start_link(fn -> [] end)
    task = Task.async(fn -> serve(listener, requests, replies) end)

    try do
      fun.("http://127.0.0.1:#{port}", requests)
      assert Task.await(task, 3_000) == :ok
    after
      Task.shutdown(task, :brutal_kill)
      :gen_tcp.close(listener)
      Agent.stop(requests)
    end
  end

  defp serve(listener, _requests, []) do
    assert {:error, :timeout} = :gen_tcp.accept(listener, 100)
    :ok
  end

  defp serve(listener, requests, [:drop_headers | rest]) do
    {:ok, socket} = :gen_tcp.accept(listener, 2_000)
    request = read_request(socket, "")
    Agent.update(requests, &(&1 ++ [request]))
    :gen_tcp.close(socket)
    serve(listener, requests, rest)
  end

  defp serve(listener, requests, [reply | rest]) do
    {:ok, socket} = :gen_tcp.accept(listener, 2_000)
    request = read_request(socket, "")
    Agent.update(requests, &(&1 ++ [request]))

    {status, body, padding} =
      case reply do
        {status, body} -> {status, body, 0}
        {status, body, :truncated_http} -> {status, body, 100}
      end

    :ok =
      :gen_tcp.send(socket, [
        "HTTP/1.1 #{status} Test\r\ncontent-type: text/event-stream\r\ncontent-length: #{byte_size(body) + padding}\r\nconnection: close\r\n\r\n",
        body
      ])

    :gen_tcp.close(socket)
    serve(listener, requests, rest)
  end

  defp read_request(socket, bytes) do
    case String.split(bytes, "\r\n\r\n", parts: 2) do
      [headers, body] ->
        size =
          case Regex.run(~r/content-length: (\d+)/i, headers) do
            [_, n] -> String.to_integer(n)
            _ -> 0
          end

        if byte_size(body) >= size do
          [method, target | _] = String.split(headers)

          %{
            method: method,
            target: target,
            body: if(body == "", do: nil, else: Jason.decode!(body))
          }
        else
          read_more(socket, bytes)
        end

      _ ->
        read_more(socket, bytes)
    end
  end

  defp read_more(socket, bytes) do
    {:ok, chunk} = :gen_tcp.recv(socket, 0, 1_000)
    read_request(socket, bytes <> chunk)
  end
end
