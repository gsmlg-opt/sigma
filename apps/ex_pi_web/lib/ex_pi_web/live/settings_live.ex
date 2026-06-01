defmodule PiWeb.SettingsLive do
  use PiWeb, :live_view

  alias PiAgent.ContextBuilder
  alias PiSession.{ConfigManager, Skills}
  alias Phoenix.LiveView.AsyncResult

  @credential_ref_regex ~r/^\{\{credential:([^}]+)\}\}$/

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:active_tab, :settings)
     |> assign(:settings_data, AsyncResult.loading())
     |> assign(:context_config, %{"system_prompt" => ""})
     |> assign(:mcp_form, nil)
     |> assign(:deleting_mcp_server, nil)
     |> assign(:hooks_json, "")
     |> assign(:hooks_file, "")
     |> assign(:hooks_error, nil)
     |> assign(:selected_id, nil)}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    # Default to providers if root /settings is visited
    case socket.assigns.live_action do
      :index ->
        {:noreply, push_patch(socket, to: ~p"/settings/providers")}

      action ->
        {:noreply,
         socket
         |> assign(:selected_id, nil)
         |> load_settings_action(action)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex min-h-[calc(100vh-64px)]">
      <aside class="w-64 lg:w-72 bg-secondary text-secondary-content border-r border-outline-variant p-5 shrink-0 flex flex-col">
        <div class="flex items-center gap-2 mb-6 text-on-secondary">
          <.dm_mdi name="cog-outline" class="w-4 h-4 opacity-70" />
          <span class="text-xs uppercase tracking-widest font-bold opacity-70">Settings</span>
        </div>

        <nav class="flex flex-col gap-3">
          <.dm_link patch={~p"/settings/providers"} class={settings_nav_class(@live_action, :providers)}>
            <.dm_mdi name="robot-outline" class="w-5 h-5" />
            <span>Providers</span>
          </.dm_link>

          <.dm_link
            patch={~p"/settings/credentials"}
            class={settings_nav_class(@live_action, :credentials)}
          >
            <.dm_mdi name="key-outline" class="w-5 h-5" />
            <span>Credentials</span>
          </.dm_link>

          <.dm_link
            patch={~p"/settings/system_prompt"}
            class={settings_nav_class(@live_action, :system_prompt)}
          >
            <.dm_mdi name="text-box-outline" class="w-5 h-5" />
            <span>Context</span>
          </.dm_link>

          <.dm_link patch={~p"/settings/skills"} class={settings_nav_class(@live_action, :skills)}>
            <.dm_mdi name="auto-fix" class="w-5 h-5" />
            <span>Skills</span>
          </.dm_link>

          <.dm_link patch={~p"/settings/mcp"} class={settings_nav_class(@live_action, :mcp)}>
            <.dm_mdi name="server-network-outline" class="w-5 h-5" />
            <span>MCP</span>
          </.dm_link>

          <.dm_link patch={~p"/settings/hooks"} class={settings_nav_class(@live_action, :hooks)}>
            <.dm_mdi name="hook" class="w-5 h-5" />
            <span>Hooks</span>
          </.dm_link>
        </nav>
      </aside>

      <main class="flex-1 p-8 bg-surface text-on-surface font-sans overflow-x-hidden">
        <div class="max-w-6xl mx-auto">
          <div class="mb-10 flex justify-between items-end text-on-surface border-b border-outline-variant pb-6">
            <div>
              <h1 class="font-display text-4xl font-bold mb-2 tracking-tight">Settings</h1>
              <p class="text-on-surface-variant text-lg">Manage API credentials, AI provider configurations, and agent resources.</p>
            </div>
          </div>

          <%= case @live_action do %>
            <% :providers -> %>
              <.settings_async_result :let={data} assign={@settings_data}>
                <.render_providers
                  providers={data.providers}
                  credentials={data.credentials}
                  active_id={data.active_provider_id}
                />
              </.settings_async_result>
            <% :credentials -> %>
              <.settings_async_result :let={data} assign={@settings_data}>
                <.render_credentials credentials={data.credentials} />
              </.settings_async_result>
            <% :system_prompt -> %>
              <.render_context
                agents_md={@context_config["system_prompt"]}
                system_prompt={ContextBuilder.system_prompt_template()}
              />
            <% :skills -> %>
              <.settings_async_result :let={data} assign={@settings_data}>
                <.render_skills result={data} />
              </.settings_async_result>
            <% :mcp -> %>
              <.settings_async_result :let={data} assign={@settings_data}>
                <.render_mcp
                  servers={data.servers}
                  credentials={data.credentials}
                  deleting_server_id={@deleting_mcp_server}
                  file={data.file}
                  form={@mcp_form}
                />
              </.settings_async_result>
            <% :hooks -> %>
              <.render_hooks
                hooks_json={@hooks_json}
                hooks_file={@hooks_file}
                hooks_error={@hooks_error}
              />
            <% _ -> %>
              <.settings_loading_state />
          <% end %>
        </div>
      </main>
    </div>
    """
  end

  defp settings_nav_class(current_action, item_action) when current_action == item_action,
    do: "btn btn-primary w-full justify-start gap-3"

  defp settings_nav_class(_current_action, _item_action),
    do: "btn btn-ghost w-full justify-start gap-3 text-primary-content hover:text-primary-content"

  defp settings_async_result(assigns) do
    ~H"""
    <.async_result :let={data} assign={@assign}>
      <:loading>
        <.settings_loading_state />
      </:loading>
      <:failed :let={reason}>
        <div class="rounded-2xl border border-error/30 bg-error/10 p-6 text-error">
          <div class="flex items-center gap-2 font-bold">
            <.dm_mdi name="alert-circle-outline" class="w-5 h-5" />
            <span>Could not load settings data</span>
          </div>
          <p class="mt-2 text-sm font-mono break-all">{inspect(reason)}</p>
        </div>
      </:failed>
      {render_slot(@inner_block, data)}
    </.async_result>
    """
  end

  defp settings_loading_state(assigns) do
    ~H"""
    <div class="rounded-2xl border border-outline-variant bg-surface-container-low p-6">
      <div class="flex items-center gap-3 text-on-surface-variant">
        <.dm_loading_spinner size="sm" />
        <span class="text-sm font-medium">Loading settings data...</span>
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

      <div
        :if={Enum.empty?(@providers)}
        class="rounded-2xl border border-dashed border-outline-variant bg-surface-container-low p-8 text-center"
      >
        <.dm_mdi name="robot-off-outline" class="w-10 h-10 mx-auto text-on-surface-variant opacity-40 mb-3" />
        <p class="font-semibold text-on-surface">No providers configured</p>
      </div>

      <div :if={!Enum.empty?(@providers)} class="overflow-x-auto rounded-2xl border border-outline-variant bg-surface-container-low">
        <.dm_table id="providers-table" data={@providers} compact hover zebra class="min-w-[72rem]">
          <:col :let={row} label="Name" class="min-w-52">
            <form id={"provider-form-#{row.id}"} phx-submit="save_provider">
              <input type="hidden" name="config_id" value={row.id} />
            </form>
            <.dm_input
              form={"provider-form-#{row.id}"}
              name="name"
              value={row.provider["name"]}
              aria-label="Provider name"
              class="w-full"
              size="sm"
            />
          </:col>
          <:col :let={row} label="API" class="min-w-44">
            <select
              form={"provider-form-#{row.id}"}
              name="api_type"
              class="select select-bordered select-sm select-primary w-full"
              aria-label="Provider API type"
            >
              <option value="anthropic" selected={row.provider["api_type"] == "anthropic"}>
                Anthropic
              </option>
              <option value="openai" selected={row.provider["api_type"] == "openai"}>
                OpenAI
              </option>
            </select>
          </:col>
          <:col :let={row} label="Credential" class="min-w-52">
            <select
              form={"provider-form-#{row.id}"}
              name="credential_id"
              class="select select-bordered select-sm select-primary w-full"
              aria-label="Provider credential"
            >
              <option
                :for={{credential_id, credential_name} <- credential_select_options(@credentials)}
                value={credential_id}
                selected={row.provider["credential_id"] == credential_id}
              >
                {credential_name}
              </option>
            </select>
          </:col>
          <:col :let={row} label="Model" class="min-w-52">
            <.dm_input
              form={"provider-form-#{row.id}"}
              name="model"
              value={row.provider["model"]}
              placeholder="e.g. gpt-4o"
              aria-label="Provider model"
              class="w-full"
              size="sm"
            />
          </:col>
          <:col :let={row} label="Base URL" class="min-w-64">
            <.dm_input
              form={"provider-form-#{row.id}"}
              name="base_url"
              value={row.provider["base_url"]}
              aria-label="Provider base URL"
              class="w-full"
              size="sm"
            />
          </:col>
          <:col :let={row} label="Status" class="min-w-28">
            <div :if={@active_id == row.id} class="inline-flex bg-success/20 text-success text-[10px] font-bold px-3 py-1 rounded-full border border-success/30">
              ACTIVE
            </div>
            <.dm_btn
              :if={@active_id != row.id}
              phx-click="set_active_provider"
              phx-value-id={row.id}
              phx-hook="WebComponentHook"
              variant="outline"
              size="xs"
            >
              Activate
            </.dm_btn>
          </:col>
          <:col :let={row} label="Actions" class="min-w-36">
            <div class="flex items-center gap-2">
              <.dm_btn
                type="button"
                onclick={"document.getElementById('provider-form-#{row.id}').requestSubmit()"}
                variant="primary"
                size="sm"
              >
                Save
              </.dm_btn>
              <.dm_btn
                type="button"
                variant="error"
                size="sm"
                shape="circle"
                confirm="Are you sure you want to delete this provider?"
                confirm_title="Delete Provider"
              >
                <:confirm_action>
                  <.dm_btn type="button" variant="ghost" onclick="this.closest('el-dm-dialog').close()">
                    Cancel
                  </.dm_btn>
                  <.dm_btn type="button" phx-click="delete_provider" phx-value-id={row.id} phx-hook="WebComponentHook" variant="error" onclick="this.closest('el-dm-dialog').close()">
                    Delete
                  </.dm_btn>
                </:confirm_action>
                <.dm_mdi name="delete-outline" />
              </.dm_btn>
            </div>
          </:col>
        </.dm_table>
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

      <div
        :if={Enum.empty?(@credentials)}
        class="rounded-2xl border border-dashed border-outline-variant bg-surface-container-low p-8 text-center"
      >
        <.dm_mdi name="key-off-outline" class="w-10 h-10 mx-auto text-on-surface-variant opacity-40 mb-3" />
        <p class="font-semibold text-on-surface">No credentials configured</p>
      </div>

      <div :if={!Enum.empty?(@credentials)} class="overflow-x-auto rounded-2xl border border-outline-variant bg-surface-container-low">
        <.dm_table id="credentials-table" data={@credentials} compact hover zebra class="min-w-[48rem]">
          <:col :let={row} label="Name" class="min-w-64">
            <form id={"credential-form-#{row.id}"} phx-submit="save_credential">
              <input type="hidden" name="config_id" value={row.id} />
            </form>
            <.dm_input
              form={"credential-form-#{row.id}"}
              name="name"
              value={row.credential["name"]}
              aria-label="Credential name"
              class="w-full"
              size="sm"
            />
          </:col>
          <:col :let={row} label="Secret Key" class="min-w-80">
            <.dm_input
              form={"credential-form-#{row.id}"}
              type="password"
              name="key"
              value={row.credential["key"]}
              placeholder="sk-..."
              aria-label="Credential secret key"
              class="w-full"
              size="sm"
            />
          </:col>
          <:col :let={row} label="Actions" class="min-w-32">
            <div class="flex items-center gap-2">
              <.dm_btn
                type="button"
                onclick={"document.getElementById('credential-form-#{row.id}').requestSubmit()"}
                variant="primary"
                size="sm"
              >
                Save
              </.dm_btn>
              <.dm_btn type="button" variant="error" size="sm" shape="circle" confirm="Are you sure you want to delete this credential?" confirm_title="Delete Credential">
                <:confirm_action>
                  <.dm_btn type="button" variant="ghost" onclick="this.closest('el-dm-dialog').close()">
                    Cancel
                  </.dm_btn>
                  <.dm_btn type="button" phx-click="delete_credential" phx-value-id={row.id} phx-hook="WebComponentHook" variant="error" onclick="this.closest('el-dm-dialog').close()">
                    Delete
                  </.dm_btn>
                </:confirm_action>
                <.dm_mdi name="delete-outline" />
              </.dm_btn>
            </div>
          </:col>
        </.dm_table>
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

      <div :if={!Enum.empty?(@result.skills)} class="overflow-x-auto rounded-2xl border border-outline-variant bg-surface-container-low">
        <.dm_table id="skills-table" data={@result.skills} compact hover zebra class="min-w-[64rem]">
          <:col :let={skill} label="Name" class="min-w-56">
            <div class="flex items-center gap-3 min-w-0">
              <div class="p-2 bg-primary/10 rounded-lg text-primary shrink-0">
                <.dm_mdi name="auto-fix" class="w-5 h-5" />
              </div>
              <span class="font-bold truncate">{skill.name}</span>
            </div>
          </:col>
          <:col :let={skill} label="Invocation" class="min-w-36">
            <span class="inline-flex rounded-full bg-surface-container-high px-3 py-1 text-[11px] font-bold uppercase tracking-wider text-on-surface-variant">
              {if skill.disable_model_invocation?, do: "Manual", else: "Model"}
            </span>
          </:col>
          <:col :let={skill} label="Description" class="min-w-80">
            <p class="text-sm text-on-surface-variant leading-relaxed">{skill.description}</p>
          </:col>
          <:col :let={skill} label="Path" class="min-w-96">
            <code class="block text-[11px] font-mono text-on-surface-variant break-all">
              {skill.path}
            </code>
          </:col>
        </.dm_table>
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
        :if={Enum.empty?(@servers)}
        class="rounded-2xl border border-dashed border-outline-variant bg-surface-container-low p-8 text-center"
      >
        <.dm_mdi name="server-network-off" class="w-10 h-10 mx-auto text-on-surface-variant opacity-40 mb-3" />
        <p class="font-semibold text-on-surface">No MCP servers configured</p>
      </div>

      <div :if={!Enum.empty?(@servers)} class="overflow-x-auto rounded-2xl border border-outline-variant bg-surface-container-low">
        <.dm_table id="mcp-servers-table" data={@servers} compact hover zebra class="min-w-[64rem]">
          <:col :let={row} label="Server" class="min-w-56">
            <div class="flex items-center gap-3 min-w-0">
              <div class="p-2 bg-primary/10 rounded-lg text-primary shrink-0">
                <.dm_mdi name="server-network-outline" class="w-5 h-5" />
              </div>
              <span class="font-bold truncate">{row.id}</span>
            </div>
          </:col>
          <:col :let={row} label="Transport" class="min-w-28">
            <span class="inline-flex rounded-full bg-surface-container-high px-3 py-1 text-[11px] font-bold uppercase tracking-wider text-on-surface-variant">
              {row.server["type"]}
            </span>
          </:col>
          <:col :let={row} label="Endpoint / Command" class="min-w-96">
            <code class="block font-mono text-xs text-on-surface-variant break-all">
              {mcp_server_summary(row.server)}
            </code>
          </:col>
          <:col :let={row} label="Linked Values" class="min-w-44">
            <div class="flex flex-wrap gap-2 text-[11px] text-on-surface-variant">
              <span :if={row.server["type"] == "stdio"} class="px-2 py-1 rounded-full bg-surface-container-high">
                {length(row.server["args"] || [])} args
              </span>
              <span :if={row.server["type"] == "stdio"} class="px-2 py-1 rounded-full bg-surface-container-high">
                {map_size(row.server["env"] || %{})} env
              </span>
              <span :if={row.server["type"] == "http"} class="px-2 py-1 rounded-full bg-surface-container-high">
                {map_size(row.server["headers"] || %{})} headers
              </span>
            </div>
          </:col>
          <:col :let={row} label="Actions" class="min-w-28">
            <div class="flex items-center gap-2">
              <.dm_btn
                id={"mcp-edit-server-#{row.id}"}
                type="button"
                phx-hook="WebComponentHook"
                phx-click="edit_mcp_server"
                phx-value-id={row.id}
                variant="outline"
                size="xs"
              >
                Edit
              </.dm_btn>
              <.dm_btn
                id={"mcp-delete-server-#{row.id}"}
                type="button"
                phx-hook="WebComponentHook"
                phx-click="confirm_delete_mcp_server"
                phx-value-id={row.id}
                variant="error"
                size="xs"
                shape="circle"
              >
                <.dm_mdi name="delete-outline" />
              </.dm_btn>
            </div>
          </:col>
        </.dm_table>
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
    {:noreply, reload_current_settings_data(socket)}
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

    {:noreply, reload_current_settings_data(socket)}
  end

  @impl true
  def handle_event("save_provider", params, socket) do
    %{"config_id" => id} = params
    updates = Map.drop(params, ["config_id", "_csrf_token"])
    ConfigManager.update_provider(id, updates)
    {:noreply, socket |> reload_current_settings_data() |> put_flash(:info, "Provider updated")}
  end

  @impl true
  def handle_event("delete_provider", %{"id" => id}, socket) do
    ConfigManager.delete_provider(id)
    {:noreply, reload_current_settings_data(socket)}
  end

  @impl true
  def handle_event("set_active_provider", %{"id" => id}, socket) do
    ConfigManager.set_active_provider(id)
    {:noreply, reload_current_settings_data(socket)}
  end

  # Credential Handlers

  @impl true
  def handle_event("add_credential", _, socket) do
    ConfigManager.add_credential("New Key", "")
    {:noreply, reload_current_settings_data(socket)}
  end

  @impl true
  def handle_event("save_credential", params, socket) do
    %{"config_id" => id, "name" => name, "key" => key} = params
    ConfigManager.update_credential(id, %{"name" => name, "key" => key})
    {:noreply, socket |> reload_current_settings_data() |> put_flash(:info, "Credential updated")}
  end

  @impl true
  def handle_event("delete_credential", %{"id" => id}, socket) do
    ConfigManager.delete_credential(id)
    {:noreply, reload_current_settings_data(socket)}
  end

  @impl true
  def handle_event("save_system_prompt", %{"system_prompt" => prompt}, socket) do
    ConfigManager.update_system_prompt(prompt)
    {:noreply, socket |> load_context() |> put_flash(:info, "AGENTS.md updated")}
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
       |> assign(:mcp_form, nil)
       |> assign_settings_data_async(:mcp)
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
     |> assign(:mcp_form, nil)
     |> assign(:deleting_mcp_server, nil)
     |> assign_settings_data_async(:mcp)}
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

  defp load_settings_action(socket, action)
       when action in [:providers, :credentials, :skills, :mcp] do
    socket
    |> clear_mcp_state(action)
    |> assign_settings_data_async(action)
  end

  defp load_settings_action(socket, :system_prompt) do
    socket
    |> clear_mcp_state(:system_prompt)
    |> load_context()
  end

  defp load_settings_action(socket, :hooks) do
    socket
    |> clear_mcp_state(:hooks)
    |> load_hooks()
  end

  defp load_settings_action(socket, _action), do: socket

  defp clear_mcp_state(socket, :mcp), do: socket

  defp clear_mcp_state(socket, _action) do
    socket
    |> assign(:mcp_form, nil)
    |> assign(:deleting_mcp_server, nil)
  end

  defp assign_settings_data_async(socket, action) do
    socket
    |> assign(:settings_data, AsyncResult.loading())
    |> assign_async(:settings_data, fn ->
      {:ok, %{settings_data: load_settings_data(action)}}
    end)
  end

  defp reload_current_settings_data(%{assigns: %{live_action: action}} = socket)
       when action in [:providers, :credentials, :skills, :mcp],
       do: assign_settings_data_async(socket, action)

  defp reload_current_settings_data(socket), do: socket

  defp load_settings_data(:providers) do
    config = ConfigManager.get_config()

    %{
      providers: provider_rows(config["providers"]),
      credentials: config["credentials"] || %{},
      active_provider_id: config["active_provider_id"] || ""
    }
  end

  defp load_settings_data(:credentials) do
    config = ConfigManager.get_config()

    %{
      credentials: credential_rows(config["credentials"])
    }
  end

  defp load_settings_data(:skills), do: Skills.list_global()

  defp load_settings_data(:mcp) do
    config = ConfigManager.get_config()
    mcp_config = ConfigManager.get_mcp_config()

    %{
      servers: mcp_server_rows(mcp_config["servers"]),
      credentials: config["credentials"] || %{},
      file: ConfigManager.mcp_file()
    }
  end

  defp load_context(socket) do
    assign(socket, :context_config, ConfigManager.get_config())
  end

  defp load_hooks(socket) do
    path = ConfigManager.hooks_file()

    socket
    |> assign(:hooks_json, ConfigManager.get_hooks_json(path))
    |> assign(:hooks_file, path)
  end

  defp provider_rows(providers) when is_map(providers) do
    providers
    |> Enum.sort_by(fn {id, provider} -> {String.downcase(provider["name"] || id), id} end)
    |> Enum.map(fn {id, provider} -> %{id: id, provider: provider} end)
  end

  defp provider_rows(_providers), do: []

  defp credential_rows(credentials) when is_map(credentials) do
    credentials
    |> Enum.sort_by(fn {id, credential} -> {String.downcase(credential["name"] || id), id} end)
    |> Enum.map(fn {id, credential} -> %{id: id, credential: credential} end)
  end

  defp credential_rows(_credentials), do: []

  defp mcp_server_rows(servers) when is_map(servers) do
    servers
    |> Enum.sort_by(fn {id, _server} -> id end)
    |> Enum.map(fn {id, server} -> %{id: id, server: server} end)
  end

  defp mcp_server_rows(_servers), do: []

  defp credential_select_options(credentials) do
    [
      {"", "No Key Selected"}
      | Enum.map(credential_rows(credentials), &{&1.id, &1.credential["name"] || &1.id})
    ]
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
