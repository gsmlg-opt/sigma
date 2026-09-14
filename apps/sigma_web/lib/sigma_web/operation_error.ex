defmodule Sigma.Web.OperationError do
  @moduledoc false

  alias Sigma.Agent.Terminals.Error

  @spec message(term()) :: String.t()
  def message(%Error{code: code}), do: terminal_message(code)

  def message(:session_busy),
    do: "Wait for the active turn to finish before changing this session."

  def message(:invalid_session_id),
    do: "This session identifier is invalid. No files were changed."

  def message(_reason),
    do: "This session operation could not be completed. No files were changed."

  defp terminal_message(code)
       when code in [:cleanup_failed, :cleanup_timeout, :cleanup_unconfirmed],
       do:
         "Terminal cleanup could not be confirmed. The session was not changed; retry cleanup before trying again."

  defp terminal_message(code) when code in [:session_unavailable, :catalog_unavailable],
    do:
      "Terminal resource status is unavailable. The session was not changed; try again after it recovers."

  defp terminal_message(:session_draining),
    do:
      "Terminal resources are still active. Close or clean up terminals before changing this session."

  defp terminal_message(_code),
    do: "This session operation could not be completed. No files were changed."
end
