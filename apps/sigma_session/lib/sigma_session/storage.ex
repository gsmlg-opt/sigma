defmodule Sigma.Session.Storage do
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

  Implementations are expected to be lossy-tolerant: lines that cannot be
  decoded are skipped rather than aborting the read. Diagnostics (Logger
  messages and telemetry) are emitted for any skipped lines. The return
  value is always `{:ok, valid_entries}` as long as the storage medium is
  accessible; `{:error, reason}` is reserved for I/O-level failures.
  """
  @callback read(storage_id()) :: {:ok, [entry()]} | {:error, any()}

  @type read_diagnostic :: %{
          required(:kind) => :invalid_json | :trailing_incomplete_json,
          required(:line) => pos_integer()
        }

  @callback read_with_diagnostics(storage_id()) ::
              {:ok, [entry()], [read_diagnostic()]} | {:error, any()}

  @optional_callbacks read_with_diagnostics: 1
end
