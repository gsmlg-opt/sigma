defmodule Sigma.Agent.SkillInvocationTest do
  use ExUnit.Case, async: true

  alias Sigma.Agent.{SkillInvocation, SkillInvocationService}

  defmodule CompletingProvider do
    @behaviour Sigma.Ai.Provider

    @impl true
    def stream(_params) do
      started = message(nil)
      completed = message(:stop)
      [{:start, started}, {:done, :stop, completed}]
    end

    defp message(stop_reason) do
      %{
        role: :assistant,
        content: [%{type: :text, text: "done"}],
        model: "mock-model",
        provider: "mock-provider",
        api: "mock-api",
        usage: %{input: 1, output: 1, total_tokens: 2},
        stop_reason: stop_reason,
        timestamp: System.system_time(:millisecond)
      }
    end
  end

  defmodule BlockingProvider do
    @behaviour Sigma.Ai.Provider

    @impl true
    def stream(params) do
      send(params.options[:test_pid], {:provider_waiting, self()})

      receive do
        :release_provider -> CompletingProvider.stream(params)
      end
    end
  end

  defmodule RaisingProvider do
    @behaviour Sigma.Ai.Provider

    @impl true
    def stream(_params), do: raise("provider failed")
  end

  defmodule CountingProvider do
    @behaviour Sigma.Ai.Provider

    @impl true
    def stream(params) do
      send(params.options[:test_pid], :provider_called)
      CompletingProvider.stream(params)
    end
  end

  defmodule ResourceProvider do
    @behaviour Sigma.Ai.Provider

    @impl true
    def stream(_params) do
      step = Process.get({__MODULE__, :step}, 0)
      Process.put({__MODULE__, :step}, step + 1)

      case step do
        0 -> tool_response("register_resource")
        1 -> tool_response("capture_roots")
        _ -> CompletingProvider.stream(%{})
      end
    end

    defp tool_response(name) do
      msg = %{
        role: :assistant,
        content: [%{type: :tool_call, id: "call-#{name}", name: name, arguments: %{}}],
        model: "mock-model",
        provider: "mock-provider",
        api: "mock-api",
        usage: %{input: 1, output: 1, total_tokens: 2},
        stop_reason: :tool_use,
        timestamp: System.system_time(:millisecond)
      }

      [{:start, msg}, {:done, :tool_use, msg}]
    end
  end

  defmodule RegisterResourceTool do
    @behaviour Sigma.Coding.Tool

    def name, do: "register_resource"
    def description, do: "Registers a prepared resource."
    def schema, do: %{"type" => "object", "properties" => %{}}

    def execute(_id, _params, opts) do
      owner = Keyword.fetch!(opts, :test_pid)

      resource = %{
        root: "/prepared/model",
        release: fn -> send(owner, {:resource_released, "model"}) end
      }

      :ok = Keyword.fetch!(opts, :register_skill_resource).(resource)
      {:ok, %{content: [%{type: :text, text: "registered"}]}}
    end
  end

  defmodule CaptureRootsTool do
    @behaviour Sigma.Coding.Tool

    def name, do: "capture_roots"
    def description, do: "Captures prepared roots."
    def schema, do: %{"type" => "object", "properties" => %{}}

    def execute(_id, _params, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:skill_roots, Keyword.fetch!(opts, :skill_roots)})
      {:ok, %{content: [%{type: :text, text: "captured"}]}}
    end
  end

  @request %{
    "repositoryId" => "repo-1",
    "sessionId" => "session-1",
    "reference" => "global:review",
    "arguments" => "inspect"
  }

  test "validates and fingerprints equivalent requests deterministically" do
    assert {:ok, first} = SkillInvocation.new(@request)
    assert {:ok, second} = SkillInvocation.new(@request)
    assert first.fingerprint == second.fingerprint
    assert first.state == :preparing
    assert is_binary(first.request_id)
  end

  test "requires exactly one skill reference" do
    assert {:error, :invalid_skill_reference} =
             SkillInvocation.new(Map.put(@request, "skillId", "skill-1"))

    assert {:error, :invalid_skill_reference} =
             SkillInvocation.new(Map.delete(@request, "reference"))
  end

  test "enforces invocation state transitions" do
    assert {:ok, invocation} = SkillInvocation.new(@request)
    assert {:ok, queued} = SkillInvocation.transition(invocation, :queued)
    assert {:ok, running} = SkillInvocation.transition(queued, :running)
    assert {:ok, completed} = SkillInvocation.transition(running, :completed)
    assert SkillInvocation.terminal?(completed)
    assert {:error, :invalid_state_transition} = SkillInvocation.transition(completed, :running)
  end

  test "rejected prompt releases prepared resources before provider admission" do
    agent = start_agent(CompletingProvider)
    resource = resource_probe("rejected")

    assert {:rejected, :empty_prompt} =
             Sigma.Agent.prompt(agent, "", prepared_resources: [resource])

    assert_receive {:resource_released, "rejected"}
    refute_receive {:provider_waiting, _}, 50
  end

  test "queued preparation is retained until its owning turn finishes" do
    agent = start_agent(BlockingProvider)
    Sigma.Agent.subscribe(agent)

    assert {:accepted, _info} = Sigma.Agent.prompt(agent, "first")
    assert_receive {:provider_waiting, first_provider}

    resource = resource_probe("queued")

    assert {:queued_as_follow_up, _info} =
             Sigma.Agent.follow_up(agent, "second", prepared_resources: [resource])

    refute_receive {:resource_released, "queued"}, 50
    send(first_provider, :release_provider)
    assert_receive {:provider_waiting, second_provider}
    refute_receive {:resource_released, "queued"}, 50

    send(second_provider, :release_provider)
    assert_receive {:resource_released, "queued"}
  end

  test "cancelling a queued prompt releases only its preparation" do
    agent = start_agent(BlockingProvider)

    assert {:accepted, _info} = Sigma.Agent.prompt(agent, "first")
    assert_receive {:provider_waiting, first_provider}

    resource = resource_probe("queued-cancel")

    assert {:queued_as_follow_up, %{turn_id: turn_id}} =
             Sigma.Agent.follow_up(agent, "second", prepared_resources: [resource])

    assert :ok = Sigma.Agent.cancel_prompt(agent, turn_id)
    assert_receive {:resource_released, "queued-cancel"}

    send(first_provider, :release_provider)
    refute_receive {:provider_waiting, _second_provider}, 100
  end

  @tag timeout: 5_000
  test "force cancellation releases outer-owned preparation" do
    agent = start_agent(BlockingProvider)
    resource = resource_probe("cancelled")

    assert {:accepted, _info} =
             Sigma.Agent.prompt(agent, "block", prepared_resources: [resource])

    assert_receive {:provider_waiting, _provider}
    assert {:cancelling, _turn_id} = Sigma.Agent.cancel(agent)
    assert_receive {:resource_released, "cancelled"}, 3_000
  end

  test "task DOWN releases outer-owned preparation" do
    agent = start_agent(RaisingProvider)
    resource = resource_probe("down")

    assert {:accepted, _info} =
             Sigma.Agent.prompt(agent, "fail", prepared_resources: [resource])

    assert_receive {:resource_released, "down"}
  end

  test "prompt and model-activated roots merge and release after tool completion" do
    {:ok, agent} =
      Sigma.Agent.start_link(
        model: %{id: "mock-model", api: "mock-api", provider: "mock-provider"},
        provider: ResourceProvider,
        tools: [RegisterResourceTool, CaptureRootsTool],
        dispatcher_opts: [test_pid: self()],
        execution_engine: :sigma
      )

    Sigma.Agent.subscribe(agent)
    prompt_resource = resource_probe("prompt") |> Map.put(:root, "/prepared/prompt")

    assert {:accepted, _info} =
             Sigma.Agent.prompt(agent, "activate", prepared_resources: [prompt_resource])

    assert_receive {:skill_roots, roots}
    assert Enum.sort(roots) == ["/prepared/model", "/prepared/prompt"]
    assert_receive {:resource_released, "prompt"}
    assert_receive {:resource_released, "model"}
    assert_receive {:agent_end, _messages}
  end

  test "late cancelled preparation cannot admit a provider turn" do
    agent = start_agent(CountingProvider)
    {store, context} = invocation_context(agent)
    owner = self()

    context =
      Map.put(context, :skill_expander, fn _command, _opts ->
        send(owner, {:preparation_waiting, self()})

        receive do
          :finish_preparation ->
            {:ok,
             %{
               content: "prepared bytes",
               skill: %{ref: %{source_id: "repo", skill_id: "skill"}, digest: "sha256:exact"},
               prepared_resources: [resource_probe("late", owner)]
             }}
        end
      end)

    invoke =
      Task.async(fn ->
        SkillInvocationService.invoke(invocation_payload("late-key"), context)
      end)

    assert_receive {:preparation_waiting, preparation}
    record = Elixir.Agent.get(store, &List.first/1)

    assert {:ok, %{payload: %{"state" => "cancelled"}}} =
             SkillInvocationService.cancel(
               %{"sessionId" => "session-1", "invocationId" => record["invocationId"]},
               context
             )

    send(preparation, :finish_preparation)
    assert {:error, :cancelled} = Task.await(invoke)
    assert_receive {:resource_released, "late"}
    refute_receive :provider_called, 100
    assert %{"state" => "cancelled"} = Elixir.Agent.get(store, &List.first/1)
  end

  test "store failure after preparation releases before provider admission" do
    agent = start_agent(CountingProvider)
    {_store, context} = invocation_context(agent)
    owner = self()
    {:ok, lookups} = Elixir.Agent.start_link(fn -> 0 end)

    store =
      Map.put(context.skill_invocation_store, :find, fn _session_id, _request_key ->
        case Elixir.Agent.get_and_update(lookups, &{&1, &1 + 1}) do
          0 -> {:ok, nil}
          _later -> {:error, :store_unavailable}
        end
      end)

    context =
      context
      |> Map.put(:skill_invocation_store, store)
      |> Map.put(:skill_expander, fn _command, _opts ->
        {:ok,
         %{
           content: "prepared bytes",
           skill: %{ref: %{source_id: "repo", skill_id: "skill"}, digest: "sha256:exact"},
           prepared_resources: [resource_probe("store-error", owner)]
         }}
      end)

    assert {:error, :store_unavailable} =
             SkillInvocationService.invoke(invocation_payload("store-error-key"), context)

    assert_receive {:resource_released, "store-error"}
    refute_receive {:resource_released, "store-error"}, 50
    refute_receive :provider_called, 100
  end

  test "invalid prepared expansion releases before Agent admission" do
    agent = start_agent(CountingProvider)
    {_store, context} = invocation_context(agent)
    owner = self()

    context =
      Map.put(context, :skill_expander, fn _command, _opts ->
        {:ok, %{prepared_resources: [resource_probe("invalid-expansion", owner)]}}
      end)

    assert {:error, :invalid_prepared_prompt} =
             SkillInvocationService.invoke(invocation_payload("invalid-expansion-key"), context)

    assert_receive {:resource_released, "invalid-expansion"}
    refute_receive {:resource_released, "invalid-expansion"}, 50
    refute_receive :provider_called, 100
  end

  test "API admission records the exact prepared bytes digest and ref" do
    agent = start_agent(CountingProvider)
    {_store, context} = invocation_context(agent)
    owner = self()
    exact_ref = %{source_id: "repo-source", skill_id: "review", revision: "r1"}

    context =
      Map.put(context, :skill_expander, fn _command, _opts ->
        {:ok,
         %{
           content: "exact prepared bytes",
           skill: %{ref: exact_ref, digest: "sha256:exact-digest"},
           prepared_resources: [resource_probe("api", owner)]
         }}
      end)

    assert {:ok, %{payload: payload}} =
             SkillInvocationService.invoke(invocation_payload("api-key"), context)

    assert payload["artifactDigest"] == "sha256:exact-digest"

    assert payload["resolvedRef"] == %{
             "source_id" => "repo-source",
             "skill_id" => "review",
             "revision" => "r1"
           }

    assert_receive :provider_called
    assert_receive {:resource_released, "api"}
  end

  test "manual-only and disabled rejections record failure without provider calls" do
    agent = start_agent(CountingProvider)
    {store, context} = invocation_context(agent)
    owner = self()

    context =
      Map.put(context, :skill_expander, fn command, _opts ->
        send(owner, {:expansion_attempt, command})

        if String.contains?(command, "manual"),
          do: {:error, :manual_invocation_required},
          else: {:error, :skill_disabled}
      end)

    assert {:error, :manual_invocation_required} =
             SkillInvocationService.invoke(
               invocation_payload("manual-key", "repo:manual"),
               context
             )

    assert {:error, :skill_disabled} =
             SkillInvocationService.invoke(
               invocation_payload("disabled-key", "repo:disabled"),
               context
             )

    refute_receive :provider_called, 100
    assert_receive {:expansion_attempt, _manual}
    assert_receive {:expansion_attempt, _disabled}

    errors = Elixir.Agent.get(store, &Enum.map(&1, fn record -> record["error"] end))
    assert Enum.sort(errors) == ["manual_invocation_required", "skill_disabled"]
  end

  defp start_agent(provider) do
    {:ok, agent} =
      Sigma.Agent.start_link(
        model: %{id: "mock-model", api: "mock-api", provider: "mock-provider"},
        provider: provider,
        options: [test_pid: self()],
        execution_engine: :sigma
      )

    agent
  end

  defp resource_probe(id), do: resource_probe(id, self())

  defp resource_probe(id, owner) do
    %{
      root: Path.join(System.tmp_dir!(), "sigma-skill-probe-#{id}"),
      digest: "sha256:probe",
      ref: %{skill_id: id},
      release: fn -> send(owner, {:resource_released, id}) end
    }
  end

  defp invocation_payload(request_key, reference \\ "repo:skill") do
    %{
      "requestKey" => request_key,
      "repositoryId" => "repo-1",
      "sessionId" => "session-1",
      "reference" => reference,
      "arguments" => ""
    }
  end

  defp invocation_context(agent) do
    {:ok, store} = Elixir.Agent.start_link(fn -> [] end)

    callbacks = %{
      find: fn _session_id, request_key ->
        {:ok,
         Elixir.Agent.get(store, &Enum.find(&1, fn item -> item["requestKey"] == request_key end))}
      end,
      list: fn _session_id -> {:ok, Elixir.Agent.get(store, & &1)} end,
      reserve: fn _session_id, record ->
        Elixir.Agent.update(store, &[record | &1])
        {:ok, record}
      end,
      update: fn _session_id, invocation_id, changes ->
        Elixir.Agent.get_and_update(store, fn records ->
          updated =
            Enum.map(records, fn record ->
              if record["invocationId"] == invocation_id,
                do: Map.merge(record, changes),
                else: record
            end)

          {{:ok, Enum.find(updated, &(&1["invocationId"] == invocation_id))}, updated}
        end)
      end
    }

    context = %{
      repo_path: "/repo",
      session_id: "session-1",
      agent_lookup: fn "session-1" -> agent end,
      skill_invocation_store: callbacks
    }

    {store, context}
  end
end
