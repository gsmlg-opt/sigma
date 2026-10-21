defmodule Sigma.Agent.Hooks do
  @moduledoc false

  require Logger

  alias Sigma.Agent.Message
  alias Sigma.Coding.Hooks.Outcome

  def dispatch(event, specs, context, data \\ %{}) do
    {outcome, warnings} = Sigma.Coding.Hooks.dispatch(event, specs, context, data)
    Enum.each(warnings, &Logger.warning("[hooks] #{&1}"))
    outcome
  end

  def context(config, overrides \\ %{}) do
    Map.merge(
      %{
        session_id: Map.get(config, :session_id),
        turn_id: Map.get(config, :turn_id),
        cwd: Map.get(config, :cwd),
        transcript_path: Map.get(config, :transcript_path),
        model: model_id(Map.get(config, :model)),
        permission_mode: "default"
      },
      overrides
    )
  end

  def async_contexts, do: :ets.new(__MODULE__, [:ordered_set, :public])

  def async_callback(table) do
    fn text, warnings ->
      Enum.each(warnings, &Logger.warning("[hooks] #{&1}"))

      if is_binary(text) and text != "" do
        try do
          :ets.insert(table, {System.unique_integer([:positive, :monotonic]), text})
        rescue
          ArgumentError -> :ok
        end
      end
    end
  end

  def async_messages(messages, table) do
    table
    |> :ets.tab2list()
    |> Enum.reduce(messages, fn {_id, text}, acc -> prepend_context(acc, text) end)
  end

  def prepend_context(messages, nil), do: messages
  def prepend_context(messages, ""), do: messages

  def prepend_context(messages, text) do
    [
      Message.user(
        "hook_ctx_#{System.unique_integer([:positive])}",
        "[Developer context from hook]\n#{text}"
      )
      | messages
    ]
  end

  def stop(event, specs, context, messages, active?, data \\ %{}) do
    assistant = Enum.find(Enum.reverse(messages), &match?(%{role: :assistant}, &1))

    data =
      Map.merge(data, %{
        stop_hook_active: active?,
        last_assistant_message: message_text(assistant)
      })

    outcome = dispatch(event, specs, context, data)

    case Outcome.control(outcome) do
      {:block, reason} when is_binary(reason) and reason != "" ->
        {:continue, Message.user("hook_stop_#{System.unique_integer([:positive])}", reason)}

      _ ->
        :stop
    end
  end

  def message_text(%{content: text}) when is_binary(text), do: text

  def message_text(%{content: blocks}) when is_list(blocks) do
    Enum.map_join(blocks, "\n", fn
      %{type: :text, text: text} -> text
      _ -> ""
    end)
  end

  def message_text(_), do: nil

  defp model_id(%{} = model), do: model[:id] || model["id"] || ""
  defp model_id(model) when is_binary(model), do: model
  defp model_id(_), do: ""
end
