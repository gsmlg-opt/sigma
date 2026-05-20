defmodule PiAi.Provider do
  @callback stream(params :: map()) :: Enumerable.t()
end
