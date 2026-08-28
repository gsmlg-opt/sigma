defmodule Sigma.Web.ThemeMount do
  @moduledoc """
  Injects the persisted UI theme into every LiveView session.

  Runs as `on_mount` for all LiveViews (via `use Sigma.Web, :live_view`), so the
  value is available as `@theme` in every socket and its layouts, including
  `root.html.heex`, which renders `<html data-theme={@theme}>`.

  The theme is read from the pi-compatible config (`settings.json` via
  `Sigma.Session.ConfigManager.get_theme/0`), not from the browser, so the
  server always renders the correct theme on first paint / page refresh.
  """

  import Phoenix.Component

  @doc """
  Assigns the persisted theme onto the socket.

  Returns `{:cont, socket}` so the LiveView continues mounting.
  """
  def on_mount(_params, _session, socket) do
    {:cont, assign(socket, :theme, Sigma.Session.ConfigManager.get_theme())}
  end
end
