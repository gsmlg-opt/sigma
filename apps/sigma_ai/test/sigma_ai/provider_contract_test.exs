defmodule Sigma.Ai.ProviderContractTest do
  use ExUnit.Case, async: true

  alias Sigma.Ai.{
    Provider,
    ProviderCapabilities,
    ProviderError,
    ProviderEvent,
    ProviderRequest,
    ProviderStopReason,
    ProviderUsage
  }

  alias Sigma.Ai.Providers.{Anthropic, OpenAI}

  defmodule AnthropicFixtureProvider do
    @behaviour Provider

    @impl true
    def stream(_params), do: fixture_stream("anthropic")

    defp fixture_stream(provider) do
      started = message(provider, [], nil, usage(3, 0, 2, 1))
      text = message(provider, [%{type: :text, text: "hello"}], nil, usage(3, 1, 2, 1))

      tool = %{
        type: :tool_call,
        id: "call-1",
        name: "read",
        arguments: %{"path" => "README.md"}
      }

      completed = message(provider, [tool], :tool_use, usage(3, 2, 2, 1))

      [
        {:start, started},
        {:text_delta, 0, "hello", text},
        {:toolcall_start, 0, completed},
        {:toolcall_delta, 0, "{\"path\":\"README.md\"}", completed},
        {:toolcall_end, 0, tool, completed},
        {:done, :tool_use, completed}
      ]
    end

    defp message(provider, content, stop_reason, usage) do
      %{
        role: :assistant,
        content: content,
        model: "fixture-model",
        provider: provider,
        api: provider,
        usage: usage,
        stop_reason: stop_reason,
        timestamp: 1
      }
    end

    defp usage(input, output, cache_read, cache_write) do
      %{
        input: input,
        output: output,
        cache_read: cache_read,
        cache_write: cache_write,
        total_tokens: input + output,
        cost: %{total: 0.0}
      }
    end
  end

  defmodule OpenAIFixtureProvider do
    @behaviour Provider

    @impl true
    def stream(params), do: AnthropicFixtureProvider.stream(params)
  end

  defmodule MalformedToolProvider do
    @behaviour Provider

    @impl true
    def stream(_params) do
      message = %{
        role: :assistant,
        content: [],
        model: "fixture-model",
        provider: "fixture",
        api: "fixture",
        usage: %{input: 0, output: 0, cache_read: 0, cache_write: 0, total_tokens: 0},
        stop_reason: :tool_use,
        timestamp: 1
      }

      invalid_tool = %{type: :tool_call, id: "call-1", name: "bash", arguments: "{"}
      [{:start, message}, {:toolcall_end, 0, invalid_tool, message}, {:done, :tool_use, message}]
    end
  end

  defmodule RaisingProvider do
    @behaviour Provider

    @impl true
    def stream(_params) do
      Stream.map([:raise], fn _ -> raise "context length exceeded" end)
    end
  end

  defmodule DemandProvider do
    @behaviour Provider

    @impl true
    def stream(params) do
      test_pid = Keyword.fetch!(params.options, :test_pid)

      Stream.map(1..100, fn index ->
        send(test_pid, {:provider_pulled, index})
        {:start, %{role: :assistant, content: [], timestamp: index}}
      end)
    end
  end

  defmodule EmptyProvider do
    @behaviour Provider
    @impl true
    def stream(_params), do: []
  end

  defmodule CompleteThenRaiseProvider do
    @behaviour Provider

    @impl true
    def stream(params) do
      completed = AnthropicFixtureProvider.stream(params)
      trailing = Stream.map([:raise], fn _ -> raise "after terminal" end)
      Stream.concat(completed, trailing)
    end
  end

  defmodule CompleteThenHangProvider do
    @behaviour Provider

    @impl true
    def stream(params) do
      trailing =
        Stream.repeatedly(fn ->
          receive do
            :never -> :never
          end
        end)

      Stream.concat(AnthropicFixtureProvider.stream(params), trailing)
    end
  end

  test "normalizes legacy provider tuples into the provider-neutral lifecycle" do
    request = ProviderRequest.from_legacy(legacy_request())
    events = Provider.stream(AnthropicFixtureProvider, request) |> Enum.to_list()

    assert [
             %ProviderEvent{type: :response_started},
             %ProviderEvent{type: :content_text_delta, delta: "hello"},
             %ProviderEvent{type: :tool_call_started},
             %ProviderEvent{type: :tool_call_arguments_delta},
             %ProviderEvent{
               type: :tool_call_completed,
               tool_call: %{id: "call-1", name: "read", arguments: %{"path" => "README.md"}}
             },
             %ProviderEvent{
               type: :usage_updated,
               usage: %ProviderUsage{input_tokens: 3, output_tokens: 2, cache_read_tokens: 2}
             },
             %ProviderEvent{
               type: :response_completed,
               stop_reason: %ProviderStopReason{reason: :tool_use, raw: :tool_use}
             }
           ] = events
  end

  test "equivalent adapters produce equivalent normalized event sequences" do
    request = ProviderRequest.from_legacy(legacy_request())

    anthropic = Provider.stream(AnthropicFixtureProvider, request) |> Enum.map(&contract_shape/1)
    openai = Provider.stream(OpenAIFixtureProvider, request) |> Enum.map(&contract_shape/1)

    assert anthropic == openai
  end

  test "malformed completed tool arguments fail instead of becoming executable" do
    events =
      Provider.stream(MalformedToolProvider, ProviderRequest.from_legacy(legacy_request()))
      |> Enum.to_list()

    refute Enum.any?(events, &(&1.type == :tool_call_completed))
    refute Enum.any?(events, &(&1.type == :response_completed))

    assert %ProviderEvent{
             type: :response_failed,
             error: %ProviderError{kind: :malformed_stream, retryable: false}
           } = List.last(events)
  end

  test "classifies provider errors and retry metadata into a closed set" do
    assert %ProviderError{kind: :authentication, retryable: false} =
             ProviderError.from_http(401, %{"message" => "bad key"})

    assert %ProviderError{kind: :rate_limit, retryable: true, retry_after_ms: 2_000} =
             ProviderError.from_http(429, %{"message" => "slow down"}, retry_after: "2")

    assert %ProviderError{kind: :context_limit, retryable: false} =
             ProviderError.from_http(400, %{"code" => "context_length_exceeded"})

    assert %ProviderError{kind: :timeout, retryable: true} = ProviderError.from_reason(:timeout)
    assert %ProviderError{kind: :cancelled, retryable: false} = ProviderError.from_reason(:cancelled)
  end

  test "lazy adapter exceptions become structured terminal events" do
    assert [%ProviderEvent{type: :response_failed, error: %ProviderError{kind: :context_limit}}] =
             Provider.stream(RaisingProvider, ProviderRequest.from_legacy(legacy_request()))
             |> Enum.to_list()
  end

  test "compatibility bridge pulls only on downstream demand" do
    request =
      legacy_request()
      |> Map.put(:options, [test_pid: self()])
      |> ProviderRequest.from_legacy()

    assert [%ProviderEvent{type: :response_started}] =
             Provider.stream(DemandProvider, request) |> Enum.take(1)

    assert_receive {:provider_pulled, 1}
    refute_receive {:provider_pulled, 2}, 50
  end

  test "bridge synthesizes missing terminals and suppresses failures after completion" do
    request = ProviderRequest.from_legacy(legacy_request())

    assert [%ProviderEvent{type: :response_failed, error: %ProviderError{kind: :malformed_stream}}] =
             Provider.stream(EmptyProvider, request) |> Enum.to_list()

    events = Provider.stream(CompleteThenRaiseProvider, request) |> Enum.to_list()
    assert Enum.count(events, &(&1.type in [:response_completed, :response_failed])) == 1
    assert List.last(events).type == :response_completed

    task =
      Task.async(fn -> Provider.stream(CompleteThenHangProvider, request) |> Enum.to_list() end)

    assert List.last(Task.await(task, 1_000)).type == :response_completed
  end

  test "Anthropic and OpenAI adapters cooperatively cancel their live transports" do
    for provider <- [Anthropic, OpenAI] do
      with_hanging_sse_server(fn base_url, server_pid ->
        cancellation_ref = make_ref()

        request =
          legacy_request()
          |> put_in([:model, :provider], provider_id(provider))
          |> put_in([:options], [
            api_key: "test-key",
            base_url: base_url,
            receive_timeout: 5_000,
            cancellation_ref: cancellation_ref
          ])
          |> ProviderRequest.from_legacy()

        task = Task.async(fn -> Provider.stream(provider, request) |> Enum.to_list() end)
        assert_receive {:provider_connected, ^server_pid}, 1_000
        send(task.pid, {:cancel, cancellation_ref})

        assert [%ProviderEvent{
                 type: :response_failed,
                 error: %ProviderError{kind: :cancelled, retryable: false}
               }] = Task.await(task, 2_000)
      end)
    end
  end

  test "describes model capabilities without inventing unavailable values" do
    model = %{
      "contextWindow" => 200_000,
      "maxTokens" => 8_192,
      id: "claude-test",
      provider: "anthropic"
    }

    assert %ProviderCapabilities{
             tools: true,
             thinking: true,
             image_input: true,
             context_window: 200_000,
             max_output_tokens: 8_192
           } = Provider.capabilities(AnthropicFixtureProvider, model)
  end

  defp legacy_request do
    %{
      model: %{id: "fixture-model", provider: "anthropic", api: "fixture"},
      context: %{messages: [], tools: []},
      options: [],
      session_id: "session-1"
    }
  end

  defp contract_shape(event) do
    %{
      type: event.type,
      delta: event.delta,
      tool_call: event.tool_call,
      usage: event.usage,
      stop_reason: event.stop_reason,
      error: event.error
    }
  end

  defp provider_id(Anthropic), do: "anthropic"
  defp provider_id(OpenAI), do: "openai"

  defp with_hanging_sse_server(fun) do
    parent = self()
    {:ok, listen_socket} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])

    {:ok, port} = :inet.port(listen_socket)

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listen_socket)
        {:ok, _request} = :gen_tcp.recv(socket, 0, 1_000)

        :ok =
          :gen_tcp.send(socket, [
            "HTTP/1.1 200 OK\r\n",
            "content-type: text/event-stream\r\n",
            "connection: close\r\n",
            "\r\n"
          ])

        send(parent, {:provider_connected, self()})

        receive do
          :close -> :ok
        end

        :gen_tcp.close(socket)
      end)

    try do
      fun.("http://127.0.0.1:#{port}", server.pid)
    after
      send(server.pid, :close)
      Task.shutdown(server, 1_000)
      :gen_tcp.close(listen_socket)
    end
  end
end
