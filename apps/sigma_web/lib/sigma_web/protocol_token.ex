defmodule Sigma.Web.ProtocolToken do
  @moduledoc "Shared Protocol V1 bearer token verification."

  @spec verify(term()) :: :ok | :error
  def verify(token) when is_binary(token) do
    expected =
      Application.get_env(:sigma_web, :protocol_token) || System.get_env("SIGMA_PROTOCOL_TOKEN")

    if is_binary(expected) and byte_size(expected) >= 32 and byte_size(token) == byte_size(expected) and
         Plug.Crypto.secure_compare(token, expected) do
      :ok
    else
      :error
    end
  end

  def verify(_token), do: :error
end
