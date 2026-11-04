defmodule Sigma.Ai.ProviderUsage do
  @moduledoc "Provider-neutral token and cache usage without invented values."

  @provenance_keys [
    :source,
    :adapter,
    :input_tokens,
    :output_tokens,
    :cache_read_tokens,
    :cache_write_tokens,
    :reasoning_tokens,
    :visible_output_tokens,
    :total_tokens
  ]
  @provenance_values [
    :provider,
    :adapter,
    :reported,
    :derived,
    :estimated,
    :unknown,
    :input,
    :input_tokens,
    :prompt_tokens,
    :output,
    :output_tokens,
    :completion_tokens,
    :cache_read,
    :cache_read_tokens,
    :cache_write,
    :cache_write_tokens,
    :reasoning,
    :reasoning_tokens,
    :visible_output,
    :visible_output_tokens,
    :total_tokens,
    :included,
    :excluded,
    :subset
  ]

  defstruct [
    :input_tokens,
    :output_tokens,
    :cache_read_tokens,
    :cache_write_tokens,
    :total_tokens,
    :reasoning_tokens,
    :visible_output_tokens,
    usage_status: :unknown,
    usage_revision: 0,
    provenance: nil
  ]

  @type t :: %__MODULE__{
          input_tokens: non_neg_integer() | nil,
          output_tokens: non_neg_integer() | nil,
          cache_read_tokens: non_neg_integer() | nil,
          cache_write_tokens: non_neg_integer() | nil,
          total_tokens: non_neg_integer() | nil,
          reasoning_tokens: non_neg_integer() | nil,
          visible_output_tokens: non_neg_integer() | nil,
          usage_status: :reported | :derived | :estimated | :unknown,
          usage_revision: non_neg_integer(),
          provenance: term()
        }

  def from_map(nil), do: nil

  def from_map(usage) when is_map(usage) do
    normalize(usage)
  end

  @doc "Normalizes provider-specific counters without inventing missing values."
  def normalize(usage) when is_map(usage) do
    input =
      first_value(usage, [:input_tokens, "input_tokens", :input, :prompt_tokens, "prompt_tokens"])

    output =
      first_value(usage, [
        :output,
        :output_tokens,
        :completion_tokens,
        "output_tokens",
        "completion_tokens"
      ])

    cache_read =
      first_value(usage, [:cache_read, :cache_read_tokens, "cache_read_tokens"]) ||
        detail(
          usage,
          ["input_tokens_details", "prompt_tokens_details", "input_token_details"],
          "cached_tokens"
        )

    cache_write = first_value(usage, [:cache_write, :cache_write_tokens, "cache_write_tokens"])

    reasoning =
      first_value(usage, [:reasoning, :reasoning_tokens, "reasoning_tokens"]) ||
        detail(
          usage,
          ["output_tokens_details", "completion_tokens_details", "output_token_details"],
          "reasoning_tokens"
        )

    visible =
      first_value(usage, [:visible_output, :visible_output_tokens, "visible_output_tokens"])

    [input, output, cache_read, cache_write, reasoning, visible] =
      Enum.map([input, output, cache_read, cache_write, reasoning, visible], &counter/1)

    total = first_value(usage, [:total_tokens, "total_tokens"]) |> counter()

    total =
      if is_nil(total) and is_integer(input) and is_integer(output),
        do: input + output,
        else: total

    fields = [input, output, cache_read, cache_write, total]
    status = usage_status(input, output, fields)

    %__MODULE__{
      input_tokens: input,
      output_tokens: output,
      cache_read_tokens: cache_read,
      cache_write_tokens: cache_write,
      total_tokens: total,
      reasoning_tokens: reasoning,
      visible_output_tokens: visible,
      usage_status: status,
      usage_revision: value(usage, :usage_revision) || value(usage, :revision) || 0,
      provenance: sanitize_provenance(value(usage, :provenance) || value(usage, :source))
    }
  end

  def normalize(_), do: nil

  @doc "Extracts wire facts while retaining pi's legacy exclusive input display field."
  def from_wire(usage, protocol) when protocol in [:openai_responses, :openai, :anthropic] do
    usage = if is_map(usage), do: usage, else: %{}

    {input, output, read, write, reasoning} =
      case protocol do
        :openai_responses ->
          {counter(usage["input_tokens"]), counter(usage["output_tokens"]),
           counter(
             detail(usage, ["input_tokens_details", "input_token_details"], "cached_tokens")
           ), nil,
           counter(
             detail(usage, ["output_tokens_details", "output_token_details"], "reasoning_tokens")
           )}

        :openai ->
          {counter(usage["prompt_tokens"]), counter(usage["completion_tokens"]),
           counter(detail(usage, ["prompt_tokens_details"], "cached_tokens")), nil,
           counter(detail(usage, ["completion_tokens_details"], "reasoning_tokens"))}

        :anthropic ->
          {counter(usage["input_tokens"]), counter(usage["output_tokens"]),
           counter(usage["cache_read_input_tokens"]),
           counter(usage["cache_creation_input_tokens"]), nil}
      end

    inclusive = if protocol == :anthropic, do: sum_known([input, read, write]), else: input
    legacy_input = if protocol == :openai_responses, do: subtract_known(input, read), else: input

    %{
      input: legacy_input,
      input_tokens: inclusive,
      output: output,
      cache_read: read,
      cache_write: write,
      reasoning_tokens: reasoning,
      total_tokens: counter(usage["total_tokens"]) || sum_known([inclusive, output]),
      provenance: %{source: :provider, input_tokens: :included},
      cost: %{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0, total: 0.0}
    }
  end

  defp sum_known(values) do
    if Enum.all?(values, &is_integer/1), do: Enum.sum(values)
  end

  defp subtract_known(input, read) when is_integer(input) and is_integer(read) and input >= read,
    do: input - read

  defp subtract_known(_, _), do: nil

  def complete?(%__MODULE__{usage_status: :reported}), do: true
  def complete?(_), do: false

  @doc "Keeps only bounded semantic provenance; transport metadata and payloads are discarded."
  def sanitize_provenance(provenance) when is_map(provenance) do
    sanitized =
      Enum.reduce(@provenance_keys, %{}, fn key, acc ->
        with value when not is_nil(value) <- value(provenance, key),
             {:ok, value} <- provenance_value(value) do
          Map.put(acc, key, value)
        else
          _unknown_or_unsafe -> acc
        end
      end)

    if map_size(sanitized) == 0, do: nil, else: sanitized
  end

  def sanitize_provenance(provenance) do
    case provenance_value(provenance) do
      {:ok, value} -> %{source: value}
      :error -> nil
    end
  end

  @doc "Returns the canonical fact shape consumed by session metrics."
  def to_fact(%__MODULE__{} = usage) do
    %{
      input_tokens_total: usage.input_tokens,
      output_tokens_total: usage.output_tokens,
      cache_read_tokens: usage.cache_read_tokens,
      cache_write_tokens: usage.cache_write_tokens,
      reasoning_tokens: usage.reasoning_tokens,
      visible_output_tokens: usage.visible_output_tokens,
      usage_status: usage.usage_status,
      usage_revision: usage.usage_revision,
      provenance: usage.provenance
    }
  end

  defp usage_status(input, output, fields) do
    cond do
      is_integer(input) and is_integer(output) -> :reported
      Enum.any?(fields, &is_integer/1) or not is_nil(input) or not is_nil(output) -> :derived
      true -> :unknown
    end
  end

  # An explicit canonical nil must not fall back to legacy exclusive input.
  defp first_value(map, keys) do
    Enum.reduce_while(keys, nil, fn key, _ ->
      case Map.fetch(map, key) do
        {:ok, value} -> {:halt, value}
        :error -> {:cont, nil}
      end
    end)
  end

  defp counter(value) when is_integer(value) and value >= 0, do: value
  defp counter(_), do: nil

  defp detail(usage, keys, field) do
    case first_value(usage, keys) do
      value when is_map(value) -> Map.get(value, field)
      _ -> nil
    end
  end

  defp provenance_value(value) when is_atom(value) do
    if value in @provenance_values, do: {:ok, value}, else: :error
  end

  defp provenance_value(value) when is_binary(value) do
    case Enum.find(@provenance_values, &(Atom.to_string(&1) == value)) do
      nil -> :error
      value -> {:ok, value}
    end
  end

  defp provenance_value(_value), do: :error

  defp value(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end
