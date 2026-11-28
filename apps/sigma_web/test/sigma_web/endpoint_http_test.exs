defmodule Sigma.Web.EndpointHTTPTest do
  use ExUnit.Case, async: false

  alias HTTP.WebSocket
  alias HTTP.WebSocket.{Event, Frame, Handshake}

  defmodule Channel do
    use Phoenix.Channel

    def join("probe", _payload, socket), do: {:ok, socket}

    def handle_in("echo", %{"blob" => blob}, socket) do
      {:reply, {:ok, %{bytes: byte_size(blob)}}, socket}
    end
  end

  defmodule Socket do
    use Phoenix.Socket

    channel("probe", Sigma.Web.EndpointHTTPTest.Channel)

    def connect(_params, socket, _connect_info), do: {:ok, socket}
    def id(_socket), do: nil
  end

  defmodule Endpoint do
    use Phoenix.Endpoint, otp_app: :sigma_web

    for {path, _socket, options} <- Sigma.Web.Endpoint.__sockets__(),
        path in ["/live", "/agent"] do
      socket(path, Sigma.Web.EndpointHTTPTest.Socket,
        websocket: Keyword.delete(options[:websocket], :connect_info),
        longpoll: false
      )
    end

    plug(:respond)

    defp respond(conn, _options), do: Plug.Conn.send_resp(conn, 200, "gaoxy probe")
  end

  setup context do
    config = Application.fetch_env!(:sigma_web, Sigma.Web.Endpoint)

    http =
      config
      |> Keyword.fetch!(:http)
      |> Keyword.merge(ip: context[:listener_ip] || {127, 0, 0, 1}, port: 0)

    start_supervised!({Phoenix.PubSub, name: __MODULE__.PubSub})

    start_supervised!(
      {Endpoint,
       Keyword.merge(config,
         http: http,
         server: true,
         pubsub_server: __MODULE__.PubSub,
         check_origin: false,
         code_reloader: false,
         watchers: []
       )}
    )

    assert Endpoint.config(:adapter) == Gaoxy.PhoenixAdapter
    {:ok, {_ip, port}} = Endpoint.server_info(:http)
    %{port: port}
  end

  test "serves HTTP through the configured Gaoxy adapter", %{port: port} do
    assert_http(port, "127.0.0.1", :inet)
  end

  @tag listener_ip: {0, 0, 0, 0, 0, 0, 0, 0}
  test "the release IPv6 wildcard listener accepts IPv4 and IPv6", %{port: port} do
    assert_http(port, "127.0.0.1", :inet)
    assert_http(port, "[::1]", :inet6)
  end

  for bytes <- [300 * 1024, 16 * 1024 * 1024 - 1024] do
    test "LiveView's frame and service budgets accept a #{bytes}-byte payload", %{port: port} do
      with_websocket(port, "/live", fn ws ->
        payload =
          Formata.JSON.encode!([
            "1",
            "2",
            "probe",
            "echo",
            %{blob: String.duplicate("x", unquote(bytes))}
          ])

        assert :ok = WebSocket.send(ws, payload)
        assert_receive {WebSocket, ^ws, %Event.Message{data: reply}}, 5_000

        assert [
                 "1",
                 "2",
                 "probe",
                 "phx_reply",
                 %{"status" => "ok", "response" => %{"bytes" => unquote(bytes)}}
               ] =
                 Formata.JSON.decode!(reply)
      end)
    end
  end

  test "accepts a fragmented Phoenix message larger than 256 KiB", %{port: port} do
    with_wire_socket(port, "/live", fn socket ->
      payload =
        Formata.JSON.encode!([
          "1",
          "2",
          "probe",
          "echo",
          %{blob: String.duplicate("x", 300 * 1024)}
        ])

      <<first::binary-size(150 * 1024), last::binary>> = payload

      # A zero masking key leaves the payload unchanged in these RFC 6455 fragments.
      assert :ok =
               :gen_tcp.send(socket, <<0x01, 0xFF, byte_size(first)::64, 0::32, first::binary>>)

      assert :ok = :gen_tcp.send(socket, <<0x80, 0xFF, byte_size(last)::64, 0::32, last::binary>>)
      assert {:message, :text, reply} = receive_wire_frame(socket)

      assert [
               "1",
               "2",
               "probe",
               "phx_reply",
               %{"status" => "ok", "response" => %{"bytes" => 307_200}}
             ] =
               Formata.JSON.decode!(reply)
    end)
  end

  for {path, bytes} <- [{"/live", 16 * 1024 * 1024}, {"/agent", 1024 * 1024}] do
    test "#{path} rejects frames above its configured ceiling with close 1009", %{port: port} do
      with_wire_socket(port, unquote(path), fn socket ->
        # The declared length alone must reject the frame, without buffering its body.
        header = <<0x81, 0xFF, unquote(bytes + 1)::64, 0::32>>
        assert :ok = :gen_tcp.send(socket, header)
        assert {:close, 1009, _reason} = receive_wire_frame(socket)
      end)
    end
  end

  defp assert_http(port, host, family) do
    promise = HTTP.fetch("http://#{host}:#{port}/", socket_opts: [family], timeout: 5_000)
    assert %HTTP.Response{status: 200} = response = HTTP.Promise.await(promise, 5_000)
    assert HTTP.Response.read_all(response) == "gaoxy probe"
  end

  defp websocket_url(port, path), do: "ws://127.0.0.1:#{port}#{path}/websocket?vsn=2.0.0"

  defp join_payload, do: Formata.JSON.encode!(["1", "1", "probe", "phx_join", %{}])

  defp assert_joined(reply) do
    assert ["1", "1", "probe", "phx_reply", %{"status" => "ok"}] = Formata.JSON.decode!(reply)
  end

  defp with_websocket(port, path, callback) do
    %WebSocket{} = ws = WebSocket.new(websocket_url(port, path))

    try do
      assert_receive {WebSocket, ^ws, %Event.Open{}}, 5_000
      assert :ok = WebSocket.send(ws, join_payload())
      assert_receive {WebSocket, ^ws, %Event.Message{data: reply}}, 5_000
      assert_joined(reply)
      callback.(ws)
    after
      WebSocket.close(ws)
      :ok = HTTP.ClientCompletion.await(WebSocket.completion(ws))
    end
  end

  # These cases control FIN and the declared length independently of the body.
  defp with_wire_socket(port, path, callback) do
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 5_000)

    try do
      uri = URI.parse(websocket_url(port, path))
      key = Base.encode64(:crypto.strong_rand_bytes(16))
      {:ok, request} = Handshake.build_request(uri, [], [], key)
      :ok = :gen_tcp.send(socket, request)
      {:ok, 101, headers, ""} = receive_upgrade(socket, "")
      {:ok, _} = Handshake.validate_response(101, headers, key, [])

      {:ok, join} = Frame.encode(:text, join_payload())
      :ok = :gen_tcp.send(socket, join)
      assert {:message, :text, reply} = receive_wire_frame(socket)
      assert_joined(reply)
      callback.(socket)
    after
      :gen_tcp.close(socket)
    end
  end

  defp receive_upgrade(socket, buffer) do
    {:ok, data} = :gen_tcp.recv(socket, 0, 5_000)

    case Handshake.parse_response(buffer <> data) do
      {:more, head} -> receive_upgrade(socket, head)
      result -> result
    end
  end

  defp receive_wire_frame(socket, parser \\ Frame.new_parser()) do
    {:ok, data} = :gen_tcp.recv(socket, 0, 5_000)

    case Frame.parse(parser, data) do
      {:ok, parser, []} -> receive_wire_frame(socket, parser)
      {:ok, _parser, [frame]} -> frame
    end
  end
end
