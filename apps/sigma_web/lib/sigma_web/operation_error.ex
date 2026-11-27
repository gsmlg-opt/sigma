defmodule Sigma.Web.OperationError do
  @moduledoc false

  alias Sigma.Agent.Terminals.Error

  @commit_timeout "Sigma timed out waiting for the session state to be saved. Check the last tool results before continuing."
  def turn_message(reason)
      when reason in [
             "commit acknowledgement timed out",
             "timeout: commit acknowledgement timed out"
           ],
      do: @commit_timeout

  # Older transcripts persisted the inspected Backplane error as the turn reason.
  def turn_message(
        "%Backplane.AgentRuntime.Error{class: :timeout, message: \"commit acknowledgement timed out\"" <>
          _
      ),
      do: @commit_timeout

  def turn_message(reason), do: reason

  @spec message(term()) :: String.t()
  def message(%Error{code: code}), do: terminal_message(code)

  def message({:operation_result_persistence_failed, {:ok, %{deleted: true}}, _reason}),
    do:
      "The session was deleted, but Sigma could not save the operation result. Refresh the session list."

  def message({:operation_result_persistence_failed, {:ok, _result}, _reason}),
    do:
      "The session operation was applied, but Sigma could not save its result. Refresh the session state before retrying."

  def message({:operation_result_persistence_failed, {:error, reason}, _persistence}),
    do: "Sigma could not save the failed operation result. " <> message(reason)

  def message({:session_operation_release_failed, {:ok, _result}, _reason}),
    do:
      "The session operation was applied, but Sigma could not release its operation state. Refresh the session state before retrying."

  def message({:session_operation_release_failed, {:error, reason}, _release}),
    do: "Sigma could not release the session operation state. " <> message(reason)

  def message(%Backplane.AgentRuntime.Error{class: :unknown_outcome, cause: cause}) do
    components =
      for {key, label} <- [
            native: "native tools",
            async_hooks: "async hooks",
            session_end: "SessionEnd"
          ],
          is_map(cause) and is_map_key(cause, key),
          not match?({:ok, %{status: :confirmed}}, cause[key]),
          do: label

    case components do
      [] ->
        "The session operation outcome is unconfirmed. Check the session state before retrying."

      components ->
        "Session cleanup could not be confirmed for #{Enum.join(components, ", ")}. Check the session state and retry the operation."
    end
  end

  def message(%Backplane.AgentRuntime.Error{class: :timeout}),
    do:
      "Sigma timed out waiting for session state or cleanup. Check the session state before retrying."

  def message(:host_retirement_unconfirmed),
    do:
      "Session cleanup could not be confirmed. Check the last tool results and retry after cleanup recovers."

  def message({:session_unavailable, _reason}),
    do: "The session runtime is unavailable. Reload the session before trying again."

  def message(:session_busy),
    do: "Wait for the active turn to finish before changing this session."

  def message(:invalid_session_id),
    do: "This session identifier is invalid. No files were changed."

  def message(_reason),
    do:
      "This session operation could not be completed. Refresh the session state before trying again."

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
    do:
      "This session operation could not be completed. Refresh the session state before trying again."
end
