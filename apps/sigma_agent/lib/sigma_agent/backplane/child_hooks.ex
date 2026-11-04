defmodule Sigma.Agent.Backplane.ChildHooks do
  @moduledoc false

  alias Backplane.AgentRuntime.Error
  alias Sigma.Agent.Hooks
  alias Sigma.Agent.Backplane.{ChildPermission, HookDelivery, ToolPreparation}
  alias Sigma.Coding.Hooks.Outcome

  def prompt(message, %{host: host}) do
    if is_function(host[:canonical_hook_prompt], 1) do
      with {:ok, canonical} <- host.canonical_hook_prompt.(message) do
        if HookDelivery.message?(canonical),
          do: prepare_hook_prompt(host, message),
          else: user_prompt(message, host)
      end
    else
      user_prompt(message, host)
    end
  end

  defp user_prompt(message, host) do
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
        message = add_context(message, Outcome.context(outcome))

        prepare_hook_prompt(host, message)
    end
  end

  defp prepare_hook_prompt(host, message) do
    if is_function(host[:prepare_hook_prompt], 1),
      do: host.prepare_hook_prompt.(message),
      else: {:ok, message}
  end

  def prepare_tool(invocation, %{host: host} = context) do
    if invocation.tool_name in Map.get(host, :native_tool_names, []) do
      context =
        case context do
          %{interact: interact} when is_function(interact, 1) ->
            Map.put(context, :interact, fn request ->
              with {:ok, reply} <- interact.(request), do: ChildPermission.decode(reply)
            end)

          _ ->
            context
        end

      with {:ok, opts} <- host.permission_options.() do
        ToolPreparation.prepare_tool(invocation, Map.put(context, :permission_options, opts))
      end
    else
      :allow
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
