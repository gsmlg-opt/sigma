defmodule PiSession.Storage do
  @moduledoc """
  Behaviour for session storage.
  """

  @type storage_id :: String.t()
  @type entry :: map()

  @doc """
  Appends an entry to the storage.
  """
  @callback append(storage_id(), entry()) :: :ok | {:error, any()}

  @doc """
  Reads all entries from the storage.
  """
  @callback read(storage_id()) :: {:ok, [entry()]} | {:error, any()}
end
