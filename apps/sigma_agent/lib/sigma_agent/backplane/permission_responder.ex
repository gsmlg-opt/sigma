defmodule Sigma.Agent.Backplane.PermissionResponder do
  @moduledoc """
  Compatibility entry point for the owned native permission responder.

  The shared `InteractionResponder` retains the same permission callback and
  lifecycle. This wrapper preserves the existing child identity and public API.
  """

  alias Sigma.Agent.Backplane.InteractionResponder

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, restart: :temporary}
  end

  defdelegate start_link(opts), to: InteractionResponder
  defdelegate attach(pid, conversation), to: InteractionResponder
end
