defmodule Sigma.Agent.BackplaneChildNativeToolsTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.{Conversation, Error, Codex.MultiAgent}
  alias Sigma.Agent.Backplane.{CodexResources, NativeTools, ToolCatalog}

  @moduletag :tmp_dir

  test "published Runtime refuses a managed child Session for the root-owned manager", c do
    # Rejected startup may also deliver a linked EXIT after returning its error.
    Process.flag(:trap_exit, true)
    root_resources = resources!(c.tmp_dir, :root_resources)
    authority = authority("root", "root-run")

    manager =
      start_supervised!(
        {MultiAgent,
         parent_run_id: authority.run_id,
         parent_name: "/root",
         parent_authority: authority,
         child_options: fn _, _, _ -> {:ok, []} end}
      )

    contracts = MultiAgent.contracts(:v2, manager)
    {root_catalog, root_binding} = catalog!(root_resources, authority, contracts)

    root =
      start_supervised!(
        {Conversation,
         run_id: authority.run_id,
         registry: root_catalog.registry,
         tools: root_catalog.tools,
         authority: root_catalog.authority,
         session_binding: root_binding},
        id: :root_conversation
      )

    assert Backplane.AgentRuntime.Codex.Session.status(root_binding.session).phase == :active

    child_resources = resources!(c.tmp_dir, :child_resources)
    child_authority = authority("child", "child-run")
    {child_catalog, child_binding} = catalog!(child_resources, child_authority, contracts)

    try do
      # These are the same public options supplied by MultiAgent's child_options
      # callback; no private child PID or altered collaboration descriptor is used.
      assert {:error,
              %Error{class: :forbidden, message: "collaboration belongs to another session"}} =
               Conversation.start_link(
                 run_id: child_authority.run_id,
                 registry: child_catalog.registry,
                 tools: child_catalog.tools,
                 authority: child_catalog.authority,
                 session_binding: child_binding
               )

      assert Process.alive?(root)
    after
      # Both Sessions need the shared manager alive while confirming cleanup.
      # The supervisor otherwise stops the manager before root_resources.
      assert {:ok, %{status: :confirmed}} = CodexResources.close(child_resources)
      assert {:ok, %{status: :confirmed}} = CodexResources.close(root_resources)
    end
  end

  defp resources!(dir, id),
    do: start_supervised!({CodexResources, workspace: dir, owner_pid: self()}, id: id)

  defp authority(caller, run),
    do: %{
      caller: caller,
      run_id: run,
      grants: ["update_plan" | Sigma.Agent.Subagents.collaboration_tools()],
      tool_revision: 1
    }

  defp catalog!(resources, authority, contracts) do
    assert {:ok, binding} = CodexResources.bind(resources, authority)
    assert {:ok, context} = CodexResources.context(resources, binding)

    assert {:ok, profile} =
             NativeTools.profile(context, authority, %{hook_specs: []}, tools: ["update_plan"])

    assert {:ok, catalog} =
             ToolCatalog.admit([], authority, fn _ -> raise "unused" end,
               contracts: contracts,
               profiles: [profile]
             )

    {catalog, binding}
  end
end
