defmodule Sigma.Ai.Provider do
  @callback stream(params :: map()) :: Enumerable.t()
end
