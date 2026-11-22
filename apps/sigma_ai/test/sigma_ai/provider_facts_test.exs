defmodule Sigma.Ai.ProviderFactsTest do
  use ExUnit.Case, async: true

  alias Sigma.Ai.{Provider, ProviderEvent, ProviderRequest, ProviderUsage}

  test "normalizes complete provider usage and preserves cache as a subdivision" do
    usage =
      ProviderUsage.normalize(%{
        "prompt_tokens" => 40_000,
        "completion_tokens" => 1_000,
        "input_token_details" => %{"cached_tokens" => 30_000},
        "total_tokens" => 41_000,
        "usage_revision" => 2,
        "source" => :provider
      })

    assert usage.input_tokens == 40_000
    assert usage.output_tokens == 1_000
    assert usage.cache_read_tokens == 30_000
    assert usage.total_tokens == 41_000
    assert usage.usage_status == :reported
    assert usage.usage_revision == 2
    assert usage.provenance == %{source: :provider}
    assert ProviderUsage.complete?(usage)
    assert ProviderUsage.to_fact(usage).input_tokens_total == 40_000
  end

  test "marks partial and unknown usage without inventing zero counters" do
    partial = ProviderUsage.normalize(%{output_tokens: 4})
    assert partial.output_tokens == 4
    assert is_nil(partial.input_tokens)
    assert partial.usage_status == :derived
    refute ProviderUsage.complete?(partial)

    unknown = ProviderUsage.normalize(%{})
    assert unknown.usage_status == :unknown
    assert is_nil(unknown.input_tokens)
    assert is_nil(unknown.output_tokens)
  end

  test "request timing uses monotonic boundaries and never goes negative" do
    request = ProviderRequest.new(%{model: %{id: "m"}, context: %{messages: []}})
    assert request.request_id =~ ~r/^req_[A-Za-z0-9_-]+$/

    refute request.request_id ==
             ProviderRequest.new(%{model: %{id: "m"}, context: %{messages: []}}).request_id

    request = ProviderRequest.begin(request, 1_000, ~U[2026-09-09 00:00:00Z])
    request = ProviderRequest.mark_output(request, 1_025, :thinking)
    request = ProviderRequest.mark_output(request, 1_040, :text)
    assert request.first_output_ms == 25
    assert request.ttft_ms == 40

    finished = ProviderRequest.finish(request, :completed, 990, ~U[2026-09-09 00:00:01Z])
    assert finished.elapsed_ms == 0
    assert finished.status == :completed
  end

  test "tool-only output has first output but no TTFT" do
    request =
      ProviderRequest.new(%{model: %{id: "m"}, context: %{messages: []}})
      |> ProviderRequest.begin(100)
      |> ProviderRequest.mark_output(130, :tool_arguments)

    assert request.first_output_ms == 30
    assert is_nil(request.ttft_ms)
  end

  test "drops transport metadata, credentials, and raw payloads from usage provenance" do
    secret = "sk-private-token"

    usage =
      ProviderUsage.normalize(%{
        input: 3,
        output: 2,
        provenance: %{
          source: :provider,
          input_tokens: :input_tokens,
          headers: %{"authorization" => "Bearer #{secret}"},
          api_key: secret,
          raw_payload: %{"prompt" => secret},
          adapter: secret
        }
      })

    assert usage.provenance == %{source: :provider, input_tokens: :input_tokens}

    encoded = usage |> ProviderUsage.to_fact() |> Formata.JSON.encode!()
    refute encoded =~ secret
    refute encoded =~ "authorization"
    refute encoded =~ "headers"
    refute encoded =~ "raw_payload"
    refute encoded =~ "api_key"
  end

  test "usage-only terminal preserves reported counters" do
    message = %{
      role: :assistant,
      content: [],
      usage: %{input: 8, output: 1, total_tokens: 9, source: :provider}
    }

    assert [
             %ProviderEvent{
               type: :usage_updated,
               usage: %ProviderUsage{input_tokens: 8, output_tokens: 1}
             },
             %ProviderEvent{type: :response_completed}
           ] = Provider.normalize_legacy_event({:done, :stop, message})
  end

  test "keepalive and empty events do not start first-output timing" do
    request =
      ProviderRequest.new(%{model: %{id: "m"}, context: %{messages: []}})
      |> ProviderRequest.begin(100)
      |> ProviderRequest.mark_output(120, :keepalive)
      |> ProviderRequest.mark_output(130, :empty)

    assert is_nil(request.first_output_ms)
    assert is_nil(request.ttft_ms)
  end

  test "late usage correction does not revive a cancelled request" do
    request =
      ProviderRequest.new(%{model: %{id: "m"}, context: %{messages: []}})
      |> ProviderRequest.begin(100)
      |> ProviderRequest.finish(:cancelled, 150)

    corrected =
      ProviderRequest.put_usage(
        request,
        ProviderUsage.normalize(%{input: 10, output: 2, usage_revision: 2})
      )

    assert corrected.status == :cancelled
    assert corrected.elapsed_ms == 50
    assert corrected.usage_revision == 2
    assert corrected.usage.output_tokens == 2

    stale = ProviderUsage.normalize(%{input: 10, output: 1, usage_revision: 1})
    assert ProviderRequest.put_usage(corrected, stale) == corrected
  end

  test "visible transport retry receives a distinct request identity and relation" do
    params = %{model: %{id: "m"}, context: %{messages: []}, turn_id: "turn-1"}
    first = ProviderRequest.new(params)
    retried = ProviderRequest.new(Map.put(params, :retry_of, first.request_id))

    refute retried.request_id == first.request_id
    assert retried.retry_of == first.request_id
    assert retried.turn_id == first.turn_id
  end
end
