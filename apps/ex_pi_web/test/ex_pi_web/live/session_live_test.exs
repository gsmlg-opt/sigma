defmodule ExPiWeb.SessionLiveTest do
  use ExPiWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  @workdir "/tmp/pi-test"
  @encoded_workdir Base.url_encode64(@workdir)

  setup do
    File.mkdir_p!(@workdir)

    sessions_dir =
      Path.join(ExPiWeb.get_sessions_root(), Base.url_encode64(@workdir, padding: false))

    File.rm_rf!(sessions_dir)
    on_exit(fn -> File.rm_rf!(@workdir) end)
    :ok
  end

  test "renders session page", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/repository/#{@encoded_workdir}/sessions/test")
    assert html =~ "Ask π anything"
    assert html =~ "Shift+Enter for newline"
  end

  test "submits prompt", %{conn: conn} do
    Phoenix.PubSub.subscribe(ExPiWeb.PubSub, "session:test")
    {:ok, view, _html} = live(conn, "/repository/#{@encoded_workdir}/sessions/test")

    render_submit(view, "send_prompt", %{"prompt" => "hello"})

    assert_receive {:agent_start, _}, 2000
    assert_receive {:turn_start}, 2000
    assert_receive {:message_start, %{role: :user, content: "hello"}}, 2000
    assert_receive {:message_end, %{role: :assistant}}, 2000
  end
end
