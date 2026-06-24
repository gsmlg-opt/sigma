defmodule Sigma.Tools.Hashline do
  @moduledoc false

  alias Sigma.Tools.Hashline.Native

  def compute_file_hash(text) when is_binary(text), do: Native.compute_file_hash(text)

  def parse_sections(input, cwd) when is_binary(input) do
    input
    |> Native.parse_sections_json(cwd)
    |> decode_response()
  end

  def apply_edits(text, diff) when is_binary(text) and is_binary(diff) do
    text
    |> Native.apply_edits_json(diff)
    |> decode_response()
  end

  def format_header(path, tag), do: "[#{path}##{tag}]"
  def format_numbered_line(line_number, line), do: "#{line_number}:#{line}"

  def format_numbered_lines(text, start_line \\ 1) do
    text
    |> String.split("\n")
    |> Enum.with_index(start_line)
    |> Enum.map_join("\n", fn {line, line_number} -> format_numbered_line(line_number, line) end)
  end

  def strip_bom(<<"\uFEFF", rest::binary>>), do: {"\uFEFF", rest}
  def strip_bom(text), do: {"", text}

  def normalize_to_lf(text) do
    text
    |> String.replace("\r\n", "\n")
    |> String.replace("\r", "\n")
  end

  def detect_line_ending(text) do
    cond do
      String.contains?(text, "\r\n") -> "\r\n"
      String.contains?(text, "\r") -> "\r"
      true -> "\n"
    end
  end

  def restore_line_endings(text, "\n"), do: text
  def restore_line_endings(text, line_ending), do: String.replace(text, "\n", line_ending)

  defp decode_response(json) do
    case Jason.decode(json) do
      {:ok, %{"ok" => true, "value" => value}} -> {:ok, value}
      {:ok, %{"ok" => false, "error" => error}} -> {:error, error}
      {:ok, other} -> {:error, "Unexpected hashline NIF response: #{inspect(other)}"}
      {:error, error} -> {:error, "Could not decode hashline NIF response: #{Exception.message(error)}"}
    end
  end
end
