defmodule ExPiWeb.HomeLiveIntegrationTest do
  use ExPiWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  test "submits valid workdir and navigates", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    
    # Simulate entering the path
    path = "/Users/gao/Workspace/gsmlg-dev/ex_pi"
    
    # Submit the form
    result = render_submit(view, "open_workdir", %{"workdir" => path})
    
    # Check if it navigates
    assert_redirected(view, "/workdir/#{Base.url_encode64(path, padding: false)}")
  end

  test "submits invalid workdir and shows error", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    
    path = "/non/existent/path"
    
    render_submit(view, "open_workdir", %{"workdir" => path})
    
    assert render(view) =~ "Directory does not exist or is not accessible."
  end
end
