defmodule Sigma.Ai.Providers.ResponsesCancellationTest do
  use ExUnit.Case, async: true
  alias Sigma.Ai.{ResponsesCancellation, ProviderError}

  defp options(ref, timeout \\ 500) do
    [
      cancellation_ref: ref,
      background: true,
      responses_cancel: %{capability: :openai_background_cancel_v1, timeout_ms: timeout}
    ]
  end

  defp observe(token, status \\ "in_progress") do
    ResponsesCancellation.observe(token, %{
      "type" => "response.created",
      "response" => %{"id" => "resp_test", "background" => true, "status" => status}
    })
  end

  test "explicit capability is required and other adapters reject cancellation options" do
    for opts <- [
          [responses_cancel: true],
          [responses_cancel: %{capability: :openai_background_cancel_v1}],
          options(make_ref(), 0)
        ] do
      assert_raise ProviderError, fn -> ResponsesCancellation.validate!(opts) end
    end

    assert_raise ProviderError, fn ->
      Sigma.Ai.CreationRequest.reject_responses_recovery!(options(make_ref()))
    end
  end

  test "missing ID, unsupported route and unconfirmed background have distinct outcomes" do
    for {opts, expected} <- [
          {options(make_ref()), %{outcome: :unknown, reason: :missing_id}},
          {[], %{outcome: :unsupported}}
        ] do
      token = ResponsesCancellation.register(opts, "http://127.0.0.1:1", [])
      ResponsesCancellation.request(token)
      assert [result] = ResponsesCancellation.result(token)
      assert Map.take(result, Map.keys(expected)) == expected
    end

    token = ResponsesCancellation.register(options(make_ref()), "http://127.0.0.1:1", [])
    ResponsesCancellation.observe(token, %{"response" => %{"id" => "resp_test"}})
    ResponsesCancellation.request(token)
    assert [%{reason: :background_unconfirmed}] = ResponsesCancellation.result(token)
  end

  test "cancellation before registration prevents creation" do
    ref = make_ref()
    ResponsesCancellation.request(ref)

    assert_raise ProviderError, fn ->
      ResponsesCancellation.register(options(ref), "unused", [])
    end
  end

  test "completed response does not need a cancel POST" do
    token = ResponsesCancellation.register(options(make_ref()), "http://127.0.0.1:1", [])
    observe(token, "completed")
    ResponsesCancellation.request(token)

    assert [%{outcome: :already_terminal, status: "completed"}] =
             ResponsesCancellation.result(token)
  end

  test "duplicate stop sends one pinned POST and preserves upstream terminal status" do
    for status <- ["cancelled", "completed", "failed", "incomplete"] do
      server(200, %{"id" => "resp_test", "status" => status}, fn url ->
        ref = make_ref()

        token =
          ResponsesCancellation.register(options(ref), url <> "/v1", [
            {"authorization", "Bearer fixture"}
          ])

        observe(token)
        ResponsesCancellation.request(ref)
        ResponsesCancellation.request(ref)
        result = await_result(token)
        assert result.status == status

        assert result.outcome ==
                 if(status == "cancelled", do: :confirmed, else: :already_terminal)

        assert_receive {:http_request, request}
        assert request =~ "POST /v1/responses/resp_test/cancel HTTP/1.1"
        assert String.downcase(request) =~ "authorization: bearer fixture"
      end)
    end
  end

  test "nonterminal, mismatched ID, HTTP failure and redirects never confirm cancellation" do
    for {code, body, outcome} <- [
          {200, %{"id" => "resp_test", "status" => "in_progress"}, :unknown},
          {200, %{"id" => "another", "status" => "cancelled"}, :unknown},
          {500, %{}, :failed},
          {302, %{}, :failed},
          {404, %{}, :failed}
        ] do
      server(code, body, fn url ->
        token = ResponsesCancellation.register(options(make_ref()), url, [])
        observe(token)
        ResponsesCancellation.request(token)
        assert await_result(token).outcome == outcome
        assert_receive {:http_request, _}
      end)
    end
  end

  test "cancel continues independently after stream worker is killed" do
    server(200, %{"id" => "resp_test", "status" => "cancelled"}, fn url ->
      parent = self()
      ref = make_ref()

      worker =
        spawn(fn ->
          token = ResponsesCancellation.register(options(ref), url, [])
          observe(token)
          send(parent, {:registered, token})

          receive do
            :never -> :ok
          end
        end)

      assert_receive {:registered, token}
      ResponsesCancellation.request(ref)
      Process.exit(worker, :kill)
      assert await_result(token).outcome == :confirmed
      assert_receive {:http_request, _}
    end)
  end

  test "worker death alone never initiates cancellation; a later explicit stop can" do
    server(200, %{"id" => "resp_test", "status" => "cancelled"}, fn url ->
      parent = self()
      ref = make_ref()

      {worker, monitor} =
        spawn_monitor(fn ->
          token = ResponsesCancellation.register(options(ref), url, [])
          observe(token)
          send(parent, {:registered, token})
        end)

      assert_receive {:registered, token}
      assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}
      refute_receive {:http_request, _}, 50
      ResponsesCancellation.request(ref)
      assert await_result(token).outcome == :confirmed
      assert_receive {:http_request, _}
    end)
  end

  test "late ID after stop is cancelled once without recreating the response" do
    server(200, %{"id" => "resp_test", "status" => "cancelled"}, fn url ->
      token = ResponsesCancellation.register(options(make_ref()), url, [])
      ResponsesCancellation.request(token)
      assert [%{reason: :missing_id}] = ResponsesCancellation.result(token)
      observe(token)
      assert await_result(token).outcome == :confirmed
      assert_receive {:http_request, _}
    end)
  end

  test "bounded timeout is unknown and does not retry" do
    server(
      200,
      %{},
      fn url ->
        token = ResponsesCancellation.register(options(make_ref(), 500), url, [])
        observe(token)
        ResponsesCancellation.request(token)
        assert await_result(token).outcome == :unknown
        assert_receive {:http_request, _}
      end,
      700
    )
  end

  test "real Responses stream registers its ID before the worker is killed by Stop" do
    parent = self()
    ref = make_ref()
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listener)

    server =
      Task.async(fn ->
        {:ok, stream_socket} = :gen_tcp.accept(listener, 2_000)
        {:ok, create} = :gen_tcp.recv(stream_socket, 0, 1_000)
        assert create =~ "POST /responses HTTP/1.1"

        frames =
          [
            %{
              "type" => "response.created",
              "sequence_number" => 0,
              "response" => %{
                "id" => "resp_test",
                "background" => true,
                "status" => "in_progress"
              }
            },
            %{"type" => "response.output_text.delta", "sequence_number" => 1, "delta" => "hello"}
          ]
          |> Enum.map_join(fn event -> "data: " <> Jason.encode!(event) <> "\n\n" end)

        :ok =
          :gen_tcp.send(
            stream_socket,
            "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\nconnection: close\r\n\r\n" <>
              frames
          )

        {:ok, cancel_socket} = :gen_tcp.accept(listener, 2_000)
        {:ok, cancel} = :gen_tcp.recv(cancel_socket, 0, 1_000)
        assert cancel =~ "POST /responses/resp_test/cancel HTTP/1.1"
        body = Jason.encode!(%{id: "resp_test", status: "cancelled"})

        :ok =
          :gen_tcp.send(
            cancel_socket,
            "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n" <>
              body
          )

        :gen_tcp.close(cancel_socket)
        :gen_tcp.close(stream_socket)
        assert {:error, :timeout} = :gen_tcp.accept(listener, 100)
      end)

    worker =
      spawn(fn ->
        Sigma.Ai.Providers.OpenAIResponses.stream(%{
          model: %{id: "test", api: "openai-responses", provider: "test"},
          context: %{messages: [], tools: []},
          options: options(ref) ++ [api_key: "fixture", base_url: "http://127.0.0.1:#{port}"]
        })
        |> Enum.each(fn
          {:text_delta, _, "hello", _} -> send(parent, :streaming)
          _ -> :ok
        end)
      end)

    try do
      assert_receive :streaming, 2_000
      ResponsesCancellation.request(ref)
      Process.exit(worker, :kill)
      assert await_result(ref).outcome == :confirmed
      Task.await(server, 3_000)
    after
      Process.exit(worker, :kill)
      Task.shutdown(server, :brutal_kill)
      :gen_tcp.close(listener)
    end
  end

  test "acknowledged child interrupt cancels only the exact child run and reports final outcome" do
    server(200, %{"id" => "resp_test", "status" => "cancelled"}, fn url ->
      key = Sigma.Ai.ManagedCancellation.key("child", "run-old", 1)
      token = ResponsesCancellation.register(options(key), url, [])
      observe(token)

      next =
        ResponsesCancellation.register(
          options(Sigma.Ai.ManagedCancellation.key("child", "run-new", 2)),
          url,
          []
        )

      observe(next)

      sibling =
        ResponsesCancellation.register(
          options(Sigma.Ai.ManagedCancellation.key("sibling", "run-old", 1)),
          url,
          []
        )

      observe(sibling)

      event = %{
        type: :interrupted,
        agent: %{
          host_metadata: %{"child_session_id" => "child"},
          run_id: "run-old",
          incarnation: 1,
          name: "/root/child"
        }
      }

      Sigma.Ai.ManagedCancellation.observe(event, self(), &"public-#{&1}")

      assert_receive {:upstream_cancel_result,
                      %{turn_id: "public-run-old", target: "/root/child"}, %{outcome: :pending}}

      assert_receive {:upstream_cancel_result, %{turn_id: "public-run-old"},
                      %{outcome: :confirmed}},
                     1_000

      assert await_result(token).outcome == :confirmed
      assert ResponsesCancellation.result(next) == [nil]
      assert ResponsesCancellation.result(sibling) == [nil]
      assert_receive {:http_request, _}
    end)
  end

  test "snapshot interrupted status, steer, ordinary settlement and disconnect never send child cancel" do
    agent = %{
      host_metadata: %{child_session_id: "child"},
      run_id: "unregistered",
      incarnation: 1,
      name: "/root/child",
      status: :interrupted
    }

    for event <- [
          %{agent: agent},
          %{type: :settled, agent: agent},
          %{type: :steer, agent: agent},
          %{type: :cleanup_uncertain, agent: agent}
        ] do
      assert :ok = Sigma.Ai.ManagedCancellation.observe(event, self(), & &1)
    end

    refute_receive {:upstream_cancel_result, _, _}, 50
  end

  test "missing in-memory checkpoint after restart is reported without replaying cancellation" do
    ref = Sigma.Ai.ManagedCancellation.key("lost", "lost-run", 1)
    ResponsesCancellation.request(ref, {self(), %{turn_id: "lost-run", target: "Child"}})
    assert_receive {:upstream_cancel_result, _, %{outcome: :unknown, reason: :missing_checkpoint}}
  end

  defp await_result(token, attempts \\ 100)
  defp await_result(_token, 0), do: flunk("cancellation did not settle")

  defp await_result(token, attempts) do
    case ResponsesCancellation.result(token) do
      [%{outcome: outcome} = result] when outcome != :pending ->
        result

      _ ->
        Process.sleep(10)
        await_result(token, attempts - 1)
    end
  end

  defp server(status, body, fun, delay \\ 0) do
    parent = self()
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listener)

    task =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 2_000)
        {:ok, request} = :gen_tcp.recv(socket, 0, 1_000)
        send(parent, {:http_request, request})
        Process.sleep(delay)
        encoded = Jason.encode!(body)

        :gen_tcp.send(
          socket,
          "HTTP/1.1 #{status} Test\r\ncontent-type: application/json\r\ncontent-length: #{byte_size(encoded)}\r\nconnection: close\r\n\r\n" <>
            encoded
        )

        :gen_tcp.close(socket)
        assert {:error, :timeout} = :gen_tcp.accept(listener, 100)
      end)

    try do
      fun.("http://127.0.0.1:#{port}")
      Task.await(task, 3_000)
    after
      Task.shutdown(task, :brutal_kill)
      :gen_tcp.close(listener)
    end
  end
end
