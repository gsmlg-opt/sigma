defmodule Sigma.Web.EndpointTest do
  use ExUnit.Case, async: true

  test "configures a 16 MB maximum frame size for the LiveView websocket" do
    {"/live", _socket, opts} =
      Enum.find(Sigma.Web.Endpoint.__sockets__(), fn {path, _socket, _opts} ->
        path == "/live"
      end)

    assert get_in(opts, [:websocket, :max_frame_size]) == 16 * 1024 * 1024
  end
end
