defmodule Sigma.Web.ConnCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      import Plug.Conn
      import Phoenix.ConnTest
      import Sigma.Web.ConnCase

      alias Sigma.Web.Router.Helpers, as: Routes

      @endpoint Sigma.Web.Endpoint
      use Sigma.Web, :verified_routes
    end
  end

  setup _tags do
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
