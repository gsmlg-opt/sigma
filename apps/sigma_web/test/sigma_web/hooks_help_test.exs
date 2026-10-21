defmodule Sigma.Web.HooksHelpTest do
  use ExUnit.Case, async: true

  alias Sigma.Coding.Hooks.{Catalog, CodexOutput, Outcome, Payload}
  alias Sigma.Web.HooksHelp

  @observers [:pre_model_request, :post_model_request, :session_end]
  @blocking [
    :pre_tool_use,
    :permission_request,
    :post_tool_use,
    :user_prompt_submit,
    :stop,
    :subagent_stop
  ]
  @context %{
    session_id: "test-session",
    turn_id: "test-turn",
    cwd: "/example/test",
    model: "test-model"
  }

  test "all events document exactly the runtime fields, including optional child fields" do
    assert length(Catalog.events()) == 14

    for %{event: event} <- Catalog.events() do
      help = HooksHelp.for_event(event)
      root = Payload.build(event, @context)

      child =
        Payload.build(event, Map.merge(@context, %{agent_id: "child", agent_type: "worker"}))

      names = Enum.map(help.input_fields, & &1.name)

      assert Enum.sort(names) == Enum.sort(Map.keys(child))
      assert length(names) == length(Enum.uniq(names))
      assert Enum.sort(Map.keys(help.input_example)) == Enum.sort(Map.keys(root))
      assert Jason.decode!(Jason.encode!(help.input_example)) == help.input_example

      for field <- help.input_fields do
        assert is_binary(field.type) and field.type != ""
        assert is_binary(field.description) and field.description != ""
        assert String.contains?(field.type, "optional") == not Map.has_key?(root, field.name)
      end

      assert [_ | _] = help.output_rules
      assert is_binary(help.async_note) and help.async_note != ""
      assert Enum.map(help.exit_codes, & &1.code) == ["0", "2", "Other nonzero"]
    end
  end

  test "nullable fields are documented separately from omitted child fields" do
    for %{event: event} <- Catalog.events(), field <- HooksHelp.for_event(event).input_fields do
      if field.name in [
           "transcript_path",
           "last_assistant_message",
           "agent_transcript_path",
           "error",
           "token_usage"
         ] do
        assert String.contains?(field.type, "null")
        refute String.contains?(field.type, "optional")
      end
    end
  end

  test "every stdout example is accepted by the real Codex output decoder" do
    for %{event: event} <- Catalog.events() do
      help = HooksHelp.for_event(event)

      if event in @observers do
        assert help.output_examples == []
      else
        assert [_ | _] = help.output_examples
      end

      for example <- help.output_examples do
        assert is_binary(example.label) and example.label != ""
        assert is_map(example.output) or is_binary(example.output)
        {outcome, warnings} = CodexOutput.evaluate(event, raw(example.output))
        assert warnings == expected_diagnostics(example.output)
        assert outcome == expected_outcome(example.output)

        if is_map(example.output) and is_map(example.output["hookSpecificOutput"]) do
          assert example.output["hookSpecificOutput"]["hookEventName"] ==
                   help.input_example["hook_event_name"]
        end
      end
    end
  end

  test "async example outputs preserve context without returning controls" do
    for %{event: event} <- Catalog.events(),
        example <- HooksHelp.for_event(event).output_examples do
      {sync, warnings} = CodexOutput.evaluate(event, raw(example.output))
      {async, async_warnings} = CodexOutput.evaluate_async(event, raw(example.output))
      assert warnings == expected_diagnostics(example.output)
      assert async_warnings == warnings
      assert Outcome.control(async) == :proceed
      assert Outcome.context(async) == Outcome.context(sync)
    end
  end

  test "exit status wins over stdout and exit two steers only its supported events" do
    for %{event: event} <- Catalog.events() do
      output = %{raw(%{"continue" => false}) | exit: 2, stderr: "example reason"}
      {outcome, warnings} = CodexOutput.evaluate(event, output)

      if event in @blocking do
        assert outcome == {:block, "example reason"}
        assert warnings == []
        assert {:proceed, [_]} = CodexOutput.evaluate(event, %{output | stderr: ""})
      else
        assert outcome == :proceed
        assert [_] = warnings
      end

      assert {:proceed, [_]} = CodexOutput.evaluate(event, %{output | exit: 1})
    end
  end

  test "successful stderr is not a diagnostic and systemMessage works on parsed events" do
    for %{event: event} <- Catalog.events() do
      assert {:proceed, []} =
               CodexOutput.evaluate(event, %{exit: 0, stdout: "", stderr: "unused"})

      result = CodexOutput.evaluate(event, raw(%{"systemMessage" => "example diagnostic"}))

      if event in @observers,
        do: assert(result == {:proceed, []}),
        else: assert(result == {:proceed, ["example diagnostic"]})
    end
  end

  test "unknown stdout fields never steer execution" do
    for %{event: event} <- Catalog.events() do
      result = CodexOutput.evaluate(event, raw(%{"continue" => false, "unknown" => true}))

      if event in @observers,
        do: assert(result == {:proceed, []}),
        else: assert(match?({:proceed, [_]}, result))
    end
  end

  defp raw(output) do
    %{exit: 0, stderr: "", stdout: if(is_binary(output), do: output, else: Jason.encode!(output))}
  end

  defp expected_diagnostics(%{"systemMessage" => message}), do: [message]
  defp expected_diagnostics(_output), do: []

  defp expected_outcome(text) when is_binary(text), do: {:context, text}
  defp expected_outcome(%{"continue" => false, "stopReason" => reason}), do: {:halt, reason}
  defp expected_outcome(%{"decision" => "block", "reason" => reason}), do: {:block, reason}

  defp expected_outcome(%{"hookSpecificOutput" => fields}) do
    case fields do
      %{"permissionDecision" => "allow", "updatedInput" => input} -> {:replace_input, input}
      %{"decision" => %{"behavior" => "allow"}} -> :allow
      %{"decision" => %{"behavior" => "deny", "message" => message}} -> {:block, message}
      %{"additionalContext" => context} -> {:context, context}
    end
  end

  defp expected_outcome(_output), do: :proceed
end
