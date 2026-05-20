defmodule PiWeb.ConnCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      import Plug.Conn
      import Phoenix.ConnTest
      import PiWeb.ConnCase

      alias PiWeb.Router.Helpers, as: Routes

      @endpoint PiWeb.Endpoint
      use PiWeb, :verified_routes
    end
  end

  setup _tags do
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
