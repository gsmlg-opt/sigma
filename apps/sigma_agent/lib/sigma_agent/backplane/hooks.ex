defmodule Sigma.Agent.Backplane.Hooks do
  @moduledoc false

  def prompt(message, %{host: host}) do
    if :atomics.compare_exchange(host.initial_prompt, 1, 0, 1) == :ok do
      # Keep the public admission identity in the Runtime checkpoint. Engine
      # maps it back to the complete canonical message for Provider context.
      {:ok, %{host.initial_message | id: message.id}}
    else
      {:ok, message}
    end
  end

  def prepare_tool(invocation, %{host: host} = context) do
    if invocation.tool_name in host.native_tool_names do
      Sigma.Agent.Backplane.ToolPreparation.prepare_tool(invocation, context)
    else
      :allow
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
