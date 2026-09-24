# Session Title Rename on Repository Session List Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enable users to inline-rename the display title of a session on the repository session list card by updating `.meta.json` without altering session files or IDs.

**Architecture:** Add `SessionFiles.update_metadata/4` for atomic sidecar metadata writes in `sigma_session`. In `sigma_web`, implement inline card header title editing with a double-click/long-press JS hook (`SessionTitleDblClick`), a quick-action rename button, and LiveView event handling in `RepositoryLive` supporting save on Enter/blur and cancel on Escape/button.

**Tech Stack:** Elixir (OTP/GenServer), Phoenix LiveView, DuskMoon UI components, JavaScript (LiveView hooks).

---

### File Structure Map

- **Modify:** `apps/sigma_session/lib/sigma_session/session_files.ex`
  - Add `update_metadata/4` and supporting helper functions for atomic JSON sidecar writes.
- **Modify:** `apps/sigma_session/test/sigma_session/session_files_test.exs`
  - Unit tests covering `update_metadata/4`: existing metadata preservation, missing metadata creation, invalid session ID, missing journal, temp cleanup on failure.
- **Modify:** `apps/sigma_web/assets/js/app.js`
  - Add and register `SessionTitleDblClick` hook for desktop double-click and mobile long-press detection.
- **Modify:** `apps/sigma_web/lib/sigma_web/live/repository_live.ex`
  - Manage `:renaming_session` and `:renaming_title` assigns.
  - Render inline input form on rename mode or title span with rename button on normal mode.
  - Implement `start_rename_title`, `cancel_rename_title`, `rename_keydown`, and `save_rename_title` events.
- **Modify:** `apps/sigma_web/test/sigma_web/live/repository_live_test.exs`
  - Integration tests for inline rename activation, persistence, cancellation, Escape key, and empty title fallback.

---

### Task 1: Core Metadata Update in SessionFiles

**Files:**
- Modify: `apps/sigma_session/lib/sigma_session/session_files.ex`
- Test: `apps/sigma_session/test/sigma_session/session_files_test.exs`

- [ ] **Step 1: Write failing unit tests for update_metadata in session_files_test.exs**

Add the following tests to `apps/sigma_session/test/sigma_session/session_files_test.exs`:

```elixir
  test "update_metadata updates existing metadata while preserving other keys", %{tmp_dir: tmp_dir} do
    jsonl_path = jsonl_path(tmp_dir, "test-update")
    meta_path = meta_path(tmp_dir, "test-update")
    File.write!(jsonl_path, "session header\n")
    File.write!(meta_path, Jason.encode!(%{"cwd" => "/path/to/project", "title" => "Old Title", "branch" => "main"}))

    assert :ok = SessionFiles.update_metadata(tmp_dir, "test-update", %{"title" => "New Title"})

    assert read_meta!(tmp_dir, "test-update") == %{
             "cwd" => "/path/to/project",
             "title" => "New Title",
             "branch" => "main"
           }
  end

  test "update_metadata creates metadata file if missing when journal exists", %{tmp_dir: tmp_dir} do
    jsonl_path = jsonl_path(tmp_dir, "missing-meta")
    File.write!(jsonl_path, "session header\n")

    assert :ok = SessionFiles.update_metadata(tmp_dir, "missing-meta", %{"title" => "Created Title"})

    assert read_meta!(tmp_dir, "missing-meta") == %{
             "title" => "Created Title"
           }
  end

  test "update_metadata rejects invalid session id and non-existent journal", %{tmp_dir: tmp_dir} do
    assert {:error, :invalid_session_id} = SessionFiles.update_metadata(tmp_dir, "../escape", %{"title" => "Bad"})
    assert {:error, :enoent} = SessionFiles.update_metadata(tmp_dir, "does-not-exist", %{"title" => "Bad"})
  end

  test "update_metadata cleans up temp file when rename fails", %{tmp_dir: tmp_dir} do
    jsonl_path = jsonl_path(tmp_dir, "fail-replace")
    File.write!(jsonl_path, "session header\n")

    with_session_file_hook(
      fn
        :before_meta_update, _paths -> {:error, :simulated_failure}
        _event, _paths -> :ok
      end,
      fn ->
        assert {:error, :simulated_failure} =
                 SessionFiles.update_metadata(tmp_dir, "fail-replace", %{"title" => "Failed"})
      end
    )

    temp_files =
      tmp_dir
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".tmp"))

    assert temp_files == []
  end
```

- [ ] **Step 2: Run tests to verify failure**

Run: `mix test apps/sigma_session/test/sigma_session/session_files_test.exs`
Expected: FAIL with `undefined function update_metadata/3`

- [ ] **Step 3: Implement update_metadata/4 in session_files.ex**

Add `update_metadata/4` to `apps/sigma_session/lib/sigma_session/session_files.ex`:

```elixir
  @doc """
  Safely updates sidecar metadata without changing session logs or IDs.
  """
  def update_metadata(sessions_dir, id, updates, opts \\ [])

  def update_metadata(sessions_dir, id, updates, opts)
      when is_binary(sessions_dir) and is_map(updates) do
    with {:ok, meta_path} <- meta_path(sessions_dir, id),
         {:ok, jsonl_path} <- jsonl_path(sessions_dir, id),
         :ok <- require_regular(jsonl_path),
         {:ok, meta_result} <- read_metadata(meta_path),
         {:ok, new_data} <- merge_metadata(meta_result, updates),
         {:ok, encoded} <- encode_metadata(new_data),
         {:ok, temp_path} <- unused_temp_path(meta_path) do
      write_and_replace_metadata(temp_path, meta_path, encoded, opts)
    end
  end

  def update_metadata(_sessions_dir, _id, _updates, _opts), do: {:error, :invalid_arguments}
```

And add the private helpers:

```elixir
  defp merge_metadata(%{exists?: true, data: nil}, _updates),
    do: {:error, :invalid_session_metadata}

  defp merge_metadata(%{exists?: true, data: data}, updates) when is_map(data),
    do: {:ok, Map.merge(data, stringify_keys(updates))}

  defp merge_metadata(%{exists?: false}, updates),
    do: {:ok, stringify_keys(updates)}

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  defp write_and_replace_metadata(temp_path, meta_path, encoded, opts) do
    result =
      with :ok <- File.write(temp_path, encoded),
           :ok <- run_metadata_hook(opts, :before_meta_update, %{
             source: temp_path,
             target: meta_path
           }),
           :ok <- File.rename(temp_path, meta_path) do
        :ok
      end

    if result != :ok, do: rm_optional(temp_path)
    result
  end

  defp run_metadata_hook(opts, event, paths) do
    case Keyword.get(opts, :operation_hook) || Process.get({__MODULE__, :operation_hook}) do
      hook when is_function(hook, 2) -> hook.(event, paths)
      nil -> :ok
      _hook -> {:error, :invalid_operation_hook}
    end
  end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test apps/sigma_session/test/sigma_session/session_files_test.exs`
Expected: PASS (all tests pass)

- [ ] **Step 5: Commit changes**

```bash
git add apps/sigma_session/lib/sigma_session/session_files.ex apps/sigma_session/test/sigma_session/session_files_test.exs
git commit -m "feat(session): add SessionFiles.update_metadata/4 for atomic sidecar updates"
```

---

### Task 2: SessionTitleDblClick JavaScript Hook

**Files:**
- Modify: `apps/sigma_web/assets/js/app.js`

- [ ] **Step 1: Add SessionTitleDblClick hook to app.js**

In `apps/sigma_web/assets/js/app.js`, define the hook:

```javascript
// Triggers title rename mode via double-click or long-press on touch devices.
// Use: phx-hook="SessionTitleDblClick" data-session-id="session_id"
const SessionTitleDblClick = {
  mounted() {
    let pressTimer = null
    const trigger = () => {
      const id = this.el.dataset.sessionId
      if (id) {
        this.pushEvent("start_rename_title", { id })
      }
    }
    this._dblHandler = (e) => {
      e.stopPropagation()
      trigger()
    }
    this._touchStart = () => {
      pressTimer = setTimeout(trigger, 500)
    }
    this._touchEnd = () => {
      if (pressTimer) clearTimeout(pressTimer)
    }
    this.el.addEventListener("dblclick", this._dblHandler)
    this.el.addEventListener("touchstart", this._touchStart, { passive: true })
    this.el.addEventListener("touchend", this._touchEnd)
    this.el.addEventListener("touchcancel", this._touchEnd)
  },
  destroyed() {
    this.el.removeEventListener("dblclick", this._dblHandler)
    this.el.removeEventListener("touchstart", this._touchStart)
    this.el.removeEventListener("touchend", this._touchEnd)
    this.el.removeEventListener("touchcancel", this._touchEnd)
  }
}
```

Add `SessionTitleDblClick` to the `hooks: { ... }` object passed to `LiveSocket`.

- [ ] **Step 2: Build assets and verify bundle succeeds**

Run: `mix assets.build`
Expected: Successful build without errors.

- [ ] **Step 3: Commit changes**

```bash
git add apps/sigma_web/assets/js/app.js
git commit -m "feat(web): add SessionTitleDblClick hook for session title rename trigger"
```

---

### Task 3: RepositoryLive Inline Title Rename UI and Handlers

**Files:**
- Modify: `apps/sigma_web/lib/sigma_web/live/repository_live.ex`

- [ ] **Step 1: Update mount/3 assigns in repository_live.ex**

In `mount/3`:
```elixir
        socket =
          socket
          |> assign(:active_tab, :repository)
          |> assign(:workdir, workdir)
          |> assign(:encoded_repository, encoded_repository)
          |> assign(:sessions_dir, sessions_dir)
          |> assign(:sessions, sessions)
          |> assign(:deleting_session, nil)
          |> assign(:renaming_session, nil)
          |> assign(:renaming_title, nil)
```

- [ ] **Step 2: Update render/1 template in repository_live.ex**

Replace the `<:title ...>` slot content in `render/1`:

```heex
              <:title class="min-w-0 flex-1 overflow-hidden">
                <form
                  :if={@renaming_session == s.session_id}
                  id={"rename-form-#{s.session_id}"}
                  phx-submit="save_rename_title"
                  class="flex w-full min-w-0 items-center gap-2 py-1"
                >
                  <input type="hidden" name="id" value={s.session_id} />
                  <input
                    type="text"
                    name="title"
                    id={"rename-input-#{s.session_id}"}
                    value={@renaming_title}
                    maxlength="120"
                    autofocus
                    phx-blur="save_rename_title"
                    phx-value-id={s.session_id}
                    phx-keydown="rename_keydown"
                    phx-key="Escape"
                    class="flex-1 min-w-0 px-2 py-1 text-base font-semibold bg-surface text-on-surface rounded-lg border border-primary focus:outline-none focus:ring-2 focus:ring-primary/40"
                  />
                  <div class="flex items-center gap-1 shrink-0">
                    <.dm_btn
                      id={"save-title-#{s.session_id}"}
                      type="submit"
                      variant="primary"
                      size="sm"
                      shape="circle"
                      title="Save title"
                      phx-hook="WebComponentHook"
                    >
                      <.dm_mdi name="check" class="w-4 h-4" />
                    </.dm_btn>
                    <.dm_btn
                      id={"cancel-title-#{s.session_id}"}
                      type="button"
                      phx-click="cancel_rename_title"
                      variant="ghost"
                      size="sm"
                      shape="circle"
                      title="Cancel"
                      phx-hook="WebComponentHook"
                    >
                      <.dm_mdi name="close" class="w-4 h-4" />
                    </.dm_btn>
                  </div>
                </form>

                <div
                  :if={@renaming_session != s.session_id}
                  class="flex w-full min-w-0 max-w-full items-center justify-between gap-3 overflow-hidden py-1 text-on-surface"
                >
                  <div
                    class="flex min-w-0 flex-1 items-center gap-3 overflow-hidden cursor-pointer"
                    id={"session-title-container-#{s.session_id}"}
                    phx-hook="SessionTitleDblClick"
                    data-session-id={s.session_id}
                    title="Double-click to rename"
                  >
                    <div class="p-2 bg-primary/10 rounded-lg text-primary group-hover:bg-primary group-hover:text-primary-content transition-colors duration-300 shrink-0">
                      <.dm_mdi name="chat-processing-outline" class="w-5 h-5" />
                    </div>
                    <span class="block min-w-0 truncate font-bold text-lg" title={s.session_id}>{s.title}</span>
                  </div>
                  <div class="flex items-center gap-1 shrink-0">
                    <.dm_btn
                      id={"rename-session-#{s.session_id}"}
                      phx-click="start_rename_title"
                      phx-value-id={s.session_id}
                      phx-hook="WebComponentHook"
                      variant="ghost"
                      size="sm"
                      shape="circle"
                      class="shrink-0 opacity-0 group-hover:opacity-100 transition-opacity"
                      title="Rename session"
                    >
                      <.dm_mdi name="pencil-outline" class="w-4 h-4 text-on-surface-variant" />
                    </.dm_btn>
                    <.dm_btn
                      id={"delete-session-#{s.session_id}"}
                      phx-click="delete_session"
                      phx-value-id={s.session_id}
                      phx-hook="WebComponentHook"
                      variant="ghost"
                      size="sm"
                      shape="circle"
                      class="shrink-0 opacity-0 group-hover:opacity-100 transition-opacity"
                      title="Delete session"
                    >
                      <.dm_mdi name="delete-outline" class="w-4 h-4 text-error" />
                    </.dm_btn>
                  </div>
                </div>
              </:title>
```

- [ ] **Step 3: Implement handle_event callbacks in repository_live.ex**

Add the event handlers:

```elixir
  @impl true
  def handle_event("start_rename_title", params, socket) do
    id = Map.get(params, "id")

    if SessionFiles.valid_session_id?(id) do
      session = Enum.find(socket.assigns.sessions, &(&1.session_id == id))
      current_title = (session && session.title) || id

      {:noreply,
       socket
       |> assign(renaming_session: id, renaming_title: current_title)}
    else
      {:noreply, put_flash(socket, :error, OperationError.message(:invalid_session_id))}
    end
  end

  @impl true
  def handle_event("cancel_rename_title", _, socket) do
    {:noreply, assign(socket, renaming_session: nil, renaming_title: nil)}
  end

  @impl true
  def handle_event("rename_keydown", %{"key" => "Escape"}, socket) do
    {:noreply, assign(socket, renaming_session: nil, renaming_title: nil)}
  end

  @impl true
  def handle_event("rename_keydown", _, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("save_rename_title", params, socket) do
    id = Map.get(params, "id") || socket.assigns.renaming_session
    raw_title = Map.get(params, "title") || Map.get(params, "value") || ""
    new_title = raw_title |> String.trim() |> String.slice(0, 120)

    session = Enum.find(socket.assigns.sessions, &(&1.session_id == id))
    current_title = (session && session.title) || id

    cond do
      not SessionFiles.valid_session_id?(id) ->
        {:noreply,
         socket
         |> assign(renaming_session: nil, renaming_title: nil)
         |> put_flash(:error, OperationError.message(:invalid_session_id))}

      new_title == "" or new_title == current_title ->
        {:noreply, assign(socket, renaming_session: nil, renaming_title: nil)}

      true ->
        case SessionFiles.update_metadata(socket.assigns.sessions_dir, id, %{"title" => new_title}) do
          :ok ->
            updated_sessions =
              Enum.map(socket.assigns.sessions, fn
                %{session_id: ^id} = s -> %{s | title: new_title}
                s -> s
              end)

            {:ok, fresh_sessions} =
              Sigma.Session.Log.list_session_summaries(socket.assigns.sessions_dir)

            sessions = if fresh_sessions != [], do: fresh_sessions, else: updated_sessions

            {:noreply,
             socket
             |> assign(sessions: sessions, renaming_session: nil, renaming_title: nil)
             |> put_flash(:info, "Session title updated.")}

          {:error, reason} ->
            {:noreply,
             socket
             |> assign(renaming_session: nil, renaming_title: nil)
             |> put_flash(:error, OperationError.message(reason))}
        end
    end
  end
```

- [ ] **Step 4: Verify compilation and formatting**

Run: `mix compile --warnings-as-errors && mix format --check-formatted`
Expected: PASS with 0 warnings.

- [ ] **Step 5: Commit changes**

```bash
git add apps/sigma_web/lib/sigma_web/live/repository_live.ex
git commit -m "feat(web): add inline session title rename form and handlers in RepositoryLive"
```

---

### Task 4: Integration Tests for RepositoryLive Rename Flow

**Files:**
- Modify: `apps/sigma_web/test/sigma_web/live/repository_live_test.exs`

- [ ] **Step 1: Write integration tests in repository_live_test.exs**

Add the following tests to `apps/sigma_web/test/sigma_web/live/repository_live_test.exs`:

```elixir
  @tag :tmp_dir
  test "clicking rename button opens inline rename form prefilled with current title", %{
    conn: conn,
    tmp_dir: tmp_dir
  } do
    workdir = tmp_workdir!("repository-rename-start")
    on_exit(fn -> File.rm_rf!(workdir) end)

    with_agent_dir(tmp_dir, fn ->
      {:ok, _repo} = RepoManager.add_repo(workdir, name: "Repo")
      sessions_dir = ConfigManager.sessions_dir(workdir)
      write_session_files!(sessions_dir, "session-to-rename")

      encoded_repository = Base.url_encode64(workdir, padding: false)
      {:ok, view, html} = live(conn, "/repository/#{encoded_repository}")

      assert html =~ ~s(id="rename-session-session-to-rename")

      render_click(view, "start_rename_title", %{"id" => "session-to-rename"})
      html = render(view)

      assert html =~ ~s(id="rename-form-session-to-rename")
      assert html =~ ~s(id="rename-input-session-to-rename")
      assert html =~ ~s(value="session-to-rename")
    end)
  end

  @tag :tmp_dir
  test "submitting rename form updates session title in metadata and list", %{
    conn: conn,
    tmp_dir: tmp_dir
  } do
    workdir = tmp_workdir!("repository-rename-save")
    on_exit(fn -> File.rm_rf!(workdir) end)

    with_agent_dir(tmp_dir, fn ->
      {:ok, _repo} = RepoManager.add_repo(workdir, name: "Repo")
      sessions_dir = ConfigManager.sessions_dir(workdir)
      write_session_files!(sessions_dir, "rename-me")

      encoded_repository = Base.url_encode64(workdir, padding: false)
      {:ok, view, _html} = live(conn, "/repository/#{encoded_repository}")

      render_click(view, "start_rename_title", %{"id" => "rename-me"})

      html =
        render_submit(view, "save_rename_title", %{
          "id" => "rename-me",
          "title" => "Updated Session Title"
        })

      assert html =~ "Session title updated."
      assert html =~ "Updated Session Title"
      refute html =~ ~s(id="rename-form-rename-me")

      meta =
        sessions_dir
        |> Path.join("rename-me.meta.json")
        |> File.read!()
        |> Jason.decode!()

      assert meta["title"] == "Updated Session Title"
    end)
  end

  @tag :tmp_dir
  test "cancelling rename form restores original display without persisting", %{
    conn: conn,
    tmp_dir: tmp_dir
  } do
    workdir = tmp_workdir!("repository-rename-cancel")
    on_exit(fn -> File.rm_rf!(workdir) end)

    with_agent_dir(tmp_dir, fn ->
      {:ok, _repo} = RepoManager.add_repo(workdir, name: "Repo")
      sessions_dir = ConfigManager.sessions_dir(workdir)
      write_session_files!(sessions_dir, "cancel-me")

      encoded_repository = Base.url_encode64(workdir, padding: false)
      {:ok, view, _html} = live(conn, "/repository/#{encoded_repository}")

      render_click(view, "start_rename_title", %{"id" => "cancel-me"})
      assert render(view) =~ ~s(id="rename-form-cancel-me")

      html = render_click(view, "cancel_rename_title")
      refute html =~ ~s(id="rename-form-cancel-me")
      assert html =~ "cancel-me"

      # Also test Escape key via rename_keydown
      render_click(view, "start_rename_title", %{"id" => "cancel-me"})
      assert render(view) =~ ~s(id="rename-form-cancel-me")

      html = render_hook(view, "rename_keydown", %{"key" => "Escape"})
      refute html =~ ~s(id="rename-form-cancel-me")
    end)
  end

  @tag :tmp_dir
  test "submitting empty title reverts without changes or errors", %{
    conn: conn,
    tmp_dir: tmp_dir
  } do
    workdir = tmp_workdir!("repository-rename-empty")
    on_exit(fn -> File.rm_rf!(workdir) end)

    with_agent_dir(tmp_dir, fn ->
      {:ok, _repo} = RepoManager.add_repo(workdir, name: "Repo")
      sessions_dir = ConfigManager.sessions_dir(workdir)
      write_session_files!(sessions_dir, "empty-me")

      encoded_repository = Base.url_encode64(workdir, padding: false)
      {:ok, view, _html} = live(conn, "/repository/#{encoded_repository}")

      render_click(view, "start_rename_title", %{"id" => "empty-me"})

      html =
        render_submit(view, "save_rename_title", %{
          "id" => "empty-me",
          "title" => "   "
        })

      refute html =~ ~s(id="rename-form-empty-me")
      refute html =~ "Session title updated."
      assert html =~ "empty-me"
    end)
  end
```

- [ ] **Step 2: Run all web tests**

Run: `mix test apps/sigma_web/test/sigma_web/live/repository_live_test.exs`
Expected: All tests PASS.

- [ ] **Step 3: Run full suite checks**

Run: `mix format --check-formatted && mix compile --warnings-as-errors && mix test`
Expected: PASS across all umbrella apps.

- [ ] **Step 4: Commit changes**

```bash
git add apps/sigma_web/test/sigma_web/live/repository_live_test.exs
git commit -m "test(web): add RepositoryLive integration tests for session title rename"
```
