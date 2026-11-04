defmodule Sigma.Agent.BackplaneToolCatalogTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.Codex.MultiAgent
  alias Backplane.AgentRuntime.Codex
  alias Backplane.AgentRuntime.Codex.Session
  alias Sigma.Agent.Backplane.ToolCatalog

  defmodule ReadTool do
    def name, do: "read_fixture"
    def description, do: "Read a fixture"
    def schema, do: %{"type" => "object", "properties" => %{}}
    def metadata, do: %{effect: :read, concurrency: :shared}
  end

  defmodule UnsupportedTool do
    defdelegate name(), to: ReadTool
    defdelegate description(), to: ReadTool
    def schema, do: %{"$schema" => "https://example.test/unsupported"}
  end

  defmodule CatalogProvider do
    def stream(params) do
      send(params.options[:test_pid], {:provider_catalog, params.context})
      []
    end
  end

  test "provider uses the current runtime request catalog instead of a captured tool list" do
    tools = [
      %{name: "runtime_only", description: "Runtime tool", parameters: %{"type" => "object"}}
    ]

    host = %{
      model: %{id: "fixture", api: "fixture", provider: "fixture"},
      provider: CatalogProvider,
      provider_options: [test_pid: self()],
      session_id: "root",
      log_session_id: "root",
      build_context: fn _ -> %{messages: [], tools: [], system: []} end,
      context_error: fn _ -> nil end
    }

    request = %{
      run_id: "turn-1",
      attempt_id: "attempt-1",
      messages: [],
      tools: tools,
      catalog_revision: 7
    }

    owner = self()

    task =
      Task.async(fn ->
        Sigma.Agent.Backplane.Provider.stream(request, %{host: host, owner: owner})
        |> Enum.to_list()
      end)

    assert_receive {:backplane_request_started, worker, started_ref, _request, _context}, 5_000
    refute_receive {:provider_catalog, _}
    send(worker, {:backplane_request_ready, started_ref, :ok})
    assert_receive {:provider_catalog, context}, 5_000
    assert_receive {:backplane_provider_boundary, worker, ref, _}, 5_000
    send(worker, {:backplane_provider_continue, ref})
    Task.await(task, 5_000)
    assert context.tools == tools
    assert context.catalog_revision == 7
  end

  test "provider dispatch fails when its owner exits before acknowledging request start" do
    parent = self()

    owner =
      spawn(fn ->
        receive do
          {:backplane_request_started, _, _, _, _} ->
            send(parent, :owner_received_request_start)
            receive do: (:stop -> :ok)
        end
      end)

    host = %{
      model: %{id: "fixture", api: "fixture", provider: "fixture"},
      provider: CatalogProvider,
      provider_options: [test_pid: self()],
      session_id: "root",
      log_session_id: "root",
      build_context: fn _ -> %{messages: [], tools: [], system: []} end,
      context_error: fn _ -> nil end
    }

    request = %{
      run_id: "turn-1",
      attempt_id: "attempt-1",
      messages: [],
      tools: [],
      catalog_revision: 1
    }

    task =
      Task.async(fn ->
        Sigma.Agent.Backplane.Provider.stream(request, %{host: host, owner: owner})
        |> Enum.to_list()
      end)

    assert_receive :owner_received_request_start, 1_000
    send(owner, :stop)

    assert [%{type: :response_failed, error: %Sigma.Ai.ProviderError{}}] = Task.await(task, 1_000)
    refute_receive {:provider_catalog, _}
  end

  test "one admitted bundle defines both provider tools and executable authority" do
    authority = %{caller: "root", run_id: "turn-1", grants: [ReadTool.name()], tool_revision: 1}
    execute = fn operation -> {:ok, operation.arguments} end

    assert {:ok, bundle} = ToolCatalog.admit([ReadTool], authority, execute)
    assert bundle.authority == authority

    assert [%{name: "read_fixture", parameters: schema, description: "Read a fixture"}] =
             bundle.tools

    descriptor = bundle.registry.tools["read_fixture"]
    assert descriptor.schema == schema
    assert descriptor.safety.read_only

    assert descriptor.backend_context.execute.(%{arguments: %{"id" => 1}}) ==
             {:ok, %{"id" => 1}}
  end

  test "an empty built-in catalog admits no tools or executable grants" do
    authority = %{caller: "root", run_id: "turn-1", grants: [], tool_revision: 1}

    assert {:ok, bundle} =
             ToolCatalog.admit([], authority, fn _ -> flunk("no tool can execute") end)

    assert bundle.tools == []
    assert bundle.registry.tools == %{}
    assert bundle.authority.grants == []
    assert bundle.rejected == []
  end

  @tag :tmp_dir
  test "native profile composition preserves raw format, namespace, binding and exact grants", %{
    tmp_dir: workspace
  } do
    names = ["apply_patch", "clock::curr_time"]
    authority = %{caller: "root", run_id: "turn-native", grants: names, tool_revision: 1}
    session = start_supervised!({Session, owner_pid: self()})
    assert {:ok, binding} = Session.bind(session, authority)

    assert {:ok, profile} =
             Codex.profile(
               :pinned_local,
               %{workspace: workspace, session_binding: binding},
               authority,
               tools: names
             )

    combined_authority = %{authority | grants: [ReadTool.name() | names]}

    assert {:ok, bundle} =
             ToolCatalog.admit([ReadTool], combined_authority, fn _ -> :unused end,
               profiles: [profile]
             )

    assert MapSet.new(Map.keys(bundle.registry.tools)) == MapSet.new(combined_authority.grants)
    assert MapSet.new(Enum.map(bundle.tools, & &1.name)) == MapSet.new(combined_authority.grants)
    assert bundle.registry.tools["apply_patch"] == profile.registry.tools["apply_patch"]
    assert bundle.registry.tools["apply_patch"].backend_context.session_binding == binding

    assert %{type: "custom", format: %{"syntax" => "lark"}} =
             Enum.find(bundle.tools, &(&1.name == "apply_patch"))

    assert Enum.find(bundle.tools, &(&1.name == "clock::curr_time")).type == "function"

    assert {:error, %{class: :forbidden}} =
             ToolCatalog.admit(
               [ReadTool],
               %{combined_authority | grants: [ReadTool.name()]},
               fn _ -> flunk("admission must not dispatch") end,
               profiles: [profile]
             )

    assert {:error, %{class: :forbidden}} =
             ToolCatalog.admit(
               [ReadTool],
               %{combined_authority | run_id: "different-turn"},
               fn _ -> :unused end,
               profiles: [profile]
             )

    assert {:ok, %{status: :confirmed}} = Session.close(session)
  end

  test "malformed native profiles fail before dispatch" do
    authority = %{caller: "root", run_id: "turn-1", grants: [], tool_revision: 1}

    for profiles <- [nil, [%{}]] do
      assert {:error, %{class: :validation}} =
               ToolCatalog.admit([], authority, fn _ -> flunk("no dispatch") end,
                 profiles: profiles
               )
    end
  end

  test "actual V2 contracts join the same bundle without static Sigma tool modules" do
    {:ok, manager} =
      start_supervised(
        {MultiAgent,
         parent_run_id: "turn-1",
         parent_name: "root",
         parent_authority: %{},
         child_options: fn _, _, _ -> {:error, :not_enabled} end}
      )

    contracts = MultiAgent.contracts(:v2, manager)
    names = Enum.map(contracts, & &1.name)

    authority = %{
      caller: "root",
      run_id: "turn-1",
      grants: [ReadTool.name() | names],
      tool_revision: 1
    }

    assert {:ok, bundle} =
             ToolCatalog.admit([ReadTool], authority, fn _ -> :unused end, contracts: contracts)

    assert MapSet.new(Enum.map(bundle.tools, & &1.name)) == MapSet.new(authority.grants)
    assert MapSet.new(Map.keys(bundle.registry.tools)) == MapSet.new(authority.grants)

    assert bundle.registry.tools["spawn_agent"].schema ==
             Enum.find(bundle.tools, &(&1.name == "spawn_agent")).parameters
  end

  test "quarantine removes unsupported tools from provider definitions and grants together" do
    authority = %{caller: "root", run_id: "turn-1", grants: [ReadTool.name()], tool_revision: 1}

    assert {:ok, bundle} =
             ToolCatalog.admit([UnsupportedTool], authority, fn _ -> :unused end,
               mode: :quarantine
             )

    assert bundle.tools == []
    assert bundle.registry.tools == %{}
    assert bundle.authority.grants == []
    assert [%{name: "read_fixture"}] = bundle.rejected
  end

  test "strict admission rejects unsupported schemas and authority expansion" do
    authority = %{caller: "root", run_id: "turn-1", grants: [ReadTool.name()], tool_revision: 1}

    assert {:error, %{class: :unsupported_capability}} =
             ToolCatalog.admit([UnsupportedTool], authority, fn _ -> :unused end)

    assert {:error, %{class: :forbidden}} =
             ToolCatalog.admit([ReadTool], %{authority | grants: []}, fn _ -> :unused end)
  end
end
