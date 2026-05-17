defmodule ExPiWeb.HomeLiveIntegrationTest do
  use ExPiWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  alias ExPiSession.RepoManager

  test "renders home page grid", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/")
    assert html =~ "Repositories"
    assert html =~ "Add Repository"
  end

  test "navigates to add repository page", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    
    view 
    |> element("#add-repo-btn") 
    |> render_click()

    assert_patch(view, "/workdir/new/project")
    assert render(view) =~ "Add Project Repository"
    assert render(view) =~ "Selected Path"
  end

  test "adds valid repo and returns to index", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/workdir/new/project")
    
    # By default browser shows user home
    render_click(view, "browser_confirm")
    
    # Should redirect to index
    assert_redirected(view, "/")
    
    # Check index content
    {:ok, view, html} = live(conn, "/")
    assert html =~ "Repository added successfully."
    home = System.user_home!()
    assert html =~ Path.basename(home)
    
    # Cleanup
    RepoManager.remove_repo(home)
  end

  test "toggles directory browser", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/workdir/new/project")
    
    assert render(view) =~ "Add This Directory"
    home = System.user_home!()
    assert render(view) =~ home
    
    # Navigate up
    render_click(view, "browser_up")
    assert render(view) =~ Path.dirname(home)
  end
end
