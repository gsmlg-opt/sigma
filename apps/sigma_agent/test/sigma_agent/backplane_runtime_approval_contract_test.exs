defmodule Sigma.Agent.BackplaneRuntimeApprovalContractTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.{Approval, Error}

  # Resolver identity validation is not authentication. These exercise Runtime's
  # public field-binding checks; the embedding host authenticates its own UI.
  test "published approval rejects absent, blank, nonbinary and self resolver identities" do
    {approval, decision} = approval(plan("A"))
    assert {:ok, :approved} = Approval.decide(approval, decision)

    for resolver <- [nil, "", "  ", 42, approval.run_id] do
      assert {:error, %Error{class: class}} =
               Approval.decide(approval, Map.put(decision, :resolver_id, resolver))

      assert class in [:validation, :forbidden]
    end

    assert {:error, %Error{class: :validation}} =
             Approval.decide(approval, Map.delete(decision, :resolver_id))
  end

  test "approval identity, tool revision, digest and binding remain inseparable" do
    {approval, decision} = approval(plan("A"))

    for {key, value} <- [
          approval_id: "another-approval",
          tool_name: "apply_patch",
          tool_revision: 2,
          arguments_digest: digest(plan("B")),
          collaboration_binding: %{fingerprint: "another-binding"}
        ] do
      assert {:error, %Error{class: :forbidden}} =
               Approval.decide(approval, Map.put(decision, key, value))
    end

    assert {:ok, :denied} = Approval.decide(approval, %{decision | decision: :denied})
  end

  test "prepared replacement input requires a freshly bound approval decision" do
    {old, old_decision} = approval(plan("A"))
    {final, final_decision} = approval(plan("B"))
    refute old.arguments_digest == final.arguments_digest
    assert {:error, %Error{class: :forbidden}} = Approval.decide(final, old_decision)
    assert {:ok, :approved} = Approval.decide(final, final_decision)
  end

  defp approval(arguments) do
    approval = %{
      approval_id: "approval-1",
      run_id: "approval-run",
      tool_name: "update_plan",
      tool_revision: 1,
      arguments_digest: digest(arguments),
      collaboration_binding: %{fingerprint: "binding-1"},
      current_time: 100,
      expires_at: 200
    }

    decision =
      approval
      |> Map.take([
        :approval_id,
        :tool_name,
        :tool_revision,
        :arguments_digest,
        :collaboration_binding
      ])
      |> Map.merge(%{decision: :approved, resolver_id: "authenticated-host"})

    {approval, decision}
  end

  defp digest(arguments),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(arguments)) |> Base.encode16(case: :lower)

  defp plan(step), do: %{"plan" => [%{"step" => step, "status" => "completed"}]}
end
