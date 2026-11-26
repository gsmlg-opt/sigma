defmodule Sigma.Ai.ProviderErrorTest do
  use ExUnit.Case, async: true

  alias Backplane.AiProtocol.Error
  alias Sigma.Ai.ProviderError

  test "finalized invalid tool arguments use the typed stream retry contract" do
    error = invalid_tool_arguments()

    assert %ProviderError{
             kind: :malformed_stream,
             message: "Anthropic tool arguments are not complete JSON",
             code: "invalid_tool_arguments",
             retryable: true,
             retry_class: :stream,
             raw: nil
           } = ProviderError.malformed(error)
  end

  test "other malformed streams remain terminal even with the same message" do
    error = invalid_tool_arguments()

    for other <- [
          %{error | kind: :invalid_request},
          %{error | stage: :validation},
          %{error | provider_code: nil},
          %{error | retry_hint: :not_retryable},
          error.message
        ] do
      assert %ProviderError{
               kind: :malformed_stream,
               message: "Anthropic tool arguments are not complete JSON",
               retryable: false,
               retry_class: nil
             } = ProviderError.malformed(other)
    end
  end

  defp invalid_tool_arguments do
    %Error{
      kind: :upstream_error,
      stage: :observation,
      provider_code: "invalid_tool_arguments",
      retry_hint: :retryable,
      message: "Anthropic tool arguments are not complete JSON"
    }
  end
end
