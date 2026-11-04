defmodule Sigma.Web.NativeToolsProvider do
  @moduledoc false
  @behaviour Sigma.Ai.Provider

  @impl true
  def stream(params) do
    fixture = Application.fetch_env!(:sigma_web, :native_tools_test)
    results = Enum.filter(params.context.messages, &(&1.role == :tool_result))
    plan? = Map.get(fixture, :mode) == :plan

    call =
      case length(results) do
        0 ->
          %{
            type: :tool_call,
            id: "native-question",
            name: "request_user_input",
            arguments: %{
              "questions" => [
                %{
                  "id" => "flow",
                  "header" => "Flow",
                  "question" =>
                    if(plan?,
                      do: "Continue with the native plan?",
                      else: "Continue with the native patch?"
                    ),
                  "options" => [
                    %{
                      "label" => "Proceed",
                      "description" =>
                        if(plan?, do: "Publish the task plan", else: "Apply the file change")
                    },
                    %{"label" => "Wait", "description" => "Keep reviewing"}
                  ]
                }
              ]
            }
          }

        1 ->
          next_call(fixture)

        _ ->
          nil
      end

    message = %{
      role: :assistant,
      content: if(call, do: [call], else: [%{type: :text, text: "Native tools completed"}]),
      model: "mock-model",
      provider: "mock-provider",
      api: "openai-responses",
      usage: %{input: 1, output: 1, total_tokens: 2, cost: %{total: 0.0}},
      timestamp: System.system_time(:millisecond),
      stop_reason: if(call, do: :tool_use, else: :stop)
    }

    [{:start, %{message | content: []}}, {:done, message.stop_reason, message}]
  end

  defp next_call(%{mode: :plan}) do
    %{
      type: :tool_call,
      id: "native-plan",
      name: "update_plan",
      arguments: %{
        "plan" => [%{"step" => "Native client verified", "status" => "completed"}]
      }
    }
  end

  defp next_call(fixture) do
    %{
      type: :tool_call,
      id: "native-patch",
      name: "apply_patch",
      input_kind: :custom,
      arguments:
        "*** Begin Patch\n*** Add File: #{fixture.path}\n+native client verified\n*** End Patch"
    }
  end
end
