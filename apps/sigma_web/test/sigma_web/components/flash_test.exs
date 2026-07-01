defmodule Sigma.Web.FlashTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Sigma.Web.Flash

  test "flash body click does not clear the flash" do
    html =
      render_component(&Flash.sigma_flash_group/1,
        flash: %{"error" => "Could not load session"}
      )

    tree = Floki.parse_document!(html)
    [toast] = Floki.find(tree, "#flash-error")
    [close] = Floki.find(toast, ".toast-close")

    assert Floki.attribute(toast, "phx-click") == []
    assert Floki.attribute(close, "phx-click") |> List.first() =~ "lv:clear-flash"
  end
end
