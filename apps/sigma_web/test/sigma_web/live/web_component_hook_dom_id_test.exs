defmodule Sigma.Web.WebComponentHookDomIdTest do
  use ExUnit.Case, async: true

  @live_dir Path.expand("../../../lib/sigma_web/live", __DIR__)

  test "DuskMoon buttons with WebComponentHook have DOM IDs" do
    missing_ids =
      @live_dir
      |> Path.join("*.ex")
      |> Path.wildcard()
      |> Enum.flat_map(&missing_web_component_hook_button_ids/1)

    assert missing_ids == []
  end

  test "DOM ID check accepts literal and HEEx expression IDs" do
    for id <- [
          ~s(id="literal"),
          ~S|id={"model-#{@id}"}|,
          ~S|id={row_id("edit", row)}|
        ] do
      content = ~s(<.dm_btn #{id} phx-hook="WebComponentHook">Edit</.dm_btn>)

      assert missing_web_component_hook_button_ids(content, "fixture.ex") == []
    end
  end

  test "DOM ID check rejects missing IDs and value attributes" do
    for attributes <- ["", ~s(phx-value-id="row")] do
      content = ~s(<.dm_btn #{attributes} phx-hook="WebComponentHook">Edit</.dm_btn>)

      assert missing_web_component_hook_button_ids(content, "fixture.ex") == ["fixture.ex:1"]
    end
  end

  defp missing_web_component_hook_button_ids(path) do
    missing_web_component_hook_button_ids(File.read!(path), path)
  end

  defp missing_web_component_hook_button_ids(content, path) do
    ~r/<\.dm_btn\b(?:(?!<\/\.dm_btn>).)*?phx-hook="WebComponentHook"(?:(?!<\/\.dm_btn>).)*?<\/\.dm_btn>/s
    |> Regex.scan(content, return: :index)
    |> Enum.reject(fn [{start, length}] ->
      Regex.match?(~r/\sid\s*=\s*(?:"|\{)/, binary_part(content, start, length))
    end)
    |> Enum.map(fn [{start, _length}] ->
      line = content |> binary_part(0, start) |> String.split("\n") |> length()
      "#{Path.relative_to_cwd(path)}:#{line}"
    end)
  end
end
