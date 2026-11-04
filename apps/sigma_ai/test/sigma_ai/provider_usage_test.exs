defmodule Sigma.Ai.ProviderUsageTest do
  use ExUnit.Case, async: true

  alias Sigma.Ai.ProviderUsage

  test "Responses plural details retain inclusive input, cached subset and reasoning" do
    wire = %{
      "input_tokens" => 100,
      "output_tokens" => 12,
      "input_tokens_details" => %{"cached_tokens" => 80},
      "output_tokens_details" => %{"reasoning_tokens" => 9}
    }

    extracted = ProviderUsage.from_wire(wire, :openai_responses)
    assert extracted.input == 20
    usage = ProviderUsage.normalize(extracted)
    assert usage.input_tokens == 100
    assert usage.cache_read_tokens == 80
    assert usage.output_tokens == 12
    assert usage.reasoning_tokens == 9
    assert usage.total_tokens == 112
  end

  test "Responses singular compatibility is accepted and plural fields take precedence" do
    base = %{
      "input_tokens" => 10,
      "output_tokens" => 2,
      "input_token_details" => %{"cached_tokens" => 3},
      "output_token_details" => %{"reasoning_tokens" => 1}
    }

    assert ProviderUsage.normalize(ProviderUsage.from_wire(base, :openai_responses)).cache_read_tokens ==
             3

    both = Map.put(base, "input_tokens_details", %{"cached_tokens" => 0})

    assert ProviderUsage.normalize(ProviderUsage.from_wire(both, :openai_responses)).cache_read_tokens ==
             0
  end

  test "Anthropic adds read and creation cache to inclusive Runtime input" do
    extracted =
      ProviderUsage.from_wire(
        %{
          "input_tokens" => 10,
          "output_tokens" => 4,
          "cache_read_input_tokens" => 80,
          "cache_creation_input_tokens" => 5
        },
        :anthropic
      )

    assert extracted.input == 10
    usage = ProviderUsage.normalize(extracted)
    assert usage.input_tokens == 95
    assert usage.cache_read_tokens == 80
    assert usage.cache_write_tokens == 5
    assert usage.total_tokens == 99
  end

  test "absent counters remain unknown while reported zero remains known" do
    for protocol <- [:openai_responses, :openai, :anthropic] do
      usage = ProviderUsage.normalize(ProviderUsage.from_wire(%{}, protocol))
      assert is_nil(usage.input_tokens)
      assert is_nil(usage.output_tokens)
      assert is_nil(usage.cache_read_tokens)
      assert is_nil(usage.total_tokens)
    end

    usage =
      ProviderUsage.normalize(
        ProviderUsage.from_wire(
          %{
            "input_tokens" => 0,
            "output_tokens" => 0,
            "input_tokens_details" => %{"cached_tokens" => 0}
          },
          :openai_responses
        )
      )

    assert usage.input_tokens == 0
    assert usage.cache_read_tokens == 0
    assert usage.output_tokens == 0
  end

  test "Chat Completions cached prompt detail is an inclusive subset" do
    usage =
      ProviderUsage.from_wire(
        %{
          "prompt_tokens" => 30,
          "completion_tokens" => 4,
          "prompt_tokens_details" => %{"cached_tokens" => 20},
          "completion_tokens_details" => %{"reasoning_tokens" => 3}
        },
        :openai
      )
      |> ProviderUsage.normalize()

    assert usage.input_tokens == 30
    assert usage.cache_read_tokens == 20
    assert usage.reasoning_tokens == 3
  end

  test "normalization rejects malformed counters without inventing nonnegative values" do
    for invalid <- [-1, 1.2, "12", false] do
      usage = ProviderUsage.normalize(%{input_tokens: invalid, output_tokens: 2})
      assert is_nil(usage.input_tokens)
      refute ProviderUsage.complete?(usage)
    end
  end
end
