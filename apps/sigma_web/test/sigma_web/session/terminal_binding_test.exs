defmodule Sigma.Web.Session.TerminalBindingTest do
  use ExUnit.Case, async: true

  alias Sigma.Agent.Terminals.Identity
  alias Sigma.Web.Session.TerminalBinding

  test "attachment stays unsynchronized until its recovery boundary is rendered" do
    session = Identity.session("repo", "session", "incarnation")
    run = session |> Identity.terminal("terminal") |> Identity.run(3)

    attachment =
      TerminalBinding.attachment(
        %{
          run: run,
          attachment_id: "attachment",
          control_epoch: 4,
          controller: true,
          recovery_id: "recovery",
          recovery_boundary: 12,
          dimensions: {91, 37},
          resynced: false
        },
        "/workspace"
      )

    assert %{
             attachment_id: "attachment",
             recovery_id: "recovery",
             recovery_boundary: 12,
             dimensions: {91, 37},
             rendered_sequence: 0,
             resynced?: false
           } = attachment
  end

  test "same-sequence snapshot stays unsynchronized until its render callback" do
    run =
      Identity.session("repo", "session", "incarnation")
      |> Identity.terminal("terminal")
      |> Identity.run(1)

    attachment =
      TerminalBinding.attachment(
        %{
          run: run,
          attachment_id: "attachment",
          control_epoch: 1,
          controller: true,
          recovery_id: "recovery",
          recovery_boundary: 0,
          requires_render: true
        },
        "/workspace"
      )

    refute attachment.resynced?
  end
end
