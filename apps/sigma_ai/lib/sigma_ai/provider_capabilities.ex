defmodule Sigma.Ai.ProviderCapabilities do
  @moduledoc "Capabilities advertised for one provider model."

  defstruct [
    :context_window,
    :max_output_tokens,
    tools: false,
    thinking: false,
    image_input: false,
    supported_options: []
  ]

  @type t :: %__MODULE__{
          tools: boolean(),
          thinking: boolean(),
          image_input: boolean(),
          context_window: pos_integer() | nil,
          max_output_tokens: pos_integer() | nil,
          supported_options: [atom()]
        }
end
