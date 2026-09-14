defmodule Sigma.Web.RepositoryLiveTest do
  use Sigma.Web.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Sigma.Agent.Terminals.{FakeBackend, ResourceLedger}
  alias Sigma.Session.{ConfigManager, RepoManager}
  alias Sigma.Web.OperationError

  @tag :tmp_dir
  test "renders sessions without embedding repository skills", %{
    conn: conn,
    tmp_dir: tmp_dir
  } do
    with_agent_dir(tmp_dir, fn ->
      {:ok, _repo} = RepoManager.add_repo(tmp_dir, name: "Repo")

      skill_dir = Path.join([tmp_dir, ".agents", "skills", "repo-only"])
      File.mkdir_p!(skill_dir)

      File.write!(
        Path.join(skill_dir, "SKILL.md"),
        """
        ---
        name: repo-only
        description: Repository scoped skill
        ---
        Use this skill.
        """
      )

      encoded_repository = Base.url_encode64(tmp_dir, padding: false)

      on_exit(fn ->
        File.rm_rf(ConfigManager.sessions_dir(tmp_dir))
      end)

      {:ok, _view, html} = live(conn, "/repository/#{encoded_repository}")

      assert html =~ "Settings"
      assert html =~ "Skills"
      assert html =~ "New Session"
      assert html =~ "Session List"
      refute html =~ "All Repositories"
      assert_sidebar_order(html)
      assert html =~ ~s(href="/repository/#{encoded_repository}/settings")
      assert html =~ ~s(href="/repository/#{encoded_repository}/skills")
      assert html =~ ~s(href="/repository/#{encoded_repository}/sessions/new")

      assert html =~ "Sessions"
      refute html =~ "Repository Skills"
      refute html =~ "repo-only"
      refute html =~ "Repository scoped skill"
    end)
  end

  @tag :tmp_dir
  test "rejects unregistered repository route", %{conn: conn, tmp_dir: tmp_dir} do
    with_agent_dir(tmp_dir, fn ->
      path = System.tmp_dir!()
      encoded = Base.url_encode64(path, padding: false)

      assert {:error,
              {:redirect, %{to: "/", flash: %{"error" => "Repository is not registered."}}}} =
               live(conn, "/repository/#{encoded}")
    end)
  end

  @tag :tmp_dir
  test "rejects invalid repository route", %{conn: conn, tmp_dir: tmp_dir} do
    with_agent_dir(tmp_dir, fn ->
      assert {:error,
              {:redirect, %{to: "/", flash: %{"error" => "Repository is not registered."}}}} =
               live(conn, "/repository/not-base64!")
    end)
  end

  @tag :tmp_dir
  test "constrains long session titles without displacing the delete button", %{
    conn: conn,
    tmp_dir: tmp_dir
  } do
    workdir = tmp_workdir!("repository-long-session-title")
    on_exit(fn -> File.rm_rf!(workdir) end)

    with_agent_dir(tmp_dir, fn ->
      {:ok, _repo} = RepoManager.add_repo(workdir, name: "Repo")

      session_id = "session_abcdefghijklmnopqrstuvwxyz0123456789"
      write_session_files!(ConfigManager.sessions_dir(workdir), session_id)

      encoded_repository = Base.url_encode64(workdir, padding: false)
      {:ok, _view, html} = live(conn, "/repository/#{encoded_repository}")
      document = LazyHTML.from_document(html)

      assert document
             |> LazyHTML.query("[id='delete-session-#{session_id}']")
             |> Enum.any?()

      assert document
             |> LazyHTML.query("span[title='#{session_id}'].min-w-0.truncate")
             |> Enum.any?()

      assert document
             |> LazyHTML.query(".w-full.min-w-0.max-w-full")
             |> Enum.any?()

      assert document
             |> LazyHTML.query("[slot='header'].min-w-0.flex-1.overflow-hidden")
             |> Enum.any?()
    end)
  end

  @tag :tmp_dir
  test "deleting a session removes its log and metadata and refreshes the list", %{
    conn: conn,
    tmp_dir: tmp_dir
  } do
    workdir = tmp_workdir!("repository-delete")
    on_exit(fn -> File.rm_rf!(workdir) end)

    with_agent_dir(tmp_dir, fn ->
      {:ok, _repo} = RepoManager.add_repo(workdir, name: "Repo")

      sessions_dir = ConfigManager.sessions_dir(workdir)
      write_session_files!(sessions_dir, "delete-me")
      write_session_files!(sessions_dir, "keep-me")

      encoded_repository = Base.url_encode64(workdir, padding: false)
      {:ok, view, html} = live(conn, "/repository/#{encoded_repository}")

      assert html =~ "delete-me"
      assert html =~ "keep-me"

      render_click(view, "delete_session", %{"id" => "delete-me"})
      assert render(view) =~ ~s(id="delete-session-modal")

      html = render_click(view, "confirm_delete")

      assert html =~ "Session deleted successfully."
      refute File.exists?(Path.join(sessions_dir, "delete-me.jsonl"))
      refute File.exists?(Path.join(sessions_dir, "delete-me.meta.json"))
      assert File.exists?(Path.join(sessions_dir, "keep-me.jsonl"))
      assert File.exists?(Path.join(sessions_dir, "keep-me.meta.json"))

      html = render(view)
      refute html =~ "delete-me"
      refute html =~ ~s(id="delete-session-modal")
      assert html =~ "keep-me"
    end)
  end

  @tag :tmp_dir
  test "keeps an orphaned session visible and explicitly adopts it into the repository", %{
    conn: conn,
    tmp_dir: tmp_dir
  } do
    workdir = tmp_workdir!("repository-adopt")
    on_exit(fn -> File.rm_rf!(workdir) end)

    with_agent_dir(tmp_dir, fn ->
      {:ok, _repo} = RepoManager.add_repo(workdir, name: "Repo")
      sessions_dir = ConfigManager.sessions_dir(workdir)
      File.mkdir_p!(sessions_dir)

      :ok =
        Sigma.Session.Log.persist_event(
          Path.join(sessions_dir, "orphan.jsonl"),
          {:agent_start, "/missing/repository"}
        )

      File.write!(
        Path.join(sessions_dir, "orphan.meta.json"),
        Jason.encode!(%{"cwd" => "/missing/repository", "branch" => "main"})
      )

      encoded_repository = Base.url_encode64(workdir, padding: false)
      {:ok, view, html} = live(conn, "/repository/#{encoded_repository}")

      assert html =~ "orphan"
      assert html =~ "Recorded working directory is missing"
      assert html =~ ~s(id="adopt-session-orphan")

      html = render_click(view, "adopt_session", %{"id" => "orphan"})
      assert html =~ "Session adopted into this repository."
      refute html =~ "Recorded working directory is missing"

      metadata =
        sessions_dir
        |> Path.join("orphan.meta.json")
        |> File.read!()
        |> Jason.decode!()

      assert metadata == %{"cwd" => Path.expand(workdir), "branch" => "main"}
    end)
  end

  @tag :tmp_dir
  test "forged traversal delete id does not remove outside files and clears modal", %{
    conn: conn,
    tmp_dir: tmp_dir
  } do
    workdir = tmp_workdir!("repository-forged-delete")
    on_exit(fn -> File.rm_rf!(workdir) end)

    with_agent_dir(tmp_dir, fn ->
      {:ok, _repo} = RepoManager.add_repo(workdir, name: "Repo")

      sessions_dir = ConfigManager.sessions_dir(workdir)
      write_session_files!(sessions_dir, "safe-session")

      outside_path = Path.join(Path.dirname(sessions_dir), "outside.jsonl")
      File.write!(outside_path, "outside\n")

      encoded_repository = Base.url_encode64(workdir, padding: false)
      {:ok, view, _html} = live(conn, "/repository/#{encoded_repository}")

      render_click(view, "delete_session", %{"id" => "../outside"})
      refute render(view) =~ ~s(id="delete-session-modal")

      html = render(view)

      assert html =~ "This session identifier is invalid. No files were changed."
      assert File.exists?(outside_path)
      assert File.exists?(Path.join(sessions_dir, "safe-session.jsonl"))
      assert File.exists?(Path.join(sessions_dir, "safe-session.meta.json"))

      html = render(view)
      refute html =~ ~s(id="delete-session-modal")
      assert html =~ "safe-session"
    end)
  end

  @tag :tmp_dir
  test "direct malformed repository events keep the LiveView and session files intact", %{
    conn: conn,
    tmp_dir: tmp_dir
  } do
    workdir = tmp_workdir!("repository-malformed-operation-events")
    on_exit(fn -> File.rm_rf!(workdir) end)

    with_agent_dir(tmp_dir, fn ->
      {:ok, _repo} = RepoManager.add_repo(workdir, name: "Repo")
      sessions_dir = ConfigManager.sessions_dir(workdir)
      write_session_files!(sessions_dir, "safe-session")

      encoded_repository = Base.url_encode64(workdir, padding: false)
      {:ok, view, _html} = live(conn, "/repository/#{encoded_repository}")

      html = render_click(view, "confirm_delete")
      assert html =~ "This session identifier is invalid. No files were changed."
      refute html =~ ~s(id="delete-session-modal")

      html = render_click(view, "delete_session", %{})
      assert html =~ "This session identifier is invalid. No files were changed."

      html = render_click(view, "adopt_session", %{"id" => ["not-a-session-id"]})
      assert html =~ "This session identifier is invalid. No files were changed."

      html = render_click(view, "adopt_session", %{})
      assert html =~ "This session identifier is invalid. No files were changed."
      assert File.exists?(Path.join(sessions_dir, "safe-session.jsonl"))
      assert File.exists?(Path.join(sessions_dir, "safe-session.meta.json"))
      assert render(view) =~ "safe-session"
    end)
  end

  @tag :tmp_dir
  test "cleanup uncertainty keeps the session files and clears the delete modal", %{
    conn: conn,
    tmp_dir: tmp_dir
  } do
    workdir = tmp_workdir!("repository-delete-cleanup-uncertain")
    session_id = "cleanup-uncertain"
    ledger_key = {__MODULE__, session_id, make_ref()}
    {:ok, ledger} = ResourceLedger.start_link(name: nil, persistence_key: ledger_key)

    on_exit(fn ->
      stop_repository(workdir)
      if Process.alive?(ledger), do: GenServer.stop(ledger)
      :persistent_term.erase(ledger_key)
      File.rm_rf!(workdir)
    end)

    with_agent_dir(tmp_dir, fn ->
      {:ok, _repo} = RepoManager.add_repo(workdir, name: "Repo")
      sessions_dir = ConfigManager.sessions_dir(workdir)
      session_path = Path.join(sessions_dir, "#{session_id}.jsonl")
      File.mkdir_p!(sessions_dir)
      :ok = Sigma.Session.Log.persist_event(session_path, {:agent_start, workdir})

      assert {:ok, _handle} =
               Sigma.Agent.Runtime.get_session(workdir, session_id,
                 cwd: workdir,
                 transcript_path: session_path,
                 model: %{id: "mock", api: "mock", provider: "mock"},
                 provider: EmptyProvider,
                 idle_timeout_ms: 30_000,
                 terminal_backend: {FakeBackend, cleanup: :unconfirmed},
                 terminal_resource_ledger: ledger
               )

      operation = Sigma.Agent.Terminals.issue_operation(workdir, session_id, "create", :create)
      assert {:ok, _terminal} = Sigma.Agent.Terminals.create(workdir, session_id, operation)

      encoded_repository = Base.url_encode64(workdir, padding: false)
      {:ok, view, _html} = live(conn, "/repository/#{encoded_repository}")

      render_click(view, "delete_session", %{"id" => session_id})
      html = render_click(view, "confirm_delete")

      assert html =~
               "Terminal cleanup could not be confirmed. The session was not changed; retry cleanup before trying again."

      assert File.exists?(session_path)
      refute render(view) =~ ~s(id="delete-session-modal")
      assert render(view) =~ session_id
    end)
  end

  @tag :tmp_dir
  test "untrusted and unavailable ledgers reject deletion without changing files", %{
    conn: conn,
    tmp_dir: tmp_dir
  } do
    workdir = tmp_workdir!("repository-delete-ledger-guard")
    untrusted_id = "ledger-untrusted"
    unavailable_id = "ledger-unavailable"
    untrusted_key = {__MODULE__, untrusted_id, make_ref()}
    unavailable_key = {__MODULE__, unavailable_id, make_ref()}
    {:ok, untrusted_ledger} = ResourceLedger.start_link(name: nil, persistence_key: untrusted_key)

    {:ok, unavailable_ledger} =
      ResourceLedger.start_link(name: nil, persistence_key: unavailable_key)

    on_exit(fn ->
      stop_repository(workdir)
      if Process.alive?(untrusted_ledger), do: GenServer.stop(untrusted_ledger)
      if Process.alive?(unavailable_ledger), do: GenServer.stop(unavailable_ledger)
      :persistent_term.erase(untrusted_key)
      :persistent_term.erase(unavailable_key)
      File.rm_rf!(workdir)
    end)

    with_agent_dir(tmp_dir, fn ->
      {:ok, _repo} = RepoManager.add_repo(workdir, name: "Repo")
      sessions_dir = ConfigManager.sessions_dir(workdir)

      untrusted_path =
        start_runtime_session!(workdir, untrusted_id, sessions_dir, untrusted_ledger)

      unavailable_path =
        start_runtime_session!(workdir, unavailable_id, sessions_dir, unavailable_ledger)

      assert :ok = ResourceLedger.mark_untrustworthy(untrusted_ledger)
      GenServer.stop(unavailable_ledger)

      encoded_repository = Base.url_encode64(workdir, padding: false)
      {:ok, view, _html} = live(conn, "/repository/#{encoded_repository}")

      for {session_id, message, path} <- [
            {untrusted_id,
             "Terminal cleanup could not be confirmed. The session was not changed; retry cleanup before trying again.",
             untrusted_path},
            {unavailable_id,
             "Terminal resource status is unavailable. The session was not changed; try again after it recovers.",
             unavailable_path}
          ] do
        render_click(view, "delete_session", %{"id" => session_id})
        html = render_click(view, "confirm_delete")

        assert html =~ message
        assert File.exists?(path)
        refute render(view) =~ ~s(id="delete-session-modal")
      end
    end)
  end

  @tag :tmp_dir
  test "adoption rejects active terminal resources without changing orphaned session files", %{
    conn: conn,
    tmp_dir: tmp_dir
  } do
    workdir = tmp_workdir!("repository-adopt-active-terminal")
    session_id = "active-terminal"
    ledger_key = {__MODULE__, session_id, make_ref()}
    {:ok, ledger} = ResourceLedger.start_link(name: nil, persistence_key: ledger_key)

    on_exit(fn ->
      stop_repository(workdir)
      if Process.alive?(ledger), do: GenServer.stop(ledger)
      :persistent_term.erase(ledger_key)
      File.rm_rf!(workdir)
    end)

    with_agent_dir(tmp_dir, fn ->
      {:ok, _repo} = RepoManager.add_repo(workdir, name: "Repo")
      sessions_dir = ConfigManager.sessions_dir(workdir)

      session_path =
        start_runtime_session!(workdir, session_id, sessions_dir, ledger,
          recorded_cwd: "/missing/repository"
        )

      metadata_path = Path.join(sessions_dir, "#{session_id}.meta.json")

      File.write!(
        metadata_path,
        Jason.encode!(%{"cwd" => "/missing/repository", "branch" => "main"})
      )

      operation = Sigma.Agent.Terminals.issue_operation(workdir, session_id, "create", :create)
      assert {:ok, _terminal} = Sigma.Agent.Terminals.create(workdir, session_id, operation)

      encoded_repository = Base.url_encode64(workdir, padding: false)
      {:ok, view, _html} = live(conn, "/repository/#{encoded_repository}")
      html = render_click(view, "adopt_session", %{"id" => session_id})

      assert html =~
               "Terminal resources are still active. Close or clean up terminals before changing this session."

      assert File.exists?(session_path)

      assert Jason.decode!(File.read!(metadata_path)) == %{
               "cwd" => "/missing/repository",
               "branch" => "main"
             }

      assert render(view) =~ session_id
    end)
  end

  test "maps terminal operation rejections to safe actionable messages" do
    assert OperationError.message(Sigma.Agent.Terminals.Error.new(:cleanup_unconfirmed)) ==
             "Terminal cleanup could not be confirmed. The session was not changed; retry cleanup before trying again."

    assert OperationError.message(
             Sigma.Agent.Terminals.Error.new(:session_unavailable, %{reason: :ledger_untrusted})
           ) ==
             "Terminal resource status is unavailable. The session was not changed; try again after it recovers."

    assert OperationError.message(Sigma.Agent.Terminals.Error.new(:session_draining)) ==
             "Terminal resources are still active. Close or clean up terminals before changing this session."

    assert OperationError.message(:session_busy) ==
             "Wait for the active turn to finish before changing this session."

    assert OperationError.message(:invalid_session_id) ==
             "This session identifier is invalid. No files were changed."

    assert OperationError.message({:internal, %{secret: "do not expose"}}) ==
             "This session operation could not be completed. No files were changed."
  end

  defp assert_sidebar_order(html) do
    assert :binary.match(html, "project-sidebar-settings") <
             :binary.match(html, "project-sidebar-skills")

    assert :binary.match(html, "project-sidebar-skills") <
             :binary.match(html, "project-sidebar-new-session")

    assert :binary.match(html, "project-sidebar-new-session") <
             :binary.match(html, "project-sidebar-session-list")
  end

  defp with_agent_dir(tmp_dir, fun) do
    previous = Application.get_env(:sigma_session, :agent_dir)
    Application.put_env(:sigma_session, :agent_dir, Path.join(tmp_dir, "agent"))

    try do
      fun.()
    after
      if previous do
        Application.put_env(:sigma_session, :agent_dir, previous)
      else
        Application.delete_env(:sigma_session, :agent_dir)
      end
    end
  end

  defp write_session_files!(sessions_dir, id) do
    File.mkdir_p!(sessions_dir)
    File.write!(Path.join(sessions_dir, "#{id}.jsonl"), "{}\n")

    File.write!(
      Path.join(sessions_dir, "#{id}.meta.json"),
      Jason.encode!(%{"cwd" => "/tmp/repo"})
    )
  end

  defp tmp_workdir!(prefix) do
    path = Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    path
  end

  defp stop_repository(repo) do
    case Sigma.Agent.Runtime.lookup(repo, :supervisor) do
      pid when is_pid(pid) ->
        DynamicSupervisor.terminate_child(Sigma.Agent.DynamicSupervisor, pid)

      nil ->
        :ok
    end
  end

  defp start_runtime_session!(workdir, session_id, sessions_dir, ledger, opts \\ []) do
    session_path = Path.join(sessions_dir, "#{session_id}.jsonl")
    recorded_cwd = Keyword.get(opts, :recorded_cwd, workdir)
    File.mkdir_p!(sessions_dir)
    :ok = Sigma.Session.Log.persist_event(session_path, {:agent_start, recorded_cwd})

    assert {:ok, _handle} =
             Sigma.Agent.Runtime.get_session(workdir, session_id,
               cwd: workdir,
               transcript_path: session_path,
               model: %{id: "mock", api: "mock", provider: "mock"},
               provider: EmptyProvider,
               idle_timeout_ms: 30_000,
               terminal_backend: Keyword.get(opts, :terminal_backend, FakeBackend),
               terminal_resource_ledger: ledger
             )

    session_path
  end

  defmodule EmptyProvider do
    @behaviour Sigma.Ai.Provider

    @impl true
    def stream(_params), do: []
  end
end
