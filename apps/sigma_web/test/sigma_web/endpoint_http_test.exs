defmodule Sigma.Web.EndpointHTTPTest do
  use ExUnit.Case, async: false

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
    assert_http(port, "127.0.0.1")
  end

  @tag listener_ip: {0, 0, 0, 0, 0, 0, 0, 0}
  test "the release IPv6 wildcard listener accepts IPv4 and IPv6", %{port: port} do
    assert_http(port, "127.0.0.1")
    assert_http(port, "::1")
  end

  for bytes <- [300 * 1024, 16 * 1024 * 1024 - 1024] do
    test "LiveView's frame and service budgets accept a #{bytes}-byte payload", %{port: port} do
      with_websocket(port, "/live", fn conn, ref, ws ->
        payload =
          Jason.encode!([
            "1",
            "2",
            "probe",
            "echo",
            %{blob: String.duplicate("x", unquote(bytes))}
          ])

        {conn, ws} = send_frame(conn, ref, ws, {:text, payload})
        {_conn, _ws, [{:text, reply}]} = receive_frames(conn, ws)

        assert [
                 "1",
                 "2",
                 "probe",
                 "phx_reply",
                 %{"status" => "ok", "response" => %{"bytes" => unquote(bytes)}}
               ] =
                 Jason.decode!(reply)
      end)
    end
  end

  test "accepts a fragmented Phoenix message larger than 256 KiB", %{port: port} do
    with_websocket(port, "/live", fn conn, ref, ws ->
      payload =
        Jason.encode!(["1", "2", "probe", "echo", %{blob: String.duplicate("x", 300 * 1024)}])

      <<first::binary-size(150 * 1024), last::binary>> = payload

      # A zero masking key leaves the payload unchanged in these RFC 6455 fragments.
      {:ok, conn} =
        Mint.WebSocket.stream_request_body(
          conn,
          ref,
          <<0x01, 0xFF, byte_size(first)::64, 0::32, first::binary>>
        )

      {:ok, conn} =
        Mint.WebSocket.stream_request_body(
          conn,
          ref,
          <<0x80, 0xFF, byte_size(last)::64, 0::32, last::binary>>
        )

      {_conn, _ws, [{:text, reply}]} = receive_frames(conn, ws)

      assert [
               "1",
               "2",
               "probe",
               "phx_reply",
               %{"status" => "ok", "response" => %{"bytes" => 307_200}}
             ] =
               Jason.decode!(reply)
    end)
  end

  for {path, bytes} <- [{"/live", 16 * 1024 * 1024}, {"/agent", 1024 * 1024}] do
    test "#{path} rejects frames above its configured ceiling with close 1009", %{port: port} do
      with_websocket(port, unquote(path), fn conn, ref, ws ->
        # The declared length alone must reject the frame, without buffering its body.
        header = <<0x81, 0xFF, unquote(bytes + 1)::64, 0::32>>
        {:ok, conn} = Mint.WebSocket.stream_request_body(conn, ref, header)
        {_conn, _ws, frames} = receive_frames(conn, ws)
        assert [{:close, 1009, _reason}] = frames
      end)
    end
  end

  defp assert_http(port, host) do
    with_connection(port, host, fn conn ->
      {:ok, conn, ref} = Mint.HTTP.request(conn, "GET", "/", [], nil)
      {_conn, 200, _headers, "gaoxy probe"} = receive_response(conn, ref)
    end)
  end

  defp with_connection(port, host, callback) do
    {:ok, conn} =
      Mint.HTTP.connect(:http, host, port,
        protocols: [:http1],
        mode: :passive,
        transport_opts: [inet6: host == "::1"]
      )

    try do
      callback.(conn)
    after
      Mint.HTTP.close(conn)
    end
  end

  defp with_websocket(port, path, callback) do
    with_connection(port, "127.0.0.1", fn conn ->
      {:ok, conn, ref} = Mint.WebSocket.upgrade(:ws, conn, path <> "/websocket?vsn=2.0.0", [])
      {conn, status, headers, _body} = receive_response(conn, ref)
      {:ok, conn, ws} = Mint.WebSocket.new(conn, ref, status, headers, mode: :passive)

      {conn, ws} =
        send_frame(conn, ref, ws, {:text, Jason.encode!(["1", "1", "probe", "phx_join", %{}])})

      {conn, ws, [{:text, joined}]} = receive_frames(conn, ws)
      assert ["1", "1", "probe", "phx_reply", %{"status" => "ok"}] = Jason.decode!(joined)
      callback.(conn, ref, ws)
    end)
  end

  defp receive_response(conn, ref, status \\ nil, headers \\ [], body \\ []) do
    {:ok, conn, responses} = Mint.HTTP.recv(conn, 0, 5_000)

    {status, headers, body, done?} =
      Enum.reduce(responses, {status, headers, body, false}, fn
        {:status, ^ref, status}, {_, headers, body, done?} ->
          {status, headers, body, done?}

        {:headers, ^ref, headers}, {status, _, body, done?} ->
          {status, headers, body, done?}

        {:data, ^ref, data}, {status, headers, body, done?} ->
          {status, headers, [body, data], done?}

        {:done, ^ref}, {status, headers, body, _} ->
          {status, headers, body, true}
      end)

    if done?,
      do: {conn, status, headers, IO.iodata_to_binary(body)},
      else: receive_response(conn, ref, status, headers, body)
  end

  defp send_frame(conn, ref, ws, frame) do
    {:ok, ws, encoded} = Mint.WebSocket.encode(ws, frame)
    {:ok, conn} = Mint.WebSocket.stream_request_body(conn, ref, encoded)
    {conn, ws}
  end

  defp receive_frames(conn, ws) do
    {:ok, conn, responses} = Mint.WebSocket.recv(conn, 0, 5_000)

    {ws, frames} =
      Enum.reduce(responses, {ws, []}, fn {:data, _ref, bytes}, {ws, frames} ->
        {:ok, ws, decoded} = Mint.WebSocket.decode(ws, bytes)
        {ws, frames ++ decoded}
      end)

    if frames == [], do: receive_frames(conn, ws), else: {conn, ws, frames}
  end
end
