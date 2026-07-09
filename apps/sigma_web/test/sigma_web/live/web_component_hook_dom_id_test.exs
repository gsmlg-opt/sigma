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

  defp missing_web_component_hook_button_ids(path) do
    content = File.read!(path)

    ~r/<\.dm_btn\b(?:(?!<\/\.dm_btn>).)*?phx-hook="WebComponentHook"(?:(?!<\/\.dm_btn>).)*?<\/\.dm_btn>/s
    |> Regex.scan(content, return: :index)
    |> Enum.reject(fn [{start, length}] ->
      Regex.match?(~r/\bid=\{?"/, binary_part(content, start, length))
    end)
    |> Enum.map(fn [{start, _length}] ->
      line = content |> binary_part(0, start) |> String.split("\n") |> length()
      "#{Path.relative_to_cwd(path)}:#{line}"
    end)
  end
end
