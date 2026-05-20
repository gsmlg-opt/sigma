defmodule PiSession.Storage.JsonlFile do
  @moduledoc """
  JSONL file implementation of `PiSession.Storage`.
  """

  @behaviour PiSession.Storage

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
      path
      |> File.stream!()
      |> Stream.map(&String.trim/1)
      |> Stream.reject(&(&1 == ""))
      |> Enum.reduce_while({:ok, []}, fn line, {:ok, acc} ->
        case Jason.decode(line) do
          {:ok, decoded} -> {:cont, {:ok, [decoded | acc]}}
          {:error, _} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, entries} -> {:ok, Enum.reverse(entries)}
        {:error, _} = error -> error
      end
    else
      {:ok, []}
    end
  end
end
