defmodule Sigma.Agent.PromptQueue do
  @moduledoc "Pure FIFO steering and follow-up queues."

  defstruct steering: [], follow_up: []

  def new, do: %__MODULE__{}

  def enqueue(%__MODULE__{} = queue, :steering, item),
    do: %{queue | steering: queue.steering ++ [item]}

  def enqueue(%__MODULE__{} = queue, :follow_up, item),
    do: %{queue | follow_up: queue.follow_up ++ [item]}

  def peek(%__MODULE__{steering: [item | _]}, :steering), do: item
  def peek(%__MODULE__{follow_up: [item | _]}, :follow_up), do: item
  def peek(%__MODULE__{}, queue) when queue in [:steering, :follow_up], do: nil

  def ack(%__MODULE__{} = queue, :steering, message_id),
    do: ack_queue(queue, :steering, message_id)

  def ack(%__MODULE__{} = queue, :follow_up, message_id),
    do: ack_queue(queue, :follow_up, message_id)

  def pop(%__MODULE__{} = queue, :steering), do: pop_queue(queue, :steering)
  def pop(%__MODULE__{} = queue, :follow_up), do: pop_queue(queue, :follow_up)

  def counts(%__MODULE__{} = queue) do
    %{steering: length(queue.steering), follow_up: length(queue.follow_up)}
  end

  defp ack_queue(queue, type, message_id) do
    case Map.fetch!(queue, type) do
      [%{message_id: ^message_id} | rest] -> {:ok, Map.put(queue, type, rest)}
      _queue -> {:error, :prompt_not_reserved}
    end
  end

  defp pop_queue(queue, type) do
    case Map.fetch!(queue, type) do
      [item | rest] -> {item, Map.put(queue, type, rest)}
      [] -> {nil, queue}
    end
  end
end
