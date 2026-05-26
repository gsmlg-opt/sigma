defmodule PiSession.Storage.JsonlFile do
  @moduledoc """
  JSONL file implementation of `PiSession.Storage`.
  """

  @behaviour PiSession.Storage

  require Logger

  alias PiSession.Storage

  @impl Storage
  def append(path, entry) do
    with {:ok, json} <- Jason.encode(entry) do
      File.write(path, json <> "\n", [:append])
    end
  end

  @impl Storage
  def read(path) do
    if File.exists?(path) do
      stream =
        path
        |> File.stream!()
        |> Stream.map(&String.trim/1)
        |> Stream.reject(&(&1 == ""))
        |> Stream.with_index(1)

      {entries_rev, bad_rev, total_lines} =
        Enum.reduce(stream, {[], [], 0}, fn {line, idx}, {good, bad, _} ->
          case Jason.decode(line) do
            {:ok, decoded} -> {[decoded | good], bad, idx}
            {:error, _} -> {good, [{idx, line} | bad], idx}
          end
        end)

      if bad_rev != [] do
        emit_diagnostics(path, Enum.reverse(bad_rev), total_lines)
      end

      {:ok, Enum.reverse(entries_rev)}
    else
      {:ok, []}
    end
  end

  defp emit_diagnostics(path, bad_lines, total_lines) do
    bad_count = length(bad_lines)

    :telemetry.execute(
      [:ex_pi, :session, :corrupt_lines],
      %{count: bad_count},
      %{path: path, line_numbers: Enum.map(bad_lines, &elem(&1, 0))}
    )

    {trailing, interior} = Enum.split_with(bad_lines, fn {idx, _} -> idx == total_lines end)

    Enum.each(interior, fn {idx, _} ->
      Logger.warning(
        "[PiSession] Skipping corrupt line #{idx} in #{path} (#{bad_count} bad line(s) total)"
      )
    end)

    Enum.each(trailing, fn {idx, _} ->
      Logger.debug(
        "[PiSession] Skipping trailing incomplete line #{idx} in #{path} — likely torn write"
      )
    end)
  end
end
