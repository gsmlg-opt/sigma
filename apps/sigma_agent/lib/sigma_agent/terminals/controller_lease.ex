defmodule Sigma.Agent.Terminals.ControllerLease do
  @moduledoc "Pure single-controller lease and final-dispatch fence."

  alias Sigma.Agent.Terminals.{Error, Identity, Limits}

  defstruct controller_id: nil, epoch: 0, expires_at_ms: nil

  @type t :: %__MODULE__{
          controller_id: binary() | nil,
          epoch: non_neg_integer(),
          expires_at_ms: non_neg_integer() | nil
        }

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec expire(t(), non_neg_integer()) :: t()
  def expire(%__MODULE__{expires_at_ms: expires_at_ms} = lease, now_ms)
      when is_integer(expires_at_ms) and now_ms >= expires_at_ms,
      do: %{lease | controller_id: nil, expires_at_ms: nil}

  def expire(%__MODULE__{} = lease, _now_ms), do: lease

  @spec acquire(t(), binary(), non_neg_integer(), Limits.t()) :: {:ok, t()} | {:error, Error.t()}
  def acquire(%__MODULE__{} = lease, attachment_id, now_ms, %Limits{} = limits) do
    lease = expire(lease, now_ms)

    if lease.controller_id == nil do
      {:ok, grant(lease, attachment_id, now_ms, limits)}
    else
      {:error, Error.new(:control_occupied, %{epoch: lease.epoch})}
    end
  end

  @spec takeover(t(), binary(), non_neg_integer(), non_neg_integer(), Limits.t()) ::
          {:ok, t()} | {:error, Error.t()}
  def takeover(%__MODULE__{} = lease, attachment_id, expected_epoch, now_ms, %Limits{} = limits) do
    lease = expire(lease, now_ms)

    if lease.epoch == expected_epoch do
      {:ok, grant(lease, attachment_id, now_ms, limits)}
    else
      {:error, Error.new(:control_conflict, %{expected: expected_epoch, actual: lease.epoch})}
    end
  end

  @spec renew(t(), binary(), non_neg_integer(), non_neg_integer(), Limits.t()) ::
          {:ok, t()} | {:error, Error.t()}
  def renew(%__MODULE__{} = lease, attachment_id, epoch, now_ms, %Limits{} = limits) do
    with :ok <- active(lease, now_ms),
         :ok <- controller(lease, attachment_id),
         :ok <- epoch(lease, epoch) do
      {:ok, %{lease | expires_at_ms: now_ms + limits.controller_lease_ms}}
    end
  end

  @spec release(t(), binary(), non_neg_integer()) :: {:ok, t()} | {:error, Error.t()}
  def release(%__MODULE__{} = lease, attachment_id, epoch) do
    with :ok <- controller(lease, attachment_id),
         :ok <- epoch(lease, epoch) do
      {:ok, %{lease | controller_id: nil, epoch: lease.epoch + 1, expires_at_ms: nil}}
    end
  end

  @spec authorize(map(), map(), non_neg_integer()) :: :ok | {:error, Error.t()}
  def authorize(
        %{run: %Identity.Run{} = current_run, catalog_revision: revision, lease: lease},
        request,
        now_ms
      ) do
    with :ok <- session(current_run, request.run),
         :ok <- terminal(current_run, request.run),
         :ok <- generation(current_run, request.run),
         :ok <- revision(revision, request.catalog_revision),
         :ok <- active(lease, now_ms),
         :ok <- controller(lease, request.attachment_id),
         :ok <- epoch(lease, request.control_epoch) do
      :ok
    end
  end

  defp grant(lease, attachment_id, now_ms, limits) do
    %{
      lease
      | controller_id: attachment_id,
        epoch: lease.epoch + 1,
        expires_at_ms: now_ms + limits.controller_lease_ms
    }
  end

  defp active(%__MODULE__{expires_at_ms: expires_at_ms}, now_ms)
       when is_integer(expires_at_ms) and now_ms < expires_at_ms,
       do: :ok

  defp active(_lease, _now_ms), do: {:error, Error.new(:controller_lease_expired)}

  defp controller(%__MODULE__{controller_id: attachment_id}, attachment_id), do: :ok
  defp controller(_lease, _attachment_id), do: {:error, Error.new(:not_controller)}

  defp epoch(%__MODULE__{epoch: epoch}, epoch), do: :ok

  defp epoch(%__MODULE__{epoch: actual}, expected),
    do: {:error, Error.new(:stale_control_epoch, %{expected: expected, actual: actual})}

  defp session(%Identity.Run{terminal: %{session: expected}}, %Identity.Run{
         terminal: %{session: actual}
       }) do
    cond do
      expected.repository_id != actual.repository_id or expected.session_id != actual.session_id ->
        {:error, Error.new(:session_scope_mismatch)}

      expected.incarnation_id != actual.incarnation_id ->
        {:error, Error.new(:stale_session_incarnation)}

      true ->
        :ok
    end
  end

  defp terminal(%Identity.Run{terminal: expected}, %Identity.Run{terminal: actual}) do
    if expected.terminal_id == actual.terminal_id,
      do: :ok,
      else: {:error, Error.new(:stale_terminal)}
  end

  defp generation(%Identity.Run{generation: generation}, %Identity.Run{generation: generation}),
    do: :ok

  defp generation(_current, _actual), do: {:error, Error.new(:stale_run_generation)}

  defp revision(revision, revision), do: :ok

  defp revision(actual, expected),
    do: {:error, Error.new(:stale_catalog_revision, %{expected: expected, actual: actual})}
end
