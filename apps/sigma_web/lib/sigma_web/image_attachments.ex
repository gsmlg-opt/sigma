defmodule Sigma.Web.ImageAttachments do
  @moduledoc false

  @allowed_mime_types ~w(image/png image/jpeg image/gif image/webp)
  @max_images 4
  @max_image_bytes 5 * 1024 * 1024
  @max_total_bytes 10 * 1024 * 1024

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
         {:ok, images} <- decode_images(raw_images) do
      build_content(text, images)
    end
  end

  def normalize(_text, _raw_images), do: {:error, :invalid_data}

  def client_error(code), do: Map.fetch(@client_messages, code)
  def error_message(reason), do: Map.fetch!(@server_messages, reason)

  def data_url(%{type: :image, data: data, mime_type: mime})
      when mime in @allowed_mime_types and is_binary(data),
      do: "data:#{mime};base64,#{data}"

  def data_url(_block), do: nil

  defp build_content("", []), do: {:ok, :empty}
  defp build_content(text, []), do: {:ok, text}
  defp build_content("", images), do: {:ok, images}
  defp build_content(text, images), do: {:ok, [%{type: :text, text: text} | images]}

  defp validate_count(images) when length(images) <= @max_images, do: :ok
  defp validate_count(_images), do: {:error, :too_many}

  defp validate_slash_command("/" <> _rest, [_image | _images]), do: {:error, :slash_command}
  defp validate_slash_command(_text, _images), do: :ok

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
    with {:ok, bytes} <- Base.decode64(data, strict: true),
         :ok <- validate_size(bytes),
         :ok <- validate_signature(mime, bytes) do
      {:ok, %{type: :image, data: data, mime_type: mime}, byte_size(bytes)}
    else
      :error -> {:error, :invalid_data}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_image(%{"mime_type" => _mime, "data" => _data}),
    do: {:error, :unsupported_type}

  defp decode_image(_raw), do: {:error, :invalid_data}

  defp validate_size(bytes) when byte_size(bytes) <= @max_image_bytes, do: :ok
  defp validate_size(_bytes), do: {:error, :too_large}

  defp validate_signature("image/png", <<137, 80, 78, 71, 13, 10, 26, 10, _rest::binary>>),
    do: :ok

  defp validate_signature("image/jpeg", <<255, 216, 255, _rest::binary>>), do: :ok

  defp validate_signature("image/gif", <<header::binary-size(6), _rest::binary>>)
       when header in ["GIF87a", "GIF89a"],
       do: :ok

  defp validate_signature("image/webp", <<"RIFF", _size::little-32, "WEBP", _rest::binary>>),
    do: :ok

  defp validate_signature(_mime, _bytes), do: {:error, :invalid_data}
end
