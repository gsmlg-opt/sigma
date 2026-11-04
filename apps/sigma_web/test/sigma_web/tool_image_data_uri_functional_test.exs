defmodule Sigma.Web.ToolImageDataUriFunctionalTest do
  use ExUnit.Case, async: true

  alias Sigma.Web.ImageAttachments

  @moduletag :responses_image_functional
  @png "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jR9sAAAAASUVORK5CYII="
  @uri "data:image/png;base64," <> @png

  test "tool cards display the same valid image from bare base64 and complete data URI" do
    for detail <- ~w(auto low high original) do
      images = [
        %{type: :image, data: @png, mime_type: "image/png", detail: detail},
        %{type: :image, data: @uri, mime_type: "image/png", detail: detail}
      ]

      assert {:ok, [@uri, @uri]} = ImageAttachments.tool_data_urls(images)
    end
  end

  test "ordinary bare-base64 user image projection retains its existing output" do
    image = %{type: :image, data: @png, mime_type: "image/png"}
    assert {:ok, [@uri]} = ImageAttachments.data_urls([image])
  end
end
