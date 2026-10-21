defmodule Sigma.Coding.Hooks.Outcome do
  @moduledoc """
  Decodes hook subprocess results and folds outcomes in completion order.

  ## Outcome lattice (most restrictive wins)

    halt > block > defer > ask > input changes > allow > proceed

  `:halt` is the absorbing element — once present it wins regardless of order.
  `:proceed` is the identity element.

  Additional context is retained independently of the control decision.
  Codex input replacements use the latest completed replacement, so `join/2`
  is order-sensitive. Legacy Claude input patches retain their merge behavior.

  ## Dialect divergences

  `:codex` and `:pi` use the Codex decoder. PostToolUse blocking adds feedback
  alongside the tool result; Codex does not support `updatedToolOutput`.
  The `:claude` decoder retains the legacy output schema and patch semantics.

  PreToolUse `defer` is Claude-only (headless -p mode). If not headless,
  degrades to `ask`.

  ## Exit-code semantics

  - exit 0, empty stdout → :proceed
  - Codex exit 2 → blocking only for steering events with nonempty stderr
  - other non-zero → non-blocking error (surface to user, not model)
  - Codex nonzero exits take precedence over JSON stdout
  - the legacy Claude decoder attempts JSON stdout before exit-code handling
  """

  @type raw_result :: %{
          exit: non_neg_integer(),
          stdout: String.t(),
          stderr: String.t()
        }

  @type outcome :: Sigma.Coding.Hooks.Spec.outcome()

  @max_context_chars 10_000

  # ---------------------------------------------------------------------------
  # Decode
  # ---------------------------------------------------------------------------

  @doc """
  Decode a single hook subprocess result into an outcome.

  `event` is the hook event atom. `raw` is `%{exit: int, stdout: str, stderr: str}`.
  `dialect` is `:codex | :claude | :pi`.
  """
  @spec decode(atom(), raw_result(), atom()) :: outcome()
  def decode(event, raw, dialect) when dialect in [:codex, :pi] do
    {outcome, _warnings} = Sigma.Coding.Hooks.CodexOutput.evaluate(event, raw)
    outcome
  end

  def decode(event, %{exit: exit_code, stdout: stdout, stderr: stderr}, dialect) do
    stdout = String.slice(stdout, 0, @max_context_chars)

    # Try JSON stdout first; it overrides exit-code decisions.
    case parse_json_stdout(stdout) do
      {:ok, json} ->
        decode_json(event, json, exit_code, stderr, dialect)

      :plain ->
        decode_exit(event, exit_code, stdout, stderr)
    end
  end

  def evaluate(event, raw, dialect) when dialect in [:codex, :pi],
    do: Sigma.Coding.Hooks.CodexOutput.evaluate(event, raw)

  def evaluate(event, raw, dialect), do: {decode(event, raw, dialect), []}

  def evaluate_async(event, raw, dialect) when dialect in [:codex, :pi],
    do: Sigma.Coding.Hooks.CodexOutput.evaluate_async(event, raw)

  def evaluate_async(event, raw, dialect) do
    {outcome, warnings} = evaluate(event, raw, dialect)
    context = context(outcome)
    {if(is_binary(context), do: {:context, context}, else: :proceed), warnings}
  end

  # ---------------------------------------------------------------------------
  # Join (lattice operation)
  # ---------------------------------------------------------------------------

  def control({:with_context, control, _text}), do: control
  def control({:context, _text}), do: :proceed
  def control(outcome), do: outcome

  def context({:with_context, _control, text}), do: text
  def context({:context, text}), do: text
  def context(_outcome), do: nil

  @doc """
  Fold outcomes in completion order, retaining context and the stricter control.

  `:halt` absorbs other controls; the rightmost input replacement wins.
  """
  @spec join(outcome(), outcome()) :: outcome()
  def join(left, right) do
    control = join_control(control(left), control(right))
    text = [context(left), context(right)] |> Enum.reject(&is_nil/1) |> Enum.join("\n")
    text = String.slice(text, 0, @max_context_chars)

    cond do
      text == "" -> control
      control == :proceed -> {:context, text}
      true -> {:with_context, control, text}
    end
  end

  defp join_control({:halt, _} = h, _), do: h
  defp join_control(_, {:halt, _} = h), do: h
  defp join_control({:block, _} = b, _), do: b
  defp join_control(_, {:block, _} = b), do: b
  defp join_control({:defer, _} = d, _), do: d
  defp join_control(_, {:defer, _} = d), do: d
  defp join_control({:ask, _} = a, _), do: a
  defp join_control(_, {:ask, _} = a), do: a
  defp join_control(_left, {:replace_input, _} = replacement), do: replacement
  defp join_control({:replace_input, _} = replacement, _right), do: replacement

  # Both modify: merge patches; conflicting key → escalate to :ask
  defp join_control({:modify, p1}, {:modify, p2}) do
    conflicts =
      Enum.any?(p1, fn {k, v} ->
        Map.has_key?(p2, k) and Map.get(p2, k) != v
      end)

    if conflicts do
      {:ask, "Conflicting hook modifications for the same input field"}
    else
      {:modify, Map.merge(p1, p2)}
    end
  end

  defp join_control(:allow, :proceed), do: :allow
  defp join_control(:proceed, :allow), do: :allow
  defp join_control(:allow, other), do: other
  defp join_control(other, :allow), do: other

  defp join_control(:proceed, other), do: other
  defp join_control(other, :proceed), do: other

  # Fallback: left wins (should not normally be reached with well-formed outcomes)
  defp join_control(left, _right), do: left

  @doc "Fold a list of outcomes into a single outcome."
  @spec fold([outcome()]) :: outcome()
  def fold(outcomes) when is_list(outcomes) do
    Enum.reduce(outcomes, :proceed, &join(&2, &1))
  end

  # ---------------------------------------------------------------------------
  # Private: JSON stdout decoding
  # ---------------------------------------------------------------------------

  defp parse_json_stdout(""), do: :plain

  defp parse_json_stdout(stdout) do
    case Jason.decode(stdout) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> :plain
    end
  end

  # New schema: hookSpecificOutput
  defp decode_json(event, %{"hookSpecificOutput" => hso} = json, _exit_code, _stderr, dialect)
       when is_map(hso) do
    decision = Map.get(hso, "permissionDecision") || Map.get(hso, "decision")
    reason = Map.get(hso, "permissionDecisionReason") || Map.get(hso, "reason", "")
    additional_context = Map.get(hso, "additionalContext") || Map.get(json, "additionalContext")
    continue = Map.get(json, "continue")

    base_outcome =
      decode_decision(event, decision, reason, json, hso, dialect)

    base_outcome
    |> apply_context(additional_context)
    |> apply_halt(continue)
  end

  # Legacy schema: top-level decision/reason
  defp decode_json(event, %{"decision" => _} = json, _exit_code, _stderr, dialect) do
    decision = Map.get(json, "decision")
    reason = Map.get(json, "reason", "")
    additional_context = Map.get(json, "additionalContext") || Map.get(json, "systemMessage")
    continue = Map.get(json, "continue")

    # Normalize legacy decision names
    decision = normalize_legacy_decision(decision)

    base_outcome = decode_decision(event, decision, reason, json, %{}, dialect)

    base_outcome
    |> apply_context(additional_context)
    |> apply_halt(continue)
  end

  # No decision field but has additionalContext / systemMessage / continue
  defp decode_json(event, json, exit_code, stderr, _dialect) do
    additional_context = Map.get(json, "additionalContext") || Map.get(json, "systemMessage")
    continue = Map.get(json, "continue")

    # Plain stdout with JSON wrapper — check exit-code too
    base = decode_exit(event, exit_code, Map.get(json, "output", ""), stderr)

    base
    |> apply_context(additional_context)
    |> apply_halt(continue)
  end

  defp decode_decision(:pre_tool_use, decision, reason, json, hso, _dialect) do
    case decision do
      d when d in ["deny", "block"] ->
        {:block, reason}

      "allow" ->
        updated_input = Map.get(hso, "updatedInput") || Map.get(json, "updatedInput")
        if is_map(updated_input), do: {:modify, updated_input}, else: :proceed

      "ask" ->
        {:ask, reason}

      "defer" ->
        {:defer, reason}

      _ ->
        :proceed
    end
  end

  defp decode_decision(:permission_request, decision, reason, json, hso, _dialect) do
    behavior = Map.get(hso, "behavior") || Map.get(json, "behavior")

    case behavior || decision do
      "deny" ->
        {:block, reason}

      "allow" ->
        updated_input = Map.get(hso, "updatedInput") || Map.get(json, "updatedInput")
        if is_map(updated_input), do: {:modify, updated_input}, else: :proceed

      _ ->
        :proceed
    end
  end

  defp decode_decision(:post_tool_use, decision, reason, json, hso, dialect) do
    updated_output =
      Map.get(hso, "updatedToolOutput") || Map.get(json, "updatedToolOutput")

    cond do
      is_binary(updated_output) ->
        {:modify, %{"tool_output" => updated_output}}

      decision == "block" and dialect == :codex ->
        {:block, reason}

      decision == "block" ->
        # Claude: annotate alongside — encode as context so the runner can append
        {:context, reason}

      true ->
        :proceed
    end
  end

  defp decode_decision(:user_prompt_submit, decision, reason, _json, _hso, _dialect) do
    case decision do
      "block" -> {:block, reason}
      _ -> :proceed
    end
  end

  defp decode_decision(:stop, decision, reason, _json, _hso, _dialect) do
    case decision do
      "block" -> {:block, reason}
      _ -> :proceed
    end
  end

  defp decode_decision(:session_start, _decision, _reason, _json, _hso, _dialect) do
    :proceed
  end

  defp decode_decision(:session_end, _decision, _reason, _json, _hso, _dialect) do
    :proceed
  end

  defp decode_decision(_event, decision, reason, _json, _hso, _dialect) do
    case decision do
      d when d in ["block", "deny"] -> {:block, reason}
      _ -> :proceed
    end
  end

  # ---------------------------------------------------------------------------
  # Private: exit-code fallback
  # ---------------------------------------------------------------------------

  defp decode_exit(_event, 0, stdout, _stderr) do
    case String.trim(stdout) do
      "" -> :proceed
      text -> {:context, text}
    end
  end

  defp decode_exit(event, 2, stdout, stderr) do
    reason =
      case String.trim(stderr) do
        "" -> String.trim(stdout)
        s -> s
      end

    case event do
      :stop -> {:block, reason}
      :user_prompt_submit -> {:block, reason}
      :pre_tool_use -> {:block, reason}
      :permission_request -> {:block, reason}
      :post_tool_use -> {:block, reason}
      _ -> :proceed
    end
  end

  # Non-zero, non-2: non-blocking error — surface to user but don't block
  defp decode_exit(_event, _code, _stdout, _stderr), do: :proceed

  # ---------------------------------------------------------------------------
  # Private: apply continue:false and additionalContext
  # ---------------------------------------------------------------------------

  defp apply_halt({:halt, _} = h, _), do: h

  defp apply_halt(outcome, false), do: join(outcome, {:halt, nil})
  defp apply_halt(outcome, _), do: outcome

  defp apply_context(outcome, nil), do: outcome
  defp apply_context(outcome, ""), do: outcome

  defp apply_context(outcome, text) when is_binary(text) do
    join(outcome, {:context, String.slice(text, 0, @max_context_chars)})
  end

  # Normalize legacy Codex decision names to Claude names
  defp normalize_legacy_decision("approve"), do: "allow"
  defp normalize_legacy_decision(d), do: d
end
