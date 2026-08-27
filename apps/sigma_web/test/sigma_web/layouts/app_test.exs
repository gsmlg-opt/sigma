defmodule Sigma.Web.Layouts.AppTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  test "renders appbar tooltips with native hint popovers" do
    html =
      render_component(&Sigma.Web.Layouts.app/1, %{
        active_tab: :home,
        flash: %{},
        inner_content: "Content",
        logs_available: true,
        show_logs: false
      })

    document = LazyHTML.from_document(html)

    for {id, label} <- [
          {"appbar-home-tooltip", "Home"},
          {"appbar-settings-tooltip", "Settings"},
          {"appbar-debug-logs-tooltip", "Debug Logs"}
        ] do
      assert document
             |> LazyHTML.query(
               "[interestfor='#{id}'][aria-describedby='#{id}'][title='#{label}'][style*='anchor-name: --#{id}']"
             )
             |> Enum.any?()

      assert document
             |> LazyHTML.query(
               "##{id}[popover='hint'][role='tooltip'][style*='position-anchor: --#{id}'].tooltip.tooltip-bottom"
             )
             |> LazyHTML.text()
             |> String.trim() == label
    end

    refute html =~ "tooltip-content"
  end
end
