defmodule Sigma.Web.SettingsLive do
  use Sigma.Web, :live_view

  alias Sigma.Agent.ContextBuilder
  alias Sigma.Session.{ConfigManager, Skills}
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
     |> assign(:provider_form, nil)
     |> assign(:deleting_provider, nil)
     |> assign(:credential_form, nil)
     |> assign(:deleting_credential, nil)
     |> assign(:skills_query, "")
     |> assign(:selected_skill_names, [])
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
                  form={@provider_form}
                  deleting_provider={@deleting_provider}
                />
              </.settings_async_result>
            <% :credentials -> %>
              <.settings_async_result :let={data} assign={@settings_data}>
                <.render_credentials
                  credentials={data.credentials}
                  form={@credential_form}
                  deleting_credential={@deleting_credential}
                />
              </.settings_async_result>
            <% :system_prompt -> %>
              <.render_context
                agents_md={@context_config["system_prompt"]}
                system_prompt={ContextBuilder.system_prompt_template()}
              />
            <% :skills -> %>
              <.settings_async_result :let={data} assign={@settings_data}>
                <.render_skills
                  result={data}
                  query={@skills_query}
                  selected_skill_names={@selected_skill_names}
                />
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
    do:
      "flex w-full items-center justify-start gap-3 rounded-lg bg-primary px-4 py-3 font-medium text-primary-content transition-colors hover:bg-primary hover:text-primary-content hover:!opacity-100"

  defp settings_nav_class(_current_action, _item_action),
    do:
      "flex w-full items-center justify-start gap-3 rounded-lg px-4 py-3 font-medium text-secondary-content transition-colors hover:bg-secondary-content/10 hover:text-secondary-content hover:!opacity-100"

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
        <.dm_btn
          id="provider-new-btn"
          phx-click="add_provider"
          phx-hook="WebComponentHook"
          variant="primary"
          size="sm"
        >
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
        <.dm_table id="providers-table" data={@providers} compact hover zebra class="settings-table min-w-[60rem]">
          <:col :let={row} label="Name" class="min-w-52">
            <div class="font-semibold text-on-surface">{row.provider["name"] || row.id}</div>
            <div class="text-xs text-on-surface-variant font-mono">{row.id}</div>
          </:col>
          <:col :let={row} label="API" class="min-w-36">
            {format_api_type(row.provider["api_type"])}
          </:col>
          <:col :let={row} label="Credential" class="min-w-52">
            {credential_name(@credentials, row.provider["credential_id"])}
          </:col>
          <:col :let={row} label="Model" class="min-w-52">
            <span class="font-mono text-xs">{row.provider["model"] || "-"}</span>
          </:col>
          <:col :let={row} label="Base URL" class="min-w-64">
            <span class="font-mono text-xs text-on-surface-variant">
              {blank_fallback(row.provider["base_url"], "Default endpoint")}
            </span>
          </:col>
          <:col :let={row} label="Status" class="min-w-28">
            <div :if={@active_id == row.id} class="inline-flex bg-success/20 text-success text-[10px] font-bold px-3 py-1 rounded-full border border-success/30">
              ACTIVE
            </div>
            <.dm_tooltip :if={@active_id != row.id} content="Activate">
              <.dm_btn
                phx-click="set_active_provider"
                phx-value-id={row.id}
                phx-hook="WebComponentHook"
                variant="outline"
                size="xs"
                shape="circle"
                aria-label="Activate"
              >
                <.dm_mdi name="check-circle-outline" />
              </.dm_btn>
            </.dm_tooltip>
          </:col>
          <:col :let={row} label="Actions" class="min-w-32">
            <div class="flex items-center gap-2">
              <.dm_tooltip content="Edit">
                <.dm_btn
                  id={"provider-edit-#{row.id}"}
                  type="button"
                  phx-click="edit_provider"
                  phx-value-id={row.id}
                  phx-hook="WebComponentHook"
                  variant="outline"
                  size="xs"
                  shape="circle"
                  aria-label="Edit"
                >
                  <.dm_mdi name="pencil-outline" />
                </.dm_btn>
              </.dm_tooltip>
              <.dm_tooltip content="Delete">
                <.dm_btn
                  id={"provider-delete-#{row.id}"}
                  type="button"
                  phx-click="confirm_delete_provider"
                  phx-value-id={row.id}
                  phx-hook="WebComponentHook"
                  variant="error"
                  size="xs"
                  shape="circle"
                  aria-label="Delete"
                >
                  <.dm_mdi name="delete-outline" />
                </.dm_btn>
              </.dm_tooltip>
            </div>
          </:col>
        </.dm_table>
      </div>

      <.dm_modal :if={@form} id="provider-settings-modal" phx-hook="ModalHook" size="lg" responsive={true} hide_close={true}>
        <:title>
          <div class="flex items-center gap-2 text-on-surface">
            <.dm_mdi name="robot-outline" class="w-6 h-6 text-primary" />
            <span>{if @form["mode"] == "new", do: "New Provider", else: "Edit Provider"}</span>
          </div>
        </:title>
        <:body>
          <form id="provider-settings-form" phx-change="change_provider_form" phx-submit="save_provider" class="space-y-5">
            <input type="hidden" name="provider[mode]" value={@form["mode"]} />
            <input type="hidden" name="provider[id]" value={@form["id"] || ""} />

            <.dm_input
              name="provider[name]"
              value={@form["name"]}
              label="Name"
              placeholder="Anthropic"
              class="w-full"
              size="sm"
            />
            <.dm_select
              name="provider[api_type]"
              value={@form["api_type"]}
              label="API"
              options={provider_api_options()}
              size="sm"
              class="w-full"
            />
            <.dm_select
              name="provider[credential_id]"
              value={@form["credential_id"]}
              label="Credential"
              options={credential_select_options(@credentials)}
              size="sm"
              class="w-full"
            />
            <.dm_select
              name="provider[auth_type]"
              value={@form["auth_type"]}
              label="Auth Type"
              options={provider_auth_type_options()}
              size="sm"
              class="w-full"
            />
            <.dm_input
              :if={@form["auth_type"] == "custom_header"}
              name="provider[auth_header_name]"
              value={@form["auth_header_name"]}
              label="Header Name"
              placeholder="X-API-Key"
              class="w-full"
              size="sm"
            />
            <.dm_input
              name="provider[model]"
              value={@form["model"]}
              label="Current Model"
              placeholder="claude-3-5-sonnet-latest"
              class="w-full"
              size="sm"
            />
            <.dm_input
              name="provider[base_url]"
              value={@form["base_url"]}
              label="Base URL"
              placeholder="https://api.anthropic.com"
              class="w-full"
              size="sm"
            />
          </form>
        </:body>
        <:footer>
          <.dm_btn
            id="provider-cancel-form-btn"
            type="button"
            phx-click="cancel_provider_form"
            phx-hook="WebComponentHook"
            variant="ghost"
          >
            Cancel
          </.dm_btn>
          <.dm_btn
            id="provider-save-form-btn"
            type="button"
            onclick="document.getElementById('provider-settings-form').requestSubmit()"
            variant="primary"
          >
            Save Provider
          </.dm_btn>
        </:footer>
      </.dm_modal>

      <.dm_modal :if={@deleting_provider} id="delete-provider-modal" phx-hook="ModalHook">
        <:title>
          <div class="flex items-center gap-2 text-error">
            <.dm_mdi name="alert-circle-outline" class="w-6 h-6" />
            <span>Delete Provider</span>
          </div>
        </:title>
        <:body>
          <p class="text-on-surface">
            Delete the provider <span class="font-bold">"{@deleting_provider["name"]}"</span>?
          </p>
        </:body>
        <:footer>
          <.dm_btn
            id="provider-cancel-delete-btn"
            type="button"
            phx-click="cancel_delete_provider"
            phx-hook="WebComponentHook"
            variant="ghost"
          >
            Cancel
          </.dm_btn>
          <.dm_btn
            id="provider-confirm-delete-btn"
            type="button"
            phx-click="delete_provider"
            phx-value-id={@deleting_provider["id"]}
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

  defp render_credentials(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex justify-between items-center text-on-surface">
        <h2 class="text-2xl font-bold font-display">API Credentials</h2>
        <.dm_btn
          id="credential-new-btn"
          phx-click="add_credential"
          phx-hook="WebComponentHook"
          variant="primary"
          size="sm"
        >
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
        <.dm_table id="credentials-table" data={@credentials} compact hover zebra class="settings-table min-w-[48rem]">
          <:col :let={row} label="Name" class="min-w-64">
            <div class="font-semibold text-on-surface">{row.credential["name"] || row.id}</div>
            <div class="text-xs text-on-surface-variant font-mono">{row.id}</div>
          </:col>
          <:col :let={row} label="Secret Key" class="min-w-80">
            <span class="font-mono text-xs text-on-surface-variant">
              {credential_key_preview(row.credential["key"])}
            </span>
          </:col>
          <:col :let={row} label="Actions" class="min-w-32">
            <div class="flex items-center gap-2">
              <.dm_tooltip content="Edit">
                <.dm_btn
                  id={"credential-edit-#{row.id}"}
                  type="button"
                  phx-click="edit_credential"
                  phx-value-id={row.id}
                  phx-hook="WebComponentHook"
                  variant="outline"
                  size="xs"
                  shape="circle"
                  aria-label="Edit"
                >
                  <.dm_mdi name="pencil-outline" />
                </.dm_btn>
              </.dm_tooltip>
              <.dm_tooltip content="Delete">
                <.dm_btn
                  id={"credential-delete-#{row.id}"}
                  type="button"
                  phx-click="confirm_delete_credential"
                  phx-value-id={row.id}
                  phx-hook="WebComponentHook"
                  variant="error"
                  size="xs"
                  shape="circle"
                  aria-label="Delete"
                >
                  <.dm_mdi name="delete-outline" />
                </.dm_btn>
              </.dm_tooltip>
            </div>
          </:col>
        </.dm_table>
      </div>

      <.dm_modal :if={@form} id="credential-settings-modal" phx-hook="ModalHook" size="md" responsive={true} hide_close={true}>
        <:title>
          <div class="flex items-center gap-2 text-on-surface">
            <.dm_mdi name="key-outline" class="w-6 h-6 text-primary" />
            <span>{if @form["mode"] == "new", do: "New Credential", else: "Edit Credential"}</span>
          </div>
        </:title>
        <:body>
          <form id="credential-settings-form" phx-submit="save_credential" class="space-y-5">
            <input type="hidden" name="credential[mode]" value={@form["mode"]} />
            <input type="hidden" name="credential[id]" value={@form["id"] || ""} />

            <.dm_input
              name="credential[name]"
              value={@form["name"]}
              label="Name"
              placeholder="OpenAI Key"
              class="w-full"
              size="sm"
            />
            <.dm_input
              name="credential[key]"
              value={@form["key"]}
              type="password"
              label="Secret Key"
              placeholder="sk-..."
              class="w-full"
              size="sm"
            />
          </form>
        </:body>
        <:footer>
          <.dm_btn
            id="credential-cancel-form-btn"
            type="button"
            phx-click="cancel_credential_form"
            phx-hook="WebComponentHook"
            variant="ghost"
          >
            Cancel
          </.dm_btn>
          <.dm_btn
            id="credential-save-form-btn"
            type="button"
            onclick="document.getElementById('credential-settings-form').requestSubmit()"
            variant="primary"
          >
            Save Credential
          </.dm_btn>
        </:footer>
      </.dm_modal>

      <.dm_modal :if={@deleting_credential} id="delete-credential-modal" phx-hook="ModalHook">
        <:title>
          <div class="flex items-center gap-2 text-error">
            <.dm_mdi name="alert-circle-outline" class="w-6 h-6" />
            <span>Delete Credential</span>
          </div>
        </:title>
        <:body>
          <p class="text-on-surface">
            Delete the credential <span class="font-bold">"{@deleting_credential["name"]}"</span>?
            Providers using it will keep their provider record but lose the credential reference.
          </p>
        </:body>
        <:footer>
          <.dm_btn
            id="credential-cancel-delete-btn"
            type="button"
            phx-click="cancel_delete_credential"
            phx-hook="WebComponentHook"
            variant="ghost"
          >
            Cancel
          </.dm_btn>
          <.dm_btn
            id="credential-confirm-delete-btn"
            type="button"
            phx-click="delete_credential"
            phx-value-id={@deleting_credential["id"]}
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
    query = assigns[:query] || ""
    selected_skill_names = assigns[:selected_skill_names] || []
    skills = assigns.result.skills
    filtered_skills = filter_skills(skills, query)
    visible_skill_names = Enum.map(filtered_skills, & &1.name)
    selected_visible_skill_count = Enum.count(visible_skill_names, &(&1 in selected_skill_names))

    all_visible_skills_selected? =
      filtered_skills != [] and selected_visible_skill_count == length(filtered_skills)

    some_visible_skills_selected? =
      selected_visible_skill_count > 0 and !all_visible_skills_selected?

    assigns =
      assigns
      |> assign(:query, query)
      |> assign(:selected_skill_names, selected_skill_names)
      |> assign(:filtered_skills, filtered_skills)
      |> assign(:total_skills, length(skills))
      |> assign(:shown_skills, length(filtered_skills))
      |> assign(:selected_skill_count, length(selected_skill_names))
      |> assign(:all_visible_skills_selected?, all_visible_skills_selected?)
      |> assign(:some_visible_skills_selected?, some_visible_skills_selected?)
      |> assign(:enabled_skills, Enum.count(skills, & &1.enabled?))

    ~H"""
    <div class="space-y-6">
      <div class="flex justify-between items-center text-on-surface">
        <div>
          <h2 class="text-2xl font-bold font-display">Skills</h2>
          <p class="text-sm text-on-surface-variant font-mono mt-1">{@result.dir}</p>
        </div>
      </div>

      <div
        :if={!Enum.empty?(@result.skills)}
        class="flex flex-col gap-3 rounded-2xl border border-outline-variant bg-surface-container-low p-4 md:flex-row md:items-end md:justify-between"
      >
        <form id="skills-filter-form" phx-change="filter_skills" class="w-full md:max-w-md">
          <.dm_input
            id="skills-search"
            type="search"
            name="skills[query]"
            label="Search"
            value={@query}
            placeholder="Name, description, or path"
            phx-debounce="200"
          />
        </form>

        <div class="flex flex-wrap items-center gap-2">
          <span class="text-xs font-medium text-on-surface-variant">
            {@shown_skills} shown / {@selected_skill_count} selected / {@enabled_skills} enabled
          </span>
          <.dm_btn
            id="skills-clear-selection"
            type="button"
            phx-hook="WebComponentHook"
            phx-click="clear_skill_selection"
            variant="outline"
            size="sm"
            disabled={@selected_skill_count == 0}
          >
            <:prefix><.dm_mdi name="checkbox-blank-off-outline" /></:prefix>
            Clear
          </.dm_btn>
          <.dm_btn
            id="skills-enable-selected"
            type="button"
            phx-hook="WebComponentHook"
            phx-click="set_selected_skills_enabled"
            phx-value-enabled="true"
            variant="outline"
            size="sm"
            disabled={@selected_skill_count == 0}
          >
            <:prefix><.dm_mdi name="check-circle-outline" /></:prefix>
            Enable selected
          </.dm_btn>
          <.dm_btn
            id="skills-disable-selected"
            type="button"
            phx-hook="WebComponentHook"
            phx-click="set_selected_skills_enabled"
            phx-value-enabled="false"
            variant="outline"
            size="sm"
            disabled={@selected_skill_count == 0}
          >
            <:prefix><.dm_mdi name="close-circle-outline" /></:prefix>
            Disable selected
          </.dm_btn>
        </div>
      </div>

      <div
        :if={Enum.empty?(@result.skills)}
        class="rounded-2xl border border-dashed border-outline-variant bg-surface-container-low p-8 text-center"
      >
        <.dm_mdi name="auto-fix-off" class="w-10 h-10 mx-auto text-on-surface-variant opacity-40 mb-3" />
        <p class="font-semibold text-on-surface">No global skills found</p>
      </div>

      <div
        :if={!Enum.empty?(@result.skills) and Enum.empty?(@filtered_skills)}
        class="rounded-2xl border border-dashed border-outline-variant bg-surface-container-low p-8 text-center"
      >
        <.dm_mdi name="magnify-close" class="w-10 h-10 mx-auto text-on-surface-variant opacity-40 mb-3" />
        <p class="font-semibold text-on-surface">No matching skills</p>
      </div>

      <div
        :if={!Enum.empty?(@filtered_skills)}
        class="overflow-x-auto rounded-2xl border border-outline-variant bg-surface-container-low"
      >
        <table
          role="table"
          id="skills-table"
          class="table table-zebra table-hover table-compact settings-table table-fixed min-w-[72rem]"
        >
          <thead role="row-group" class="sticky top-0">
            <tr role="row">
              <th role="columnheader" scope="col" class="w-16">
                <.dm_checkbox
                  id="skills-select-all"
                  name="skills_select_all"
                  checked={@all_visible_skills_selected?}
                  indeterminate={@some_visible_skills_selected?}
                  size="sm"
                  aria-label="Select all shown skills"
                  phx-click="toggle_visible_skill_selection"
                  phx-value-selected={to_string(!@all_visible_skills_selected?)}
                />
              </th>
              <th role="columnheader" scope="col" class="min-w-56">Name</th>
              <th role="columnheader" scope="col" class="min-w-28">Enabled</th>
              <th role="columnheader" scope="col" class="min-w-36">Invocation</th>
              <th
                role="columnheader"
                scope="col"
                class="settings-skills-description-cell"
              >
                Description
              </th>
              <th role="columnheader" scope="col" class="min-w-96">Path</th>
            </tr>
          </thead>
          <tbody role="row-group">
            <tr :for={skill <- @filtered_skills} role="row">
              <td data-label="Select" role="cell" class="w-16">
                <.dm_checkbox
                  id={"skill-select-#{skill_row_id(skill)}"}
                  name={"skill_selected[#{skill.name}]"}
                  checked={skill_selected?(@selected_skill_names, skill.name)}
                  size="sm"
                  aria-label={"Select #{skill.name}"}
                  phx-click="toggle_skill_selection"
                  phx-value-name={skill.name}
                  phx-value-selected={to_string(!skill_selected?(@selected_skill_names, skill.name))}
                />
              </td>
              <td data-label="Name" role="cell" class="min-w-56">
                <div class="flex items-center gap-3 min-w-0">
                  <div class="p-2 bg-primary/10 rounded-lg text-primary shrink-0">
                    <.dm_mdi name="auto-fix" class="w-5 h-5" />
                  </div>
                  <span class="font-bold truncate">{skill.name}</span>
                </div>
              </td>
              <td data-label="Enabled" role="cell" class="min-w-28">
                <.dm_switch
                  id={"skill-enabled-#{skill_row_id(skill)}"}
                  name={"skill_enabled[#{skill.name}]"}
                  checked={skill.enabled?}
                  size="sm"
                  aria-label={"Enable #{skill.name}"}
                  phx-click="toggle_skill"
                  phx-value-name={skill.name}
                  phx-value-enabled={to_string(!skill.enabled?)}
                />
              </td>
              <td data-label="Invocation" role="cell" class="min-w-36">
                <span class="inline-flex rounded-full bg-surface-container-high px-3 py-1 text-[11px] font-bold uppercase tracking-wider text-on-surface-variant">
                  {if skill.disable_model_invocation?, do: "Manual", else: "Model"}
                </span>
              </td>
              <td
                data-label="Description"
                role="cell"
                class="settings-skills-description-cell"
              >
                <.dm_popover
                  id={"skill-description-#{skill_row_id(skill)}"}
                  trigger_mode="hover"
                  placement="top-start"
                  class="max-w-md"
                >
                  <:trigger>
                    <p class="settings-skills-description-trigger text-sm text-on-surface-variant">
                      {skill.description}
                    </p>
                  </:trigger>
                  <p class="max-w-md whitespace-normal text-sm leading-relaxed text-on-surface">
                    {skill.description}
                  </p>
                </.dm_popover>
              </td>
              <td data-label="Path" role="cell" class="min-w-96">
                <code class="block text-[11px] font-mono text-on-surface-variant break-all">
                  {skill.path}
                </code>
              </td>
            </tr>
          </tbody>
        </table>
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
        <.dm_table id="mcp-servers-table" data={@servers} compact hover zebra class="settings-table min-w-[64rem]">
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
              <.dm_tooltip content="Edit">
                <.dm_btn
                  id={"mcp-edit-server-#{row.id}"}
                  type="button"
                  phx-hook="WebComponentHook"
                  phx-click="edit_mcp_server"
                  phx-value-id={row.id}
                  variant="outline"
                  size="xs"
                  shape="circle"
                  aria-label="Edit"
                >
                  <.dm_mdi name="pencil-outline" />
                </.dm_btn>
              </.dm_tooltip>
              <.dm_tooltip content="Delete">
                <.dm_btn
                  id={"mcp-delete-server-#{row.id}"}
                  type="button"
                  phx-hook="WebComponentHook"
                  phx-click="confirm_delete_mcp_server"
                  phx-value-id={row.id}
                  variant="error"
                  size="xs"
                  shape="circle"
                  aria-label="Delete"
                >
                  <.dm_mdi name="delete-outline" />
                </.dm_btn>
              </.dm_tooltip>
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

              <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
                <.dm_select
                  name="mcp[auth_type]"
                  value={@form["auth_type"] || ""}
                  label="Auth Type"
                  size="sm"
                  class="w-full"
                >
                  <option
                    :for={{value, label} <- mcp_auth_type_options()}
                    value={value}
                    selected={(@form["auth_type"] || "") == value}
                  >
                    {label}
                  </option>
                </.dm_select>

                <.dm_input
                  :if={@form["auth_type"] == "custom_header"}
                  name="mcp[auth_header_name]"
                  value={@form["auth_header_name"] || ""}
                  label="Header Name"
                  placeholder="X-API-Key"
                  class="w-full"
                  size="sm"
                />
              </div>

              <div
                :if={mcp_auth_enabled?(@form)}
                class="grid grid-cols-1 md:grid-cols-2 gap-4 items-end"
              >
                <% auth_credential_selected? = mcp_auth_credential_selected?(@form) %>
                <input
                  :if={auth_credential_selected?}
                  type="hidden"
                  name="mcp[auth_value]"
                  value=""
                />
                <.dm_input
                  name="mcp[auth_value]"
                  value={if auth_credential_selected?, do: "", else: @form["auth_value"] || ""}
                  label="Value"
                  placeholder={if auth_credential_selected?, do: "Using credential", else: "Token value"}
                  class="w-full"
                  size="sm"
                  disabled={auth_credential_selected?}
                />
                <.dm_select
                  name="mcp[auth_credential_id]"
                  value={@form["auth_credential_id"] || ""}
                  label="Credential"
                  size="sm"
                  class="w-full"
                >
                  <option value="" selected={(@form["auth_credential_id"] || "") == ""}>
                    Input value
                  </option>
                  <option
                    :for={{credential_id, credential} <- @credentials}
                    value={credential_id}
                    selected={@form["auth_credential_id"] == credential_id}
                  >
                    {credential["name"]}
                  </option>
                </.dm_select>
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
    {:noreply, assign(socket, :provider_form, blank_provider_form())}
  end

  @impl true
  def handle_event("edit_provider", %{"id" => id}, socket) do
    config = ConfigManager.get_config()
    provider = get_in(config, ["providers", id]) || %{"id" => id}
    {:noreply, assign(socket, :provider_form, provider_form_from_config(id, provider))}
  end

  @impl true
  def handle_event("cancel_provider_form", _, socket) do
    {:noreply, assign(socket, :provider_form, nil)}
  end

  @impl true
  def handle_event("change_provider_form", %{"provider" => params}, socket) do
    current_form = socket.assigns.provider_form || blank_provider_form()
    params = maybe_update_default_auth_type(current_form, params)

    form =
      current_form
      |> Map.merge(params)
      |> normalize_provider_form()

    {:noreply, assign(socket, :provider_form, form)}
  end

  @impl true
  def handle_event("save_provider", %{"provider" => params}, socket) do
    form =
      socket.assigns.provider_form
      |> Kernel.||(blank_provider_form())
      |> Map.merge(params)
      |> normalize_provider_form()

    {:ok, _} = save_provider_form(form)

    {:noreply,
     socket
     |> assign(:provider_form, nil)
     |> reload_current_settings_data()
     |> put_flash(:info, provider_saved_message(form))}
  end

  @impl true
  def handle_event("confirm_delete_provider", %{"id" => id}, socket) do
    provider =
      ConfigManager.get_config() |> get_in(["providers", id]) |> Kernel.||(%{"name" => id})

    {:noreply,
     assign(socket, :deleting_provider, %{
       "id" => id,
       "name" => provider["name"] || id
     })}
  end

  @impl true
  def handle_event("cancel_delete_provider", _, socket) do
    {:noreply, assign(socket, :deleting_provider, nil)}
  end

  @impl true
  def handle_event("delete_provider", %{"id" => id}, socket) do
    ConfigManager.delete_provider(id)

    {:noreply,
     socket
     |> assign(:deleting_provider, nil)
     |> reload_current_settings_data()}
  end

  @impl true
  def handle_event("set_active_provider", %{"id" => id}, socket) do
    ConfigManager.set_active_provider(id)
    {:noreply, reload_current_settings_data(socket)}
  end

  # Credential Handlers

  @impl true
  def handle_event("add_credential", _, socket) do
    {:noreply, assign(socket, :credential_form, blank_credential_form())}
  end

  @impl true
  def handle_event("edit_credential", %{"id" => id}, socket) do
    config = ConfigManager.get_config()
    credential = get_in(config, ["credentials", id]) || %{"id" => id}
    {:noreply, assign(socket, :credential_form, credential_form_from_config(id, credential))}
  end

  @impl true
  def handle_event("cancel_credential_form", _, socket) do
    {:noreply, assign(socket, :credential_form, nil)}
  end

  @impl true
  def handle_event("save_credential", %{"credential" => params}, socket) do
    form =
      socket.assigns.credential_form
      |> Kernel.||(blank_credential_form())
      |> Map.merge(params)

    {:ok, _} = save_credential_form(form)

    {:noreply,
     socket
     |> assign(:credential_form, nil)
     |> reload_current_settings_data()
     |> put_flash(:info, credential_saved_message(form))}
  end

  @impl true
  def handle_event("confirm_delete_credential", %{"id" => id}, socket) do
    credential =
      ConfigManager.get_config() |> get_in(["credentials", id]) |> Kernel.||(%{"name" => id})

    {:noreply,
     assign(socket, :deleting_credential, %{
       "id" => id,
       "name" => credential["name"] || id
     })}
  end

  @impl true
  def handle_event("cancel_delete_credential", _, socket) do
    {:noreply, assign(socket, :deleting_credential, nil)}
  end

  @impl true
  def handle_event("delete_credential", %{"id" => id}, socket) do
    ConfigManager.delete_credential(id)

    {:noreply,
     socket
     |> assign(:deleting_credential, nil)
     |> reload_current_settings_data()}
  end

  @impl true
  def handle_event("save_system_prompt", %{"system_prompt" => prompt}, socket) do
    ConfigManager.update_system_prompt(prompt)
    {:noreply, socket |> load_context() |> put_flash(:info, "AGENTS.md updated")}
  end

  # Skills Handlers

  @impl true
  def handle_event("filter_skills", %{"skills" => %{"query" => query}}, socket) do
    {:noreply, assign(socket, :skills_query, trim_form_value(query))}
  end

  @impl true
  def handle_event("filter_skills", _, socket) do
    {:noreply, assign(socket, :skills_query, "")}
  end

  @impl true
  def handle_event("toggle_skill_selection", %{"name" => name, "selected" => selected}, socket) do
    selected_skill_names =
      socket.assigns.selected_skill_names
      |> set_skill_selection(name, selected == "true")

    {:noreply, assign(socket, :selected_skill_names, selected_skill_names)}
  end

  @impl true
  def handle_event("toggle_visible_skill_selection", %{"selected" => selected}, socket) do
    visible_names =
      Skills.list_global().skills
      |> filter_skills(socket.assigns.skills_query)
      |> Enum.map(& &1.name)

    selected_skill_names =
      if selected == "true" do
        merge_skill_selection(socket.assigns.selected_skill_names, visible_names)
      else
        remove_skill_selection(socket.assigns.selected_skill_names, visible_names)
      end

    {:noreply, assign(socket, :selected_skill_names, selected_skill_names)}
  end

  @impl true
  def handle_event("clear_skill_selection", _, socket) do
    {:noreply, assign(socket, :selected_skill_names, [])}
  end

  @impl true
  def handle_event("toggle_skill", %{"name" => name, "enabled" => enabled}, socket) do
    enabled? = enabled == "true"
    ConfigManager.set_global_skill_enabled(name, enabled?)

    {:noreply,
     socket
     |> reload_current_settings_data()
     |> put_flash(:info, skill_status_message(name, enabled?))}
  end

  @impl true
  def handle_event("set_selected_skills_enabled", %{"enabled" => enabled}, socket) do
    enabled? = enabled == "true"

    names =
      Skills.list_global().skills
      |> selected_existing_skill_names(socket.assigns.selected_skill_names)

    ConfigManager.set_global_skills_enabled(names, enabled?)

    {:noreply,
     socket
     |> assign(:selected_skill_names, [])
     |> reload_current_settings_data()
     |> put_flash(:info, bulk_skill_status_message(names, enabled?))}
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
    |> clear_settings_transient_state(action)
    |> assign_settings_data_async(action)
  end

  defp load_settings_action(socket, :system_prompt) do
    socket
    |> clear_settings_transient_state(:system_prompt)
    |> load_context()
  end

  defp load_settings_action(socket, :hooks) do
    socket
    |> clear_settings_transient_state(:hooks)
    |> load_hooks()
  end

  defp load_settings_action(socket, _action), do: socket

  defp clear_settings_transient_state(socket, action) do
    socket
    |> clear_mcp_state(action)
    |> clear_provider_state(action)
    |> clear_credential_state(action)
    |> clear_skills_state(action)
  end

  defp clear_mcp_state(socket, :mcp), do: socket

  defp clear_mcp_state(socket, _action) do
    socket
    |> assign(:mcp_form, nil)
    |> assign(:deleting_mcp_server, nil)
  end

  defp clear_provider_state(socket, :providers), do: socket

  defp clear_provider_state(socket, _action) do
    socket
    |> assign(:provider_form, nil)
    |> assign(:deleting_provider, nil)
  end

  defp clear_credential_state(socket, :credentials), do: socket

  defp clear_credential_state(socket, _action) do
    socket
    |> assign(:credential_form, nil)
    |> assign(:deleting_credential, nil)
  end

  defp clear_skills_state(socket, :skills), do: socket

  defp clear_skills_state(socket, _action) do
    socket
    |> assign(:skills_query, "")
    |> assign(:selected_skill_names, [])
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

  defp filter_skills(skills, query) do
    query = (query || "") |> to_string() |> String.trim() |> String.downcase()

    if query == "" do
      skills
    else
      Enum.filter(skills, fn skill ->
        skill
        |> skill_search_text()
        |> String.contains?(query)
      end)
    end
  end

  defp skill_search_text(skill) do
    [
      skill.name,
      skill.description,
      skill.path,
      if(skill.enabled?, do: "enabled", else: "disabled"),
      if(skill.disable_model_invocation?, do: "manual", else: "model")
    ]
    |> Enum.join(" ")
    |> String.downcase()
  end

  defp skill_row_id(skill) do
    skill.name
    |> String.replace(~r/[^a-zA-Z0-9_-]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "unnamed"
      id -> id
    end
  end

  defp skill_selected?(selected_skill_names, name) do
    Enum.member?(selected_skill_names, name)
  end

  defp set_skill_selection(selected_skill_names, name, selected?) do
    selected_skill_names =
      selected_skill_names
      |> List.wrap()
      |> Enum.reject(&(&1 in [nil, ""]))

    if selected? do
      [name | selected_skill_names]
    else
      Enum.reject(selected_skill_names, &(&1 == name))
    end
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp merge_skill_selection(selected_skill_names, names) do
    (List.wrap(selected_skill_names) ++ List.wrap(names))
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp remove_skill_selection(selected_skill_names, names) do
    names = names |> List.wrap() |> MapSet.new()

    selected_skill_names
    |> List.wrap()
    |> Enum.reject(&MapSet.member?(names, &1))
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp selected_existing_skill_names(skills, selected_skill_names) do
    existing_names = skills |> Enum.map(& &1.name) |> MapSet.new()

    selected_skill_names
    |> List.wrap()
    |> Enum.filter(&MapSet.member?(existing_names, &1))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp skill_status_message(name, true), do: "#{name} enabled"
  defp skill_status_message(name, false), do: "#{name} disabled"

  defp bulk_skill_status_message([], _enabled?), do: "No matching skills"

  defp bulk_skill_status_message(names, true), do: "#{length(names)} skills enabled"
  defp bulk_skill_status_message(names, false), do: "#{length(names)} skills disabled"

  defp credential_select_options(credentials) do
    [
      {"", "No Key Selected"}
      | Enum.map(credential_rows(credentials), &{&1.id, &1.credential["name"] || &1.id})
    ]
  end

  defp provider_api_options do
    [{"anthropic", "Anthropic"}, {"openai", "OpenAI"}]
  end

  defp provider_auth_type_options do
    [
      {"x-api-key", "x-api-key"},
      {"bearer", "Bearer Token"},
      {"custom_header", "Custom Header"}
    ]
  end

  defp format_api_type("anthropic"), do: "Anthropic"
  defp format_api_type("openai"), do: "OpenAI"
  defp format_api_type(value), do: blank_fallback(value, "-")

  defp credential_name(_credentials, id) when id in [nil, ""], do: "No Key Selected"

  defp credential_name(credentials, id) when is_map(credentials) do
    case credentials[id] do
      %{"name" => name} when is_binary(name) and name != "" -> name
      _ -> id
    end
  end

  defp credential_name(_credentials, id), do: id || "No Key Selected"

  defp blank_fallback(value, fallback) when value in [nil, ""], do: fallback
  defp blank_fallback(value, _fallback), do: value

  defp credential_key_preview(value) when value in [nil, ""], do: "Not set"

  defp credential_key_preview(value) do
    value = to_string(value)
    "********" <> String.slice(value, -4, 4)
  end

  defp blank_provider_form do
    %{
      "mode" => "new",
      "id" => "",
      "name" => "New Provider",
      "api_type" => "anthropic",
      "credential_id" => "",
      "auth_type" => "x-api-key",
      "auth_header_name" => "",
      "model" => "claude-3-5-sonnet-latest",
      "base_url" => "https://api.anthropic.com"
    }
  end

  defp provider_form_from_config(id, provider) do
    api_type = provider["api_type"] || "anthropic"
    auth_type = normalize_provider_auth_type(provider["auth_type"], default_auth_type(api_type))

    blank_provider_form()
    |> Map.merge(%{
      "mode" => "edit",
      "id" => id,
      "name" => provider["name"] || "",
      "api_type" => api_type,
      "credential_id" => provider["credential_id"] || "",
      "auth_type" => auth_type,
      "auth_header_name" =>
        normalize_provider_auth_header_name(auth_type, provider["auth_header_name"]),
      "model" => provider["model"] || "",
      "base_url" => provider["base_url"] || ""
    })
  end

  defp save_provider_form(%{"mode" => "edit", "id" => id} = form)
       when is_binary(id) and id != "" do
    ConfigManager.update_provider(id, provider_form_updates(form))
  end

  defp save_provider_form(form) do
    ConfigManager.add_provider(provider_form_updates(form))
  end

  defp provider_form_updates(form) do
    auth_type =
      normalize_provider_auth_type(form["auth_type"], default_auth_type(form["api_type"]))

    %{
      "name" => trim_form_value(form["name"]),
      "api_type" => normalize_provider_api_type(form["api_type"]),
      "credential_id" => form["credential_id"] || "",
      "auth_type" => auth_type,
      "auth_header_name" =>
        normalize_provider_auth_header_name(auth_type, form["auth_header_name"]),
      "model" => trim_form_value(form["model"]),
      "base_url" => trim_form_value(form["base_url"])
    }
  end

  defp normalize_provider_api_type("openai"), do: "openai"
  defp normalize_provider_api_type(_api_type), do: "anthropic"

  defp normalize_provider_form(form) do
    api_type = normalize_provider_api_type(form["api_type"])
    auth_type = normalize_provider_auth_type(form["auth_type"], default_auth_type(api_type))

    form
    |> Map.put("api_type", api_type)
    |> Map.put("auth_type", auth_type)
    |> Map.put(
      "auth_header_name",
      normalize_provider_auth_header_name(auth_type, form["auth_header_name"])
    )
  end

  defp default_auth_type("openai"), do: "bearer"
  defp default_auth_type(_api_type), do: "x-api-key"

  defp maybe_update_default_auth_type(current_form, params) do
    current_api_type = normalize_provider_api_type(current_form["api_type"])
    next_api_type = normalize_provider_api_type(params["api_type"] || current_api_type)

    current_auth_type =
      normalize_provider_auth_type(current_form["auth_type"], default_auth_type(current_api_type))

    submitted_auth_type =
      normalize_provider_auth_type(params["auth_type"], current_auth_type)

    current_default? = current_auth_type == default_auth_type(current_api_type)
    submitted_current? = submitted_auth_type == current_auth_type

    if current_api_type != next_api_type and current_default? and submitted_current? do
      Map.put(params, "auth_type", default_auth_type(next_api_type))
    else
      params
    end
  end

  defp normalize_provider_auth_type(value, fallback) do
    normalize_provider_auth_type_value(value) || normalize_provider_auth_type_value(fallback) ||
      "x-api-key"
  end

  defp normalize_provider_auth_type_value(value) when is_atom(value) do
    value
    |> Atom.to_string()
    |> normalize_provider_auth_type_value()
  end

  defp normalize_provider_auth_type_value(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "x-api-key" -> "x-api-key"
      "x_api_key" -> "x-api-key"
      "bearer" -> "bearer"
      "bearer_token" -> "bearer"
      "bearer token" -> "bearer"
      "custom" -> "custom_header"
      "custom_header" -> "custom_header"
      "custom header" -> "custom_header"
      _ -> nil
    end
  end

  defp normalize_provider_auth_type_value(_value), do: nil

  defp normalize_provider_auth_header_name("custom_header", value), do: trim_form_value(value)
  defp normalize_provider_auth_header_name(_auth_type, _value), do: ""

  defp provider_saved_message(%{"mode" => "new"}), do: "Provider created"
  defp provider_saved_message(_form), do: "Provider updated"

  defp blank_credential_form do
    %{
      "mode" => "new",
      "id" => "",
      "name" => "New Key",
      "key" => ""
    }
  end

  defp credential_form_from_config(id, credential) do
    blank_credential_form()
    |> Map.merge(%{
      "mode" => "edit",
      "id" => id,
      "name" => credential["name"] || "",
      "key" => credential["key"] || ""
    })
  end

  defp save_credential_form(%{"mode" => "edit", "id" => id} = form)
       when is_binary(id) and id != "" do
    ConfigManager.update_credential(id, credential_form_updates(form))
  end

  defp save_credential_form(form) do
    updates = credential_form_updates(form)
    ConfigManager.add_credential(updates["name"], updates["key"])
  end

  defp credential_form_updates(form) do
    %{
      "name" => trim_form_value(form["name"]),
      "key" => form["key"] || ""
    }
  end

  defp credential_saved_message(%{"mode" => "new"}), do: "Credential created"
  defp credential_saved_message(_form), do: "Credential updated"

  defp trim_form_value(value) when is_binary(value), do: String.trim(value)
  defp trim_form_value(_value), do: ""

  defp blank_mcp_form do
    %{
      "mode" => "new",
      "original_id" => "",
      "id" => "server_#{System.unique_integer([:positive])}",
      "type" => "stdio",
      "command" => "",
      "url" => "",
      "auth_type" => "",
      "auth_header_name" => "",
      "auth_value" => "",
      "auth_credential_id" => "",
      "args" => [blank_pair_row()],
      "env" => [blank_pair_row()],
      "headers" => [blank_pair_row()]
    }
  end

  defp mcp_form_from_server(id, server) do
    type = normalize_mcp_type(server["type"])
    headers = server["headers"] || %{}
    auth_type = normalize_mcp_auth_type(server["authType"] || infer_mcp_auth_type(headers))
    auth_header_name = mcp_auth_header_name(auth_type, server["authHeaderName"])

    {auth_header_key, auth_header_value} =
      mcp_auth_header_entry(headers, auth_type, auth_header_name)

    auth_row = mcp_auth_row_from_header_value(auth_type, auth_header_value)

    visible_headers =
      if auth_header_key == "", do: headers, else: Map.delete(headers, auth_header_key)

    %{
      "mode" => "edit",
      "original_id" => id,
      "id" => id,
      "type" => type,
      "command" => server["command"] || "",
      "url" => server["url"] || "",
      "auth_type" => auth_type,
      "auth_header_name" => auth_header_name,
      "auth_value" => auth_row["value"],
      "auth_credential_id" => auth_row["credential_id"],
      "args" => args_to_pair_rows(server["args"] || []),
      "env" => map_to_pair_rows(server["env"] || %{}),
      "headers" => map_to_pair_rows(visible_headers)
    }
  end

  defp merge_mcp_form_params(form, params) do
    form
    |> Map.merge(
      Map.take(params, [
        "mode",
        "original_id",
        "id",
        "command",
        "url",
        "auth_type",
        "auth_header_name",
        "auth_value",
        "auth_credential_id"
      ])
    )
    |> Map.put("type", normalize_mcp_type(params["type"] || form["type"]))
    |> merge_pair_rows(params, "args")
    |> merge_pair_rows(params, "env")
    |> merge_pair_rows(params, "headers")
    |> normalize_mcp_auth_form()
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
    headers =
      form["headers"]
      |> map_from_pair_rows()
      |> put_mcp_auth_header(form)

    %{
      "id" => id,
      "type" => "http",
      "url" => String.trim(form["url"] || ""),
      "headers" => headers
    }
    |> put_mcp_auth_metadata(form)
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

  defp mcp_auth_type_options do
    [
      {"", "None"},
      {"x-api-key", "x-api-key"},
      {"bearer", "Bearer Token"},
      {"custom_header", "Custom Header"}
    ]
  end

  defp mcp_auth_enabled?(form) do
    normalize_mcp_auth_type(form["auth_type"]) != ""
  end

  defp mcp_auth_credential_selected?(form) do
    String.trim(form["auth_credential_id"] || "") != ""
  end

  defp normalize_mcp_auth_form(form) do
    auth_type = normalize_mcp_auth_type(form["auth_type"])

    form
    |> Map.put("auth_type", auth_type)
    |> Map.put("auth_header_name", mcp_auth_header_name(auth_type, form["auth_header_name"]))
    |> Map.put("auth_value", String.trim(form["auth_value"] || ""))
    |> Map.put("auth_credential_id", String.trim(form["auth_credential_id"] || ""))
  end

  defp normalize_mcp_auth_type(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "x-api-key" -> "x-api-key"
      "x_api_key" -> "x-api-key"
      "bearer" -> "bearer"
      "bearer_token" -> "bearer"
      "bearer token" -> "bearer"
      "custom" -> "custom_header"
      "custom_header" -> "custom_header"
      "custom header" -> "custom_header"
      _ -> ""
    end
  end

  defp normalize_mcp_auth_type(_value), do: ""

  defp mcp_auth_header_name("x-api-key", _header_name), do: "x-api-key"
  defp mcp_auth_header_name("bearer", _header_name), do: "Authorization"
  defp mcp_auth_header_name("custom_header", header_name), do: String.trim(header_name || "")
  defp mcp_auth_header_name(_auth_type, _header_name), do: ""

  defp mcp_auth_header_entry(headers, auth_type, auth_header_name) do
    case mcp_header_entry(headers, mcp_auth_header_name(auth_type, auth_header_name)) do
      nil -> {"", ""}
      entry -> entry
    end
  end

  defp mcp_header_entry(_headers, ""), do: nil

  defp mcp_header_entry(headers, header_name) do
    header_name = String.downcase(header_name)

    Enum.find(headers, fn {key, _value} ->
      key |> to_string() |> String.downcase() == header_name
    end)
  end

  defp infer_mcp_auth_type(headers) do
    cond do
      match?({_key, "Bearer " <> _token}, mcp_header_entry(headers, "Authorization")) ->
        "bearer"

      mcp_header_entry(headers, "x-api-key") != nil ->
        "x-api-key"

      true ->
        ""
    end
  end

  defp mcp_auth_row_from_header_value("bearer", "Bearer " <> value) do
    pair_row_from_value("", value)
  end

  defp mcp_auth_row_from_header_value(_auth_type, value), do: pair_row_from_value("", value)

  defp put_mcp_auth_header(headers, form) do
    auth_type = normalize_mcp_auth_type(form["auth_type"])
    header_name = mcp_auth_header_name(auth_type, form["auth_header_name"])
    value = mcp_auth_header_value(auth_type, form)

    cond do
      auth_type == "" -> headers
      header_name == "" -> headers
      value == "" -> headers
      true -> Map.put(headers, header_name, value)
    end
  end

  defp mcp_auth_header_value(auth_type, form) do
    value =
      case String.trim(form["auth_credential_id"] || "") do
        "" -> String.trim(form["auth_value"] || "")
        credential_id -> "{{credential:#{credential_id}}}"
      end

    case {auth_type, value} do
      {_auth_type, ""} -> ""
      {"bearer", value} -> "Bearer #{value}"
      {_auth_type, value} -> value
    end
  end

  defp put_mcp_auth_metadata(updates, form) do
    auth_type = normalize_mcp_auth_type(form["auth_type"])
    header_name = mcp_auth_header_name(auth_type, form["auth_header_name"])

    if auth_type == "" do
      updates
    else
      updates
      |> Map.put("authType", auth_type)
      |> Map.put("authHeaderName", header_name)
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
