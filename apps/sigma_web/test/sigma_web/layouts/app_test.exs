defmodule Sigma.Web.Layouts.AppTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  test "renders accessible appbar actions without overflow-prone hint popovers" do
    html =
      render_component(&Sigma.Web.Layouts.app/1, %{
        active_tab: :home,
        flash: %{},
        inner_content: "Content",
        logs_available: true,
        show_logs: false
      })

    document = LazyHTML.from_document(html)

    for label <- ["Home", "Settings", "Debug Logs"] do
      assert document
             |> LazyHTML.query("[aria-label='#{label}'][title='#{label}']")
             |> Enum.count() == 1

      refute document
             |> LazyHTML.query("[aria-label='#{label}'][interestfor]")
             |> Enum.any?()
    end

    assert document
           |> LazyHTML.query("#app-version-trigger")
           |> LazyHTML.text()
           |> String.trim() == "v#{Sigma.MixProject.project()[:version]}"

    assert document
           |> LazyHTML.query("#app-version-tooltip[role='tooltip']")
           |> Enum.count() == 1
  end

  test "development version includes the dev suffix and build details" do
    document = render_version(build_info())

    assert document |> LazyHTML.query("#app-version-trigger") |> LazyHTML.text() |> String.trim() ==
             "v1.2.3-dev"

    details = document |> LazyHTML.query("#app-version-tooltip") |> LazyHTML.text()

    assert details =~ "Version: 1.2.3-dev"
    assert details =~ "Environment: dev"
    assert details =~ "Git ref: main"
    assert details =~ "Commit: abcdef0123456789"
    assert details =~ "Release build time: Not released"
    assert details =~ "Build time: 2026-10-10T01:02:03Z"
  end

  test "production version shows release metadata without the dev suffix" do
    document =
      render_version(
        build_info(%{
          environment: :prod,
          git_ref: "v1.2.3",
          released_at: "2026-10-10T00:00:00Z"
        })
      )

    assert document |> LazyHTML.query("#app-version-trigger") |> LazyHTML.text() |> String.trim() ==
             "v1.2.3"

    details = document |> LazyHTML.query("#app-version-tooltip") |> LazyHTML.text()

    assert details =~ "Version: 1.2.3"
    assert details =~ "Environment: prod"
    assert details =~ "Git ref: v1.2.3"
    assert details =~ "Release build time: 2026-10-10T00:00:00Z"
    refute details =~ "-dev"
  end

  test "version details remain available through a focusable DuskMoon tooltip trigger" do
    document = render_version(build_info())

    assert document
           |> LazyHTML.query(
             "button#app-version-trigger[type='button'][aria-label='Version details']" <>
               "[aria-describedby='app-version-tooltip'][interestfor='app-version-tooltip']"
           )
           |> Enum.count() == 1

    refute document
           |> LazyHTML.query(
             "#app-version-trigger[disabled], #app-version-trigger[tabindex='-1']"
           )
           |> Enum.any?()

    assert document
           |> LazyHTML.query(
             "#app-version-tooltip[role='tooltip'][popover='hint'][phx-hook='DuskmoonPopover']"
           )
           |> Enum.count() == 1
  end

  test "missing Git and release metadata is identified explicitly" do
    document =
      render_version(build_info(%{environment: :prod, git_ref: nil, git_sha: nil}))

    details = document |> LazyHTML.query("#app-version-tooltip") |> LazyHTML.text()

    assert details =~ "Git ref: Unknown"
    assert details =~ "Commit: Unknown"
    assert details =~ "Release build time: Not recorded"
  end

  defp render_version(info) do
    render_component(&Sigma.Web.Layouts.version_badge/1, %{build_info: info})
    |> LazyHTML.from_document()
  end

  defp build_info(overrides \\ %{}) do
    Map.merge(
      %{
        version: "1.2.3",
        environment: :dev,
        git_ref: "main",
        git_sha: "abcdef0123456789",
        built_at: "2026-10-10T01:02:03Z",
        released_at: nil
      },
      overrides
    )
  end
end
