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
    live("/repository/new", HomeLive, :add)
    live("/repository/:repository/settings", ProjectSettingsLive, :index)
    live("/repository/:repository/sessions/:id", SessionLive, :show)
    live("/repository/:repository", RepositoryLive, :index)
  end
end
