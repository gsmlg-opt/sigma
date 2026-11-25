defmodule Sigma.Web.SessionComposerEffort do
  @moduledoc false

  alias Sigma.Ai.ReasoningEffort

  def setting(provider, model, effort) do
    case ReasoningEffort.levels(provider, model) do
      [] ->
        nil

      levels ->
        %{
          id: "effort",
          label: "Reasoning effort",
          value: if(effort in levels, do: effort, else: ""),
          defaultValue: "",
          ordered: true,
          choices:
            [%{value: "", label: "Default"}] ++
              Enum.map(levels, &%{value: &1, label: String.capitalize(&1)})
        }
    end
  end
end
