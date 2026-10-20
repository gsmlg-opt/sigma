defmodule Sigma.Agent.BackplaneToolFailureTest do
  use ExUnit.Case, async: true

  alias Sigma.Agent.Message
  alias Sigma.Coding.ToolError

  defmodule ToolProvider do
    @behaviour Sigma.Ai.Provider

    @impl true
    def stream(params) do
      send(params.options[:test_pid], {:backplane_provider, params.context.messages})

      {content, stop_reason} =
        case List.last(params.context.messages) do
          %{role: :tool_result} -> {[%{type: :text, text: "handled failure"}], :stop}
          _ -> {params.options[:tool_calls], :tool_use}
        end

      message = %{
        role: :assistant,
        content: content,
        model: "mock-model",
        provider: "mock-provider",
        api: "mock-api",
        usage: %{input: 1, output: 1, cache_read: 0, cache_write: 0, total_tokens: 2},
        stop_reason: stop_reason,
        timestamp: System.system_time(:millisecond)
      }

      [{:start, %{message | content: []}}, {:done, stop_reason, message}]
    end
  end

  defmodule FailingTool do
    @behaviour Sigma.Coding.Tool

    @impl true
    def name, do: "failing_tool"
    @impl true
    def description, do: "Returns ordinary tool failures"
    @impl true
    def schema do
      %{
        "type" => "object",
        "required" => ["failure"],
        "properties" => %{"failure" => %{"type" => "string"}}
      }
    end

    @impl true
    def metadata, do: %{effect: :network, concurrency: :sequential}

    @impl true
    def execute(_id, %{"failure" => "transport"}, _opts),
      do: {:transport_failure, "MCP send failed", name(), "backplane", %{reason: :send_failure}}

    def execute(_id, %{"failure" => "execution"}, _opts),
      do: {:error, ToolError.new(:execution, "command failed", details: %{exit_code: 1})}

    def execute(_id, %{"failure" => "unmatched"}, _opts), do: {:unexpected, "invalid response"}

    def execute(_id, %{"failure" => "exception"}, _opts), do: raise("tool crashed")

    def execute(_id, %{"failure" => "success"}, _opts),
      do: {:ok, %{content: [%{type: :text, text: "next tool ran"}]}}
  end

  for {failure, kind, text} <- [
        {"transport", :transport_failure, "MCP send failed"},
        {"execution", :execution, "command failed"},
        {"unmatched", :malformed_result, "invalid response"},
        {"exception", :crash, "tool crashed"}
      ] do
    @tag :tmp_dir
    test "#{failure} failure reaches the model and continues the same turn", %{tmp_dir: dir} do
      {:ok, agent} =
        start_supervised(
          {Sigma.Agent,
           backplane_runtime_path: Path.join(dir, "runtime"),
           model: %{id: "mock-model", api: "mock-api", provider: "mock-provider"},
           provider: ToolProvider,
           tools: [FailingTool],
           options: [
             test_pid: self(),
             tool_calls: [
               %{
                 type: :tool_call,
                 id: "failed-call",
                 name: FailingTool.name(),
                 arguments: %{"failure" => unquote(failure)}
               },
               %{
                 type: :tool_call,
                 id: "next-call",
                 name: FailingTool.name(),
                 arguments: %{"failure" => "success"}
               }
             ]
           ]}
        )

      :ok = Sigma.Agent.subscribe(agent)
      assert {:accepted, %{turn_id: turn_id}} = Sigma.Agent.prompt(agent, "try the tool")
      assert_receive {:backplane_provider, [%{role: :user}]}, 5_000

      assert_receive {:backplane_provider,
                      [
                        %{role: :user},
                        %{role: :assistant},
                        %{
                          role: :tool_result,
                          tool_call_id: "failed-call",
                          is_error: true,
                          content: [%{type: :text, text: error_text}]
                        },
                        %{
                          role: :tool_result,
                          tool_call_id: "next-call",
                          is_error: false,
                          content: [%{type: :text, text: "next tool ran"}]
                        }
                      ]},
                     5_000

      assert error_text =~ unquote(text)
      assert error_text =~ Atom.to_string(unquote(kind))
      assert_receive {:tool_execution_end, "failed-call", "failing_tool", _, true}, 5_000
      assert_receive {:tool_execution_end, "next-call", "failing_tool", _, false}, 5_000

      assert_receive {:agent_end,
                      [
                        %Message{role: :user},
                        %Message{role: :assistant},
                        %Message{role: :tool_result, is_error: true},
                        %Message{role: :tool_result, is_error: false},
                        %Message{
                          role: :assistant,
                          content: [%{type: :text, text: "handled failure"}]
                        }
                      ]},
                     5_000

      assert %{phase: :completed, turn_id: ^turn_id} = Sigma.Agent.status(agent)
      store = :sys.get_state(agent).backplane_store

      assert {:ok,
              %{
                run: %{
                  state: :completed,
                  active_tools: active_tools,
                  tool_results: results
                }
              }} =
               Sigma.Agent.Backplane.Store.load(store, turn_id)

      assert active_tools == %{}

      assert [%{is_error: true, details: %{error: %{kind: kind, message: message}}}] =
               results |> Map.values() |> Enum.filter(& &1.is_error)

      assert kind == unquote(kind)
      assert message =~ unquote(text)
      refute_receive {:turn_error, _}
    end
  end
end
