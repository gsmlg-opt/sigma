defmodule PiAi.Stream do
  @moduledoc """
  Pure SSE reducer for AI provider streams.
  """

  @doc """
  Takes current buffer state and a new binary chunk.
  Returns a list of parsed data (usually maps) and the new buffer state.
  """
  def decode(buffer, chunk) do
    data = buffer <> chunk
    split_events(data, [])
  end

  defp split_events(data, acc) do
    case String.split(data, "\n\n", parts: 2) do
      [event, rest] ->
        case parse_event(event) do
          nil -> split_events(rest, acc)
          parsed -> split_events(rest, [parsed | acc])
        end

      [remaining] ->
        {Enum.reverse(acc), remaining}
    end
  end

  defp parse_event(event) do
    lines = String.split(event, "\n")

    data_lines =
      for "data: " <> data <- lines do
        data
      end

    case data_lines do
      [] ->
        nil

      ["[DONE]"] ->
        :done

      list ->
        json = Enum.join(list)

        case Jason.decode(json) do
          {:ok, decoded} -> decoded
          {:error, _} -> nil
        end
    end
  end
end
