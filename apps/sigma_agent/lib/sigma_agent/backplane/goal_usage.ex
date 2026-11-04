defmodule Sigma.Agent.Backplane.GoalUsage do
  @moduledoc "Pure projection of provider usage into the public Runtime Goal accounting contract."

  alias Sigma.Ai.ProviderUsage

  @unknown %{
    input_tokens: :unknown,
    cached_tokens: :unknown,
    output_tokens: :unknown,
    reasoning_tokens: :unknown
  }

  @doc "Returns cumulative metrics for one attempt, with unavailable charge remaining unknown."
  def normalize(%ProviderUsage{} = usage) do
    if consistent?(usage) do
      %{
        input_tokens: metric(usage.input_tokens),
        cached_tokens: metric(usage.cache_read_tokens),
        output_tokens: metric(usage.output_tokens),
        reasoning_tokens: metric(usage.reasoning_tokens)
      }
    else
      @unknown
    end
  end

  def normalize(_), do: @unknown

  @doc "Whether this snapshot reports a complete, consistent provider charge; not a run capability."
  def authoritative?(%ProviderUsage{} = usage) do
    usage.usage_status == :reported and
      match?(%{source: :provider, input_tokens: :included}, usage.provenance) and
      Enum.all?(
        [usage.input_tokens, usage.output_tokens, usage.cache_read_tokens],
        &(is_integer(&1) and &1 >= 0)
      ) and consistent?(usage)
  end

  def authoritative?(_), do: false

  @doc "Current adapters accept compatible hosts without a guaranteed cache-reporting contract."
  def capability(_provider) do
    %{
      usage_authoritative: false,
      accounting: :cumulative,
      reason: :cache_reporting_not_guaranteed
    }
  end

  defp consistent?(usage) do
    subset?(usage.cache_read_tokens, usage.input_tokens) and
      subset?(usage.reasoning_tokens, usage.output_tokens) and
      total_consistent?(usage)
  end

  defp total_consistent?(%{input_tokens: input, output_tokens: output, total_tokens: total})
       when is_integer(input) and is_integer(output) and is_integer(total),
       do: total == input + output

  defp total_consistent?(_), do: true

  defp subset?(subset, total) when is_integer(subset) and is_integer(total),
    do: subset >= 0 and total >= 0 and subset <= total

  defp subset?(_, _), do: true

  defp metric(value) when is_integer(value) and value >= 0, do: value
  defp metric(_), do: :unknown
end
