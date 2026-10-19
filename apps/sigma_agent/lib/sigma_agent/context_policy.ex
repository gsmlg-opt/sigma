defmodule Sigma.Agent.ContextPolicy do
  @moduledoc """
  Pure context accounting and compaction-policy views.

  This module deliberately does not decide when to compact or mutate a session.
  It describes the last provider measurement and the next request estimate so
  runtime and clients can use the same values and provenance.
  """

  @default_threshold 80_000
  @default_ratio 0.8

  def default_context_limit, do: 256_000

  def parse_context_limit(value) do
    case positive(value) do
      limit when is_integer(limit) and limit > 0 -> {:ok, limit}
      _ -> {:error, :invalid_context_limit}
    end
  end

  @doc "Resolves a new session budget independently of the model's capacity."
  def new_session_limit(model, explicit \\ nil) do
    if explicit in [nil, ""] do
      case parse_context_limit(model_value(model, :default_context_limit)) do
        {:ok, _} = result -> result
        _ -> {:ok, default_context_limit()}
      end
    else
      parse_context_limit(explicit)
    end
  end

  defstruct context_revision: nil,
            active_leaf: nil,
            model: nil,
            source: :unknown,
            generated_at: nil,
            last_request_input_tokens: nil,
            last_request_id: nil,
            last_measured_at: nil,
            last_measurement_source: :unknown,
            next_request_estimated_input_tokens: nil,
            estimate_components: %{},
            estimate_coverage: :unknown,
            estimate_unknown_components: [],
            stale: false

  @type t :: %__MODULE__{}

  @doc "Builds a context snapshot from already assembled context parts."
  @spec snapshot(keyword() | map()) :: t()
  def snapshot(opts \\ []) do
    opts = normalize_opts(opts)
    components = estimate_components(opts)

    unknown =
      components |> Enum.filter(fn {_key, value} -> is_nil(value) end) |> Enum.map(&elem(&1, 0))

    known_total = components |> Map.values() |> Enum.filter(&is_integer/1) |> Enum.sum()

    estimate = positive(get(opts, :next_request_estimated_input_tokens)) || known_total

    %__MODULE__{
      context_revision: get(opts, :context_revision),
      active_leaf: get(opts, :active_leaf),
      model: get(opts, :model),
      source: get(opts, :source, :unknown),
      generated_at: generated_at(opts),
      last_request_input_tokens: positive(get(opts, :last_request_input_tokens)),
      last_request_id: get(opts, :last_request_id),
      last_measured_at: get(opts, :last_measured_at),
      last_measurement_source: measurement_source(opts),
      next_request_estimated_input_tokens: estimate,
      estimate_components: components,
      estimate_coverage: coverage(components),
      estimate_unknown_components: unknown,
      stale: !!get(opts, :stale, false)
    }
  end

  @doc "Alias for callers that use the longer contract name."
  def context_snapshot(opts \\ []), do: snapshot(opts)

  @doc "Invalidates an existing runtime estimate while preserving known measurements."
  @spec invalidate(t(), keyword() | map()) :: t()
  def invalidate(%__MODULE__{} = context, opts \\ []) do
    opts = normalize_opts(opts)

    %{
      context
      | context_revision: get(opts, :context_revision, next_revision(context.context_revision)),
        active_leaf: get(opts, :active_leaf, context.active_leaf),
        model: get(opts, :model, context.model),
        source: get(opts, :source, :runtime_invalidation),
        generated_at: generated_at(opts),
        stale: true
    }
  end

  @doc "Returns the effective compaction and hard-budget policy for a snapshot."
  @spec policy(t() | keyword() | map(), keyword() | map()) :: map()
  def policy(context, opts \\ [])
  def policy(%__MODULE__{} = context, opts), do: policy(Map.from_struct(context), opts)

  def policy(context, opts) when is_map(context) do
    opts = normalize_opts(opts)
    model = get(opts, :model) || Map.get(context, :model)
    model_window = positive(get(opts, :context_window)) || model_context_window(model)
    limit = positive(get(opts, :context_limit))
    window = if limit, do: min(limit, model_window || limit), else: model_window

    window_source =
      cond do
        limit && (is_nil(model_window) || limit < model_window) -> :session
        positive(get(opts, :context_window)) -> :runtime
        window -> :model
        true -> :unknown
      end

    threshold =
      positive(get(opts, :threshold)) ||
        if(window, do: floor(window * @default_ratio), else: @default_threshold)

    threshold_source =
      cond do
        positive(get(opts, :threshold)) -> :runtime
        window_source == :session -> :session_ratio
        window -> :model_ratio
        true -> :runtime_default
      end

    estimate = positive(Map.get(context, :next_request_estimated_input_tokens))

    reserve =
      positive(get(opts, :output_reserve)) || positive(model_value(model, :max_output_tokens)) ||
        0

    stale = Map.get(context, :stale, false) or Map.get(context, :estimate_coverage) == :unknown
    overflow = overflow_status(estimate, window, reserve)

    %{
      context_limit: limit,
      context_window: window,
      window_source: window_source,
      threshold: threshold,
      threshold_source: threshold_source,
      check_phase: get(opts, :check_phase, :before_request),
      output_reserve: reserve,
      overflow: overflow,
      estimate_stale: stale,
      tokens_remaining: if(is_integer(estimate), do: max(0, threshold - estimate), else: nil),
      hard_tokens_remaining:
        if(is_integer(estimate) and window, do: max(0, window - estimate - reserve), else: nil)
    }
  end

  defp estimate_components(opts) do
    %{
      system: count_part(get(opts, :system), get(opts, :system_tokens)),
      messages: count_part(get(opts, :messages), get(opts, :message_tokens)),
      tools: count_part(get(opts, :tools), get(opts, :tool_tokens)),
      skills: count_part(get(opts, :skills), get(opts, :skill_tokens)),
      attachments: count_part(get(opts, :attachments), get(opts, :attachment_tokens)),
      reserved_messages: positive(get(opts, :reserved_messages, 0))
    }
  end

  defp count_part(_value, explicit) when is_integer(explicit) and explicit >= 0, do: explicit
  defp count_part(nil, _explicit), do: 0
  defp count_part(value, _explicit) when is_binary(value), do: token_estimate(value)
  defp count_part(value, _explicit) when is_list(value), do: structured_token_estimate(value)
  defp count_part(_value, _explicit), do: nil

  defp token_estimate(value), do: max(1, div(byte_size(to_string(value)) + 3, 4))

  defp structured_token_estimate(value) do
    value
    |> structured_bytes()
    |> Kernel.+(3)
    |> div(4)
    |> max(1)
  end

  defp structured_bytes(value) when is_binary(value), do: byte_size(value)
  defp structured_bytes(value) when is_atom(value), do: value |> Atom.to_string() |> byte_size()
  defp structured_bytes(value) when is_number(value), do: value |> to_string() |> byte_size()

  defp structured_bytes(value) when is_list(value) do
    Enum.reduce(value, 2, fn item, total -> total + structured_bytes(item) + 2 end)
  end

  defp structured_bytes(%_struct{} = value), do: value |> Map.from_struct() |> structured_bytes()

  defp structured_bytes(value) when is_map(value) do
    Enum.reduce(value, 2, fn {key, item}, total ->
      total + structured_bytes(key) + structured_bytes(item) + 2
    end)
  end

  defp structured_bytes(value), do: value |> inspect() |> byte_size()

  defp coverage(parts),
    do: if(Enum.any?(Map.values(parts), &is_nil/1), do: :partial, else: :complete)

  defp overflow_status(nil, _window, _reserve), do: :unknown
  defp overflow_status(_estimate, nil, _reserve), do: :unknown

  defp overflow_status(estimate, window, reserve) when estimate + reserve > window,
    do: :hard_overflow

  defp overflow_status(estimate, window, _reserve) when estimate >= window, do: :overflow
  defp overflow_status(_estimate, _window, _reserve), do: :within_budget

  defp model_context_window(model),
    do:
      model_value(model, :context_window) || model_value(model, :context_length) ||
        model_value(model, :max_context_tokens) || model_value(model, :input_token_limit)

  defp model_value(model, key) when is_map(model) do
    keys = [key, Atom.to_string(key), camelize(key)]
    Enum.find_value(keys, &positive(Map.get(model, &1)))
  end

  defp model_value(_, _), do: nil

  defp camelize(atom),
    do:
      atom
      |> Atom.to_string()
      |> String.split("_")
      |> then(fn [h | t] -> h <> Enum.map_join(t, "", &String.capitalize/1) end)

  defp positive(value) when is_integer(value) and value >= 0, do: value

  defp positive(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n >= 0 -> n
      _ -> nil
    end
  end

  defp positive(_), do: nil

  defp measurement_source(opts) do
    case get(opts, :last_measurement_source) do
      nil ->
        if(positive(get(opts, :last_request_input_tokens)), do: :provider_usage, else: :unknown)

      source ->
        source
    end
  end

  defp generated_at(opts) do
    case get(opts, :generated_at) do
      %DateTime{} = value -> DateTime.to_iso8601(value)
      value when is_binary(value) -> value
      _value -> DateTime.utc_now() |> DateTime.to_iso8601()
    end
  end

  defp next_revision(revision) when is_integer(revision) and revision >= 0, do: revision + 1
  defp next_revision(_revision), do: 1

  defp normalize_opts(opts) when is_map(opts), do: opts
  defp normalize_opts(opts), do: Map.new(opts)

  defp get(opts, key, default \\ nil),
    do: Map.get(opts, key, Map.get(opts, Atom.to_string(key), default))
end
