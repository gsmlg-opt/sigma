defmodule ExPiWeb.SettingsLive do
  use ExPiWeb, :live_view

  alias ExPiSession.ConfigManager

  @impl true
  def mount(_params, _session, socket) do
    config = ConfigManager.get_config()

    {:ok,
     socket
     |> assign(:active_tab, :settings)
     |> assign(:config, config)
     |> assign(:active_provider_id, config["active_provider"])}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto py-12 px-6 text-on-surface">
      <div class="mb-12">
        <h1 class="font-display text-5xl font-bold mb-2 tracking-tight text-primary">Settings</h1>
        <p class="text-on-surface-variant text-lg">Configure your AI providers and models.</p>
      </div>

      <div class="grid grid-cols-1 md:grid-cols-3 gap-8">
        <!-- Sidebar -->
        <div class="space-y-2">
          <button
            :for={{id, provider} <- @config["providers"]}
            phx-click="select_provider"
            phx-value-id={id}
            class={[
              "w-full text-left p-4 rounded-xl transition-all duration-200 border",
              if(@active_provider_id == id,
                do: "bg-primary text-primary-content border-primary shadow-lg shadow-primary/20 scale-[1.02]",
                else: "bg-surface-container hover:bg-surface-container-high border-outline-variant"
              )
            ]}
          >
            <div class="font-bold">{provider["name"]}</div>
            <div class={[
              "text-xs opacity-70",
              if(@active_provider_id == id, do: "text-primary-content", else: "text-on-surface-variant")
            ]}>
              {if id == @config["active_provider"], do: "Active Provider", else: "Available"}
            </div>
          </button>
        </div>

        <!-- Main Settings Area -->
        <div class="md:col-span-2">
          <.dm_card variant="bordered" shadow="md" class="p-8">
            <:title>
              <div class="flex items-center justify-between w-full">
                <span class="text-2xl font-bold">
                  {@config["providers"][@active_provider_id]["name"]} Configuration
                </span>
                <.dm_btn
                  :if={@active_provider_id != @config["active_provider"]}
                  phx-click="set_active"
                  phx-value-id={@active_provider_id}
                  phx-hook="WebComponentHook"
                  variant="primary"
                  size="sm"
                >
                  Set as Active
                </.dm_btn>
                <div
                  :if={@active_provider_id == @config["active_provider"]}
                  class="bg-success/20 text-success text-[10px] font-bold px-3 py-1 rounded-full border border-success/30 uppercase tracking-widest"
                >
                  ACTIVE
                </div>
              </div>
            </:title>

            <form phx-submit="save_provider_config" class="space-y-6 mt-6">
              <input type="hidden" name="provider_id" value={@active_provider_id} />

              <div class="space-y-2">
                <label class="text-xs font-bold uppercase tracking-widest opacity-60">API Key</label>
                <.dm_input
                  type="password"
                  name="api_key"
                  value={@config["providers"][@active_provider_id]["api_key"]}
                  placeholder="Enter your API key..."
                  class="w-full"
                />
                <p class="text-[10px] text-on-surface-variant italic opacity-60">
                  Stored locally in apps/ex_pi_session/priv/config.json
                </p>
              </div>

              <div class="space-y-2">
                <label class="text-xs font-bold uppercase tracking-widest opacity-60">Base URL</label>
                <.dm_input
                  type="text"
                  name="base_url"
                  value={@config["providers"][@active_provider_id]["base_url"]}
                  placeholder="https://api.example.com"
                  class="w-full"
                />
              </div>

              <div class="space-y-2">
                <label class="text-xs font-bold uppercase tracking-widest opacity-60">
                  Default Model
                </label>
                <select
                  name="default_model"
                  class="w-full bg-surface-container rounded-xl border border-outline-variant p-3 text-on-surface focus:outline-none focus:ring-2 focus:ring-primary/20"
                >
                  <option
                    :for={model <- @config["providers"][@active_provider_id]["models"]}
                    value={model}
                    selected={model == @config["providers"][@active_provider_id]["default_model"]}
                  >
                    {model}
                  </option>
                </select>
              </div>

              <div class="pt-8 border-t border-outline-variant flex justify-end">
                <.dm_btn type="submit" variant="primary" size="lg" phx-hook="WebComponentHook">
                  Save Changes
                </.dm_btn>
              </div>
            </form>
          </.dm_card>
        </div>
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("select_provider", %{"id" => id}, socket) do
    {:noreply, assign(socket, active_provider_id: id)}
  end

  @impl true
  def handle_event("set_active", %{"id" => id}, socket) do
    ConfigManager.set_active_provider(id)

    {:noreply,
     socket
     |> assign(config: ConfigManager.get_config())
     |> put_flash(:info, "Active provider changed to #{id}")}
  end

  @impl true
  def handle_event("save_provider_config", params, socket) do
    %{
      "provider_id" => id,
      "api_key" => api_key,
      "base_url" => base_url,
      "default_model" => default_model
    } = params

    updates = %{
      "api_key" => api_key,
      "base_url" => base_url,
      "default_model" => default_model
    }

    ConfigManager.update_provider_config(id, updates)

    {:noreply,
     socket
     |> assign(config: ConfigManager.get_config())
     |> put_flash(:info, "Configuration saved successfully.")}
  end
end
