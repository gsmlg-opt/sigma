defmodule Sigma.Tools do
  @moduledoc """
  oh-my-pi-style built-in tool registry for sigma.
  """

  def default_tools do
    [
      Sigma.Tools.Ask,
      Sigma.Tools.Read,
      Sigma.Tools.Write,
      Sigma.Tools.Bash,
      Sigma.Tools.Edit,
      Sigma.Tools.Search,
      Sigma.Tools.Find
    ]
  end

  def planned_tools, do: Sigma.Tools.Catalog.planned()
end
