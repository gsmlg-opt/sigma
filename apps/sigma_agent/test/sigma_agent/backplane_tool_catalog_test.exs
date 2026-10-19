defmodule Sigma.Agent.BackplaneToolCatalogTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.Codex.MultiAgent
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

    assert_receive {:provider_catalog, context}, 5_000
    assert_receive {:backplane_provider_boundary, worker, ref, _}, 5_000
    send(worker, {:backplane_provider_continue, ref})
    Task.await(task, 5_000)
    assert context.tools == tools
    assert context.catalog_revision == 7
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

  test "the current application tool set passes strict admission without changing its names" do
    tools = Sigma.Tools.default_tools()
    names = Enum.map(tools, &Sigma.Coding.Tool.name/1)
    authority = %{caller: "root", run_id: "turn-1", grants: names, tool_revision: 1}

    assert {:ok, bundle} = ToolCatalog.admit(tools, authority, fn _ -> :unused end)
    assert MapSet.new(Enum.map(bundle.tools, & &1.name)) == MapSet.new(names)
    assert bundle.authority.grants == names
    assert bundle.rejected == []
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
