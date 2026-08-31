defmodule Sigma.Web.ImageAttachments do
  @moduledoc false

  @allowed_mime_types ~w(image/png image/jpeg image/gif image/webp)
  @max_images 4
  @max_image_bytes 5 * 1024 * 1024
  @max_total_bytes 10 * 1024 * 1024
  @max_encoded_image_bytes 4 * div(@max_image_bytes + 2, 3)
  @max_encoded_total_bytes 4 * (div(@max_total_bytes + 2, 3) + @max_images - 1)

  @client_messages %{
    "unsupported_type" => "Attach PNG, JPEG, single-frame GIF, or WebP images only.",
    "too_many" => "Attach no more than four images.",
    "too_large" => "Images must be at most 5 MiB each and 10 MiB total.",
    "read_failed" => "Sigma could not read one of the attached images.",
    "slash_command" => "Attachments cannot be combined with slash commands."
  }

  @server_messages %{
    unsupported_type: "Attach PNG, JPEG, single-frame GIF, or WebP images only.",
    too_many: "Attach no more than four images.",
    too_large: "Images must be at most 5 MiB each and 10 MiB total.",
    invalid_data: "One of the attached images is invalid.",
    animated_gif: "Animated GIF attachments are not supported.",
    slash_command: "Attachments cannot be combined with slash commands."
  }

  def normalize(text, raw_images) when is_binary(text) and is_list(raw_images) do
    text = String.trim(text)

    with :ok <- validate_count(raw_images),
         :ok <- validate_slash_command(text, raw_images),
         :ok <- validate_encoded_bounds(raw_images),
         {:ok, images} <- decode_images(raw_images) do
      build_content(text, images)
    end
  end

  def normalize(_text, _raw_images), do: {:error, :invalid_data}

  def client_error(code), do: Map.fetch(@client_messages, code)
  def error_message(reason), do: Map.fetch!(@server_messages, reason)

  def data_url(%{type: :image, data: data, mime_type: mime})
      when mime in @allowed_mime_types and is_binary(data) do
    case decode_image(%{"mime_type" => mime, "data" => data}) do
      {:ok, _block, _size} -> "data:#{mime};base64,#{data}"
      {:error, _reason} -> nil
    end
  end

  def data_url(_block), do: nil

  defp build_content("", []), do: {:ok, :empty}
  defp build_content(text, []), do: {:ok, text}
  defp build_content("", images), do: {:ok, images}
  defp build_content(text, images), do: {:ok, [%{type: :text, text: text} | images]}

  defp validate_count(images) when length(images) <= @max_images, do: :ok
  defp validate_count(_images), do: {:error, :too_many}

  defp validate_slash_command("/" <> _rest, [_image | _images]), do: {:error, :slash_command}
  defp validate_slash_command(_text, _images), do: :ok

  defp validate_encoded_bounds(images) do
    if Enum.any?(images, &over_encoded_image_bound?/1) or
         encoded_total(images) > @max_encoded_total_bytes do
      {:error, :too_large}
    else
      :ok
    end
  end

  defp over_encoded_image_bound?(%{"mime_type" => mime, "data" => data})
       when mime in @allowed_mime_types and is_binary(data),
       do: byte_size(data) > @max_encoded_image_bytes

  defp over_encoded_image_bound?(_raw), do: false

  defp encoded_total(images),
    do:
      Enum.reduce(images, 0, fn
        %{"mime_type" => mime, "data" => data}, total
        when mime in @allowed_mime_types and is_binary(data) ->
          total + byte_size(data)

        _, total ->
          total
      end)

  defp decode_images(images) do
    Enum.reduce_while(images, {:ok, [], 0}, fn raw, {:ok, acc, total} ->
      case decode_image(raw) do
        {:ok, block, size} when total + size <= @max_total_bytes ->
          {:cont, {:ok, [block | acc], total + size}}

        {:ok, _block, _size} ->
          {:halt, {:error, :too_large}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, blocks, _total} -> {:ok, Enum.reverse(blocks)}
      error -> error
    end
  end

  defp decode_image(%{"mime_type" => mime, "data" => data})
       when mime in @allowed_mime_types and is_binary(data) do
    with :ok <- validate_encoded_size(data),
         {:ok, bytes} <- Base.decode64(data, strict: true),
         :ok <- validate_size(bytes),
         :ok <- validate_signature(mime, bytes),
         :ok <- validate_animation(mime, bytes) do
      {:ok, %{type: :image, data: data, mime_type: mime}, byte_size(bytes)}
    else
      :error -> {:error, :invalid_data}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_image(%{"mime_type" => mime}) when mime in @allowed_mime_types,
    do: {:error, :invalid_data}

  defp decode_image(%{"mime_type" => _mime, "data" => _data}),
    do: {:error, :unsupported_type}

  defp decode_image(_raw), do: {:error, :invalid_data}

  defp validate_size(bytes) when byte_size(bytes) <= @max_image_bytes, do: :ok
  defp validate_size(_bytes), do: {:error, :too_large}

  defp validate_encoded_size(data) when byte_size(data) <= @max_encoded_image_bytes, do: :ok
  defp validate_encoded_size(_data), do: {:error, :too_large}

  defp validate_signature("image/png", <<137, 80, 78, 71, 13, 10, 26, 10, _rest::binary>>),
    do: :ok

  defp validate_signature("image/jpeg", <<255, 216, 255, _rest::binary>>), do: :ok

  defp validate_signature("image/gif", <<header::binary-size(6), _rest::binary>>)
       when header in ["GIF87a", "GIF89a"],
       do: :ok

  defp validate_signature("image/webp", <<"RIFF", _size::little-32, "WEBP", _rest::binary>>),
    do: :ok

  defp validate_signature(_mime, _bytes), do: {:error, :invalid_data}

  defp validate_animation("image/gif", bytes) do
    case gif_frame_count(bytes) do
      {:ok, 1} -> :ok
      {:ok, frames} when frames > 1 -> {:error, :animated_gif}
      {:ok, 0} -> {:error, :invalid_data}
      {:error, :invalid_data} = error -> error
    end
  end

  defp validate_animation(_mime, _bytes), do: :ok

  defp gif_frame_count(
         <<header::binary-size(6), _width::little-16, _height::little-16, packed, _background,
           _aspect_ratio, rest::binary>>
       )
       when header in ["GIF87a", "GIF89a"] do
    with {:ok, blocks} <- skip_color_table(rest, packed),
         do: count_gif_blocks(blocks, 0)
  end

  defp gif_frame_count(_bytes), do: {:error, :invalid_data}

  defp skip_color_table(rest, packed) do
    if Bitwise.band(packed, 0x80) == 0 do
      {:ok, rest}
    else
      table_bytes = 3 * Bitwise.bsl(1, Bitwise.band(packed, 0x07) + 1)

      case rest do
        <<_table::binary-size(table_bytes), tail::binary>> -> {:ok, tail}
        _truncated -> {:error, :invalid_data}
      end
    end
  end

  defp count_gif_blocks(<<0x3B>>, frames), do: {:ok, frames}

  defp count_gif_blocks(<<0x21, _extension_label, rest::binary>>, frames) do
    with {:ok, tail} <- skip_sub_blocks(rest),
         do: count_gif_blocks(tail, frames)
  end

  defp count_gif_blocks(
         <<0x2C, _left::little-16, _top::little-16, _width::little-16, _height::little-16, packed,
           rest::binary>>,
         frames
       ) do
    with {:ok, image_data} <- skip_color_table(rest, packed),
         <<_lzw_minimum_code_size, sub_blocks::binary>> <- image_data,
         {:ok, tail} <- skip_sub_blocks(sub_blocks) do
      count_gif_blocks(tail, frames + 1)
    else
      _malformed -> {:error, :invalid_data}
    end
  end

  defp count_gif_blocks(_malformed, _frames), do: {:error, :invalid_data}

  defp skip_sub_blocks(<<0, rest::binary>>), do: {:ok, rest}

  defp skip_sub_blocks(<<size, _data::binary-size(size), rest::binary>>),
    do: skip_sub_blocks(rest)

  defp skip_sub_blocks(_truncated), do: {:error, :invalid_data}
end
