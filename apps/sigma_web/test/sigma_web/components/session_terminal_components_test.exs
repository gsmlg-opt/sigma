defmodule Sigma.Web.SessionTerminalComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Sigma.Web.SessionTerminalComponents

  test "renders unavailable and empty terminal catalog states truthfully" do
    unavailable =
      render_component(&SessionTerminalComponents.terminal_trigger/1, %{
        catalog: %{status: :unavailable}
      })

    assert unavailable =~ "Terminal catalog unavailable"
    refute unavailable =~ ">0<"

    empty =
      render_component(&SessionTerminalComponents.terminal_panel/1, %{
        catalog: %{entries: [], selected_id: nil},
        session: %{repository_id: "repo", session_id: "session", incarnation_id: "one"}
      })

    assert empty =~ "No retained terminals."
    assert empty =~ "Create terminal"
  end

  test "renders the retained count and lifecycle breakdown without a visual zero badge" do
    populated =
      render_component(&SessionTerminalComponents.terminal_trigger/1, %{
        catalog: %{
          retained_count: 3,
          state_counts: %{running: 1, exited: 1, cleanup_failed: 1}
        }
      })

    assert populated =~ "3 retained terminals: 1 running, 1 exited, 1 cleanup failed"
    assert populated =~ ~s(class="sigma-terminal-count")

    empty =
      render_component(&SessionTerminalComponents.terminal_trigger/1, %{
        catalog: %{retained_count: 0, state_counts: %{}}
      })

    assert empty =~ "0 retained terminals"
    refute empty =~ ~s(class="sigma-terminal-count")
  end

  test "renders lifecycle tab states, escaped labels, and accessible terminal controls" do
    html =
      render_component(&SessionTerminalComponents.terminal_panel/1, %{
        catalog: %{
          selected_id: "a",
          entries: [
            %{
              terminal_id: "a",
              generation: 1,
              label: "<long & label>",
              state: :running,
              controller?: true,
              resynced?: true,
              startup_directory: "/very/long/path",
              unread?: true,
              renaming?: true,
              rename_value: "<long & label>",
              rename_error: "Name is too long & must be 80 bytes or fewer"
            },
            %{
              terminal_id: "b",
              generation: 2,
              label: "Terminal 2",
              state: :exited,
              resource_state: :released,
              exit_status: 23
            },
            %{terminal_id: "c", generation: 1, label: "Terminal 3", state: :cleanup_failed}
          ]
        },
        session: %{repository_id: "repo", session_id: "session", incarnation_id: "one"}
      })

    assert html =~ "&lt;long &amp; label&gt;"
    assert html =~ "Name is too long &amp; must be 80 bytes or fewer"
    assert html =~ ~s(role="tablist")
    assert html =~ ~s(role="tab")
    assert html =~ "You control input"
    assert html =~ "exit 23"
    assert html =~ "Retry cleanup"
    assert html =~ "Restart Terminal 2; prior screen will be cleared"
    assert html =~ "commands will not be replayed"
    assert html =~ "Close this live terminal?"
    assert html =~ "aria-label=\"Unread terminal output\""
    assert html =~ ~s(data-terminal-action="height")
    assert html =~ "Adjust terminal height, current automatic"
    assert html =~ ~s(data-terminal-action-value="automatic")
    assert html =~ ~s(data-terminal-action="maximize")
    assert html =~ ~s(aria-pressed="false")
    assert html =~ ~s(phx-submit="terminal_rename_submit")
    assert html =~ ~s(phx-change="terminal_rename_validate")
    assert html =~ ~s(phx-click="terminal_rename_cancel")
    assert html =~ ~s(name="terminal_id" value="a")
    assert html =~ ~s(name="label")
    assert html =~ ~s(maxlength="80")
    assert html =~ ~s(data-max-bytes="80")
    assert html =~ "Save terminal name"
    assert html =~ ~s(phx-update="ignore")
  end
end
