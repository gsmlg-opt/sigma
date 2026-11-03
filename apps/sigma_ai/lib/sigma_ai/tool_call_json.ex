defmodule Sigma.Ai.ToolCallJson do
  @moduledoc """
  Decodes and repairs streamed tool-call JSON arguments.

  Models frequently emit raw control characters (such as unescaped newlines or
  tabs) or unescaped backslashes (such as `\\|` in shell/grep regular
  expressions) inside JSON string literals, or empty strings for zero-argument
  tool calls. This module mirrors upstream `json-parse.ts` by repairing string
  literal escapes before failing as malformed JSON.
  """

  @valid_escapes [?", ?\\, ?/, ?b, ?f, ?n, ?r, ?t]

  @spec decode_arguments(term()) :: {:ok, map()} | :error
  def decode_arguments(arguments) when is_map(arguments), do: {:ok, arguments}
  def decode_arguments(nil), do: {:ok, %{}}

  def decode_arguments(arguments) when is_binary(arguments) do
    if String.trim(arguments) == "" do
      {:ok, %{}}
    else
      case Jason.decode(arguments) do
        {:ok, value} when is_map(value) ->
          {:ok, value}

        {:ok, _non_map} ->
          :error

        {:error, _} ->
          repaired = repair_json(arguments)

          if repaired != arguments do
            case Jason.decode(repaired) do
              {:ok, value} when is_map(value) -> {:ok, value}
              _ -> :error
            end
          else
            :error
          end
      end
    end
  end

  def decode_arguments(_arguments), do: :error

  @doc """
  Repairs malformed JSON string literals by:
  - escaping raw control characters (`0x00..0x1F`) inside strings
  - doubling backslashes before invalid escape characters
  """
  @spec repair_json(String.t()) :: String.t()
  def repair_json(json) when is_binary(json) do
    json
    |> do_repair_json(false, [])
    |> IO.iodata_to_binary()
  end

  defp do_repair_json(<<>>, _in_string?, acc), do: Enum.reverse(acc)

  defp do_repair_json(<<?", rest::binary>>, false, acc) do
    do_repair_json(rest, true, [?" | acc])
  end

  defp do_repair_json(<<byte, rest::binary>>, false, acc) do
    do_repair_json(rest, false, [byte | acc])
  end

  defp do_repair_json(<<?", rest::binary>>, true, acc) do
    do_repair_json(rest, false, [?" | acc])
  end

  defp do_repair_json(<<?\\>>, true, acc) do
    Enum.reverse(["\\\\" | acc])
  end

  defp do_repair_json(<<?\\, ?u, a, b, c, d, rest::binary>>, true, acc) do
    if hex_digit?(a) and hex_digit?(b) and hex_digit?(c) and hex_digit?(d) do
      do_repair_json(rest, true, [<<?\\, ?u, a, b, c, d>> | acc])
    else
      do_repair_json(<<?u, a, b, c, d, rest::binary>>, true, ["\\\\" | acc])
    end
  end

  defp do_repair_json(<<?\\, next, rest::binary>>, true, acc) when next in @valid_escapes do
    do_repair_json(rest, true, [<<?\\, next>> | acc])
  end

  defp do_repair_json(<<?\\, rest::binary>>, true, acc) do
    do_repair_json(rest, true, ["\\\\" | acc])
  end

  defp do_repair_json(<<byte, rest::binary>>, true, acc) when byte >= 0x00 and byte <= 0x1F do
    do_repair_json(rest, true, [escape_control_byte(byte) | acc])
  end

  defp do_repair_json(<<byte, rest::binary>>, true, acc) do
    do_repair_json(rest, true, [byte | acc])
  end

  defp hex_digit?(byte),
    do: byte in ?0..?9 or byte in ?a..?f or byte in ?A..?F

  defp escape_control_byte(?\b), do: "\\b"
  defp escape_control_byte(?\f), do: "\\f"
  defp escape_control_byte(?\n), do: "\\n"
  defp escape_control_byte(?\r), do: "\\r"
  defp escape_control_byte(?\t), do: "\\t"

  defp escape_control_byte(byte) do
    hex =
      byte
      |> Integer.to_string(16)
      |> String.downcase()
      |> String.pad_leading(4, "0")

    "\\u" <> hex
  end
end
