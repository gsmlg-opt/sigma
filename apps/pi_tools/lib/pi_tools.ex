defmodule PiTools do
  @moduledoc """
  oh-my-pi-style built-in tool registry for ex_pi.
  """

  def default_tools do
    [
      PiTools.Ask,
      PiTools.Read,
      PiTools.Write,
      PiTools.Bash,
      PiTools.Edit,
      PiTools.Search,
      PiTools.Find
    ]
  end

  def planned_tools, do: PiTools.Catalog.planned()
end
