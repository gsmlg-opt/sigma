defmodule ExPiWeb do
  def static_paths, do: ~w(assets fonts images favicon.ico robots.txt)

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
        layouts: [html: ExPiWeb.Layouts]

      import Plug.Conn
      import ExPiWeb.Gettext
      alias ExPiWeb.Router.Helpers, as: Routes
    end
  end

  def live_view do
    quote do
      use Phoenix.LiveView,
        layout: {ExPiWeb.Layouts, :app}

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
      use Gettext, backend: ExPiWeb.Gettext

      unquote(verified_routes())
    end
  end

  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: ExPiWeb.Endpoint,
        router: ExPiWeb.Router,
        statics: ExPiWeb.static_paths()
    end
  end

  def get_sessions_root do
    if Mix.env() == :dev do
      # Find umbrella root by looking for mix.exs
      cwd = File.cwd!()
      root = if File.exists?(Path.join(cwd, "apps")), do: cwd, else: Path.expand("../..", cwd)
      Path.join(root, "apps/ex_pi_web/priv/sessions")
    else
      case :code.priv_dir(:ex_pi_web) do
        {:error, :bad_name} -> Path.expand("priv/sessions", File.cwd!())
        path -> Path.join(List.to_string(path), "sessions")
      end
    end
  end

  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
