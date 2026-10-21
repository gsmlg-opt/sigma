defmodule Sigma.Web.HooksSettingsLiveTest do
  use Sigma.Web.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Sigma.Session.ConfigManager

  @moduletag :tmp_dir
  @events ~w(PreModelRequest PostModelRequest PreToolUse PermissionRequest PostToolUse PreCompact PostCompact SessionStart SessionEnd UserPromptSubmit SubagentStart SubagentStop Stop Interrupt)

  setup %{tmp_dir: tmp_dir} do
    previous = Application.get_env(:sigma_session, :agent_dir)
    Application.put_env(:sigma_session, :agent_dir, Path.join(tmp_dir, "agent"))

    on_exit(fn ->
      if previous,
        do: Application.put_env(:sigma_session, :agent_dir, previous),
        else: Application.delete_env(:sigma_session, :agent_dir)
    end)

    %{hooks_file: ConfigManager.hooks_file()}
  end

  test "new settings show every event without creating configuration", %{
    conn: conn,
    hooks_file: path
  } do
    {:ok, view, html} = live(conn, "/settings/hooks")

    assert_catalog(html)
    refute File.exists?(path)
    assert has_element?(view, "#settings-hooks-add-PreToolUse")
    for event <- @events, do: assert(has_element?(view, "#settings-hooks-add-#{event}"))

    view |> element("#settings-hooks-add-PreToolUse") |> render_click()
    assert has_element?(view, "#settings-hooks-command-form")
    assert has_element?(view, "#settings-hooks-event-PreToolUse[open]")
    view |> element("#settings-hooks-command-cancel") |> render_click()
    refute has_element?(view, "#settings-hooks-command-form")
    assert has_element?(view, "#settings-hooks-event-PreToolUse[open]")
    view |> element("#settings-hooks-event-PreToolUse > summary") |> render_click()
    refute has_element?(view, "#settings-hooks-event-PreToolUse[open]")
    refute File.exists?(path)
  end

  test "every event exposes input and output help before configuration", %{
    conn: conn,
    hooks_file: path
  } do
    {:ok, view, _html} = live(conn, "/settings/hooks")

    for event <- @events do
      event_selector = "#settings-hooks-event-#{event}"
      help_selector = "#settings-hooks-help-#{event}"

      assert has_element?(
               view,
               ~s(#{help_selector} > summary[aria-label="#{event} input and output help"])
             )

      refute has_element?(view, "#{help_selector}[open]")
      view |> element("#{event_selector} > summary") |> render_click()
      view |> element("#{help_selector} > summary") |> render_click()
      assert has_element?(view, "#{event_selector}[open]")
      assert has_element?(view, "#{help_selector}[open]")
      assert has_element?(view, "#{help_selector} h3", "Output · stdout")
      assert has_element?(view, "#{help_selector} h3", "Exit codes & stderr")

      input =
        view
        |> render()
        |> Floki.parse_document!()
        |> Floki.find("#{help_selector} [data-hook-input-example] code")
        |> Floki.text()
        |> Jason.decode!()

      assert input["hook_event_name"] == event
      view |> element("#{event_selector} > summary") |> render_click()
    end

    refute File.exists?(path)
  end

  test "help remains open while a command is edited without saving", %{
    conn: conn,
    hooks_file: path
  } do
    {:ok, view, _html} = live(conn, "/settings/hooks")
    view |> element("#settings-hooks-event-PreToolUse > summary") |> render_click()
    view |> element("#settings-hooks-help-PreToolUse > summary") |> render_click()
    view |> element("#settings-hooks-add-PreToolUse") |> render_click()

    view
    |> form("#settings-hooks-command-form", command: %{command: "echo draft"})
    |> render_change()

    assert has_element?(view, "#settings-hooks-help-PreToolUse[open]")
    assert has_element?(view, "#settings-hooks-help-PreToolUse [data-hook-output-example]")
    view |> element("#settings-hooks-command-cancel") |> render_click()
    assert has_element?(view, "#settings-hooks-help-PreToolUse[open]")
    view |> element("#settings-hooks-help-PreToolUse > summary") |> render_click()
    refute has_element?(view, "#settings-hooks-help-PreToolUse[open]")
    assert has_element?(view, "#settings-hooks-event-PreToolUse[open]")
    refute File.exists?(path)
  end

  test "commands can be added, edited and removed without losing other configuration", %{
    conn: conn,
    hooks_file: path
  } do
    sibling = %{
      "type" => "http",
      "url" => "https://example.test",
      "headers" => %{"x-key" => "value"}
    }

    group = %{"matcher" => "Bash", "extra" => true, "hooks" => [sibling]}
    original = %{"version" => 3, "hooks" => %{"PreToolUse" => [group], "FutureEvent" => []}}
    write_json(path, original)
    {:ok, view, html} = live(conn, "/settings/hooks")
    assert_catalog(html)
    assert html =~ "Configure this handler in Advanced JSON."

    view |> element("#settings-hooks-add-PreToolUse") |> render_click()
    submit_command(view, "echo before", "Edit", "12")
    assert has_element?(view, ~s([data-hook-command="echo before"]))
    assert has_element?(view, "#settings-hooks-event-PreToolUse[open]")
    added = Jason.decode!(File.read!(path))
    assert added["version"] == 3
    assert added["hooks"]["FutureEvent"] == []
    assert hd(added["hooks"]["PreToolUse"]) == group

    view |> element("#settings-hooks-PreToolUse-1-0-edit") |> render_click()
    submit_command(view, "echo after", "Read", "")
    edited = Jason.decode!(File.read!(path))

    assert List.last(edited["hooks"]["PreToolUse"]) == %{
             "matcher" => "Read",
             "hooks" => [%{"type" => "command", "command" => "echo after"}]
           }

    {:ok, reloaded, html} = live(conn, "/settings/hooks")
    assert html =~ "echo after"
    reloaded |> element("#settings-hooks-PreToolUse-1-0-remove") |> render_click()
    assert Jason.decode!(File.read!(path)) == original
    refute has_element?(reloaded, ~s([data-hook-command="echo after"]))
  end

  test "invalid commands and JSON show errors without writing", %{conn: conn, hooks_file: path} do
    {:ok, view, _html} = live(conn, "/settings/hooks")
    view |> element("#settings-hooks-add-PreToolUse") |> render_click()
    submit_command(view, "  ", "", "")
    assert has_element?(view, ~s([role="alert"]), "Command is required.")
    refute File.exists?(path)

    submit_command(view, "echo valid", "", "0")
    assert has_element?(view, ~s([role="alert"]), "Timeout must be a positive integer")
    refute File.exists?(path)

    view |> element("#settings-hooks-command-cancel") |> render_click()
    view |> form("#settings-hooks-form", hooks_json: "{broken") |> render_submit()
    assert has_element?(view, ~s([role="alert"]), "Invalid JSON")
    refute File.exists?(path)
  end

  test "formatting updates the advanced textarea without saving", %{conn: conn, hooks_file: path} do
    {:ok, view, _html} = live(conn, "/settings/hooks")

    raw =
      Jason.encode!(%{
        "extra" => "<tag> & \"quoted\" &quot; </textarea>",
        "hooks" => %{"Stop" => []}
      })

    view |> element("#settings-hooks-advanced summary") |> render_click()
    view |> form("#settings-hooks-form", hooks_json: raw) |> render_change()
    view |> element("#settings-hooks-format") |> render_click()
    assert has_element?(view, "#settings-hooks-advanced[open]")

    formatted = textarea_value(view, "#hooks-editor")
    assert formatted == Jason.encode!(Jason.decode!(raw), pretty: true)
    assert formatted =~ "\n"
    refute File.exists?(path)

    view |> form("#settings-hooks-form", hooks_json: formatted) |> render_submit()
    assert File.read!(path) == formatted
  end

  test "editing an event without a matcher field preserves its existing group matcher", %{
    conn: conn,
    hooks_file: path
  } do
    group = %{
      "matcher" => "preserve me",
      "hooks" => [%{"cmd" => "echo old", "timeoutSec" => 10, "statusMessage" => "Busy"}]
    }

    write_json(path, %{"hooks" => %{"Stop" => [group]}})
    {:ok, view, _html} = live(conn, "/settings/hooks")
    view |> element("#settings-hooks-Stop-0-0-edit") |> render_click()
    refute has_element?(view, "#settings-hooks-matcher")
    attrs = %{command: %{command: "echo changed", timeout: "10"}}
    view |> form("#settings-hooks-command-form", attrs) |> render_change()
    view |> form("#settings-hooks-command-form", attrs) |> render_submit()

    assert Jason.decode!(File.read!(path))["hooks"]["Stop"] == [
             %{
               group
               | "hooks" => [
                   %{"cmd" => "echo changed", "timeoutSec" => 10, "statusMessage" => "Busy"}
                 ]
             }
           ]
  end

  test "malformed handler values remain inspectable without changing the file", %{
    conn: conn,
    hooks_file: path
  } do
    data = %{
      "hooks" => %{
        "Stop" => [%{"hooks" => [%{"command" => %{"unexpected" => true}, "timeout" => [12]}]}]
      }
    }

    write_json(path, data)
    raw = File.read!(path)
    {:ok, _view, html} = live(conn, "/settings/hooks")

    assert_catalog(html)
    assert html =~ "unexpected"
    assert File.read!(path) == raw
  end

  test "legacy and invalid files retain advanced editing and the complete catalog", %{
    conn: conn,
    hooks_file: path
  } do
    for raw <- [~s([{"event":"Stop","hooks":[{"command":"echo legacy"}]}]), "{broken"] do
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, raw)
      {:ok, view, html} = live(conn, "/settings/hooks")

      assert_catalog(html)
      assert has_element?(view, "#settings-hooks-form")
      assert textarea_value(view, "#hooks-editor") == raw
      refute has_element?(view, "#settings-hooks-add-PreToolUse")
      view |> element("#settings-hooks-help-PreToolUse > summary") |> render_click()
      assert has_element?(view, "#settings-hooks-help-PreToolUse[open] [data-hook-input-example]")
      assert File.read!(path) == raw
    end
  end

  test "Codex bounded events expose matchers, limits and async behavior", %{
    conn: conn,
    hooks_file: path
  } do
    {:ok, view, _} = live(conn, "/settings/hooks")
    view |> element("#settings-hooks-add-SessionEnd") |> render_click()
    assert has_element?(view, ~s(#settings-hooks-matcher[placeholder="other"]))
    assert has_element?(view, ~s(#settings-hooks-timeout[max="3"][placeholder="1"]))
    refute has_element?(view, "#settings-hooks-async")
    submit_command(view, "echo closing", "other", "4")
    assert has_element?(view, ~s([role="alert"]), "Timeout cannot exceed 3 seconds")
    refute File.exists?(path)
    view |> element("#settings-hooks-command-cancel") |> render_click()

    view |> element("#settings-hooks-add-Interrupt") |> render_click()
    refute has_element?(view, "#settings-hooks-matcher")
    assert has_element?(view, "#settings-hooks-async")

    view
    |> form("#settings-hooks-command-form",
      command: %{
        command: "echo interrupted",
        timeout: "2",
        statusMessage: "Finishing",
        async: "true"
      }
    )
    |> render_submit()

    assert Jason.decode!(File.read!(path))["hooks"]["Interrupt"] == [
             %{
               "hooks" => [
                 %{
                   "type" => "command",
                   "command" => "echo interrupted",
                   "timeout" => 2,
                   "statusMessage" => "Finishing",
                   "async" => true
                 }
               ]
             }
           ]
  end

  defp submit_command(view, command, matcher, timeout) do
    view
    |> form("#settings-hooks-command-form",
      command: %{command: command, matcher: matcher, timeout: timeout}
    )
    |> render_submit()
  end

  defp assert_catalog(html) do
    document = Floki.parse_document!(html)

    assert Floki.find(document, "[data-hook-event]") |> Floki.attribute("data-hook-event") ==
             @events
  end

  defp textarea_value(view, selector) do
    view
    |> render()
    |> Floki.parse_document!()
    |> Floki.find(selector)
    |> Floki.text()
    |> Floki.parse_fragment!()
    |> Floki.text()
  end

  defp write_json(path, data) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(data))
  end
end
