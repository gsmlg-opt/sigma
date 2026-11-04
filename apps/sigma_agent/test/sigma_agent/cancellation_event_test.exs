defmodule Sigma.Agent.CancellationEventTest do
  use ExUnit.Case, async: true
  alias Sigma.Agent.ProtocolEventMapper
  alias Sigma.Protocol.Codec

  test "delayed upstream result retains cancelled child identity without changing active root turn" do
    scope = %{turn_id: "child-old-run", target: "/root/child"}

    for outcome <- [:pending, :confirmed, :already_terminal, :failed, :unsupported, :unknown] do
      {event, active} =
        ProtocolEventMapper.map(
          {:upstream_cancel_status, scope, %{outcome: outcome, status: "completed"}},
          "session",
          "new-root-turn"
        )

      assert active == "new-root-turn"
      assert event.type == "provider.cancellation"
      assert event.turn_id == "child-old-run"
      assert event.payload["outcome"] == Atom.to_string(outcome)
      assert {:ok, encoded} = Codec.encode(event)
      assert {:ok, decoded} = Codec.decode(encoded)
      assert decoded.payload == event.payload
    end
  end

  test "local turn cancellation never asserts upstream completion" do
    {event, "turn"} = ProtocolEventMapper.map({:turn_cancelled}, "session", "turn")
    assert event.payload == %{"scope" => "local"}
    assert event.type == "turn.cancelled"
  end
end
