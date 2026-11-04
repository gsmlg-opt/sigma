defmodule Sigma.Agent.Backplane.HostRetirement do
  @moduledoc """
  Private host lifetime facts, serialized by the existing runtime Store.

  Native Session generations and async-hook hosts have different lifetimes.
  Every binding is retained, including runs which detached successfully while
  commands or Code Mode cells remained alive. Confirmed retirement describes
  only these host components; it is not a Kernel work settlement.
  """

  alias Backplane.AgentRuntime.Error

  @host_keys ~w(root_header_id transcript_header_id child_session_id host_lifetime_id)a
  @native_keys ~w(native_owner_id native_session_incarnation)a
  @binding_keys @host_keys ++ @native_keys ++ ~w(run_id run_incarnation)a

  def new, do: %{version: 2, hosts: %{}}

  def decode(bytes) do
    ledger = bytes |> :erlang.binary_to_term([:safe]) |> upgrade()

    if valid_ledger?(ledger),
      do: {:ok, ledger},
      else: malformed()
  rescue
    ArgumentError -> malformed()
  end

  def register(ledger, binding) do
    with :ok <- validate_binding(binding),
         {:ok, host} <- host(ledger, Map.take(binding, @host_keys)) do
      key = binding_key(binding)
      native = native_key(binding)

      cond do
        host.bindings[key] == binding ->
          {:ok, ledger, :unchanged}

        not is_nil(host.bindings[key]) ->
          conflict("host binding identity changed")

        not is_nil(host.async_hooks) or not is_nil(host.session_end) or
            Map.has_key?(host.native, native) ->
          conflict("host binding belongs to a retired lifetime")

        true ->
          updated = %{host | bindings: Map.put(host.bindings, key, binding)}
          {:ok, put_host(ledger, updated), :changed}
      end
    end
  end

  def record(ledger, identity, :native, confirmation) do
    with :ok <- validate_native_identity(identity),
         :ok <- validate_confirmation(:native, identity, confirmation),
         {:ok, host} <- host(ledger, Map.take(identity, @host_keys)),
         true <-
           Enum.any?(host.bindings, fn {_key, binding} ->
             native_key(binding) == native_key(identity)
           end) do
      put_confirmation(ledger, host, :native, native_key(identity), confirmation)
    else
      false -> conflict("native retirement has no recorded host binding")
      error -> error
    end
  end

  def record(ledger, identity, :async_hooks, confirmation) do
    with :ok <- validate_host_identity(identity),
         :ok <- validate_confirmation(:async_hooks, identity, confirmation),
         {:ok, host} <- host(ledger, identity) do
      cond do
        host.async_hooks == confirmation ->
          {:ok, ledger, :unchanged}

        not is_nil(host.async_hooks) ->
          conflict("async hook retirement confirmation changed")

        true ->
          {:ok, put_host(ledger, %{host | async_hooks: confirmation}), :changed}
      end
    end
  end

  def record(ledger, identity, :session_end, confirmation) do
    with :ok <- validate_host_identity(identity),
         :ok <- validate_confirmation(:session_end, identity, confirmation),
         {:ok, host} <- host(ledger, identity) do
      cond do
        host.session_end == confirmation ->
          {:ok, ledger, :unchanged}

        not is_nil(host.session_end) ->
          conflict("SessionEnd completion changed")

        true ->
          {:ok, put_host(ledger, %{host | session_end: confirmation}), :changed}
      end
    end
  end

  def record(_ledger, _identity, _component, _confirmation),
    do: invalid("invalid host retirement component")

  def lookup(ledger, :all), do: {:ok, ledger}

  def lookup(ledger, binding) do
    with :ok <- validate_binding(binding),
         %{bindings: bindings} = host <- ledger.hosts[binding.host_lifetime_id],
         ^binding <- bindings[binding_key(binding)] do
      native = host.native[native_key(binding)]
      hooks = host.async_hooks

      {:ok,
       %{
         binding: binding,
         native: native,
         async_hooks: hooks,
         session_end: host.session_end,
         status: if(is_map(native) and is_map(hooks), do: :confirmed, else: :unconfirmed)
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, Error.new(:not_found, "host binding retirement not found")}
    end
  end

  defp host(ledger, identity) do
    case ledger.hosts[identity.host_lifetime_id] do
      nil ->
        {:ok,
         %{identity: identity, bindings: %{}, native: %{}, async_hooks: nil, session_end: nil}}

      %{identity: ^identity} = host ->
        {:ok, host}

      _ ->
        conflict("host lifetime identity changed")
    end
  end

  defp put_host(ledger, host),
    do: %{ledger | hosts: Map.put(ledger.hosts, host.identity.host_lifetime_id, host)}

  defp put_confirmation(ledger, host, :native, key, confirmation) do
    case host.native[key] do
      ^confirmation ->
        {:ok, ledger, :unchanged}

      nil ->
        {:ok, put_host(ledger, %{host | native: Map.put(host.native, key, confirmation)}),
         :changed}

      _ ->
        conflict("native retirement confirmation changed")
    end
  end

  defp validate_host_identity(identity) do
    if exact_keys?(identity, @host_keys) and
         Enum.all?(
           [:root_header_id, :transcript_header_id, :host_lifetime_id],
           &nonempty?(identity[&1])
         ) and
         (is_nil(identity.child_session_id) or nonempty?(identity.child_session_id)),
       do: :ok,
       else: invalid("invalid host retirement identity")
  end

  defp validate_native_identity(identity) do
    if exact_keys?(identity, @host_keys ++ @native_keys) and
         validate_host_identity(Map.take(identity, @host_keys)) == :ok and
         nonempty?(identity.native_owner_id) and
         is_integer(identity.native_session_incarnation) and
         identity.native_session_incarnation > 0,
       do: :ok,
       else: invalid("invalid native retirement identity")
  end

  defp validate_binding(binding) do
    if exact_keys?(binding, @binding_keys) and
         validate_native_identity(Map.take(binding, @host_keys ++ @native_keys)) == :ok and
         nonempty?(binding.run_id) and is_integer(binding.run_incarnation) and
         binding.run_incarnation > 0,
       do: :ok,
       else: invalid("invalid host retirement binding")
  end

  defp validate_confirmation(:native, identity, confirmation) do
    if confirmation == %{status: :confirmed, owner_id: identity.native_owner_id},
      do: :ok,
      else: invalid("native retirement requires its exact confirmed close")
  end

  defp validate_confirmation(:async_hooks, _identity, %{status: :confirmed} = confirmation) do
    if exact_keys?(confirmation, [:status]),
      do: :ok,
      else: invalid("invalid async hook retirement confirmation")
  end

  defp validate_confirmation(:async_hooks, _identity, _confirmation),
    do: invalid("async hook retirement requires confirmed shutdown")

  defp validate_confirmation(:session_end, %{child_session_id: nil}, confirmation)
       when is_map(confirmation) do
    if exact_keys?(confirmation, [:status, :dispatch, :outcome, :warnings]) and
         confirmation.status == :confirmed and confirmation.dispatch == :completed and
         is_list(confirmation.warnings) and Enum.all?(confirmation.warnings, &is_binary/1),
       do: :ok,
       else: invalid("invalid SessionEnd completion")
  end

  defp validate_confirmation(:session_end, _identity, _confirmation),
    do: invalid("SessionEnd completion requires a root host")

  # Version one had only child/native facts. Decode adds the independent root
  # completion slot in memory; a read never rewrites the existing receipt file.
  defp upgrade(%{version: 1, hosts: hosts} = ledger) when is_map(hosts) do
    if exact_keys?(ledger, [:version, :hosts]) and
         Enum.all?(hosts, fn {_id, host} ->
           exact_keys?(host, [:identity, :bindings, :native, :async_hooks])
         end),
       do: %{
         version: 2,
         hosts: Map.new(hosts, fn {id, host} -> {id, Map.put(host, :session_end, nil)} end)
       },
       else: ledger
  end

  defp upgrade(ledger), do: ledger

  defp valid_ledger?(%{version: 2, hosts: hosts} = ledger) when is_map(hosts) do
    exact_keys?(ledger, [:version, :hosts]) and
      Enum.all?(hosts, fn {id, host} -> valid_host?(id, host) end)
  end

  defp valid_ledger?(_), do: false

  defp valid_host?(
         id,
         %{
           identity: identity,
           bindings: bindings,
           native: native,
           async_hooks: hooks,
           session_end: session_end
         } = host
       )
       when is_map(bindings) and is_map(native) do
    exact_keys?(host, [:identity, :bindings, :native, :async_hooks, :session_end]) and
      validate_host_identity(identity) == :ok and id == identity.host_lifetime_id and
      Enum.all?(bindings, fn {key, binding} ->
        validate_binding(binding) == :ok and Map.take(binding, @host_keys) == identity and
          key == binding_key(binding)
      end) and
      Enum.all?(native, fn
        {{owner, incarnation} = key, confirmation} ->
          native_identity =
            Map.merge(identity, %{
              native_owner_id: owner,
              native_session_incarnation: incarnation
            })

          validate_native_identity(native_identity) == :ok and
            validate_confirmation(:native, native_identity, confirmation) == :ok and
            Enum.any?(bindings, fn {_key, binding} -> native_key(binding) == key end)

        _ ->
          false
      end) and
      (is_nil(hooks) or validate_confirmation(:async_hooks, identity, hooks) == :ok) and
      (is_nil(session_end) or
         validate_confirmation(:session_end, identity, session_end) == :ok)
  end

  defp valid_host?(_, _), do: false

  defp binding_key(binding),
    do:
      {binding.run_id, binding.run_incarnation, binding.native_owner_id,
       binding.native_session_incarnation}

  defp native_key(identity),
    do: {identity.native_owner_id, identity.native_session_incarnation}

  defp exact_keys?(value, keys) when is_map(value),
    do: Enum.sort(Map.keys(value)) == Enum.sort(keys)

  defp exact_keys?(_, _), do: false
  defp nonempty?(value), do: is_binary(value) and value != ""
  defp invalid(message), do: {:error, Error.new(:validation, message)}
  defp conflict(message), do: {:error, Error.new(:resource_conflict, message)}
  defp malformed, do: {:error, Error.new(:malformed_result, "malformed host retirement record")}
end
