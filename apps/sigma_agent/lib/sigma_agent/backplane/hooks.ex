defmodule Sigma.Agent.Backplane.Hooks do
  @moduledoc false

  def prompt(message, %{host: host}) do
    if :atomics.compare_exchange(host.initial_prompt, 1, 0, 1) == :ok do
      {:ok, host.initial_message}
    else
      {:ok, message}
    end
  end

  def stop(messages, %{host: host, owner: owner}) do
    active? = :atomics.get(host.stop_hook_active, 1) == 1

    case host.stop_hook.(messages, active?) do
      :stop ->
        :stop

      {:continue, message} ->
        :atomics.put(host.stop_hook_active, 1, 1)
        send(owner, {:backplane_synthetic_user, message})
        {:continue, message}

      {:error, _reason} = error ->
        error
    end
  end
end
