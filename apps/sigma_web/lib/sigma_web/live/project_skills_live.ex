defmodule Sigma.Web.ProjectSkillsLive do
  use Sigma.Web, :live_view

  alias Sigma.Session.{RepoManager, Skills}
  import Sigma.Web.ProjectSidebar

  @impl true
  def mount(%{"repository" => encoded_repository}, _session, socket) do
    case fetch_registered_repo(encoded_repository) do
      {:ok, workdir, _repo} ->
        {:ok,
         socket
         |> assign(:active_tab, :repository)
         |> assign(:workdir, workdir)
         |> assign(:encoded_repository, encoded_repository)
         |> assign(:tab, :project)
         |> assign(:skills_query, "")
         |> assign(:selected_skill_names, [])}

      {:error, :unknown_repository} ->
        {:ok, redirect_unknown_repository(socket)}
    end
  end

  @impl true
  def handle_params(params, _url, socket) do
    tab = normalize_tab(params["tab"])
    results = load_skill_results(socket.assigns.workdir)

    {:noreply,
     socket
     |> assign(:tab, tab)
     |> assign(:skills_query, "")
     |> assign(:selected_skill_names, [])
     |> assign(:project_skill_count, results |> Map.get(:project) |> count_enabled_skills())
     |> assign(:project_skill_total, results |> Map.get(:project) |> count_skills())
     |> assign(:global_skill_count, results |> Map.get(:global) |> count_enabled_skills())
     |> assign(:global_skill_total, results |> Map.get(:global) |> count_skills())
     |> assign(:skills_result, Map.fetch!(results, tab))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex min-h-[calc(100vh-64px)]">
      <.project_sidebar
        workdir={@workdir}
        encoded_repository={@encoded_repository}
        active_item={:skills}
      />

      <main class="flex-1 p-8 bg-surface text-on-surface font-sans">
        <div class="max-w-6xl mx-auto">
          <div class="mb-6 border-b border-outline-variant pb-6">
            <h1 class="font-display text-4xl font-bold">Project Skills</h1>
            <p class="text-on-surface-variant mt-2 text-lg">
              Skills available to sessions in this repository.
            </p>
          </div>

          <div class="flex flex-wrap items-center gap-2 mb-6">
            <.dm_link
              patch={~p"/repository/#{@encoded_repository}/skills"}
              class={"btn btn-sm #{if @tab == :project, do: "btn-primary", else: "btn-ghost"}"}
            >
              <div class="flex items-center gap-2">
                <.dm_mdi name="folder-code-outline" class="w-4 h-4" />
                <span>Project Skills</span>
                <span class="badge badge-sm badge-ghost">
                  {@project_skill_count} / {@project_skill_total}
                </span>
              </div>
            </.dm_link>
            <.dm_link
              patch={~p"/repository/#{@encoded_repository}/skills?tab=global"}
              class={"btn btn-sm #{if @tab == :global, do: "btn-primary", else: "btn-ghost"}"}
            >
              <div class="flex items-center gap-2">
                <.dm_mdi name="earth" class="w-4 h-4" />
                <span>Global Skills</span>
                <span class="badge badge-sm badge-ghost">
                  {@global_skill_count} / {@global_skill_total}
                </span>
              </div>
            </.dm_link>
          </div>

          <.project_skills_tab_content {assigns} />

          <div
            :if={!Enum.empty?(@skills_result.diagnostics)}
            class="mt-4 rounded-2xl border border-warning/30 bg-warning/10 p-4 text-warning"
          >
            <div class="flex items-center gap-2 font-bold mb-2">
              <.dm_mdi name="alert-outline" class="w-5 h-5" />
              <span>Some skills could not be loaded</span>
            </div>
            <ul class="space-y-1 text-sm">
              <li :for={diagnostic <- @skills_result.diagnostics}>
                <code class="font-mono break-all">{diagnostic.path}</code>: {diagnostic.message}
              </li>
            </ul>
          </div>
        </div>
      </main>
    </div>
    """
  end

  defp project_skills_tab_content(%{tab: :global} = assigns) do
    assigns = prepare_skill_table(assigns)

    ~H"""
    <div class="space-y-6">
      <p class="text-sm text-on-surface-variant">
        Global skills from <code class="font-mono">{@skills_result.dir}</code>. Switches here
        override availability for this project only — use
        <.dm_link navigate={~p"/settings/skills"} class="link link-primary">
          Settings → Skills
        </.dm_link>
        to enable or disable skills globally.
      </p>
      <.skills_toolbar {assigns} />
      <.skills_table {assigns} />
    </div>
    """
  end

  defp project_skills_tab_content(%{tab: :project} = assigns) do
    assigns = prepare_skill_table(assigns)

    ~H"""
    <div class="space-y-6">
      <p class="text-sm text-on-surface-variant">
        Skills discovered in <code class="font-mono">{@skills_result.dir}</code>. All skills are
        enabled by default; toggles write this project's disabled list.
      </p>
      <.skills_toolbar {assigns} />
      <.skills_table {assigns} />
    </div>
    """
  end

  defp skills_toolbar(assigns) do
    ~H"""
    <div
      :if={!Enum.empty?(@skills_result.skills)}
      class="flex flex-col gap-3 rounded-2xl border border-outline-variant bg-surface-container-low p-4 md:flex-row md:items-end md:justify-between"
    >
      <form id="project-skills-filter-form" phx-change="filter_skills" class="w-full md:max-w-md">
        <.dm_input
          id="project-skills-search"
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
          id="project-skills-clear-selection"
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
          id="project-skills-enable-selected"
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
          id="project-skills-disable-selected"
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
      :if={Enum.empty?(@skills_result.skills)}
      class="rounded-2xl border border-dashed border-outline-variant bg-surface-container-low p-8 text-center"
    >
      <.dm_mdi name="auto-fix-off" class="w-10 h-10 mx-auto text-on-surface-variant opacity-40 mb-3" />
      <p class="font-semibold text-on-surface">
        {if @tab == :global, do: "No global skills found", else: "No project skills found"}
      </p>
    </div>

    <div
      :if={!Enum.empty?(@skills_result.skills) and Enum.empty?(@filtered_skills)}
      class="rounded-2xl border border-dashed border-outline-variant bg-surface-container-low p-8 text-center"
    >
      <.dm_mdi name="magnify-close" class="w-10 h-10 mx-auto text-on-surface-variant opacity-40 mb-3" />
      <p class="font-semibold text-on-surface">No matching skills</p>
    </div>
    """
  end

  defp skills_table(assigns) do
    ~H"""
    <div
      :if={!Enum.empty?(@filtered_skills)}
      class="overflow-x-auto rounded-2xl border border-outline-variant bg-surface-container-low"
    >
      <table
        role="table"
        id="project-skills-table"
        class="table table-zebra table-hover table-compact settings-table table-fixed min-w-[72rem]"
      >
        <thead role="row-group" class="sticky top-0">
          <tr role="row">
            <th role="columnheader" scope="col" class="w-16">
              <.dm_checkbox
                id="project-skills-select-all"
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
            <th role="columnheader" scope="col" class="settings-skills-description-cell">
              Description
            </th>
            <th role="columnheader" scope="col" class="min-w-96">Path</th>
          </tr>
        </thead>
        <tbody role="row-group">
          <tr :for={skill <- @filtered_skills} role="row">
            <td data-label="Select" role="cell" class="w-16">
              <.dm_checkbox
                id={"project-skill-select-#{skill_row_id(skill)}"}
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
                <.dm_popover
                  id={"project-skill-name-#{skill_row_id(skill)}"}
                  trigger_mode="hover"
                  placement="top-start"
                  arrow={false}
                  class="max-w-xs"
                >
                  <:trigger :let={trigger_attrs}>
                    <span
                      {trigger_attrs}
                      title={skill.name}
                      class="settings-skills-name-trigger font-bold cursor-help"
                    >
                      {skill.name}
                    </span>
                  </:trigger>
                  <p class="font-mono text-xs font-semibold text-on-surface break-all">
                    {skill.name}
                  </p>
                </.dm_popover>
              </div>
            </td>
            <td data-label="Enabled" role="cell" class="min-w-28">
              <.dm_switch
                id={"project-skill-enabled-#{skill_row_id(skill)}"}
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
            <td data-label="Description" role="cell" class="settings-skills-description-cell">
              <.dm_popover
                id={"project-skill-description-#{skill_row_id(skill)}"}
                trigger_mode="hover"
                placement="top-start"
                arrow={false}
                class="max-w-md"
              >
                <:trigger :let={trigger_attrs}>
                  <p
                    {trigger_attrs}
                    title={skill.description}
                    class="settings-skills-description-trigger text-sm text-on-surface-variant cursor-help"
                  >
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
    """
  end

  # Shared table-state computation for both tabs.
  defp prepare_skill_table(assigns) do
    query = assigns[:skills_query] || ""
    selected_skill_names = assigns[:selected_skill_names] || []
    skills = assigns.skills_result.skills
    filtered_skills = filter_skills(skills, query)
    visible_skill_names = Enum.map(filtered_skills, & &1.name)
    selected_visible_skill_count = Enum.count(visible_skill_names, &(&1 in selected_skill_names))

    all_visible_skills_selected? =
      filtered_skills != [] and selected_visible_skill_count == length(filtered_skills)

    some_visible_skills_selected? =
      selected_visible_skill_count > 0 and !all_visible_skills_selected?

    assigns
    |> assign(:query, query)
    |> assign(:filtered_skills, filtered_skills)
    |> assign(:shown_skills, length(filtered_skills))
    |> assign(:selected_skill_count, length(selected_skill_names))
    |> assign(:all_visible_skills_selected?, all_visible_skills_selected?)
    |> assign(:some_visible_skills_selected?, some_visible_skills_selected?)
    |> assign(:enabled_skills, Enum.count(skills, & &1.enabled?))
  end

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
      socket.assigns.skills_result.skills
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
    set_project_skill_enabled(socket.assigns.workdir, name, enabled?)

    {:noreply,
     socket
     |> reload_skills()
     |> put_flash(:info, skill_status_message(name, enabled?))}
  end

  @impl true
  def handle_event("set_selected_skills_enabled", %{"enabled" => enabled}, socket) do
    enabled? = enabled == "true"
    workdir = socket.assigns.workdir

    names =
      socket.assigns.skills_result.skills
      |> selected_existing_skill_names(socket.assigns.selected_skill_names)

    Enum.each(names, &set_project_skill_enabled(workdir, &1, enabled?))

    {:noreply,
     socket
     |> assign(:selected_skill_names, [])
     |> reload_skills()
     |> put_flash(:info, bulk_skill_status_message(names, enabled?))}
  end

  defp set_project_skill_enabled(workdir, name, true) do
    disabled =
      workdir
      |> RepoManager.disabled_skills()
      |> List.delete(name)

    RepoManager.set_disabled_skills(workdir, disabled)
  end

  defp set_project_skill_enabled(workdir, name, false) do
    disabled = [name | RepoManager.disabled_skills(workdir)]
    RepoManager.set_disabled_skills(workdir, disabled)
  end

  defp reload_skills(%{assigns: %{workdir: workdir, tab: tab}} = socket) do
    assign(socket, :skills_result, load_skills(workdir, tab))
  end

  defp load_skill_results(workdir) do
    %{
      project: Skills.list_repository(workdir),
      global: Skills.list_global_for_repository(workdir)
    }
  end

  defp load_skills(workdir, :global), do: Skills.list_global_for_repository(workdir)
  defp load_skills(workdir, _tab), do: Skills.list_repository(workdir)

  defp count_skills(%{skills: skills}), do: length(skills)

  defp count_enabled_skills(%{skills: skills}), do: Enum.count(skills, & &1.enabled?)

  defp normalize_tab("global"), do: :global
  defp normalize_tab(_), do: :project

  defp fetch_registered_repo(encoded_repository) do
    with {:ok, workdir} <- Base.url_decode64(encoded_repository, padding: false),
         %{} = repo <- RepoManager.get_repo(workdir) do
      {:ok, Path.expand(repo["path"]), repo}
    else
      _ -> {:error, :unknown_repository}
    end
  end

  defp redirect_unknown_repository(socket) do
    socket
    |> put_flash(:error, "Repository is not registered.")
    |> redirect(to: ~p"/")
  end

  defp trim_form_value(value) when is_binary(value), do: String.trim(value)
  defp trim_form_value(_), do: ""

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

  defp skill_selected?(selected_skill_names, name), do: Enum.member?(selected_skill_names, name)

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

  defp skill_status_message(name, true), do: "#{name} enabled for this project"
  defp skill_status_message(name, false), do: "#{name} disabled for this project"

  defp bulk_skill_status_message([], _enabled?), do: "No matching skills"

  defp bulk_skill_status_message(names, true),
    do: "#{length(names)} skills enabled for this project"

  defp bulk_skill_status_message(names, false),
    do: "#{length(names)} skills disabled for this project"
end
