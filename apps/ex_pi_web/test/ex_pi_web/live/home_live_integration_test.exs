defmodule ExPiWeb.HomeLiveIntegrationTest do
  use ExPiWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  alias ExPiSession.RepoManager

  test "renders home page grid", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/")
    assert html =~ "Repositories"
    assert html =~ "Add Repository"
  end

  test "opens add repository modal", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    
    view 
    |> element("#add-repo-btn") 
    |> render_click()

    assert render(view) =~ "Add Project Repository"
    assert render(view) =~ "Selected Path"
  end

  test "adds valid repo from modal and appears in grid", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    
    view |> element("#add-repo-btn") |> render_click()
    
    # By default browser shows user home
    # We can use browser_confirm which adds current browsing_path
    render_click(view, "browser_confirm")
    
    assert render(view) =~ "Repository added successfully."
    home = System.user_home!()
    assert render(view) =~ Path.basename(home)
    
    # Cleanup
    RepoManager.remove_repo(home)
  end

  test "toggles directory browser in modal", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    
    view |> element("#add-repo-btn") |> render_click()
    
    assert render(view) =~ "Add This Directory"
    home = System.user_home!()
    assert render(view) =~ home
    
    # Navigate up
    render_click(view, "browser_up")
    assert render(view) =~ Path.dirname(home)
  end
end
