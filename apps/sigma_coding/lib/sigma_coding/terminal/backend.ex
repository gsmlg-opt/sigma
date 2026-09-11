defmodule Sigma.Coding.Terminal.Backend do
  @moduledoc "Low-level contract for a managed terminal backend."

  @type cleanup_result :: {:ok, :confirmed} | {:error, :cleanup_failed | :cleanup_unconfirmed}

  @callback capabilities(keyword()) :: {:ok, map()} | {:error, term()}
  @callback start_link(keyword()) :: GenServer.on_start()
  @callback resource(GenServer.server()) :: {:ok, map()} | {:error, term()}
  @callback input(GenServer.server(), binary()) :: :ok | {:error, term()}
  @callback resize(GenServer.server(), pos_integer(), pos_integer()) :: :ok | {:error, term()}
  @callback checkpoint(GenServer.server(), binary()) :: :ok | {:error, term()}
  @callback close(GenServer.server(), timeout()) :: cleanup_result()
end
