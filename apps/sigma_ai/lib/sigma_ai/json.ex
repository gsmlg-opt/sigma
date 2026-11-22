defmodule Sigma.Ai.JSON do
  @moduledoc """
  Non-raising JSON encoding for boundaries that return tagged results.
  Accepts the same Elixir terms and formatting options as Formata.JSON.encode!/2.
  """

  @spec encode(term(), keyword()) :: {:ok, binary()} | {:error, Exception.t()}
  def encode(value, opts \\ []) do
    {:ok, Formata.JSON.encode!(value, opts)}
  rescue
    error in [
      Protocol.UndefinedError,
      ErlangError,
      ArgumentError,
      FunctionClauseError,
      Formata.Error
    ] ->
      {:error, error}
  end
end
