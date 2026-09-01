defmodule Sigma.Ai.ProviderUsage do
  @moduledoc "Provider-neutral token and cache usage without invented values."

  defstruct [
    :input_tokens,
    :output_tokens,
    :cache_read_tokens,
    :cache_write_tokens,
    :total_tokens
  ]

  def from_map(nil), do: nil

  def from_map(usage) when is_map(usage) do
    %__MODULE__{
      input_tokens: value(usage, :input),
      output_tokens: value(usage, :output),
      cache_read_tokens: value(usage, :cache_read),
      cache_write_tokens: value(usage, :cache_write),
      total_tokens: value(usage, :total_tokens)
    }
  end

  defp value(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end
