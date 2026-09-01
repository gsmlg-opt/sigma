defmodule Sigma.Ai.ProviderRequest do
  @moduledoc "Provider-neutral request passed to provider adapters."

  @enforce_keys [:model, :context]
  defstruct [:model, :context, :session_id, :log_session_id, options: []]

  @type t :: %__MODULE__{
          model: map(),
          context: map(),
          options: keyword(),
          session_id: String.t() | nil,
          log_session_id: String.t() | nil
        }

  def from_legacy(params) when is_map(params) do
    %__MODULE__{
      model: Map.fetch!(params, :model),
      context: Map.fetch!(params, :context),
      options: Map.get(params, :options, []),
      session_id: Map.get(params, :session_id),
      log_session_id: Map.get(params, :log_session_id, Map.get(params, :session_id))
    }
  end

  def to_legacy(%__MODULE__{} = request) do
    %{
      model: request.model,
      context: request.context,
      options: request.options,
      session_id: request.session_id,
      log_session_id: request.log_session_id
    }
  end
end
