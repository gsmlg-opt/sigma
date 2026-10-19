defmodule Sigma.Web.ModelsSettingsComponent do
  use Sigma.Web, :live_component
  alias Sigma.Session.{ConfigManager, Models}

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       provider_id: "",
       query: "",
       candidates: nil,
       selected: MapSet.new(),
       discovery: :idle,
       discovery_request: nil,
       error: nil,
       editing: nil,
       removing: nil,
       manual: %{}
     )}
  end

  @impl true
  def update(assigns, socket), do: {:ok, socket |> assign(assigns) |> refresh()}

  defp refresh(socket) do
    config = ConfigManager.get_config()

    assign(socket,
      providers: config["providers"] || %{},
      rows: Models.list(config),
      default_pair: {config["active_provider_id"], config["default_model_id"]}
    )
  end

  @impl true
  def render(assigns) do
    assigns =
      assign(
        assigns,
        :visible_candidates,
        filter_candidates(assigns.candidates || [], assigns.query)
      )

    ~H"""
    <section id={@id} class="space-y-6">
      <div><h2 class="text-2xl font-bold">Models</h2><p class="text-sm text-on-surface-variant mt-1">Only configured models can be selected for sessions. Context budget is separate from a model's context window.</p></div>
      <p :if={@error} role="alert" class="text-error">{@error}</p>
      <form id="models-provider-filter" phx-change="select_provider" phx-target={@myself}>
        <.dm_select id="models-provider" name="provider_id" value={@provider_id} label="Provider" options={[{"", "All providers"} | provider_options(@providers)]} />
      </form>
      <p :if={@rows == []} class="text-on-surface-variant">No configured models. Select a provider to add models.</p>
      <div id="configured-models" class="grid gap-4 lg:grid-cols-2">
        <.dm_card :for={row <- @rows} :if={@provider_id == "" or row.provider_id == @provider_id} variant="bordered" class="bg-surface-container-low min-w-0">
          <:title>{row.name}</:title>
          <p class="text-sm break-all">{row.provider_name} / <code>{row.model_id}</code></p>
          <p class="text-sm text-on-surface-variant mt-2">Context budget: {row.default_context_limit || "Session fallback"}</p>
          <p :if={row.metadata["contextWindow"]} class="text-sm text-on-surface-variant">Context window: {row.metadata["contextWindow"]}</p>
          <p :if={@default_pair == {row.provider_id, row.model_id}} class="text-success text-sm">Global default</p>
          <div class="mt-4 flex flex-wrap gap-2">
            <.dm_btn id={row_id("default", row)} phx-click="default_model" phx-value-provider={row.provider_id} phx-value-model={row.model_id} phx-target={@myself} phx-hook="WebComponentHook" variant="outline" size="sm">Set global default</.dm_btn>
            <.dm_btn id={row_id("edit", row)} phx-click="edit_model" phx-value-provider={row.provider_id} phx-value-model={row.model_id} phx-target={@myself} phx-hook="WebComponentHook" variant="outline" size="sm">Edit</.dm_btn>
            <.dm_btn id={row_id("remove", row)} phx-click="confirm_remove_model" phx-value-provider={row.provider_id} phx-value-model={row.model_id} phx-target={@myself} phx-hook="WebComponentHook" variant="error" size="sm">Remove</.dm_btn>
          </div>
        </.dm_card>
      </div>
      <div :if={@provider_id != ""} class="space-y-5 rounded-xl border border-outline-variant p-4">
        <h3 class="text-lg font-bold">Add models</h3>
        <form id="model-manual-form" phx-submit="add_manual_model" phx-target={@myself} class="grid gap-3 md:grid-cols-3">
          <.dm_input name="model[id]" value={@manual["id"] || ""} label="Model ID" required />
          <.dm_input name="model[name]" value={@manual["name"] || ""} label="Display name" />
          <.dm_input name="model[defaultContextLimit]" value={@manual["defaultContextLimit"] || ""} label="Default context budget" type="number" min="1" placeholder="Session fallback" />
          <.dm_btn id="model-manual-add" native_submit variant="primary">Add model</.dm_btn>
        </form>
        <.dm_btn id="models-discover" phx-click="discover_models" phx-target={@myself} phx-hook="WebComponentHook" variant="outline" disabled={@discovery == :loading}>Discover candidates</.dm_btn>
        <p :if={@discovery == :loading} role="status">Loading model candidates…</p>
        <div :if={is_list(@candidates)} class="space-y-3">
          <form id="model-candidate-search" phx-change="search_candidates" phx-target={@myself}>
            <.dm_input name="query" value={@query} label="Search candidates" />
          </form>
          <p :if={@candidates == []}>No models discovered. You can add a model manually.</p>
          <p :if={@candidates != [] and @visible_candidates == []}>No candidates match your search.</p>
          <div :for={candidate <- @visible_candidates} class="flex items-center gap-3 rounded-lg border border-outline-variant p-3">
            <.dm_checkbox id={candidate_id(candidate["id"])} name="candidate" value={candidate["id"]} checked={MapSet.member?(@selected, candidate["id"])} disabled={configured?(@rows, @provider_id, candidate["id"])} phx-click="toggle_candidate" phx-value-id={candidate["id"]} phx-target={@myself} label={candidate["name"] || candidate["id"]} />
            <code class="text-xs break-all">{candidate["id"]}</code>
            <span :if={configured?(@rows, @provider_id, candidate["id"])} class="text-sm text-on-surface-variant">Already configured</span>
          </div>
          <.dm_btn id="models-add-selected" phx-click="add_selected_models" phx-target={@myself} phx-hook="WebComponentHook" variant="primary" disabled={MapSet.size(@selected) == 0}>Add selected ({MapSet.size(@selected)})</.dm_btn>
        </div>
      </div>
      <.dm_modal :if={@editing} id="model-edit-modal" phx-hook="ModalHook" hide_close={true}>
        <:title>Edit model</:title>
        <:body>
          <p :if={@error} class="text-error" role="alert">{@error}</p>
          <form id="model-edit-form" phx-submit="save_model" phx-target={@myself} class="space-y-4">
            <p class="text-sm break-all">{@editing.provider_id} / {@editing.model_id}</p>
            <.dm_input name="model[name]" value={@editing.name} label="Display name" />
            <.dm_input name="model[defaultContextLimit]" value={@editing.default_context_limit || ""} label="Default context budget" type="number" min="1" placeholder="Session fallback" />
            <div class="flex gap-2"><.dm_btn native_submit variant="primary">Save model</.dm_btn><.dm_btn id="model-cancel-edit" phx-click="cancel_model_edit" phx-target={@myself} phx-hook="WebComponentHook" variant="ghost">Cancel</.dm_btn></div>
          </form>
        </:body>
      </.dm_modal>
      <.dm_modal :if={@removing} id="model-remove-modal" phx-hook="ModalHook" hide_close={true}>
        <:title>Remove model</:title>
        <:body><p>Remove {@removing.name}? Removing the global default also clears the default selection.</p></:body>
        <:footer><.dm_btn id="model-confirm-remove" phx-click="remove_model" phx-target={@myself} phx-hook="WebComponentHook" variant="error">Remove model</.dm_btn><.dm_btn id="model-cancel-remove" phx-click="cancel_model_remove" phx-target={@myself} phx-hook="WebComponentHook" variant="ghost">Cancel</.dm_btn></:footer>
      </.dm_modal>
    </section>
    """
  end

  @impl true
  def handle_event("select_provider", %{"provider_id" => id}, socket) do
    {:noreply,
     socket
     |> cancel_async(:model_discovery)
     |> assign(
       provider_id: id,
       candidates: nil,
       selected: MapSet.new(),
       query: "",
       discovery: :idle,
       discovery_request: nil,
       error: nil
     )
     |> refresh()}
  end

  def handle_event("add_manual_model", %{"model" => attrs}, socket) do
    with {:ok, attrs} <- model_attrs(attrs),
         {:ok, _} <- Models.add(socket.assigns.provider_id, [attrs]) do
      {:noreply, socket |> assign(manual: %{}, error: nil) |> refresh()}
    else
      _ ->
        {:noreply,
         assign(socket,
           manual: attrs,
           error:
             "Enter a model ID and a positive integer context budget, or leave the budget blank."
         )}
    end
  end

  def handle_event("edit_model", params, socket),
    do: {:noreply, assign(socket, editing: find_row(socket, params), error: nil)}

  def handle_event("cancel_model_edit", _, socket),
    do: {:noreply, assign(socket, editing: nil, error: nil)}

  def handle_event("confirm_remove_model", params, socket),
    do: {:noreply, assign(socket, :removing, find_row(socket, params))}

  def handle_event("cancel_model_remove", _, socket),
    do: {:noreply, assign(socket, :removing, nil)}

  def handle_event("save_model", %{"model" => attrs}, %{assigns: %{editing: row}} = socket)
      when not is_nil(row) do
    with {:ok, attrs} <- model_attrs(Map.put(attrs, "id", row.model_id)),
         {:ok, _} <- Models.update(row.provider_id, row.model_id, Map.delete(attrs, "id")) do
      {:noreply, socket |> assign(editing: nil, error: nil) |> refresh()}
    else
      _ ->
        {:noreply,
         assign(
           socket,
           :error,
           "Enter a positive integer context budget, or leave the budget blank."
         )}
    end
  end

  def handle_event("remove_model", _, %{assigns: %{removing: row}} = socket)
      when not is_nil(row) do
    {:noreply,
     apply_result(socket, Models.remove(row.provider_id, row.model_id)) |> assign(:removing, nil)}
  end

  def handle_event("default_model", %{"provider" => pid, "model" => mid}, socket),
    do: {:noreply, apply_result(socket, Models.set_default(pid, mid))}

  def handle_event("discover_models", _, socket) do
    pid = socket.assigns.provider_id
    config = ConfigManager.get_provider_config(pid)

    if config do
      opts = Application.get_env(:sigma_web, :model_discovery_options, [])
      snapshot = connection_snapshot(pid)

      {:noreply,
       socket
       |> assign(
         discovery: :loading,
         candidates: nil,
         selected: MapSet.new(),
         error: nil,
         discovery_request: {pid, snapshot}
       )
       |> start_async(:model_discovery, fn -> Sigma.Ai.ModelDiscovery.discover(config, opts) end)}
    else
      {:noreply, assign(socket, :error, "Provider connection is unavailable.")}
    end
  end

  def handle_event("search_candidates", %{"query" => query}, socket),
    do: {:noreply, assign(socket, :query, query)}

  def handle_event("toggle_candidate", %{"id" => id}, socket) do
    selected = socket.assigns.selected

    valid? =
      Enum.any?(socket.assigns.candidates || [], &(&1["id"] == id)) and
        not configured?(socket.assigns.rows, socket.assigns.provider_id, id)

    selected =
      if valid?,
        do:
          if(MapSet.member?(selected, id),
            do: MapSet.delete(selected, id),
            else: MapSet.put(selected, id)
          ),
        else: selected

    {:noreply, assign(socket, :selected, selected)}
  end

  def handle_event("add_selected_models", _, socket) do
    if current_request?(socket) do
      attrs =
        Enum.filter(
          socket.assigns.candidates || [],
          &MapSet.member?(socket.assigns.selected, &1["id"])
        )

      {:noreply,
       apply_result(socket, Models.add(socket.assigns.provider_id, attrs))
       |> assign(:selected, MapSet.new())}
    else
      {:noreply,
       assign(socket,
         candidates: nil,
         selected: MapSet.new(),
         error: "Provider connection changed. Discover candidates again."
       )}
    end
  end

  @impl true
  def handle_async(:model_discovery, {:ok, result}, socket) do
    if current_request?(socket) do
      case result do
        {:ok, candidates} ->
          {:noreply, assign(socket, discovery: :ready, candidates: candidates)}

        {:error, code} ->
          {:noreply, assign(socket, discovery: :error, error: discovery_error(code))}
      end
    else
      {:noreply,
       assign(socket,
         discovery: :idle,
         candidates: nil,
         error: "Provider connection changed. Discover candidates again."
       )}
    end
  end

  def handle_async(:model_discovery, {:exit, _}, socket),
    do:
      {:noreply,
       assign(socket,
         discovery: :error,
         error: "Model discovery is unavailable. Try again or add a model manually."
       )}

  defp current_request?(socket) do
    case socket.assigns.discovery_request do
      {pid, snapshot} ->
        pid == socket.assigns.provider_id and
          snapshot == connection_snapshot(pid)

      _ ->
        false
    end
  end

  defp connection_snapshot(pid) do
    case ConfigManager.get_provider_config(pid) do
      nil ->
        nil

      provider ->
        Map.take(provider, [
          "kind",
          "service_origin",
          "api_type",
          "base_url",
          "credential_id",
          "auth_type",
          "auth_header_name",
          "resolved_key"
        ])
    end
  end

  defp model_attrs(attrs) do
    id = String.trim(attrs["id"] || "")
    budget = String.trim(to_string(attrs["defaultContextLimit"] || ""))

    case {id, Integer.parse(budget)} do
      {"", _} ->
        {:error, :invalid_id}

      {_, {n, ""}} when n > 0 ->
        {:ok, Map.merge(attrs, %{"id" => id, "defaultContextLimit" => n})}

      {_, _} when budget == "" ->
        {:ok, Map.merge(attrs, %{"id" => id, "defaultContextLimit" => nil})}

      _ ->
        {:error, :invalid_budget}
    end
  end

  defp find_row(_socket, %{"provider" => pid, "model" => mid}),
    do: Enum.find(Models.list(), &(&1.provider_id == pid and &1.model_id == mid))

  defp apply_result(socket, {:ok, _}), do: socket |> assign(:error, nil) |> refresh()

  defp apply_result(socket, _),
    do:
      socket
      |> assign(
        :error,
        "Model is unavailable or could not be saved. Refresh the page and try again."
      )
      |> refresh()

  defp configured?(rows, pid, mid),
    do: Enum.any?(rows, &(&1.provider_id == pid and &1.model_id == mid))

  defp provider_options(providers),
    do:
      providers |> Enum.map(fn {id, p} -> {id, p["name"] || id} end) |> Enum.sort_by(&elem(&1, 1))

  defp row_id(action, row),
    do:
      "model-#{action}-" <>
        Base.url_encode64(row.provider_id <> ":" <> row.model_id, padding: false)

  defp candidate_id(id), do: "candidate-" <> URI.encode(id, &URI.char_unreserved?/1)

  defp filter_candidates(candidates, query) do
    query = String.downcase(String.trim(query))

    Enum.filter(
      candidates,
      &String.contains?(String.downcase((&1["name"] || "") <> " " <> &1["id"]), query)
    )
  end

  defp discovery_error(code) when code in [:unauthorized, :authentication_failed, :forbidden],
    do: "Provider authentication failed. Check its credential."

  defp discovery_error(:unsupported),
    do: "Discovery is unavailable for this API. Add a model manually."

  defp discovery_error(_),
    do: "Model discovery is unavailable. Try again or add a model manually."
end
