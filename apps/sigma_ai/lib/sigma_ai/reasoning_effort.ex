defmodule Sigma.Ai.ReasoningEffort do
  @moduledoc "Reasoning effort choices for providers that accept the reasoning_effort option."

  alias Sigma.Ai.Provider

  @default_levels ~w(low medium high)

  def levels(provider, model) do
    Code.ensure_loaded?(provider)
    supported = Provider.capabilities(provider, model).supported_options

    if :reasoning_effort in supported and Map.get(model, "reasoning", model[:reasoning]) != false do
      declared =
        model["reasoningEfforts"] || model[:reasoning_efforts] ||
          model["reasoning_efforts"] || model["efforts"]

      case declared do
        levels when is_list(levels) ->
          levels |> Enum.filter(&(is_binary(&1) and &1 != "")) |> Enum.uniq()

        _ ->
          @default_levels
      end
    else
      []
    end
  end

  def validate(provider, model, value) do
    levels = levels(provider, model)

    cond do
      levels == [] -> {:error, :reasoning_effort_unavailable}
      value in [nil, ""] -> {:ok, nil}
      value in levels -> {:ok, value}
      true -> {:error, :invalid_reasoning_effort}
    end
  end

  def options(provider, model, value, options) do
    case validate(provider, model, value) do
      {:ok, effort} when is_binary(effort) -> Keyword.put(options, :reasoning_effort, effort)
      _ -> Keyword.delete(options, :reasoning_effort)
    end
  end
end
