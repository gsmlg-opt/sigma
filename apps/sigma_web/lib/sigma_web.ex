defmodule Sigma.Web do
  def static_paths, do: ~w(assets fonts images favicon.ico favicon.svg)

  def router do
    quote do
      use Phoenix.Router, helpers: false
      import Plug.Conn
      import Phoenix.Controller
      import Phoenix.LiveView.Router
    end
  end

  def controller do
    quote do
      use Phoenix.Controller,
        formats: [:html, :json],
        layouts: [html: Sigma.Web.Layouts]

      import Plug.Conn
      import Sigma.Web.Gettext
      alias Sigma.Web.Router.Helpers, as: Routes
    end
  end

  def live_view do
    quote do
      use Phoenix.LiveView,
        layout: {Sigma.Web.Layouts, :app}

      unquote(html_helpers())
    end
  end

  def live_component do
    quote do
      use Phoenix.LiveComponent

      unquote(html_helpers())
    end
  end

  def html do
    quote do
      use Phoenix.Component

      import Phoenix.Controller,
        only: [get_csrf_token: 0, view_module: 1, view_template: 1]

      unquote(html_helpers())
    end
  end

  defp html_helpers do
    quote do
      import Phoenix.HTML
      import Phoenix.HTML.Form
      import Phoenix.Component

      use PhoenixDuskmoon.Component
      use PhoenixDuskmoon.ArtComponent
      use Gettext, backend: Sigma.Web.Gettext

      unquote(verified_routes())
    end
  end

  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: Sigma.Web.Endpoint,
        router: Sigma.Web.Router,
        statics: Sigma.Web.static_paths()
    end
  end

  def get_sessions_root do
    Sigma.Session.ConfigManager.sessions_root()
  end

  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
