defmodule Sigma.Agent.Backplane.ChildHooks do
  @moduledoc false

  alias Backplane.AgentRuntime.Error
  alias Sigma.Agent.Hooks
  alias Sigma.Coding.Hooks.Outcome

  def prompt(message, %{host: host}) do
    # MultiAgent only admits this prompt after the host acknowledges its durable
    # created receipt. Preparing ChildIO itself must never fire a start hook.
    :ok = host.start_hook.()

    outcome =
      Hooks.dispatch(:user_prompt_submit, host.hook_specs, host.hook_context, %{
        prompt: Hooks.message_text(message) || ""
      })

    case Outcome.control(outcome) do
      {control, reason} when control in [:block, :halt] ->
        {:error, Error.new(:cancelled, reason || "UserPromptSubmit hook stopped the turn")}

      _ ->
        {:ok, add_context(message, Outcome.context(outcome))}
    end
  end

  def stop(messages, %{host: host}) do
    active? = :atomics.get(host.stop_hook_active, 1) == 1

    result =
      Hooks.stop(
        :subagent_stop,
        host.hook_specs,
        host.stop_hook_context,
        messages,
        active?,
        host.stop_hook_data
      )

    if match?({:continue, _}, result), do: :atomics.put(host.stop_hook_active, 1, 1)
    result
  end

  defp add_context(message, nil), do: message

  defp add_context(%{content: content} = message, text) when is_binary(content) do
    %{message | content: content <> "\n\n[Additional context from hook]\n" <> text}
  end

  defp add_context(%{content: content} = message, text) when is_list(content) do
    %{
      message
      | content: [%{type: :text, text: "[Additional context from hook]\n" <> text} | content]
    }
  end
end
