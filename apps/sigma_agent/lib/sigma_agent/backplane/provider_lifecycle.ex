defmodule Sigma.Agent.Backplane.ProviderLifecycle do
  @moduledoc """
  Durable observations of exact Runtime provider workers.

  A stopped worker is independent of its response, Kernel settlement, native
  resource retirement and Goal acknowledgement. Missing observations never
  become confirmations merely because a Store was reopened.
  """

  alias Backplane.AgentRuntime.Error

  @identity_keys ~w(run_id incarnation step_id attempt_id)a
  @exit_kinds [:normal, :shutdown, :killed, :other]

  def new, do: %{version: 1, attempts: %{}}
  def identity(request), do: Map.take(request, @identity_keys)
  def key(identity), do: Map.take(identity, @identity_keys)

  def decode(bytes) do
    ledger = :erlang.binary_to_term(bytes, [:safe])
    if valid?(ledger), do: {:ok, ledger}, else: malformed()
  rescue
    ArgumentError -> malformed()
  end

  def observe(ledger, identity, observer) do
    with :ok <- validate_identity(identity), true <- nonempty?(observer) do
      case ledger.attempts[key(identity)] do
        nil ->
          entry = %{identity: identity, observer: observer, status: :observing, exit_kind: nil}
          {:ok, put(ledger, entry), :changed}

        _ ->
          conflict("provider attempt already has a lifecycle observation")
      end
    else
      false -> conflict("provider observer identity is unavailable")
      error -> error
    end
  end

  def stopped(ledger, identity, observer, exit_kind) when exit_kind in @exit_kinds do
    with :ok <- validate_identity(identity) do
      case ledger.attempts[key(identity)] do
        %{identity: ^identity, observer: ^observer, status: :observing} = entry ->
          {:ok, put(ledger, %{entry | status: :stopped, exit_kind: exit_kind}), :changed}

        %{identity: ^identity, observer: ^observer, status: :stopped, exit_kind: ^exit_kind} ->
          {:ok, ledger, :unchanged}

        _ ->
          conflict("provider termination does not match its original observation")
      end
    end
  end

  def lookup(ledger, :all), do: {:ok, ledger}

  def lookup(ledger, identity) do
    with :ok <- validate_identity(identity) do
      case ledger.attempts[key(identity)] do
        nil -> {:error, Error.new(:not_found, "provider lifecycle observation not found")}
        entry -> {:ok, entry}
      end
    end
  end

  def validate_identity(identity) do
    if is_map(identity) and Enum.sort(Map.keys(identity)) == Enum.sort(@identity_keys) and
         is_integer(identity.incarnation) and identity.incarnation > 0 and
         Enum.all?([:run_id, :step_id, :attempt_id], &nonempty?(identity[&1])),
       do: :ok,
       else: {:error, Error.new(:validation, "invalid Runtime provider identity")}
  end

  defp valid?(%{version: 1, attempts: attempts} = ledger) when is_map(attempts) do
    Enum.sort(Map.keys(ledger)) == [:attempts, :version] and
      Enum.all?(attempts, fn
        {identity,
         %{identity: identity, observer: observer, status: status, exit_kind: kind} =
             entry} ->
          Enum.sort(Map.keys(entry)) == [:exit_kind, :identity, :observer, :status] and
            validate_identity(identity) == :ok and nonempty?(observer) and
            ((status == :observing and is_nil(kind)) or
               (status == :stopped and kind in @exit_kinds))

        _ ->
          false
      end)
  end

  defp valid?(_), do: false

  defp put(ledger, entry),
    do: %{ledger | attempts: Map.put(ledger.attempts, key(entry.identity), entry)}

  defp nonempty?(value), do: is_binary(value) and value != ""
  defp conflict(message), do: {:error, Error.new(:resource_conflict, message)}

  defp malformed,
    do: {:error, Error.new(:malformed_result, "malformed provider lifecycle ledger")}
end
