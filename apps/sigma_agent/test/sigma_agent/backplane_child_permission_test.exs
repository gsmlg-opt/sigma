defmodule Sigma.Agent.BackplaneChildPermissionTest do
  use ExUnit.Case, async: true

  alias Sigma.Agent.Backplane.ChildPermission

  test "allow, deny and checked map edits round trip through strict JSON envelopes" do
    for {reply, expected} <- [
          {:allow, :allow},
          {{:allow, %{"plan" => [%{"step" => "Edited", "status" => "pending"}]}},
           {:allow, %{"plan" => [%{"step" => "Edited", "status" => "pending"}]}}},
          {{:deny, :denied_once}, {:deny, "denied_once"}}
        ] do
      assert {:ok, envelope} = ChildPermission.encode(reply)
      wire = envelope |> Jason.encode!() |> Jason.decode!()
      assert wire["kind"] == "sigma_tool_permission_reply"
      assert {:ok, ^expected} = ChildPermission.decode(wire)
    end
  end

  test "malformed or non JSON edits and cross-channel replies are rejected" do
    for reply <- [
          :approved,
          :denied,
          {:ok, "allow"},
          {:allow, "raw replacement"},
          {:allow, %{owner: self()}},
          {:allow, %{"callback" => fn -> :allow end}}
        ] do
      assert {:error, _} = ChildPermission.encode(reply)
    end

    for wire <- [
          %{"decision" => "allow"},
          %{"kind" => "sigma_tool_permission_reply", "decision" => "approved"},
          %{"kind" => "permission", "decision" => "allow"},
          %{"kind" => "sigma_tool_permission_reply", "decision" => "allow", "extra" => true},
          %{"kind" => "sigma_tool_permission_reply", "decision" => "deny"},
          %{
            "kind" => "sigma_tool_permission_reply",
            "decision" => "allow",
            "arguments_patch" => "raw"
          },
          %{
            "kind" => "sigma_tool_permission_reply",
            "decision" => "allow",
            "arguments_patch" => %{"pid" => self()}
          },
          :allow,
          :approved,
          {:allow, %{}}
        ] do
      assert {:error, _} = ChildPermission.decode(wire)
    end
  end

  test "the complete reply must fit the public JSON boundary" do
    reason = String.duplicate("x", 262_145)
    patch = %{"edited" => String.duplicate("x", 262_120)}
    assert {:ok, ^patch} = Backplane.AgentRuntime.Conversation.public_interaction(patch)

    for {decision, envelope} <- [
          {{:deny, reason},
           %{"kind" => "sigma_tool_permission_reply", "decision" => "deny", "reason" => reason}},
          {{:allow, patch},
           %{
             "kind" => "sigma_tool_permission_reply",
             "decision" => "allow",
             "arguments_patch" => patch
           }}
        ] do
      assert {:error, _} = Backplane.AgentRuntime.Conversation.public_interaction(envelope)
      assert {:error, _} = ChildPermission.encode(decision)
      assert {:error, _} = ChildPermission.decode(envelope)
    end
  end
end
