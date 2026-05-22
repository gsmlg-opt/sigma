defmodule PiLogs.Entry do
  @enforce_keys [:id, :session_id, :category, :event, :metadata, :timestamp]
  defstruct [:id, :session_id, :category, :event, :metadata, :timestamp]

  @counter_key {__MODULE__, :counter}

  def init_counter do
    ref = :atomics.new(1, signed: false)
    :persistent_term.put(@counter_key, ref)
  end

  def new(session_id, category, event, metadata) do
    ref = :persistent_term.get(@counter_key)
    id = :atomics.add_get(ref, 1, 1)

    %__MODULE__{
      id: id,
      session_id: session_id,
      category: category,
      event: event,
      metadata: metadata,
      timestamp: System.system_time(:millisecond)
    }
  end
end
