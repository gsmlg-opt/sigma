defmodule Sigma.Ai.ProviderModel do
  @moduledoc "Normalized provider model descriptor."
  defstruct [:id, :provider, :api, :name, :capabilities]
end
