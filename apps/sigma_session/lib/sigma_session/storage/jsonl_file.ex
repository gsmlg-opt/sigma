defmodule Sigma.Session.Storage.JsonlFile do
  @moduledoc """
  JSONL file implementation of `Sigma.Session.Storage`.
  """

  @behaviour Sigma.Session.Storage

  require Logger

  alias Sigma.Session.Storage

  @impl Storage
  def append(path, entry) do
    with {:ok, json} <- Jason.encode(entry) do
      File.write(path, json <> "\n", [:append])
    end
  end

  @impl Storage
  def read(path) do
    with {:ok, entries, _diagnostics} <- read_with_diagnostics(path) do
      {:ok, entries}
    end
  end

  @impl Storage
  def read_with_diagnostics(path) do
    if File.exists?(path) do
      {entries_rev, bad_rev, last_nonblank_line} =
        path
        |> File.stream!()
        |> Stream.with_index(1)
        |> Enum.reduce({[], [], nil}, fn {raw_line, line_number}, {good, bad, last_nonblank} ->
          line = String.trim(raw_line)

          if line == "" do
            {good, bad, last_nonblank}
          else
            case Jason.decode(line) do
              {:ok, decoded} ->
                {[decoded | good], bad, line_number}

              {:error, _reason} ->
                terminated? = String.ends_with?(raw_line, "\n")
                {good, [{line_number, terminated?} | bad], line_number}
            end
          end
        end)

      diagnostics =
        bad_rev
        |> Enum.reverse()
        |> Enum.map(fn {line_number, terminated?} ->
          kind =
            if line_number == last_nonblank_line and not terminated?,
              do: :trailing_incomplete_json,
              else: :invalid_json

          %{kind: kind, line: line_number}
        end)

      emit_diagnostics(path, diagnostics)
      {:ok, Enum.reverse(entries_rev), diagnostics}
    else
      {:ok, [], []}
    end
  end

  defp emit_diagnostics(_path, []), do: :ok

  defp emit_diagnostics(path, diagnostics) do
    :telemetry.execute(
      [:sigma, :session, :corrupt_lines],
      %{count: length(diagnostics)},
      %{path: path, line_numbers: Enum.map(diagnostics, & &1.line)}
    )

    Enum.each(diagnostics, fn
      %{kind: :invalid_json, line: line_number} ->
        Logger.warning(
          "[Sigma.Session] Skipping corrupt line #{line_number} in #{path} " <>
            "(#{length(diagnostics)} bad line(s) total)"
        )

      %{kind: :trailing_incomplete_json, line: line_number} ->
        Logger.debug(
          "[Sigma.Session] Skipping trailing incomplete line #{line_number} in #{path} " <>
            "- likely torn write"
        )
    end)
  end
end
