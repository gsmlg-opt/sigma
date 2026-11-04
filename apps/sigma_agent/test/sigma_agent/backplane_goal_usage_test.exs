defmodule Sigma.Agent.Backplane.GoalUsageTest do
  use ExUnit.Case, async: true

  alias Sigma.Agent.Backplane.GoalUsage
  alias Sigma.Ai.ProviderUsage
  alias Backplane.AgentRuntime.{GoalBridge, Usage}

  defmodule UsageProvider do
    def stream(params) do
      [
        {:done, :stop,
         %{
           role: :assistant,
           content: [],
           usage: %{
             input_tokens: 100,
             output: 12,
             cache_read: 80,
             provenance: %{source: :provider, input_tokens: :included}
           }
         }}
      ]
      |> then(fn events ->
        if params.options[:unknown],
          do: [{:done, :stop, %{role: :assistant, content: []}}],
          else: events
      end)
    end
  end

  test "real Provider boundary projects cache aliases and repeats terminal usage cumulatively" do
    for unknown <- [false, true] do
      host = %{
        model: %{id: "fixture", api: "fixture", provider: "fixture"},
        provider: UsageProvider,
        provider_options: [unknown: unknown],
        session_id: "root",
        log_session_id: "root",
        build_context: fn _ -> %{messages: [], system: []} end,
        context_error: fn _ -> nil end
      }

      request = %{
        run_id: "run",
        attempt_id: "attempt",
        messages: [],
        tools: [],
        catalog_revision: 1
      }

      owner = self()

      task =
        Task.async(fn ->
          Sigma.Agent.Backplane.Provider.stream(request, %{host: host, owner: owner})
          |> Enum.to_list()
        end)

      assert_receive {:backplane_request_started, worker, ref, _, _}, 5_000
      send(worker, {:backplane_request_ready, ref, :ok})
      assert_receive {:backplane_provider_boundary, worker, ref, _}, 5_000
      send(worker, {:backplane_provider_continue, ref})
      events = Task.await(task, 5_000)
      completed = Enum.find(events, &(&1.type == :response_completed))

      if unknown do
        assert completed.usage == GoalUsage.normalize(nil)
      else
        updated = Enum.find(events, &(&1.type == :usage_updated))
        assert updated.usage == completed.usage
        assert completed.usage.cached_tokens == 80
        assert completed.usage.input_tokens == 100
        refute Map.has_key?(completed.usage, :cache_read_tokens)
      end
    end
  end

  test "maps known canonical cache to public Runtime cached_tokens" do
    usage =
      ProviderUsage.normalize(%{
        input_tokens: 100,
        output_tokens: 12,
        cache_read_tokens: 80,
        reasoning_tokens: 9,
        provenance: %{source: :provider, input_tokens: :included}
      })

    assert GoalUsage.normalize(usage) == %{
             input_tokens: 100,
             cached_tokens: 80,
             output_tokens: 12,
             reasoning_tokens: 9
           }

    assert GoalUsage.authoritative?(usage)
  end

  test "input and output alone do not establish authoritative uncached charge" do
    usage = ProviderUsage.normalize(%{input_tokens: 100, output_tokens: 12})
    assert GoalUsage.normalize(usage).cached_tokens == :unknown
    refute GoalUsage.authoritative?(usage)
    refute GoalUsage.authoritative?(nil)
  end

  test "reported zero cache is authoritative only with explicit provider provenance" do
    base = %{input_tokens: 0, output_tokens: 0, cache_read_tokens: 0}
    refute GoalUsage.authoritative?(ProviderUsage.normalize(base))

    assert GoalUsage.authoritative?(
             ProviderUsage.normalize(
               Map.put(base, :provenance, %{source: :provider, input_tokens: :included})
             )
           )
  end

  test "inconsistent cache and reasoning subsets cannot become authoritative" do
    for fields <- [%{cache_read_tokens: 11}, %{reasoning_tokens: 11}, %{total_tokens: 21}] do
      usage =
        ProviderUsage.normalize(
          Map.merge(
            %{
              input_tokens: 10,
              output_tokens: 10,
              cache_read_tokens: 0,
              provenance: %{source: :provider, input_tokens: :included}
            },
            fields
          )
        )

      refute GoalUsage.authoritative?(usage)
      assert GoalUsage.normalize(usage).input_tokens == :unknown
    end
  end

  test "public GoalBridge handles cumulative terminal repeats without double charging" do
    identity = %{run_id: "run", incarnation: 1, attempt_id: "attempt", step_id: "step"}

    first =
      GoalUsage.normalize(
        ProviderUsage.normalize(%{input_tokens: 100, output_tokens: 2, cache_read_tokens: 80})
      )

    last = %{first | output_tokens: 12}
    {:ok, ledger} = Usage.new()
    assert {:ok, next, report} = GoalBridge.report(ledger, [first, last, last], identity)
    assert report.input_tokens == 100
    assert report.cached_tokens == 80
    assert report.output_tokens == 12
    assert {:ok, ^next, ^report} = GoalBridge.report(next, [first, last, last], identity)
    assert {:error, _} = GoalBridge.report(ledger, [last, first], identity)
  end

  test "unknown cumulative snapshots do not erase already reported metrics" do
    {:ok, ledger} = Usage.new()
    identity = %{run_id: "run", incarnation: 1, attempt_id: "attempt", step_id: "step"}

    assert {:ok, _, report} =
             GoalBridge.report(
               ledger,
               [
                 GoalUsage.normalize(
                   ProviderUsage.normalize(%{
                     input_tokens: 8,
                     output_tokens: 2,
                     cache_read_tokens: 0
                   })
                 ),
                 GoalUsage.normalize(nil)
               ],
               identity
             )

    assert report.input_tokens == 8
    assert report.output_tokens == 2
  end
end
