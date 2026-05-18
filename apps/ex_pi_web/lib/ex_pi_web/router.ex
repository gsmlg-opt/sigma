defmodule ExPiWeb.Router do
  use ExPiWeb, :router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {ExPiWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  scope "/", ExPiWeb do
    pipe_through(:browser)

    live("/", HomeLive, :index)
    live("/settings/credentials", SettingsLive, :credentials)
    live("/settings/providers", SettingsLive, :providers)
    live("/settings/system_prompt", SettingsLive, :system_prompt)
    live("/settings", SettingsLive, :index)
    live("/workdir/:workdir", WorkdirLive, :index)
    live("/workdir/new/project", HomeLive, :add)
    live("/workdir/:workdir/sessions/:id", SessionLive, :show)
  end
end
