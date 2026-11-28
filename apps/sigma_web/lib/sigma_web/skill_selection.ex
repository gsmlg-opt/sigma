defmodule Sigma.Web.SkillSelection do
  @moduledoc false

  alias Sigma.Session.Skills

  def dom_key(skill) do
    skill
    |> Skills.identity()
    |> :erlang.term_to_binary()
    |> Base.url_encode64(padding: false)
  end

  def set(selection, identities, true), do: MapSet.union(selection, MapSet.new(identities))
  def set(selection, identities, false), do: MapSet.difference(selection, MapSet.new(identities))

  def names(selection, skills) do
    skills
    |> Enum.filter(&MapSet.member?(selection, Skills.identity(&1)))
    |> Enum.map(& &1.name)
    |> Enum.uniq()
    |> Enum.sort()
  end
end
