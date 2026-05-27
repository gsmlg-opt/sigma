defmodule PiWeb.SettingsLive do
  use PiWeb, :live_view

  alias PiAgent.ContextBuilder
  alias PiSession.{ConfigManager, Skills}

  @credential_ref_regex ~r/^\{\{credential:([^}]+)\}\}$/

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:active_tab, :settings)
     |> assign(:mcp_form, nil)
     |> assign(:deleting_mcp_server, nil)
     |> assign(:hooks_error, nil)
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
      |> maybe_load_mcp()
      |> maybe_load_hooks()

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
              <span>Context</span>
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

            <.dm_link
              patch={~p"/settings/mcp"}
              class={["p-4 rounded-2xl border transition-all flex items-center gap-3 font-bold",
                if(@live_action == :mcp,
                  do: "bg-primary text-primary-content border-primary shadow-lg",
                  else: "border-secondary-content/20 hover:bg-secondary-content/10 text-secondary-content"
                )]}
            >
              <.dm_mdi name="server-network-outline" class="w-5 h-5" />
              <span>MCP</span>
            </.dm_link>

            <.dm_link
              patch={~p"/settings/hooks"}
              class={["p-4 rounded-2xl border transition-all flex items-center gap-3 font-bold",
                if(@live_action == :hooks,
                  do: "bg-primary text-primary-content border-primary shadow-lg",
                  else: "border-secondary-content/20 hover:bg-secondary-content/10 text-secondary-content"
                )]}
            >
              <.dm_mdi name="hook" class="w-5 h-5" />
              <span>Hooks</span>
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
              <.render_context
                agents_md={@config["system_prompt"]}
                system_prompt={ContextBuilder.system_prompt_template()}
              />
            <% :skills -> %>
              <.render_skills result={@global_skills_result} />
            <% :mcp -> %>
              <.render_mcp
                config={@mcp_config}
                credentials={@config["credentials"]}
                deleting_server_id={@deleting_mcp_server}
                file={@mcp_file}
                form={@mcp_form}
              />
            <% :hooks -> %>
              <.render_hooks
                hooks_json={@hooks_json}
                hooks_file={@hooks_file}
                hooks_error={@hooks_error}
              />
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

  defp render_context(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex justify-between items-center text-on-surface">
        <h2 class="text-2xl font-bold font-display">Context</h2>
      </div>

      <.dm_card variant="bordered" class="bg-surface-container-low">
        <form phx-submit="save_system_prompt" class="space-y-4">
          <div class="flex items-center gap-2 text-on-surface">
            <.dm_mdi name="file-document-outline" class="w-5 h-5 text-primary" />
            <h3 class="text-lg font-bold">AGENTS.md</h3>
          </div>
          <.dm_markdown_input
            id="system-prompt-editor"
            phx-update="ignore"
            phx-hook="MarkdownInputHook"
            name="system_prompt"
            value={@agents_md}
            class="w-full"
          />

          <div class="flex justify-end pt-4 border-t border-outline-variant">
             <.dm_btn type="submit" phx-hook="WebComponentHook" variant="primary" size="md">
               Save AGENTS.md
             </.dm_btn>
          </div>
        </form>
      </.dm_card>

      <.dm_card variant="bordered" class="bg-surface-container-low">
        <:title>
          <div class="flex items-center gap-2 text-on-surface">
            <.dm_mdi name="shield-text-outline" class="w-5 h-5 text-primary" />
            <span>System Prompt</span>
          </div>
        </:title>
        <div
          id="system-prompt-preview"
          class="max-h-[36rem] overflow-y-auto rounded-xl border border-outline-variant bg-surface-container p-4 text-on-surface"
        >
          <.dm_markdown content={@system_prompt} />
        </div>
      </.dm_card>

      <div class="bg-primary/5 rounded-2xl p-6 border border-primary/10">
        <div class="flex items-center gap-2 text-primary mb-2">
          <.dm_mdi name="information-outline" class="w-5 h-5" />
          <span class="font-bold">About Context</span>
        </div>
        <p class="text-sm text-on-surface-variant leading-relaxed">
          AGENTS.md is user-level context loaded into sessions. The readonly system prompt below is the default provider prompt, with runtime-only sections shown as placeholders.
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

  defp render_mcp(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex justify-between items-center text-on-surface">
        <div>
          <h2 class="text-2xl font-bold font-display">MCP Servers</h2>
          <p class="text-sm text-on-surface-variant font-mono mt-1">{@file}</p>
        </div>
        <.dm_btn id="mcp-new-server-btn" phx-click="new_mcp_server" phx-hook="WebComponentHook" variant="primary" size="sm">
          <:prefix><.dm_mdi name="plus" /></:prefix>
          New Server
        </.dm_btn>
      </div>

      <div
        :if={map_size(@config["servers"]) == 0}
        class="rounded-2xl border border-dashed border-outline-variant bg-surface-container-low p-8 text-center"
      >
        <.dm_mdi name="server-network-off" class="w-10 h-10 mx-auto text-on-surface-variant opacity-40 mb-3" />
        <p class="font-semibold text-on-surface">No MCP servers configured</p>
      </div>

      <div :if={map_size(@config["servers"]) > 0} class="grid grid-cols-1 gap-4">
        <.dm_card :for={{id, server} <- @config["servers"]} variant="bordered" class="bg-surface-container-low">
          <:title>
            <div class="flex items-center justify-between w-full text-on-surface">
              <div class="flex items-center gap-3 min-w-0">
                <div class="p-2 bg-primary/10 rounded-lg text-primary shrink-0">
                  <.dm_mdi name="server-network-outline" class="w-5 h-5" />
                </div>
                <div class="min-w-0">
                  <div class="font-bold truncate">{id}</div>
                  <div class="text-[10px] opacity-40 uppercase tracking-widest">{server["type"]}</div>
                </div>
              </div>
              <div class="flex items-center gap-2">
                <.dm_btn
                  id={"mcp-edit-server-#{id}"}
                  type="button"
                  phx-hook="WebComponentHook"
                  phx-click="edit_mcp_server"
                  phx-value-id={id}
                  variant="outline"
                  size="xs"
                >
                  Edit
                </.dm_btn>
                <.dm_btn
                  id={"mcp-delete-server-#{id}"}
                  type="button"
                  phx-hook="WebComponentHook"
                  phx-click="confirm_delete_mcp_server"
                  phx-value-id={id}
                  variant="error"
                  size="xs"
                  shape="circle"
                >
                  <.dm_mdi name="delete-outline" />
                </.dm_btn>
              </div>
            </div>
          </:title>

          <div class="grid grid-cols-1 gap-3 py-2 text-sm">
            <div class="rounded-xl bg-surface-container p-3 font-mono text-xs text-on-surface-variant break-all">
              {mcp_server_summary(server)}
            </div>
            <div class="flex flex-wrap gap-2 text-[11px] text-on-surface-variant">
              <span :if={server["type"] == "stdio"} class="px-2 py-1 rounded-full bg-surface-container-high">
                {length(server["args"] || [])} args
              </span>
              <span :if={server["type"] == "stdio"} class="px-2 py-1 rounded-full bg-surface-container-high">
                {map_size(server["env"] || %{})} env
              </span>
              <span :if={server["type"] == "http"} class="px-2 py-1 rounded-full bg-surface-container-high">
                {map_size(server["headers"] || %{})} headers
              </span>
            </div>
          </div>
        </.dm_card>
      </div>

      <.dm_modal :if={@form} id="mcp-server-modal" phx-hook="ModalHook" size="xl" responsive={true} hide_close={true}>
        <:title>
          <div class="flex items-center gap-2 text-on-surface">
            <.dm_mdi name="server-network-outline" class="w-6 h-6 text-primary" />
            <span>{if @form["mode"] == "new", do: "New MCP Server", else: "Edit MCP Server"}</span>
          </div>
        </:title>
        <:body>
          <form id="mcp-server-form" phx-change="change_mcp_form" phx-submit="save_mcp_server" class="space-y-5">
            <input type="hidden" name="mcp[mode]" value={@form["mode"]} />
            <input type="hidden" name="mcp[original_id]" value={@form["original_id"] || ""} />

            <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
              <div class="space-y-1">
                <label class="text-[10px] font-bold opacity-40 uppercase tracking-wider text-on-surface">Server ID</label>
                <.dm_input name="mcp[id]" value={@form["id"]} class="w-full" size="sm" />
              </div>

              <div class="space-y-1">
                <.dm_select name="mcp[type]" value={@form["type"]} label="Transport" size="sm" class="w-full">
                  <option value="stdio" selected={@form["type"] == "stdio"}>stdio</option>
                  <option value="http" selected={@form["type"] == "http"}>HTTP</option>
                </.dm_select>
              </div>
            </div>

            <div :if={@form["type"] == "stdio"} class="space-y-5">
              <div class="space-y-1">
                <label class="text-[10px] font-bold opacity-40 uppercase tracking-wider text-on-surface">Command</label>
                <.dm_input name="mcp[command]" value={@form["command"] || ""} placeholder="npx" class="w-full" size="sm" />
              </div>

              <.mcp_pair_rows
                field="args"
                label="Args"
                key_label="Arg"
                rows={@form["args"]}
                credentials={@credentials}
              />

              <.mcp_pair_rows
                field="env"
                label="Env"
                key_label="Name"
                rows={@form["env"]}
                credentials={@credentials}
              />
            </div>

            <div :if={@form["type"] == "http"} class="space-y-5">
              <div class="space-y-1">
                <label class="text-[10px] font-bold opacity-40 uppercase tracking-wider text-on-surface">URL</label>
                <.dm_input name="mcp[url]" value={@form["url"] || ""} placeholder="https://example.com/mcp" class="w-full" size="sm" />
              </div>

              <.mcp_pair_rows
                field="headers"
                label="Headers"
                key_label="Header"
                rows={@form["headers"]}
                credentials={@credentials}
              />
            </div>

            <div class="flex justify-end gap-3 pt-4 border-t border-outline-variant">
              <.dm_btn id="mcp-cancel-server-btn" type="button" phx-click="cancel_mcp_form" phx-hook="WebComponentHook" variant="ghost">
                Cancel
              </.dm_btn>
              <.dm_btn
                id="mcp-save-server-btn"
                type="button"
                onclick="this.closest('form').requestSubmit()"
                variant="primary"
              >
                Save Server
              </.dm_btn>
            </div>
          </form>
        </:body>
      </.dm_modal>

      <.dm_modal :if={@deleting_server_id} id="delete-mcp-server-modal" phx-hook="ModalHook">
        <:title>
          <div class="flex items-center gap-2 text-error">
            <.dm_mdi name="alert-circle-outline" class="w-6 h-6" />
            <span>Delete MCP Server</span>
          </div>
        </:title>
        <:body>
          <p class="text-on-surface">
            Delete the MCP server <span class="font-bold">"{@deleting_server_id}"</span>?
          </p>
        </:body>
        <:footer>
          <.dm_btn
            id="mcp-cancel-delete-server-btn"
            type="button"
            phx-click="cancel_delete_mcp_server"
            phx-hook="WebComponentHook"
            variant="ghost"
          >
            Cancel
          </.dm_btn>
          <.dm_btn
            id="mcp-confirm-delete-server-btn"
            type="button"
            phx-click="delete_mcp_server"
            phx-value-id={@deleting_server_id}
            phx-hook="WebComponentHook"
            variant="error"
          >
            Delete
          </.dm_btn>
        </:footer>
      </.dm_modal>
    </div>
    """
  end

  defp render_hooks(assigns) do
    assigns =
      assign(
        assigns,
        :hooks_example,
        ~S"""
        {
          "hooks": {
            "SessionStart": [
              {
                "hooks": [{ "type": "command", "command": "echo session started" }]
              }
            ],
            "PreToolUse": [
              {
                "matcher": "Bash",
                "hooks": [{ "type": "command", "command": "echo running bash" }]
              }
            ]
          }
        }
        """
      )

    ~H"""
    <div class="space-y-6">
      <div class="flex justify-between items-center text-on-surface">
        <div>
          <h2 class="text-2xl font-bold font-display">Hooks</h2>
          <p class="text-sm text-on-surface-variant mt-1">
            User-level lifecycle hooks run for every session.
          </p>
        </div>
      </div>

      <.dm_card variant="bordered" class="bg-surface-container-low">
        <form phx-submit="save_hooks" phx-change="change_hooks" class="space-y-4">
          <div class="flex items-center gap-2 text-on-surface">
            <.dm_mdi name="hook" class="w-5 h-5 text-primary" />
            <h3 class="text-lg font-bold">hooks.json</h3>
          </div>
          <code class="block text-[11px] font-mono text-on-surface-variant bg-surface-container rounded-lg px-3 py-2">
            {@hooks_file}
          </code>

          <div :if={@hooks_error} class="flex items-center gap-2 rounded-xl bg-error/10 text-error p-3 text-sm">
            <.dm_mdi name="alert-circle-outline" class="w-4 h-4 shrink-0" />
            <span>{@hooks_error}</span>
          </div>

          <textarea
            id="hooks-editor"
            name="hooks_json"
            phx-update="ignore"
            class="w-full font-mono text-sm bg-surface-container-high rounded-xl p-4 min-h-96 text-on-surface resize-y border border-outline-variant focus:outline-none focus:border-primary"
            spellcheck="false"
          >{@hooks_json}</textarea>

          <div class="flex justify-between pt-4 border-t border-outline-variant">
            <.dm_btn
              id="hooks-format-btn"
              type="button"
              phx-click="format_hooks"
              phx-hook="WebComponentHook"
              variant="outline"
              size="sm"
            >
              <:prefix><.dm_mdi name="code-json" class="w-4 h-4" /></:prefix>
              Format JSON
            </.dm_btn>
            <.dm_btn type="submit" phx-hook="WebComponentHook" variant="primary" size="md">
              Save hooks.json
            </.dm_btn>
          </div>
        </form>
      </.dm_card>

      <div class="bg-primary/5 rounded-2xl p-6 border border-primary/10 text-sm space-y-3">
        <div class="flex items-center gap-2 text-primary font-bold">
          <.dm_mdi name="information-outline" class="w-5 h-5" />
          <span>About Hooks</span>
        </div>
        <p class="text-on-surface-variant leading-relaxed">
          Hooks run shell commands at key points in the agent lifecycle — before/after tool calls,
          on session start, and more. They are compatible with Claude Code and Codex
          <code class="font-mono text-xs bg-surface-container px-1 py-0.5 rounded">hooks.json</code> format.
        </p>
        <p class="text-on-surface-variant leading-relaxed">
          The file is a JSON object with a top-level
          <code class="font-mono text-xs bg-surface-container px-1 py-0.5 rounded">hooks</code> key
          whose value maps event names to arrays of matcher groups. Each matcher group has an optional
          <code class="font-mono text-xs bg-surface-container px-1 py-0.5 rounded">matcher</code>
          and a list of command handlers. Example:
        </p>
        <pre class="font-mono text-xs bg-surface-container rounded-xl p-4 text-on-surface-variant overflow-x-auto"><code>{@hooks_example}</code></pre>
      </div>
    </div>
    """
  end

  defp mcp_pair_rows(assigns) do
    assigns = assign(assigns, :rows, ensure_pair_rows(assigns.rows))

    ~H"""
    <div class="space-y-3">
      <div class="flex items-center justify-between">
        <label class="text-[10px] font-bold opacity-40 uppercase tracking-wider text-on-surface">
          {@label}
        </label>
        <.dm_btn
          id={"mcp-#{@field}-add-row-btn"}
          type="button"
          phx-click="add_mcp_pair"
          phx-value-field={@field}
          phx-hook="WebComponentHook"
          variant="outline"
          size="xs"
        >
          <:prefix><.dm_mdi name="plus" class="w-3 h-3" /></:prefix>
          Add
        </.dm_btn>
      </div>

      <div class="space-y-2">
        <div
          :for={{row, idx} <- Enum.with_index(@rows)}
          class="grid grid-cols-1 md:grid-cols-[1fr_1fr_1fr_auto] gap-2 items-end"
        >
          <% credential_selected? = (row["credential_id"] || "") != "" %>
          <.dm_input
            name={"mcp[#{@field}][key][]"}
            value={row["key"] || ""}
            placeholder={@key_label}
            class="w-full"
            size="sm"
          />
          <input
            :if={credential_selected?}
            type="hidden"
            name={"mcp[#{@field}][value][]"}
            value=""
          />
          <.dm_input
            name={"mcp[#{@field}][value][]"}
            value={if credential_selected?, do: "", else: row["value"] || ""}
            placeholder={if credential_selected?, do: "Using credential", else: "Value"}
            class="w-full"
            size="sm"
            disabled={credential_selected?}
          />
          <.dm_select
            name={"mcp[#{@field}][credential_id][]"}
            value={row["credential_id"] || ""}
            label="Credential"
            size="sm"
            class="w-full"
          >
            <option value="" selected={(row["credential_id"] || "") == ""}>Input value</option>
            <option
              :for={{credential_id, credential} <- @credentials}
              value={credential_id}
              selected={row["credential_id"] == credential_id}
            >
              {credential["name"]}
            </option>
          </.dm_select>
          <.dm_btn
            id={"mcp-#{@field}-remove-row-#{idx}-btn"}
            type="button"
            phx-click="remove_mcp_pair"
            phx-value-field={@field}
            phx-value-index={idx}
            phx-hook="WebComponentHook"
            variant="ghost"
            size="sm"
            shape="circle"
          >
            <.dm_mdi name="minus" class="w-4 h-4" />
          </.dm_btn>
        </div>
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
    {:noreply, socket |> load_config() |> put_flash(:info, "AGENTS.md updated")}
  end

  @impl true
  def handle_event("new_mcp_server", _, socket) do
    {:noreply, assign(socket, :mcp_form, blank_mcp_form())}
  end

  @impl true
  def handle_event("edit_mcp_server", %{"id" => id}, socket) do
    server = ConfigManager.get_mcp_server(id) || %{"type" => "stdio"}
    {:noreply, assign(socket, :mcp_form, mcp_form_from_server(id, server))}
  end

  @impl true
  def handle_event("cancel_mcp_form", _, socket) do
    {:noreply, assign(socket, :mcp_form, nil)}
  end

  @impl true
  def handle_event("confirm_delete_mcp_server", %{"id" => id}, socket) do
    {:noreply, assign(socket, :deleting_mcp_server, id)}
  end

  @impl true
  def handle_event("cancel_delete_mcp_server", _, socket) do
    {:noreply, assign(socket, :deleting_mcp_server, nil)}
  end

  @impl true
  def handle_event("change_mcp_form", %{"mcp" => params}, socket) do
    form = socket.assigns.mcp_form || blank_mcp_form()
    {:noreply, assign(socket, :mcp_form, merge_mcp_form_params(form, params))}
  end

  @impl true
  def handle_event("add_mcp_pair", %{"field" => field}, socket) do
    {:noreply,
     update(socket, :mcp_form, fn form ->
       update_mcp_pair_rows(form, field, &(&1 ++ [blank_pair_row()]))
     end)}
  end

  @impl true
  def handle_event("remove_mcp_pair", %{"field" => field, "index" => index}, socket) do
    index = String.to_integer(index)

    {:noreply,
     update(socket, :mcp_form, fn form ->
       update_mcp_pair_rows(form, field, &List.delete_at(&1, index))
     end)}
  end

  @impl true
  def handle_event("save_mcp_server", %{"mcp" => params}, socket) do
    form =
      socket.assigns.mcp_form
      |> Kernel.||(blank_mcp_form())
      |> merge_mcp_form_params(params)

    with {:ok, updates} <- mcp_server_updates(form),
         {:ok, _} <- save_mcp_server_form(form, updates) do
      {:noreply,
       socket
       |> load_mcp()
       |> assign(:mcp_form, nil)
       |> put_flash(:info, "MCP server updated")}
    else
      {:error, :invalid_id} ->
        {:noreply, put_flash(socket, :error, "MCP server ID cannot be empty.")}

      {:error, :id_conflict} ->
        {:noreply, put_flash(socket, :error, "Another MCP server already uses that ID.")}

      {:error, message} ->
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  @impl true
  def handle_event("delete_mcp_server", %{"id" => id}, socket) do
    ConfigManager.delete_mcp_server(id)

    {:noreply,
     socket
     |> load_mcp()
     |> assign(:mcp_form, nil)
     |> assign(:deleting_mcp_server, nil)}
  end

  @impl true
  def handle_event("change_hooks", %{"hooks_json" => json}, socket) do
    {:noreply, assign(socket, hooks_json: json, hooks_error: nil)}
  end

  @impl true
  def handle_event("format_hooks", _, socket) do
    case Jason.decode(socket.assigns.hooks_json) do
      {:ok, data} ->
        {:noreply,
         assign(socket, hooks_json: Jason.encode!(data, pretty: true), hooks_error: nil)}

      {:error, reason} ->
        {:noreply, assign(socket, hooks_error: "Cannot format: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("save_hooks", %{"hooks_json" => json}, socket) do
    path = ConfigManager.hooks_file()

    case ConfigManager.save_hooks_json(path, json) do
      :ok ->
        {:noreply,
         socket
         |> assign(hooks_json: json, hooks_error: nil)
         |> put_flash(:info, "hooks.json saved")}

      {:error, msg} ->
        {:noreply, assign(socket, hooks_error: msg)}
    end
  end

  defp load_config(socket) do
    assign(socket, :config, ConfigManager.get_config())
  end

  defp load_mcp(socket) do
    socket
    |> assign(:mcp_config, ConfigManager.get_mcp_config())
    |> assign(:mcp_file, ConfigManager.mcp_file())
  end

  defp maybe_load_skills(%{assigns: %{live_action: :skills}} = socket) do
    assign(socket, :global_skills_result, Skills.list_global())
  end

  defp maybe_load_skills(socket), do: socket

  defp maybe_load_mcp(%{assigns: %{live_action: :mcp}} = socket), do: load_mcp(socket)
  defp maybe_load_mcp(socket), do: socket

  defp maybe_load_hooks(%{assigns: %{live_action: :hooks}} = socket), do: load_hooks(socket)
  defp maybe_load_hooks(socket), do: socket

  defp load_hooks(socket) do
    path = ConfigManager.hooks_file()

    socket
    |> assign(:hooks_json, ConfigManager.get_hooks_json(path))
    |> assign(:hooks_file, path)
  end

  defp blank_mcp_form do
    %{
      "mode" => "new",
      "original_id" => "",
      "id" => "server_#{System.unique_integer([:positive])}",
      "type" => "stdio",
      "command" => "",
      "url" => "",
      "args" => [blank_pair_row()],
      "env" => [blank_pair_row()],
      "headers" => [blank_pair_row()]
    }
  end

  defp mcp_form_from_server(id, server) do
    type = normalize_mcp_type(server["type"])

    %{
      "mode" => "edit",
      "original_id" => id,
      "id" => id,
      "type" => type,
      "command" => server["command"] || "",
      "url" => server["url"] || "",
      "args" => args_to_pair_rows(server["args"] || []),
      "env" => map_to_pair_rows(server["env"] || %{}),
      "headers" => map_to_pair_rows(server["headers"] || %{})
    }
  end

  defp merge_mcp_form_params(form, params) do
    form
    |> Map.merge(Map.take(params, ["mode", "original_id", "id", "command", "url"]))
    |> Map.put("type", normalize_mcp_type(params["type"] || form["type"]))
    |> merge_pair_rows(params, "args")
    |> merge_pair_rows(params, "env")
    |> merge_pair_rows(params, "headers")
  end

  defp merge_pair_rows(form, params, field) do
    if Map.has_key?(params, field) do
      Map.put(form, field, pair_rows_from_params(params[field]))
    else
      form
    end
  end

  defp update_mcp_pair_rows(nil, field, fun) do
    blank_mcp_form()
    |> update_mcp_pair_rows(field, fun)
  end

  defp update_mcp_pair_rows(form, field, fun) when field in ["args", "env", "headers"] do
    rows =
      form
      |> Map.get(field, [])
      |> ensure_pair_rows()
      |> fun.()
      |> ensure_pair_rows()

    Map.put(form, field, rows)
  end

  defp update_mcp_pair_rows(form, _field, _fun), do: form

  defp mcp_server_updates(form) do
    id = form["id"] |> to_string() |> String.trim()
    type = normalize_mcp_type(form["type"])

    if id == "" do
      {:error, :invalid_id}
    else
      {:ok, mcp_server_updates_for_type(id, type, form)}
    end
  end

  defp mcp_server_updates_for_type(id, "http", form) do
    %{
      "id" => id,
      "type" => "http",
      "url" => String.trim(form["url"] || ""),
      "headers" => map_from_pair_rows(form["headers"])
    }
  end

  defp mcp_server_updates_for_type(id, "stdio", form) do
    %{
      "id" => id,
      "type" => "stdio",
      "command" => String.trim(form["command"] || ""),
      "args" => args_from_pair_rows(form["args"]),
      "env" => map_from_pair_rows(form["env"])
    }
  end

  defp save_mcp_server_form(%{"mode" => "new"}, updates) do
    if Map.has_key?(ConfigManager.list_mcp_servers(), updates["id"]) do
      {:error, :id_conflict}
    else
      ConfigManager.put_mcp_server(updates["id"], Map.drop(updates, ["id"]))
    end
  end

  defp save_mcp_server_form(%{"original_id" => original_id}, updates) do
    ConfigManager.update_mcp_server(original_id, updates)
  end

  defp save_mcp_server_form(_form, updates), do: save_mcp_server_form(%{"mode" => "new"}, updates)

  defp blank_pair_row, do: %{"key" => "", "value" => "", "credential_id" => ""}

  defp ensure_pair_rows(rows) do
    rows =
      rows
      |> List.wrap()
      |> Enum.reject(&is_nil/1)

    if rows == [], do: [blank_pair_row()], else: rows
  end

  defp pair_rows_from_params(nil), do: [blank_pair_row()]

  defp pair_rows_from_params(params) do
    keys = list_param(params["key"])
    values = list_param(params["value"])
    credential_ids = list_param(params["credential_id"])
    count = Enum.max([length(keys), length(values), length(credential_ids), 1])

    Enum.map(0..(count - 1), fn index ->
      %{
        "key" => Enum.at(keys, index, ""),
        "value" => Enum.at(values, index, ""),
        "credential_id" => Enum.at(credential_ids, index, "")
      }
    end)
  end

  defp list_param(value) when is_list(value), do: value
  defp list_param(nil), do: []
  defp list_param(value), do: [value]

  defp args_to_pair_rows(args) do
    args
    |> List.wrap()
    |> Enum.chunk_every(2, 2, [""])
    |> Enum.map(fn [key, value] -> pair_row_from_value(key, value) end)
    |> ensure_pair_rows()
  end

  defp map_to_pair_rows(values) when is_map(values) do
    values
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.map(fn {key, value} -> pair_row_from_value(key, value) end)
    |> ensure_pair_rows()
  end

  defp map_to_pair_rows(_values), do: [blank_pair_row()]

  defp pair_row_from_value(key, value) do
    case credential_id_from_value(value) do
      nil ->
        %{"key" => to_string(key), "value" => to_string(value || ""), "credential_id" => ""}

      credential_id ->
        %{"key" => to_string(key), "value" => "", "credential_id" => credential_id}
    end
  end

  defp credential_id_from_value(value) when is_binary(value) do
    case Regex.run(@credential_ref_regex, value) do
      [_, credential_id] -> credential_id
      _ -> nil
    end
  end

  defp credential_id_from_value(_value), do: nil

  defp args_from_pair_rows(rows) do
    rows
    |> ensure_pair_rows()
    |> Enum.flat_map(fn row ->
      key = String.trim(row["key"] || "")
      value = pair_row_value(row)

      cond do
        key == "" and value == "" -> []
        key == "" -> [value]
        value == "" -> [key]
        true -> [key, value]
      end
    end)
  end

  defp map_from_pair_rows(rows) do
    rows
    |> ensure_pair_rows()
    |> Enum.reduce(%{}, fn row, acc ->
      key = String.trim(row["key"] || "")

      if key == "" do
        acc
      else
        Map.put(acc, key, pair_row_value(row))
      end
    end)
  end

  defp pair_row_value(row) do
    credential_id = String.trim(row["credential_id"] || "")

    if credential_id == "" do
      String.trim(row["value"] || "")
    else
      "{{credential:#{credential_id}}}"
    end
  end

  defp normalize_mcp_type(type) when type in ["http", "streamable-http", "sse"], do: "http"
  defp normalize_mcp_type(_type), do: "stdio"

  defp mcp_server_summary(%{"type" => "http", "url" => url}), do: "http: #{url}"

  defp mcp_server_summary(%{"type" => "stdio", "command" => command, "args" => args}) do
    [command | args || []]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" ")
  end

  defp mcp_server_summary(server), do: inspect(server)
end
