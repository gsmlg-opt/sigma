defmodule Sigma.Web.RemoteSkillSourcesComponent do
  use Sigma.Web, :live_component
  alias Sigma.Session.{ConfigManager, Providers}
  alias Sigma.Session.Skills.Facade

  @impl true
  def mount(socket),
    do:
      {:ok,
       assign(socket,
         form: nil,
         deleting: nil,
         error: nil,
         browsing: nil,
         catalog: nil,
         catalog_state: :idle,
         query: "",
         catalog_request: nil
       )}

  @impl true
  def update(assigns, socket), do: {:ok, socket |> assign(assigns) |> refresh()}

  defp refresh(socket) do
    config = ConfigManager.get_config()

    assign(socket,
      sources: ConfigManager.skill_sources(),
      providers: config["providers"] || %{},
      credentials: config["credentials"] || %{}
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section id={@id} class="space-y-4 mb-8">
      <div class="flex flex-wrap items-center justify-between gap-3"><h3 class="text-xl font-bold">Remote sources</h3><.dm_btn id="remote-source-new" phx-click="new_remote_source" phx-target={@myself} phx-hook="WebComponentHook" variant="primary" size="sm">Add remote source</.dm_btn></div>
      <p :if={@error} class="text-error" role="alert">{@error}</p>
      <p :if={@sources == []} class="text-sm text-on-surface-variant">No remote sources configured.</p>
      <div class="grid gap-4 lg:grid-cols-2">
        <.dm_card :for={source <- @sources} variant="bordered" class="min-w-0 bg-surface-container-low">
          <:title>{source.name}</:title>
          <p class="font-mono text-xs break-all">{source.source_id}</p>
          <p class="text-sm mt-2">{source_status(source)}</p>
          <p class="text-sm text-on-surface-variant break-all">{source.base_url}</p>
          <p class="text-sm text-on-surface-variant">Credential: {credential_name(@credentials, source.credential_id)}</p>
          <p :if={Map.get(source, :provider_id) in [nil, ""]} class="text-sm text-on-surface-variant">Standalone source</p>
          <div class="flex flex-wrap gap-2 mt-4">
            <.dm_btn id={source_dom_id("browse", source.source_id)} phx-click="browse_remote_source" phx-value-id={source.source_id} phx-target={@myself} phx-hook="WebComponentHook" variant="outline" size="sm" disabled={!source.enabled? or source.offline?}>Browse</.dm_btn>
            <.dm_btn id={source_dom_id("edit", source.source_id)} phx-click="edit_remote_source" phx-value-id={source.source_id} phx-target={@myself} phx-hook="WebComponentHook" variant="outline" size="sm">Edit</.dm_btn>
            <.dm_btn id={source_dom_id("delete", source.source_id)} phx-click="confirm_delete_remote_source" phx-value-id={source.source_id} phx-target={@myself} phx-hook="WebComponentHook" variant="error" size="sm">Delete</.dm_btn>
          </div>
        </.dm_card>
      </div>
      <div :if={@browsing} id="remote-catalog" class="space-y-3 rounded-xl border border-outline-variant p-4">
        <h4 class="font-bold">Remote catalog: {@browsing}</h4>
        <form id="remote-catalog-search" phx-submit="search_remote_catalog" phx-target={@myself} class="flex flex-wrap items-end gap-3">
          <.dm_input name="query" value={@query} label="Search remote skills" />
          <.dm_btn native_submit variant="outline">Search</.dm_btn>
        </form>
        <p :if={@catalog_state == :loading} role="status">Loading remote catalog…</p>
        <p :if={@catalog && @catalog.items == []}>No remote skills match this search.</p>
        <div :if={@catalog} class="space-y-3">
          <article :for={skill <- @catalog.items} class="rounded-lg bg-surface-container-high p-3">
            <p class="font-bold">{skill.name}</p><p class="text-sm">{skill.description}</p>
            <p class="text-xs mt-2">Use this reference with the existing manual skill invocation:</p><code class="text-sm break-all">{skill.reference}</code>
            <p class="text-xs text-on-surface-variant">{skill.status}</p>
          </article>
          <.dm_btn :if={@catalog.next_cursor} id="remote-catalog-next" phx-click="next_remote_catalog" phx-target={@myself} phx-hook="WebComponentHook" variant="outline" disabled={@catalog_state == :loading}>Next page</.dm_btn>
        </div>
      </div>
      <.dm_modal :if={@form} id="remote-source-modal" phx-hook="ModalHook" hide_close={true}>
        <:title>{if @form["editing"], do: "Edit remote source", else: "Add remote source"}</:title>
        <:body>
          <p :if={@error} class="text-error" role="alert">{@error}</p>
          <form id="remote-source-form" phx-change="change_remote_source" phx-submit="save_remote_source" phx-target={@myself} class="space-y-4">
            <.dm_input name="source[id]" value={@form["id"]} label="Source ID" readonly={@form["editing"] == true} required />
            <.dm_input name="source[name]" value={@form["name"]} label="Display name" />
            <.dm_select name="source[provider_id]" value={@form["provider_id"]} label="Backplane provider" options={source_provider_options(@providers, @form)} />
            <.source_preview provider_id={@form["provider_id"]} credentials={@credentials} />
            <p :if={@form["provider_id"] == "" and @form["standalone"]} class="text-sm">This standalone source keeps its existing origin and credential. Select a provider to use a shared connection.</p>
            <.dm_select name="source[enabled]" value={@form["enabled"]} label="Enabled" options={[{"true", "Enabled"}, {"false", "Disabled"}]} />
            <.dm_select name="source[offline]" value={@form["offline"]} label="Access" options={[{"false", "Online"}, {"true", "Offline: verified cached skills only"}]} />
            <div class="flex gap-2"><.dm_btn native_submit variant="primary">Save source</.dm_btn><.dm_btn id="remote-source-cancel" phx-click="cancel_remote_source" phx-target={@myself} phx-hook="WebComponentHook" variant="ghost">Cancel</.dm_btn></div>
          </form>
        </:body>
      </.dm_modal>
      <.dm_modal :if={@deleting} id="remote-source-delete-modal" phx-hook="ModalHook" hide_close={true}>
        <:title>Delete remote source</:title><:body><p>Delete {@deleting}? Its remote skills will no longer be available through this source.</p></:body>
        <:footer><.dm_btn id="remote-source-confirm-delete" phx-click="delete_remote_source" phx-target={@myself} phx-hook="WebComponentHook" variant="error">Delete source</.dm_btn><.dm_btn id="remote-source-cancel-delete" phx-click="cancel_remote_source_delete" phx-target={@myself} phx-hook="WebComponentHook" variant="ghost">Cancel</.dm_btn></:footer>
      </.dm_modal>
    </section>
    """
  end

  defp source_preview(assigns) do
    assigns = assign(assigns, :service, Providers.resolve_service(assigns.provider_id, :skills))

    ~H"""
    <div :if={@provider_id != ""} class="rounded-lg bg-surface-container-high p-3 text-sm break-all">
      <%= case @service do %>
        <% {:ok, service} -> %>
          <p>Service origin: {service.origin}</p><p>Credential: {credential_name(@credentials, service.credential_id)}</p><p>Protocol: {service.origin <> "/skill-protocol/v1"}</p>
        <% _ -> %><p class="text-error" role="status">Provider unavailable. Check its service origin and credential.</p>
      <% end %>
    </div>
    """
  end

  @impl true
  def handle_event("new_remote_source", _, socket),
    do:
      {:noreply,
       assign(socket,
         form: %{
           "id" => "",
           "name" => "",
           "provider_id" => "",
           "enabled" => "true",
           "offline" => "false",
           "editing" => false,
           "standalone" => false
         },
         error: nil
       )}

  def handle_event("edit_remote_source", %{"id" => id}, socket) do
    case Enum.find(ConfigManager.skill_sources(), &(&1.source_id == id)) do
      nil ->
        {:noreply, assign(socket, :error, "Source is unavailable.")}

      source ->
        {:noreply,
         assign(socket,
           form: %{
             "id" => id,
             "name" => source.name,
             "provider_id" => Map.get(source, :provider_id) || "",
             "enabled" => to_string(source.enabled?),
             "offline" => to_string(source.offline?),
             "editing" => true,
             "standalone" => Map.get(source, :provider_id) in [nil, ""]
           },
           error: nil
         )}
    end
  end

  def handle_event("change_remote_source", %{"source" => attrs}, socket),
    do: {:noreply, assign(socket, :form, merge_source(socket.assigns.form, attrs))}

  def handle_event("cancel_remote_source", _, socket), do: {:noreply, assign(socket, :form, nil)}

  def handle_event("confirm_delete_remote_source", %{"id" => id}, socket),
    do: {:noreply, assign(socket, :deleting, id)}

  def handle_event("cancel_remote_source_delete", _, socket),
    do: {:noreply, assign(socket, :deleting, nil)}

  def handle_event("save_remote_source", params, socket) do
    form = merge_source(socket.assigns.form, params["source"] || %{})

    attrs = %{
      "name" => form["name"],
      "enabled" => form["enabled"] == "true",
      "offline" => form["offline"] == "true"
    }

    attrs =
      if form["provider_id"] != "",
        do: Map.put(attrs, "providerId", form["provider_id"]),
        else: attrs

    valid =
      if form["provider_id"] != "",
        do: match?({:ok, _}, Providers.resolve_service(form["provider_id"], :skills)),
        else: form["standalone"]

    duplicate? =
      not form["editing"] and
        Enum.any?(ConfigManager.skill_sources(), &(&1.source_id == form["id"]))

    if valid and not duplicate? do
      case ConfigManager.put_skill_source(form["id"], attrs) do
        {:ok, _} ->
          {:noreply,
           socket
           |> cancel_async(:remote_catalog)
           |> assign(form: nil, browsing: nil, catalog: nil, catalog_state: :idle, error: nil)
           |> refresh()}

        _ ->
          {:noreply,
           assign(socket,
             form: form,
             error: "Source could not be saved. Check its ID and provider."
           )}
      end
    else
      {:noreply, assign(socket, form: form, error: "Select an available Backplane provider.")}
    end
  end

  def handle_event("delete_remote_source", _, socket) do
    case ConfigManager.delete_skill_source(socket.assigns.deleting) do
      {:ok, _} ->
        {:noreply,
         socket
         |> cancel_async(:remote_catalog)
         |> assign(deleting: nil, browsing: nil, catalog: nil, catalog_state: :idle)
         |> refresh()}

      _ ->
        {:noreply, assign(socket, :error, "Source could not be deleted.")}
    end
  end

  def handle_event("browse_remote_source", %{"id" => id}, socket),
    do: {:noreply, socket |> assign(browsing: id, query: "") |> load_catalog(nil)}

  def handle_event("search_remote_catalog", %{"query" => query}, socket),
    do: {:noreply, socket |> assign(:query, query) |> load_catalog(nil)}

  def handle_event("next_remote_catalog", _, socket),
    do: {:noreply, load_catalog(socket, socket.assigns.catalog.next_cursor)}

  defp load_catalog(socket, cursor) do
    id = socket.assigns.browsing
    params = %{source_id: id, q: socket.assigns.query, cursor: cursor, limit: 20}
    snapshot = Enum.find(ConfigManager.skill_sources(), &(&1.source_id == id))

    socket
    |> assign(catalog: nil, catalog_state: :loading, error: nil, catalog_request: {id, snapshot})
    |> start_async(:remote_catalog, fn -> Facade.remote_catalog(params) end)
  end

  @impl true
  def handle_async(:remote_catalog, {:ok, result}, socket) do
    {id, snapshot} = socket.assigns.catalog_request
    current = Enum.find(ConfigManager.skill_sources(), &(&1.source_id == id))

    if id == socket.assigns.browsing and snapshot == current do
      case result do
        {:ok, catalog} ->
          {:noreply, assign(socket, catalog: catalog, catalog_state: :ready)}

        {:error, error} ->
          {:noreply,
           assign(socket, catalog: nil, catalog_state: :error, error: catalog_error(error))}
      end
    else
      {:noreply,
       assign(socket,
         catalog: nil,
         catalog_state: :idle,
         error: "Source connection changed. Browse it again."
       )}
    end
  end

  def handle_async(:remote_catalog, {:exit, _}, socket),
    do:
      {:noreply,
       assign(socket,
         catalog: nil,
         catalog_state: :error,
         error: "Remote catalog is unavailable. Try again."
       )}

  defp merge_source(form, attrs) do
    permitted =
      if form["editing"],
        do: ["name", "provider_id", "enabled", "offline"],
        else: ["id", "name", "provider_id", "enabled", "offline"]

    Map.merge(form, Map.take(attrs, permitted))
  end

  defp source_provider_options(providers, form) do
    options =
      providers
      |> Enum.filter(fn {_, p} -> p["kind"] == "backplane" end)
      |> Enum.map(fn {id, p} -> {id, p["name"] || id} end)
      |> Enum.sort_by(&elem(&1, 1))

    options =
      if form["provider_id"] not in [nil, ""] and
           not Enum.any?(options, &(elem(&1, 0) == form["provider_id"])),
         do: [{form["provider_id"], "Unavailable provider"} | options],
         else: options

    [
      {"",
       if(form["standalone"],
         do: "Existing standalone source",
         else: "Select a Backplane provider"
       )}
      | options
    ]
  end

  defp source_status(source) do
    cond do
      Map.get(source, :resolution_error) != nil -> "Provider unavailable"
      not source.enabled? -> "Disabled"
      source.offline? -> "Offline"
      true -> "Configured"
    end
  end

  defp credential_name(credentials, id),
    do: get_in(credentials, [id, "name"]) || "Unavailable credential"

  defp source_dom_id(action, id),
    do: "remote-source-#{action}-" <> Base.url_encode64(id, padding: false)

  defp catalog_error(%{reason: reason}) when reason in [:unauthorized, :forbidden],
    do: "Remote skill authentication failed. Check the provider credential."

  defp catalog_error(%{code: code})
       when code in ["unauthorized", "forbidden", "authentication_failed"],
       do: "Remote skill authentication failed. Check the provider credential."

  defp catalog_error(_),
    do: "Remote catalog is unavailable. Check the source connection and try again."
end
