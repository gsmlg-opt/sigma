defmodule Sigma.Session.ConfigEvents do
  @moduledoc "Agent-directory scoped configuration change notifications."
  alias Sigma.Session.ConfigManager

  def subscribe do
    if Process.whereis(__MODULE__), do: :pg.join(__MODULE__, group(), self())
    :ok
  end

  def broadcast do
    if Process.whereis(__MODULE__) do
      message = {:models_changed, ConfigManager.agent_dir()}
      Enum.each(:pg.get_members(__MODULE__, group()), &send(&1, message))
    end

    :ok
  end

  defp group, do: {:configuration, ConfigManager.agent_dir()}
end
