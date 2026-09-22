defmodule Sigma.Agent.SkillInvocationService do
  @moduledoc "Shared local skill invocation adapter for public transports."

  alias Sigma.Protocol.Envelope
  alias Sigma.Agent.Runtime

  def callbacks(context) when is_map(context) do
    %{
      skill_invoke: &invoke(&1, context),
      skill_invocation_status: &status(&1, context),
      skill_invocation_cancel: &cancel(&1, context)
    }
  end

  def invoke(payload, context) when is_map(payload) and is_map(context) do
    session_id = payload["sessionId"] || context[:session_id]
    request_key = payload["requestKey"] || context[:request_key]

    with true <- is_binary(request_key) and request_key != "",
         {:ok, request} <-
           Sigma.Agent.SkillInvocation.new(
             Map.merge(payload, %{"sessionId" => session_id, "request_key" => request_key})
           ),
         {:ok, existing} <- store_find(context, session_id, request_key) do
      result =
        cond do
          existing && existing["fingerprint"] != request.fingerprint ->
            {:error, :idempotency_conflict}

          existing ->
            existing

          true ->
            reserve_and_admit(request, context)
        end

      invocation_event(result, session_id)
    else
      false -> {:error, :idempotency_key_required}
      {:error, reason} -> {:error, reason}
    end
  end

  def status(payload, context) do
    session_id = payload["sessionId"] || context[:session_id]

    with {:ok, records} <- store_list(context, session_id),
         record when is_map(record) <-
           Enum.find(records, &(&1["invocationId"] == payload["invocationId"])) do
      invocation_event(record, session_id)
    else
      nil -> {:error, :invocation_not_found}
      {:error, _reason} = error -> error
    end
  end

  def cancel(payload, context) do
    session_id = payload["sessionId"] || context[:session_id]

    with {:ok, records} <- store_list(context, session_id),
         record when is_map(record) <-
           Enum.find(records, &(&1["invocationId"] == payload["invocationId"])),
         :ok <- cancel_admitted(record, context, session_id),
         {:ok, record} <-
           store_update(context, session_id, payload["invocationId"], %{"state" => "cancelled"}) do
      invocation_event(record, session_id)
    else
      nil -> {:error, :invocation_not_found}
      {:error, _reason} = error -> error
    end
  end

  defp reserve_and_admit(request, context) do
    record = %{
      "invocationId" => request.request_id,
      "requestKey" => request.request_key,
      "fingerprint" => request.fingerprint,
      "state" => "preparing",
      "repositoryId" => request.repository_id,
      "sessionId" => request.session_id,
      "skillId" => request.skill_id,
      "reference" => request.reference,
      "arguments" => request.arguments
    }

    with {:ok, _record} <- store_reserve(context, request.session_id, record) do
      case prepare_and_admit(request, context) do
        {:ok, updated} ->
          updated

        {:error, reason} = error ->
          mark_failed(context, request, reason)
          error
      end
    else
      {:error, _reason} = error -> error
    end
  end

  defp prepare_and_admit(request, context) do
    with agent when is_pid(agent) <- lookup_agent(context, request.session_id),
         {:ok, expanded} <- expand_skill(context, request),
         :ok <- ensure_not_cancelled(context, request, expanded) do
      admit_and_update(agent, expanded, request, context)
    else
      nil -> {:error, :session_not_running}
      {:error, _reason} = error -> error
    end
  end

  defp admit_prepared(agent, %{content: content, prepared_resources: resources}) do
    Sigma.Agent.follow_up(agent, content, prepared_resources: resources)
  end

  defp admit_prepared(_agent, expanded) do
    release_expanded(expanded)
    {:rejected, :invalid_prepared_prompt}
  end

  defp admit_and_update(agent, expanded, request, context) do
    case admit_prepared(agent, expanded) do
      {:accepted, info} ->
        update_admitted(context, request, expanded, info, "running")

      {:queued_as_follow_up, info} ->
        update_admitted(context, request, expanded, info, "queued")

      {:rejected, reason} ->
        _ =
          store_update(context, request.session_id, request.request_id, %{
            "state" => "failed",
            "error" => to_string(reason)
          })

        {:error, reason}
    end
  end

  defp update_admitted(context, request, expanded, info, state) do
    store_update(
      context,
      request.session_id,
      request.request_id,
      invocation_changes(expanded, info, state)
    )
  end

  defp ensure_not_cancelled(context, request, expanded) do
    case store_find(context, request.session_id, request.request_key) do
      {:ok, %{"state" => "cancelled"}} ->
        release_expanded(expanded)
        {:error, :cancelled}

      {:ok, _record} ->
        :ok

      {:error, _reason} = error ->
        release_expanded(expanded)
        error
    end
  end

  defp mark_failed(context, request, reason) do
    case store_find(context, request.session_id, request.request_key) do
      {:ok, %{"state" => "cancelled"}} ->
        :ok

      _ ->
        _ =
          store_update(context, request.session_id, request.request_id, %{
            "state" => "failed",
            "error" => to_string(reason)
          })

        :ok
    end
  end

  defp release_expanded(%{prepared_resources: resources}) do
    Enum.each(resources, fn %{release: release} -> release.() end)
  end

  defp release_expanded(_expanded), do: :ok

  defp cancel_admitted(%{"state" => state, "turnId" => turn_id}, context, session_id)
       when state in ["queued", "running"] and is_binary(turn_id) do
    case lookup_agent(context, session_id) do
      agent when is_pid(agent) -> Sigma.Agent.cancel_prompt(agent, turn_id)
      nil -> :ok
    end
  end

  defp cancel_admitted(_record, _context, _session_id), do: :ok

  defp lookup_agent(context, session_id) do
    case context[:agent_lookup] do
      callback when is_function(callback, 1) -> callback.(session_id)
      _callback -> Runtime.lookup(context[:repo_path], session_id, :agent)
    end
  end

  defp invocation_changes(expanded, info, state) do
    %{skill: %{ref: ref, digest: digest}} = expanded

    %{
      "state" => state,
      "turnId" => info.turn_id,
      "artifactDigest" => digest,
      "resolvedRef" => Map.new(ref, fn {key, value} -> {Atom.to_string(key), value} end)
    }
  end

  defp invocation_event({:error, reason}, _session_id), do: {:error, reason}

  defp invocation_event(record, session_id) when is_map(record) do
    Envelope.event("skill.invocation.updated", session_id, record, turn_id: record["turnId"])
  end

  defp store_find(context, session_id, request_key),
    do: store_call(context, :find, [session_id, request_key])

  defp store_list(context, session_id), do: store_call(context, :list, [session_id])

  defp store_reserve(context, session_id, record),
    do: store_call(context, :reserve, [session_id, record])

  defp store_update(context, session_id, invocation_id, changes),
    do: store_call(context, :update, [session_id, invocation_id, changes])

  defp store_call(context, operation, args) do
    case context[:skill_invocation_store] do
      %{^operation => callback} when is_function(callback) -> apply(callback, args)
      _ -> {:error, :skill_store_unavailable}
    end
  end

  defp expand_skill(context, request) do
    case context[:skill_expander] do
      callback when is_function(callback, 2) ->
        callback.("/skill #{request.reference || request.skill_id} #{request.arguments}",
          cwd: context[:repo_path]
        )

      _ ->
        {:error, :skill_expander_unavailable}
    end
  end
end
