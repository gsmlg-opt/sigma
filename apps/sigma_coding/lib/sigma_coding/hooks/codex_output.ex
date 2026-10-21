defmodule Sigma.Coding.Hooks.CodexOutput do
  @moduledoc """
  Codex command output control rules, pinned by Hooks.Catalog.

  Host adaptation: diagnostics are returned as strings; additional context uses
  the host's bounded in-memory Outcome representation rather than Codex disk spilling.
  """

  alias Sigma.Coding.Hooks.{Catalog, Outcome}

  @names Map.new(Catalog.events(), &{&1.event, &1.name})
  @universal ~w(continue stopReason suppressOutput systemMessage)
  @blocking [
    :pre_tool_use,
    :permission_request,
    :post_tool_use,
    :user_prompt_submit,
    :stop,
    :subagent_stop
  ]
  @context_events [
    :session_start,
    :subagent_start,
    :user_prompt_submit,
    :pre_tool_use,
    :post_tool_use
  ]

  def evaluate(event, raw), do: evaluate(event, raw, :sync)
  def evaluate_async(event, raw), do: evaluate(event, raw, :async)

  defp evaluate(event, raw, _mode)
       when event in [:pre_model_request, :post_model_request, :session_end] do
    warnings = if raw.exit == 0, do: [], else: [failure(raw)]
    {:proceed, warnings}
  end

  defp evaluate(event, %{exit: 2, stderr: stderr}, :sync) when event in @blocking do
    case String.trim(stderr) do
      "" ->
        {:proceed,
         ["#{@names[event]} hook exited with code 2 without a blocking reason on stderr."]}

      reason ->
        {{:block, reason}, []}
    end
  end

  defp evaluate(_event, %{exit: code} = raw, _mode) when code != 0,
    do: {:proceed, [failure(raw)]}

  defp evaluate(event, %{stdout: stdout}, mode) do
    text = String.trim(stdout)

    cond do
      text == "" ->
        {:proceed, []}

      String.starts_with?(text, ["{", "["]) ->
        with {:ok, json} when is_map(json) <- Jason.decode(text),
             :ok <- validate(event, json) do
          interpret(event, json, mode)
        else
          {:error, reason} when is_binary(reason) -> {:proceed, [reason]}
          _ -> {:proceed, ["Invalid #{@names[event]} hook JSON output."]}
        end

      event in [:session_start, :subagent_start, :user_prompt_submit] ->
        {{:context, text}, []}

      event in [:pre_tool_use, :pre_compact, :post_compact] ->
        {:proceed, []}

      true ->
        {:proceed, ["#{@names[event]} hook returned non-JSON stdout."]}
    end
  end

  defp validate(:interrupt, json) do
    if keys?(json, ["systemMessage"]) and optional_text?(json, "systemMessage"),
      do: :ok,
      else: {:error, "Invalid Interrupt hook JSON output."}
  end

  defp validate(event, json) do
    allowed = @universal ++ root_fields(event)
    hso = json["hookSpecificOutput"]

    valid =
      keys?(json, allowed) and
        Map.get(json, "continue", true) in [true, false] and
        Map.get(json, "suppressOutput", false) in [true, false] and
        Enum.all?(~w(stopReason systemMessage reason), &optional_text?(json, &1)) and
        valid_root_decision?(event, json["decision"]) and
        (is_nil(hso) or valid_specific?(event, hso))

    if valid, do: :ok, else: {:error, "Invalid #{@names[event]} hook JSON output."}
  end

  defp valid_root_decision?(:pre_tool_use, value), do: value in [nil, "approve", "block"]

  defp valid_root_decision?(event, value)
       when event in [:post_tool_use, :stop, :subagent_stop, :user_prompt_submit],
       do: value in [nil, "block"]

  defp valid_root_decision?(_event, _value), do: true

  defp root_fields(event) when event in [:pre_tool_use, :post_tool_use, :user_prompt_submit],
    do: ~w(decision reason hookSpecificOutput)

  defp root_fields(event) when event in [:stop, :subagent_stop], do: ~w(decision reason)

  defp root_fields(event) when event in [:session_start, :subagent_start, :permission_request],
    do: ["hookSpecificOutput"]

  defp root_fields(_), do: []

  defp valid_specific?(event, hso) when is_map(hso) do
    fields =
      case event do
        :pre_tool_use ->
          ~w(hookEventName permissionDecision permissionDecisionReason updatedInput additionalContext)

        :post_tool_use ->
          ~w(hookEventName additionalContext updatedMCPToolOutput)

        :permission_request ->
          ~w(hookEventName decision)

        _ ->
          ~w(hookEventName additionalContext)
      end

    keys?(hso, fields) and hso["hookEventName"] == @names[event] and
      optional_text?(hso, "additionalContext") and optional_text?(hso, "permissionDecisionReason") and
      valid_specific_decision?(event, hso)
  end

  defp valid_specific?(_, _), do: false

  defp valid_specific_decision?(:pre_tool_use, hso),
    do: hso["permissionDecision"] in [nil, "allow", "deny", "ask"]

  defp valid_specific_decision?(:permission_request, %{"decision" => decision})
       when not is_nil(decision) do
    is_map(decision) and
      keys?(decision, ~w(behavior updatedInput updatedPermissions message interrupt)) and
      decision["behavior"] in ["allow", "deny"] and
      optional_text?(decision, "message") and
      Map.get(decision, "interrupt", false) in [true, false]
  end

  defp valid_specific_decision?(_event, _hso), do: true

  defp interpret(:interrupt, json, _mode), do: {:proceed, message(json)}

  defp interpret(event, json, :async) do
    hso = json["hookSpecificOutput"] || %{}
    {with_context(:proceed, event, hso), message(json)}
  end

  defp interpret(event, json, :sync) do
    hso = json["hookSpecificOutput"] || %{}
    warnings = message(json)

    case event_control(event, json, hso) do
      {:error, reason} ->
        {:proceed, warnings ++ [reason]}

      control ->
        control =
          if event not in [:pre_tool_use, :permission_request, :subagent_start] and
               json["continue"] == false,
             do: {:halt, json["stopReason"]},
             else: control

        {with_context(control, event, hso), warnings}
    end
  end

  defp with_context(control, event, hso) do
    context = if event in @context_events, do: hso["additionalContext"]

    if is_binary(context) and context != "",
      do: Outcome.join(control, {:context, context}),
      else: control
  end

  defp event_control(:pre_tool_use, json, hso) do
    cond do
      json["continue"] == false or not is_nil(json["stopReason"]) or
          json["suppressOutput"] == true ->
        {:error, "PreToolUse hook returned unsupported universal control fields."}

      Enum.any?(
        ~w(permissionDecision permissionDecisionReason updatedInput),
        &(not is_nil(hso[&1]))
      ) ->
        case hso["permissionDecision"] do
          "allow" ->
            cond do
              is_nil(hso["updatedInput"]) ->
                {:error, "PreToolUse permissionDecision:allow requires updatedInput."}

              is_map(hso["updatedInput"]) ->
                {:replace_input, hso["updatedInput"]}

              true ->
                {:error, "Sigma tools require PreToolUse updatedInput to be a JSON object."}
            end

          "deny" ->
            if not is_nil(hso["updatedInput"]),
              do: {:error, "updatedInput requires permissionDecision:allow."},
              else: block_reason(hso["permissionDecisionReason"])

          nil ->
            {:error, "PreToolUse hook returned permission fields without permissionDecision."}

          _ ->
            {:error, "PreToolUse hook returned an unsupported permission decision."}
        end

      json["decision"] == "block" ->
        block_reason(json["reason"])

      not is_nil(json["decision"]) or not is_nil(json["reason"]) ->
        {:error, "PreToolUse hook returned an unsupported decision."}

      true ->
        :proceed
    end
  end

  defp event_control(:permission_request, json, hso) do
    decision = hso["decision"]

    cond do
      json["continue"] == false or not is_nil(json["stopReason"]) or
          json["suppressOutput"] == true ->
        {:error, "PermissionRequest hook returned unsupported universal control fields."}

      is_nil(decision) ->
        :proceed

      not is_map(decision) or
          not keys?(decision, ~w(behavior updatedInput updatedPermissions message interrupt)) ->
        {:error, "Invalid PermissionRequest decision."}

      not is_nil(decision["updatedInput"]) or not is_nil(decision["updatedPermissions"]) or
          Map.get(decision, "interrupt", false) != false ->
        {:error, "PermissionRequest hook returned unsupported decision fields."}

      not optional_text?(decision, "message") ->
        {:error, "Invalid PermissionRequest decision message."}

      decision["behavior"] == "allow" ->
        :allow

      decision["behavior"] == "deny" ->
        {:block, nonempty(decision["message"]) || "PermissionRequest hook denied approval"}

      true ->
        {:error, "Invalid PermissionRequest decision behavior."}
    end
  end

  defp event_control(:post_tool_use, json, hso) do
    cond do
      json["suppressOutput"] == true or not is_nil(hso["updatedMCPToolOutput"]) ->
        {:error, "PostToolUse hook returned unsupported output fields."}

      is_nil(json["decision"]) and json["continue"] != false and not is_nil(json["reason"]) ->
        {:error, "PostToolUse hook returned reason without decision."}

      true ->
        block_decision(json)
    end
  end

  defp event_control(event, json, _hso)
       when event in [:stop, :subagent_stop, :user_prompt_submit],
       do: block_decision(json)

  defp event_control(_event, _json, _hso), do: :proceed

  defp block_decision(%{"decision" => "block"} = json), do: block_reason(json["reason"])

  defp block_decision(%{"decision" => decision}) when not is_nil(decision),
    do: {:error, "Unsupported hook decision."}

  defp block_decision(_), do: :proceed

  defp block_reason(reason) do
    case nonempty(reason) do
      nil -> {:error, "Hook block decision requires a non-empty reason."}
      text -> {:block, text}
    end
  end

  defp nonempty(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp nonempty(_), do: nil

  defp message(json),
    do: if(is_binary(json["systemMessage"]), do: [json["systemMessage"]], else: [])

  defp keys?(map, allowed), do: Enum.all?(Map.keys(map), &(&1 in allowed))
  defp optional_text?(map, key), do: is_nil(map[key]) or is_binary(map[key])
  defp failure(raw), do: nonempty(raw.stderr) || "Hook exited with code #{inspect(raw.exit)}."
end
