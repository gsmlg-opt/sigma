defmodule Sigma.Web.PluginsSettingsComponent do
  use Sigma.Web, :live_component

  alias Sigma.Agent.PluginInstallations

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       initialized: false,
       host: nil,
       page: nil,
       loading: false,
       installing: nil,
       installation: nil,
       error: nil,
       notice: nil
     )}
  end

  @impl true
  def update(assigns, socket) do
    refresh? = not socket.assigns.initialized or Map.get(assigns, :refresh, false)
    socket = assign(socket, assigns)
    {:ok, if(refresh?, do: load_page(socket, %{}), else: socket)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section id={@id} class="space-y-6">
      <div class="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h2 class="text-2xl font-bold">Plugins</h2>
          <p class="mt-1 text-sm text-on-surface-variant">Review plugin requests and install their packages. Installed skills are available on the next agent turn.</p>
        </div>
        <.dm_btn id="plugins-refresh" phx-click="refresh_plugins" phx-target={@myself} phx-hook="WebComponentHook" variant="outline" disabled={@loading}>Refresh</.dm_btn>
      </div>

      <p :if={@notice} role="status" class="text-on-surface-variant">{@notice}</p>
      <p :if={@error} id="plugins-error" role="alert" class="text-error">{@error}</p>
      <p :if={@loading} role="status">Loading plugin requests…</p>
      <p :if={@installing} role="status">Installing the requested plugin package…</p>

      <div :if={@installation} id="plugin-installation-result" role="status" class="rounded-xl border border-success/30 bg-success/10 p-4 space-y-2">
        <p class="font-bold">Installed {@installation["pluginId"]}</p>
        <p class="text-sm break-all">Release: {@installation["releaseId"]}</p>
        <p class="text-xs text-on-surface-variant break-all">Registry: {@installation["registryUrl"]}</p>
        <p class="text-sm">Its skills will be available on the next agent turn.</p>
      </div>

      <%= if @page do %>
        <%= if @page["configured"] do %>
          <p class="text-sm text-on-surface-variant break-all">Registry: {@page["registryUrl"]}</p>
          <p :if={@page["total"] == 0} id="plugins-empty" class="text-on-surface-variant">No plugin installation requests yet.</p>
          <div id="plugin-requests" class="grid gap-4 lg:grid-cols-2">
            <.dm_card :for={request <- @page["items"]} id={request_dom_id(request["requestId"])} variant="bordered" class="min-w-0 bg-surface-container-low">
              <:title>{request["pluginId"]}</:title>
              <p class="text-sm font-medium">{status_label(request["status"])}</p>
              <p :if={request["releaseId"]} class="mt-2 text-sm break-all">Release: {request["releaseId"]}</p>
              <p class="mt-2 text-xs text-on-surface-variant break-all">Request: {request["requestId"]}</p>
              <p class="text-xs text-on-surface-variant">Requested: {format_time(request["requestedAt"])}</p>
              <.dm_btn :if={request["status"] in ["requested", "installing"]} id={install_dom_id(request["requestId"])} phx-click="install_plugin" phx-value-request-id={request["requestId"]} phx-target={@myself} phx-hook="WebComponentHook" variant="primary" size="sm" class="mt-4" disabled={@installing != nil or @loading}>
                {if request["status"] == "installing", do: "Check installation", else: "Install package"}
              </.dm_btn>
            </.dm_card>
          </div>
          <div :if={@page["total"] > 0} class="flex flex-wrap items-center gap-3">
            <p id="plugin-page-position" class="text-sm text-on-surface-variant">Showing {@page["offset"] + 1}–{@page["offset"] + length(@page["items"])} of {@page["total"]}</p>
            <.dm_btn :if={@page["offset"] > 0} id="plugins-first" phx-click="refresh_plugins" phx-target={@myself} phx-hook="WebComponentHook" variant="outline" disabled={@loading}>First page</.dm_btn>
            <.dm_btn :if={@page["nextOffset"] != nil} id="plugins-next" phx-click="next_plugins" phx-target={@myself} phx-hook="WebComponentHook" variant="outline" disabled={@loading}>Next page</.dm_btn>
          </div>
        <% else %>
          <p id="plugins-unconfigured" class="text-on-surface-variant">No plugin registry is configured.</p>
        <% end %>
      <% end %>
    </section>
    """
  end

  @impl true
  def handle_event("refresh_plugins", _, socket),
    do: {:noreply, socket |> assign(:notice, nil) |> load_page(%{})}

  def handle_event("next_plugins", _, %{assigns: %{page: page}} = socket) do
    if page && page["nextOffset"] != nil do
      {:noreply,
       load_page(socket, %{
         "offset" => page["nextOffset"],
         "expectedRevision" => page["revision"]
       })}
    else
      {:noreply, socket}
    end
  end

  def handle_event("install_plugin", %{"request-id" => request_id}, socket) do
    page = socket.assigns.page

    available? =
      not is_nil(page) and
        Enum.any?(page["items"], fn request ->
          request["requestId"] == request_id and request["status"] in ["requested", "installing"]
        end)

    if available? and socket.assigns.installing == nil and not socket.assigns.loading do
      host = socket.assigns.host

      {:noreply,
       socket
       |> assign(installing: request_id, error: nil, notice: nil)
       |> start_async(:plugin_install, fn ->
         PluginInstallations.install(host, request_id, :settings)
       end)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_async(:plugin_requests, {:ok, {:ok, host, page}}, socket),
    do: {:noreply, assign(socket, host: host, page: page, loading: false, error: nil)}

  def handle_async(:plugin_requests, {:ok, {:error, :plugin_requests_stale}}, socket) do
    {:noreply,
     socket
     |> assign(:notice, "Plugin requests changed. Showing the first page again.")
     |> load_page(%{})}
  end

  def handle_async(:plugin_requests, {:ok, {:error, reason}}, socket),
    do: {:noreply, assign(socket, loading: false, error: error_message(reason))}

  def handle_async(:plugin_requests, {:exit, _reason}, socket),
    do:
      {:noreply,
       assign(socket,
         loading: false,
         error: "Plugin requests could not be loaded. Refresh to check again."
       )}

  def handle_async(:plugin_install, {:ok, {:ok, installation}}, socket) do
    {:noreply,
     socket
     |> assign(installing: nil, installation: installation, error: nil)
     |> load_page(%{})}
  end

  def handle_async(:plugin_install, {:ok, {:error, reason}}, socket),
    do: {:noreply, assign(socket, installing: nil, error: error_message(reason))}

  def handle_async(:plugin_install, {:exit, _reason}, socket),
    do:
      {:noreply,
       assign(socket,
         installing: nil,
         error: "Installation result is unconfirmed. Refresh to check the saved installation."
       )}

  defp load_page(socket, request) do
    socket
    |> assign(initialized: true, loading: true, error: nil)
    |> start_async(:plugin_requests, fn ->
      with {:ok, host} <- PluginInstallations.configured(),
           {:ok, page} <- PluginInstallations.list(host, request),
           do: {:ok, host, page}
    end)
  end

  defp request_dom_id(id), do: "plugin-request-" <> Base.url_encode64(id, padding: false)
  defp install_dom_id(id), do: "plugin-install-" <> Base.url_encode64(id, padding: false)

  defp status_label("requested"), do: "Requested"
  defp status_label("installing"), do: "Installation unconfirmed"
  defp status_label("installed"), do: "Installed"
  defp status_label("failed"), do: "Installation failed"

  defp format_time(timestamp) when is_integer(timestamp) do
    case DateTime.from_unix(timestamp, :microsecond) do
      {:ok, time} -> Calendar.strftime(time, "%Y-%m-%d %H:%M UTC")
      _ -> "Unknown"
    end
  end

  defp format_time(_timestamp), do: "Unknown"

  defp error_message(%{message: message}) when is_binary(message), do: message
  defp error_message(:plugin_host_unconfigured), do: "No plugin registry is configured."
  defp error_message(_reason), do: "Plugin operation failed. Refresh to check its saved state."
end
