defmodule Sigma.Web.ImageAttachmentsTest do
  use ExUnit.Case, async: true

  alias Sigma.Web.ImageAttachments

  @png <<137, 80, 78, 71, 13, 10, 26, 10, 0>>
  @jpeg <<255, 216, 255, 224, 0>>
  @webp <<"RIFF", 0::little-32, "WEBP", 0>>
  @single_gif Base.decode64!("R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw==")

  describe "normalize/2" do
    test "normalizes empty and text-only prompts" do
      assert {:ok, :empty} = ImageAttachments.normalize("   \n", [])
      assert {:ok, "hello"} = ImageAttachments.normalize("  hello\n", [])
    end

    test "normalizes text-plus-image and image-only prompts into canonical blocks" do
      raw = raw_image("image/png", @png)
      encoded = raw["data"]

      assert {:ok,
              [
                %{type: :text, text: "Describe this"},
                %{type: :image, mime_type: "image/png", data: ^encoded}
              ]} = ImageAttachments.normalize(" Describe this ", [raw])

      assert {:ok, [%{type: :image, mime_type: "image/png", data: ^encoded}]} =
               ImageAttachments.normalize(" \n", [raw])
    end

    test "accepts each supported image signature" do
      for {mime, bytes} <- [
            {"image/png", @png},
            {"image/jpeg", @jpeg},
            {"image/gif", @single_gif},
            {"image/webp", @webp}
          ] do
        assert {:ok, [%{type: :image, mime_type: ^mime}]} =
                 ImageAttachments.normalize("", [raw_image(mime, bytes)])
      end
    end

    test "rejects unsupported MIME types, malformed maps, and invalid base64" do
      assert {:error, :unsupported_type} =
               ImageAttachments.normalize("", [raw_image("image/svg+xml", "<svg/>")])

      assert {:error, :invalid_data} = ImageAttachments.normalize("", [%{}])

      assert {:error, :invalid_data} =
               ImageAttachments.normalize("", [%{"mime_type" => "image/png", "data" => nil}])

      assert {:error, :invalid_data} =
               ImageAttachments.normalize("", [
                 %{"mime_type" => "image/png", "data" => "not/base64!"}
               ])

      assert {:error, :invalid_data} =
               ImageAttachments.normalize("", [
                 %{"mime_type" => "image/png", "data" => Base.encode64(@png) <> "\n"}
               ])

      assert {:error, :invalid_data} = ImageAttachments.normalize(nil, [])
      assert {:error, :invalid_data} = ImageAttachments.normalize("", nil)
    end

    test "rejects MIME and signature mismatches" do
      assert {:error, :invalid_data} =
               ImageAttachments.normalize("", [raw_image("image/png", @jpeg)])

      assert {:error, :invalid_data} =
               ImageAttachments.normalize("", [raw_image("image/jpeg", @webp)])

      assert {:error, :invalid_data} =
               ImageAttachments.normalize("", [raw_image("image/gif", @png)])

      assert {:error, :invalid_data} =
               ImageAttachments.normalize("", [raw_image("image/webp", @png)])
    end

    test "rejects images accompanying slash-prefixed text" do
      assert {:error, :slash_command} =
               ImageAttachments.normalize("  /reload-tools ", [raw_image("image/png", @png)])

      assert {:ok, "/reload-tools"} = ImageAttachments.normalize(" /reload-tools ", [])
    end

    test "rejects more than four images" do
      images = List.duplicate(raw_image("image/png", @png), 5)

      assert {:error, :too_many} = ImageAttachments.normalize("", images)
    end

    test "rejects an image over the decoded per-file limit" do
      bytes = @png <> :binary.copy(<<0>>, 5 * 1024 * 1024 + 1 - byte_size(@png))

      assert {:error, :too_large} =
               ImageAttachments.normalize("", [raw_image("image/png", bytes)])
    end

    test "rejects an over-bound encoded per-file payload before decoding" do
      encoded = String.duplicate("!", 4 * div(5 * 1024 * 1024 + 2, 3) + 1)

      assert {:error, :too_large} =
               ImageAttachments.normalize("", [%{"mime_type" => "image/png", "data" => encoded}])
    end

    test "rejects images over the decoded aggregate limit" do
      chunk_size = 3_500_000
      bytes = @png <> :binary.copy(<<0>>, chunk_size - byte_size(@png))
      images = List.duplicate(raw_image("image/png", bytes), 3)

      assert {:error, :too_large} = ImageAttachments.normalize("", images)
    end

    test "rejects an over-bound encoded aggregate payload before decoding" do
      total_bound = 4 * (div(10 * 1024 * 1024 + 2, 3) + 3)
      encoded_size = div(total_bound, 4) + 1

      images =
        List.duplicate(
          %{"mime_type" => "image/png", "data" => String.duplicate("!", encoded_size)},
          4
        )

      assert {:error, :too_large} = ImageAttachments.normalize("", images)
    end
  end

  describe "GIF structural validation" do
    test "accepts one real image frame with global or local color tables and extensions" do
      assert {:ok, [%{type: :image, mime_type: "image/gif"}]} =
               ImageAttachments.normalize("", [raw_image("image/gif", @single_gif)])

      with_extension =
        gif_global_prefix() <>
          <<0x21, 0xFE, 2, 0x2C, 0x3B, 0>> <>
          gif_frame() <>
          <<0x3B>>

      assert {:ok, [%{type: :image, mime_type: "image/gif"}]} =
               ImageAttachments.normalize("", [raw_image("image/gif", with_extension)])

      assert {:ok, [%{type: :image, mime_type: "image/gif"}]} =
               ImageAttachments.normalize("", [raw_image("image/gif", gif_with_local_table())])
    end

    test "rejects a second structurally valid image frame as animated" do
      animated =
        gif_global_prefix() <>
          gif_frame() <>
          gif_frame() <>
          <<0x3B>>

      assert {:error, :animated_gif} =
               ImageAttachments.normalize("", [raw_image("image/gif", animated)])
    end

    test "rejects truncated logical screens and color tables" do
      truncated_logical_screen = <<"GIF89a", 1::little-16>>

      truncated_global_table =
        <<"GIF89a", 1::little-16, 1::little-16, 0x80, 0, 0, 0, 0, 0>>

      for gif <- [truncated_logical_screen, truncated_global_table] do
        assert {:error, :invalid_data} =
                 ImageAttachments.normalize("", [raw_image("image/gif", gif)])
      end
    end

    test "rejects malformed extension subblocks and image blocks" do
      malformed_extension = gif_global_prefix() <> <<0x21, 0xFE, 2, 0x41>>

      truncated_descriptor = gif_global_prefix() <> <<0x2C, 0, 0>>

      truncated_local_table =
        gif_without_global_table_prefix() <>
          <<0x2C, 0::little-16, 0::little-16, 1::little-16, 1::little-16, 0x80, 0, 0, 0>>

      unterminated_image_data =
        gif_global_prefix() <>
          <<0x2C, 0::little-16, 0::little-16, 1::little-16, 1::little-16, 0, 2, 1, 0x4C>>

      for gif <- [
            malformed_extension,
            truncated_descriptor,
            truncated_local_table,
            unterminated_image_data
          ] do
        assert {:error, :invalid_data} =
                 ImageAttachments.normalize("", [raw_image("image/gif", gif)])
      end
    end

    test "rejects zero frames and a missing trailer" do
      zero_frames = gif_global_prefix() <> <<0x3B>>
      missing_trailer = binary_part(@single_gif, 0, byte_size(@single_gif) - 1)

      for gif <- [zero_frames, missing_trailer] do
        assert {:error, :invalid_data} =
                 ImageAttachments.normalize("", [raw_image("image/gif", gif)])
      end
    end
  end

  describe "trusted errors" do
    test "returns messages for every server validation reason" do
      expected = %{
        unsupported_type: "Attach PNG, JPEG, single-frame GIF, or WebP images only.",
        too_many: "Attach no more than four images.",
        too_large: "Images must be at most 5 MiB each and 10 MiB total.",
        invalid_data: "One of the attached images is invalid.",
        animated_gif: "Animated GIF attachments are not supported.",
        slash_command: "Attachments cannot be combined with slash commands."
      }

      for {reason, message} <- expected do
        assert ImageAttachments.error_message(reason) == message
      end
    end

    test "maps only bounded client error codes to trusted messages" do
      for code <- ~w(unsupported_type too_many too_large read_failed slash_command) do
        assert {:ok, message} = ImageAttachments.client_error(code)
        assert is_binary(message)
      end

      assert :error = ImageAttachments.client_error("<script>alert(1)</script>")
      assert :error = ImageAttachments.client_error(:too_large)
    end
  end

  describe "data_url/1" do
    test "builds data URLs only for canonical allowed image blocks" do
      block = %{type: :image, data: "iVBORw0KGgo=", mime_type: "image/png"}

      assert ImageAttachments.data_url(block) == "data:image/png;base64,iVBORw0KGgo="
      assert ImageAttachments.data_url(%{block | mime_type: "image/svg+xml"}) == nil
      assert ImageAttachments.data_url(%{block | type: :text}) == nil
      assert ImageAttachments.data_url(%{block | data: nil}) == nil
      assert ImageAttachments.data_url(%{block | data: "not-base64!"}) == nil
      assert ImageAttachments.data_url(%{block | data: Base.encode64("not a PNG")}) == nil

      assert ImageAttachments.data_url(%{
               "type" => "image",
               "data" => block.data,
               "mime_type" => block.mime_type
             }) == nil
    end

    test "rejects animated and malformed GIF blocks" do
      animated =
        gif_global_prefix() <>
          gif_frame() <>
          gif_frame() <>
          <<0x3B>>

      malformed = binary_part(@single_gif, 0, byte_size(@single_gif) - 1)

      assert ImageAttachments.data_url(canonical_gif(animated)) == nil
      assert ImageAttachments.data_url(canonical_gif(malformed)) == nil
    end
  end

  defp raw_image(mime, bytes),
    do: %{"mime_type" => mime, "data" => Base.encode64(bytes)}

  defp canonical_gif(bytes),
    do: %{type: :image, mime_type: "image/gif", data: Base.encode64(bytes)}

  defp gif_global_prefix(), do: binary_part(@single_gif, 0, 19)
  defp gif_frame(), do: binary_part(@single_gif, 19, byte_size(@single_gif) - 20)

  defp gif_without_global_table_prefix(),
    do: <<"GIF89a", 1::little-16, 1::little-16, 0, 0, 0>>

  defp gif_with_local_table() do
    gif_without_global_table_prefix() <>
      <<0x2C, 0::little-16, 0::little-16, 1::little-16, 1::little-16, 0x80, 0, 0, 0, 255, 255,
        255, 2, 1, 0x4C, 0, 0x3B>>
  end
end
