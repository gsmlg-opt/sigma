defmodule Sigma.Web.SamgitaHost.HandlerTest do
  use ExUnit.Case, async: true

  alias Sigma.Web.SamgitaHost.Handler

  test "methods match advertised groups" do
    assert Handler.capabilities() == ["sessions.v1", "streaming.v1", "cancellation.v1"]
    assert Handler.methods() == SamgitaProtocol.Capabilities.methods(Handler.capabilities())
    assert {:ok, _server} = SamgitaProtocol.Server.new(Handler, Handler.state(:test))
  end
end
