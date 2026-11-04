defmodule Sigma.Web.UpstreamCancelFeedbackTest do
  use ExUnit.Case, async: true
  alias Sigma.Web.SessionLive

  test "late child cancellation feedback does not stop the active root turn" do
    socket = %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        flash: %{},
        runtime_status: :running,
        turn_in_flight: true,
        streaming_message_id: "new-root-message"
      }
    }

    for {result, expected} <- [
          {%{outcome: :pending}, "waiting for upstream confirmation"},
          {%{outcome: :confirmed}, "upstream confirmed cancellation"},
          {%{outcome: :already_terminal, status: "completed"}, "already completed"},
          {%{outcome: :unknown, reason: :missing_checkpoint}, "unconfirmed"},
          {%{outcome: :failed}, "unconfirmed"},
          {%{outcome: :unsupported}, "Generation may continue"}
        ] do
      assert {:noreply, updated} =
               SessionLive.handle_info(
                 {:upstream_cancel_status, %{target: "/root/child", turn_id: "old-run"}, result},
                 socket
               )

      assert updated.assigns.flash["info"] =~ "/root/child"
      assert updated.assigns.flash["info"] =~ expected
      assert updated.assigns.runtime_status == :running
      assert updated.assigns.turn_in_flight
      assert updated.assigns.streaming_message_id == "new-root-message"
    end
  end
end
