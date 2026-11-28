defmodule Sigma.Web.ProjectRemoteSkillsComponent do
  use Sigma.Web, :live_component

  alias Sigma.Session.Skills.Facade
  alias Sigma.Web.SkillSelection

  @impl true
  def update(%{id: id} = assigns, socket) do
    if socket.assigns[:id] == id do
      {:ok, assign(socket, assigns)}
    else
      {:ok,
       socket
       |> assign(assigns)
       |> assign(cursor: nil, error: nil, empty?: false)
       |> stream_configure(:skills,
         dom_id: fn skill -> id <> "-" <> SkillSelection.dom_key(skill) end
       )
       |> stream(:skills, [])
       |> load_page()}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} aria-busy={to_string(@loading?)}>
      <ul id={"#{@id}-items"} phx-update="stream" class="divide-y divide-outline-variant">
        <li :for={{id, skill} <- @streams.skills} id={id} class="py-3">
          <p class="font-semibold text-on-surface">{skill.name}</p>
          <p>{skill.description}</p>
          <code class="break-all text-xs">/skill {skill.reference}</code>
        </li>
      </ul>
      <p :if={@loading?} role="status">Loading remote skills…</p>
      <p :if={@empty?}>No skills returned by this source.</p>
      <p :if={@error} role="alert" class="text-error">{@error}</p>
      <.dm_btn :if={!@loading? and (@cursor || @error)} phx-click="load_page" phx-target={@myself} size="sm" variant="outline">
        {if @error, do: "Retry", else: "Load more"}
      </.dm_btn>
    </div>
    """
  end

  @impl true
  def handle_event("load_page", _, socket) do
    if !socket.assigns.loading? and (socket.assigns.cursor || socket.assigns.error),
      do: {:noreply, load_page(socket)},
      else: {:noreply, socket}
  end

  defp load_page(socket) do
    params = %{source_id: socket.assigns.source_id, cursor: socket.assigns.cursor, limit: 20}

    socket
    |> assign(loading?: true, error: nil)
    |> start_async(:catalog, fn -> Facade.remote_catalog(params) end)
  end

  @impl true
  def handle_async(:catalog, {:ok, {:ok, page}}, socket) do
    empty? = is_nil(socket.assigns.cursor) and page.items == [] and is_nil(page.next_cursor)

    {:noreply,
     socket
     |> stream(:skills, page.items)
     |> assign(loading?: false, empty?: empty?, cursor: page.next_cursor)}
  end

  def handle_async(:catalog, {:ok, {:error, error}}, socket),
    do: {:noreply, assign(socket, loading?: false, error: error.message)}

  def handle_async(:catalog, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, loading?: false, error: "Could not load remote skills.")}
end
