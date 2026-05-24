defmodule PiWeb.SettingsLive do
  use PiWeb, :live_view

  alias PiSession.{ConfigManager, Skills}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:active_tab, :settings)
     |> load_config()}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    # Default to providers if root /settings is visited
    socket =
      if socket.assigns.live_action == :index do
        socket |> push_patch(to: ~p"/settings/providers")
      else
        socket
      end

    socket =
      socket
      |> assign(:selected_id, nil)
      |> maybe_load_skills()

    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-6xl mx-auto py-12 px-6 text-on-surface">
      <div class="mb-12 flex justify-between items-end text-on-surface">
        <div>
          <h1 class="font-display text-5xl font-bold mb-2 tracking-tight text-primary">Settings</h1>
          <p class="text-on-surface-variant text-lg">Manage API credentials, AI provider configurations, and agent resources.</p>
        </div>
      </div>

      <div class="grid grid-cols-1 md:grid-cols-4 gap-8">
        <!-- Sidebar Navigation -->
        <aside class="bg-secondary text-secondary-content rounded-2xl p-4 space-y-4">
          <nav class="flex flex-col gap-2">
            <.dm_link
              patch={~p"/settings/providers"}
              class={["p-4 rounded-2xl border transition-all flex items-center gap-3 font-bold",
                if(@live_action == :providers,
                   do: "bg-primary text-primary-content border-primary shadow-lg",
                   else: "border-secondary-content/20 hover:bg-secondary-content/10 text-secondary-content"
                )]}
            >
              <.dm_mdi name="robot-outline" class="w-5 h-5" />
              <span>Providers</span>
            </.dm_link>

            <.dm_link
              patch={~p"/settings/credentials"}
              class={["p-4 rounded-2xl border transition-all flex items-center gap-3 font-bold",
                if(@live_action == :credentials,
                   do: "bg-primary text-primary-content border-primary shadow-lg",
                   else: "border-secondary-content/20 hover:bg-secondary-content/10 text-secondary-content"
                )]}
            >
              <.dm_mdi name="key-outline" class="w-5 h-5" />
              <span>Credentials</span>
            </.dm_link>

            <.dm_link
              patch={~p"/settings/system_prompt"}
              class={["p-4 rounded-2xl border transition-all flex items-center gap-3 font-bold",
                if(@live_action == :system_prompt,
                  do: "bg-primary text-primary-content border-primary shadow-lg",
                  else: "border-secondary-content/20 hover:bg-secondary-content/10 text-secondary-content"
                )]}
            >
              <.dm_mdi name="text-box-outline" class="w-5 h-5" />
              <span>System Prompt</span>
            </.dm_link>

            <.dm_link
              patch={~p"/settings/skills"}
              class={["p-4 rounded-2xl border transition-all flex items-center gap-3 font-bold",
                if(@live_action == :skills,
                  do: "bg-primary text-primary-content border-primary shadow-lg",
                  else: "border-secondary-content/20 hover:bg-secondary-content/10 text-secondary-content"
                )]}
            >
              <.dm_mdi name="auto-fix" class="w-5 h-5" />
              <span>Skills</span>
            </.dm_link>
          </nav>
        </aside>

        <!-- Main Content -->
        <main class="md:col-span-3">
          <%= case @live_action do %>
            <% :providers -> %>
              <.render_providers 
                providers={@config["providers"]} 
                credentials={@config["credentials"]}
                active_id={@config["active_provider_id"]}
              />
            <% :credentials -> %>
              <.render_credentials 
                credentials={@config["credentials"]}
              />
            <% :system_prompt -> %>
              <.render_system_prompt system_prompt={@config["system_prompt"]} />
            <% :skills -> %>
              <.render_skills result={@global_skills_result} />
          <% end %>
        </main>
      </div>
    </div>
    """
  end

  defp render_providers(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex justify-between items-center text-on-surface">
        <h2 class="text-2xl font-bold font-display">AI Providers</h2>
        <.dm_btn phx-click="add_provider" phx-hook="WebComponentHook" variant="primary" size="sm">
          <:prefix><.dm_mdi name="plus" /></:prefix>
          New Provider
        </.dm_btn>
      </div>

      <div class="grid grid-cols-1 gap-4">
        <.dm_card :for={{id, p} <- @providers} variant="bordered" class="bg-surface-container-low overflow-hidden">
          <:title>
            <div class="flex items-center justify-between w-full text-on-surface">
              <div class="flex items-center gap-3">
                <div class="p-2 bg-primary/10 rounded-lg text-primary">
                   <.dm_mdi name={if p["api_type"] == "anthropic", do: "alpha-a-box", else: "alpha-o-box"} class="w-5 h-5" />
                </div>
                <div>
                  <div class="font-bold">{p["name"]}</div>
                  <div class="text-[10px] opacity-40 uppercase tracking-widest">{p["api_type"]}</div>
                </div>
              </div>
              <div class="flex items-center gap-2">
                <div :if={@active_id == id} class="bg-success/20 text-success text-[10px] font-bold px-3 py-1 rounded-full border border-success/30">
                  ACTIVE
                </div>
                <.dm_btn :if={@active_id != id} phx-click="set_active_provider" phx-value-id={id} phx-hook="WebComponentHook" variant="outline" size="xs">
                   Activate
                </.dm_btn>
              </div>
            </div>
          </:title>

          <form phx-submit="save_provider" class="grid grid-cols-1 md:grid-cols-2 gap-4 py-2">
            <input type="hidden" name="config_id" value={id} />
            <div class="space-y-1">
              <label class="text-[10px] font-bold opacity-40 uppercase tracking-wider text-on-surface">Display Name</label>
              <.dm_input name="name" value={p["name"]} class="w-full" size="sm" />
            </div>
            <div class="space-y-1">
              <.dm_select name="api_type" value={p["api_type"]} label="API Type" size="sm" class="w-full">
                <option value="anthropic" selected={p["api_type"] == "anthropic"}>Anthropic</option>
                <option value="openai" selected={p["api_type"] == "openai"}>OpenAI</option>
              </.dm_select>
            </div>
            <div class="space-y-1">
              <.dm_select name="credential_id" value={p["credential_id"]} label="Credential (API Key)" prompt="No Key Selected" size="sm" class="w-full">
                <option :for={{cid, c} <- @credentials} value={cid} selected={p["credential_id"] == cid}>{c["name"]}</option>
              </.dm_select>
            </div>
            <div class="space-y-1">
              <label class="text-[10px] font-bold opacity-40 uppercase tracking-wider text-on-surface">Model ID (Manual Input)</label>
              <.dm_input name="model" value={p["model"]} placeholder="e.g. gpt-4o" class="w-full" size="sm" />
            </div>
            <div class="md:col-span-2 space-y-1">
              <label class="text-[10px] font-bold opacity-40 uppercase tracking-wider text-on-surface">Base URL</label>
              <.dm_input name="base_url" value={p["base_url"]} class="w-full" size="sm" />
            </div>

            <div class="md:col-span-2 flex justify-between items-center pt-4 border-t border-outline-variant mt-2">
               <.dm_btn type="button" variant="error" size="sm" class="opacity-40 hover:opacity-100 transition-opacity" confirm="Are you sure you want to delete this provider?" confirm_title="Delete Provider">
                 <:confirm_action>
                   <.dm_btn type="button" variant="ghost" onclick="this.closest('el-dm-dialog').close()">
                     Cancel
                   </.dm_btn>
                   <.dm_btn type="button" phx-click="delete_provider" phx-value-id={id} phx-hook="WebComponentHook" variant="error" onclick="this.closest('el-dm-dialog').close()">
                     Delete
                   </.dm_btn>
                 </:confirm_action>
                 <.dm_mdi name="delete-outline" />
               </.dm_btn>
               <.dm_btn type="submit" phx-hook="WebComponentHook" variant="primary" size="sm">
                 Save Provider
               </.dm_btn>
            </div>
          </form>
        </.dm_card>
      </div>
    </div>
    """
  end

  defp render_credentials(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex justify-between items-center text-on-surface">
        <h2 class="text-2xl font-bold font-display">API Credentials</h2>
        <.dm_btn phx-click="add_credential" phx-hook="WebComponentHook" variant="primary" size="sm">
          <:prefix><.dm_mdi name="plus" /></:prefix>
          Add Key
        </.dm_btn>
      </div>

      <div class="grid grid-cols-1 gap-4">
        <.dm_card :for={{id, c} <- @credentials} variant="bordered" class="bg-surface-container-low">
          <form phx-submit="save_credential" class="flex flex-col md:flex-row items-end gap-4">
            <input type="hidden" name="config_id" value={id} />
            <div class="flex-1 w-full space-y-1">
              <label class="text-[10px] font-bold opacity-40 uppercase tracking-wider text-on-surface">Key Name</label>
              <.dm_input name="name" value={c["name"]} class="w-full" size="sm" />
            </div>
            <div class="flex-1 w-full space-y-1">
              <label class="text-[10px] font-bold opacity-40 uppercase tracking-wider text-on-surface">Secret Key</label>
              <.dm_input type="password" name="key" value={c["key"]} placeholder="sk-..." class="w-full" size="sm" />
            </div>
            <div class="flex gap-2">
               <.dm_btn type="submit" phx-hook="WebComponentHook" variant="primary" size="sm">
                 Save
               </.dm_btn>
               <.dm_btn type="button" variant="error" size="sm" shape="circle" confirm="Are you sure you want to delete this credential?" confirm_title="Delete Credential">
                 <:confirm_action>
                   <.dm_btn type="button" variant="ghost" onclick="this.closest('el-dm-dialog').close()">
                     Cancel
                   </.dm_btn>
                   <.dm_btn type="button" phx-click="delete_credential" phx-value-id={id} phx-hook="WebComponentHook" variant="error" onclick="this.closest('el-dm-dialog').close()">
                     Delete
                   </.dm_btn>
                 </:confirm_action>
                 <.dm_mdi name="delete-outline" />
               </.dm_btn>
            </div>
          </form>
        </.dm_card>
      </div>
    </div>
    """
  end

  defp render_system_prompt(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex justify-between items-center text-on-surface">
        <h2 class="text-2xl font-bold font-display">System Prompt</h2>
      </div>

      <.dm_card variant="bordered" class="bg-surface-container-low">
        <form phx-submit="save_system_prompt" class="space-y-4">
          <.dm_markdown_input
            id="system-prompt-editor"
            phx-update="ignore"
            phx-hook="MarkdownInputHook"
            name="system_prompt"
            value={@system_prompt}
            label="Base Instructions"
            class="w-full"
          />

          <div class="flex justify-end pt-4 border-t border-outline-variant">
             <.dm_btn type="submit" phx-hook="WebComponentHook" variant="primary" size="md">
               Save System Prompt
             </.dm_btn>
          </div>
        </form>
      </.dm_card>

      <div class="bg-primary/5 rounded-2xl p-6 border border-primary/10">
        <div class="flex items-center gap-2 text-primary mb-2">
          <.dm_mdi name="information-outline" class="w-5 h-5" />
          <span class="font-bold">About the System Prompt</span>
        </div>
        <p class="text-sm text-on-surface-variant leading-relaxed">
          The system prompt defines the core identity and rules for the agent. 
          It is sent at the beginning of every session to ensure the AI follows specific formatting and safety guidelines.
        </p>
      </div>
    </div>
    """
  end

  defp render_skills(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex justify-between items-center text-on-surface">
        <div>
          <h2 class="text-2xl font-bold font-display">Skills</h2>
          <p class="text-sm text-on-surface-variant font-mono mt-1">{@result.dir}</p>
        </div>
      </div>

      <div
        :if={Enum.empty?(@result.skills)}
        class="rounded-2xl border border-dashed border-outline-variant bg-surface-container-low p-8 text-center"
      >
        <.dm_mdi name="auto-fix-off" class="w-10 h-10 mx-auto text-on-surface-variant opacity-40 mb-3" />
        <p class="font-semibold text-on-surface">No global skills found</p>
      </div>

      <div :if={!Enum.empty?(@result.skills)} class="grid grid-cols-1 gap-4">
        <.dm_card :for={skill <- @result.skills} variant="bordered" class="bg-surface-container-low">
          <:title>
            <div class="flex items-center gap-3 py-1 min-w-0">
              <div class="p-2 bg-primary/10 rounded-lg text-primary shrink-0">
                <.dm_mdi name="auto-fix" class="w-5 h-5" />
              </div>
              <div class="min-w-0">
                <div class="font-bold text-lg truncate">{skill.name}</div>
                <div :if={skill.disable_model_invocation?} class="text-[10px] opacity-50 uppercase tracking-widest">
                  Manual invocation
                </div>
              </div>
            </div>
          </:title>

          <div class="space-y-3">
            <p class="text-sm text-on-surface-variant leading-relaxed">{skill.description}</p>
            <code class="block text-[11px] font-mono text-on-surface-variant break-all bg-surface-container-high rounded-lg p-3">
              {skill.path}
            </code>
          </div>
        </.dm_card>
      </div>

      <div :if={!Enum.empty?(@result.diagnostics)} class="rounded-2xl border border-warning/30 bg-warning/10 p-4 text-warning">
        <div class="flex items-center gap-2 font-bold mb-2">
          <.dm_mdi name="alert-outline" class="w-5 h-5" />
          <span>Some skills could not be loaded</span>
        </div>
        <ul class="space-y-1 text-sm">
          <li :for={diagnostic <- @result.diagnostics}>
            <code class="font-mono break-all">{diagnostic.path}</code>: {diagnostic.message}
          </li>
        </ul>
      </div>
    </div>
    """
  end

  # Handlers

  @impl true
  def handle_event("theme_changed", _, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("load_config", _, socket) do
    {:noreply, load_config(socket)}
  end

  # Provider Handlers

  @impl true
  def handle_event("add_provider", _, socket) do
    ConfigManager.add_provider(%{
      "name" => "New Provider",
      "api_type" => "anthropic",
      "credential_id" => "",
      "model" => "claude-3-5-sonnet-latest",
      "base_url" => "https://api.anthropic.com"
    })

    {:noreply, load_config(socket)}
  end

  @impl true
  def handle_event("save_provider", params, socket) do
    %{"config_id" => id} = params
    updates = Map.drop(params, ["config_id", "_csrf_token"])
    ConfigManager.update_provider(id, updates)
    {:noreply, socket |> load_config() |> put_flash(:info, "Provider updated")}
  end

  @impl true
  def handle_event("delete_provider", %{"id" => id}, socket) do
    ConfigManager.delete_provider(id)
    {:noreply, load_config(socket)}
  end

  @impl true
  def handle_event("set_active_provider", %{"id" => id}, socket) do
    ConfigManager.set_active_provider(id)
    {:noreply, load_config(socket)}
  end

  # Credential Handlers

  @impl true
  def handle_event("add_credential", _, socket) do
    ConfigManager.add_credential("New Key", "")
    {:noreply, load_config(socket)}
  end

  @impl true
  def handle_event("save_credential", params, socket) do
    %{"config_id" => id, "name" => name, "key" => key} = params
    ConfigManager.update_credential(id, %{"name" => name, "key" => key})
    {:noreply, socket |> load_config() |> put_flash(:info, "Credential updated")}
  end

  @impl true
  def handle_event("delete_credential", %{"id" => id}, socket) do
    ConfigManager.delete_credential(id)
    {:noreply, load_config(socket)}
  end

  @impl true
  def handle_event("save_system_prompt", %{"system_prompt" => prompt}, socket) do
    ConfigManager.update_system_prompt(prompt)
    {:noreply, socket |> load_config() |> put_flash(:info, "System prompt updated")}
  end

  defp load_config(socket) do
    assign(socket, :config, ConfigManager.get_config())
  end

  defp maybe_load_skills(%{assigns: %{live_action: :skills}} = socket) do
    assign(socket, :global_skills_result, Skills.list_global())
  end

  defp maybe_load_skills(socket), do: socket
end
