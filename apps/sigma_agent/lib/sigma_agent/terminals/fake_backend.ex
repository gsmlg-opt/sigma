defmodule Sigma.Agent.Terminals.FakeBackend do
  @moduledoc "Deterministic state-machine backend fixture for terminal runtime tests."

  alias Sigma.Agent.Terminals.{Identity, Limits}

  defstruct start: :immediate,
            cleanup: :confirmed,
            next_ref: 1,
            pending: %{},
            runs: %{},
            events: []

  @type t :: %__MODULE__{}

  @spec new(keyword()) :: t()
  def new(opts \\ []), do: struct!(__MODULE__, opts)

  @spec start(t(), Identity.Run.t(), map()) ::
          {:ok, t()} | {:pending, pos_integer(), t()} | {:error, term(), t()}
  def start(%__MODULE__{} = backend, %Identity.Run{} = run, attrs) when is_map(attrs) do
    ref = backend.next_ref
    backend = append(backend, {:start_requested, ref, run, attrs})
    backend = %{backend | next_ref: ref + 1}

    case backend.start do
      :delayed ->
        {:pending, ref, put_in(backend.pending[ref], run)}

      :immediate ->
        {:ok,
         backend |> put_in([Access.key(:runs), run], %{}) |> append({:started, ref, run, %{}})}

      {:failed, reason} ->
        {:error, reason, append(backend, {:start_failed, ref, run, reason})}
    end
  end

  @spec complete_start(t(), pos_integer(), map()) :: {:ok, t()} | {:error, :unknown_start}
  def complete_start(%__MODULE__{} = backend, ref, resource) do
    case Map.pop(backend.pending, ref) do
      {nil, _pending} ->
        {:error, :unknown_start}

      {run, pending} ->
        backend = %{backend | pending: pending}

        {:ok,
         backend
         |> put_in([Access.key(:runs), run], resource)
         |> append({:started, ref, run, resource})}
    end
  end

  @spec emit(t(), Identity.Run.t(), binary()) :: {:ok, t()} | {:error, :run_not_found}
  def emit(%__MODULE__{} = backend, %Identity.Run{} = run, bytes) when is_binary(bytes) do
    with :ok <- running(backend, run), do: {:ok, append(backend, {:output, run, bytes})}
  end

  @spec resize(t(), Identity.Run.t(), integer(), integer(), Limits.t()) ::
          {:ok, t()} | {:error, :run_not_found | :invalid_dimensions}
  def resize(%__MODULE__{} = backend, %Identity.Run{} = run, columns, rows, %Limits{} = limits) do
    with :ok <- running(backend, run),
         true <- Limits.valid_dimensions?(limits, columns, rows) do
      {:ok, append(backend, {:resize_ack, run, columns, rows})}
    else
      false -> {:error, :invalid_dimensions}
      error -> error
    end
  end

  @spec input(t(), Identity.Run.t(), binary()) :: {:ok, t()} | {:error, :run_not_found}
  def input(%__MODULE__{} = backend, %Identity.Run{} = run, bytes) when is_binary(bytes) do
    with :ok <- running(backend, run), do: {:ok, append(backend, {:input, run, bytes})}
  end

  @spec device_response(t(), Identity.Run.t(), binary()) ::
          {:ok, t()} | {:error, :run_not_found}
  def device_response(%__MODULE__{} = backend, %Identity.Run{} = run, bytes)
      when is_binary(bytes) do
    with :ok <- running(backend, run),
         do: {:ok, append(backend, {:device_response, run, bytes})}
  end

  @spec cleanup(t(), Identity.Run.t()) ::
          {{:ok, :confirmed} | {:error, :cleanup_failed | :cleanup_unconfirmed}, t()}
  def cleanup(%__MODULE__{} = backend, %Identity.Run{} = run) do
    {outcome, backend} = next_cleanup(backend)

    case outcome do
      :confirmed ->
        {{:ok, :confirmed}, backend |> remove_run(run) |> append({:cleanup_confirmed, run})}

      :failed ->
        {{:error, :cleanup_failed}, append(backend, {:cleanup_failed, run})}

      :unconfirmed ->
        {{:error, :cleanup_unconfirmed}, append(backend, {:cleanup_unconfirmed, run})}
    end
  end

  defp next_cleanup(%__MODULE__{cleanup: [outcome | rest]} = backend),
    do: {outcome, %{backend | cleanup: rest}}

  defp next_cleanup(%__MODULE__{} = backend), do: {backend.cleanup, backend}

  @spec owner_down(t(), Identity.Run.t(), term()) ::
          {:ok, t()} | {:error, :cleanup_failed | :cleanup_unconfirmed}
  def owner_down(%__MODULE__{} = backend, %Identity.Run{} = run, reason) do
    backend = append(backend, {:owner_down, run, reason})

    case cleanup(backend, run) do
      {{:ok, :confirmed}, backend} -> {:ok, backend}
      {{:error, reason}, _backend} -> {:error, reason}
    end
  end

  @spec events(t()) :: [term()]
  def events(%__MODULE__{events: events}), do: Enum.reverse(events)

  defp running(%__MODULE__{runs: runs}, run) do
    if Map.has_key?(runs, run), do: :ok, else: {:error, :run_not_found}
  end

  defp remove_run(backend, run), do: %{backend | runs: Map.delete(backend.runs, run)}
  defp append(backend, event), do: %{backend | events: [event | backend.events]}
end
