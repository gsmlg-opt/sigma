defmodule Sigma.Agent.Incidents do
  @moduledoc """
  Auxiliary, immutable failure and recovery observations for a trusted root journal.

  These bounded records are diagnostic facts, never evidence that a runtime effect
  settled. Recording does not read history and an unavailable collector cannot
  change the outcome of the operation being observed.
  """

  require Logger

  @enforce_keys [:directory, :root_header_id, :subject]
  defstruct [:directory, :root_header_id, :subject]

  @max_bytes 16_384
  @summaries %{
    tool_failure: "Tool reported failure",
    provider_failure: "Provider attempt failed",
    runtime_failure: "Runtime reported failure",
    run_failed: "Run failed",
    retirement_failed: "Host retirement was not confirmed",
    recovery_started: "Recovery started",
    recovery_admitted: "Recovery admitted a new run",
    recovery_blocked: "Recovery was blocked",
    recovery_cancelled: "Recovery was cancelled"
  }
  @classes ~w(validation forbidden approval_required not_found timeout cancelled transient_transport resource_conflict execution_failure malformed_result budget_exceeded unsupported_capability unknown_outcome overloaded authentication authorization rate_limit rate_limited server_error upstream_error incompatible internal transport context_limit output_limit invalid_request usage_limit unknown)
  @codes ~w(rate_limit_exceeded insufficient_quota invalid_api_key authentication_error permission_error invalid_request_error context_length_exceeded model_not_found server_error overloaded_error timeout cancelled unsupported_capability unknown_outcome)
  @identity_fields ~w(run_id source_run_id target_run_id continuation_id tool_call_id tool_name provider_request_id provider_attempt_id invocation_id)a
  @label_fields ~w(stage recovery_state blocked_component)a
  @reference_fields ~w(run_id tool_call_id provider_request_id provider_attempt_id transcript_entry_id invocation_id)a

  @doc "Builds context only from the owning root's transcript and immutable header."
  def context(root_transcript_path, root_header_id, subject_attrs \\ %{})

  def context(path, header, attrs) when is_binary(path) and is_map(attrs) do
    if Path.type(path) == :absolute and component?(header) do
      subject =
        %{kind: "root", id: header}
        |> Map.merge(project(attrs, [:id, :session_id, :agent_path], &identifier/1))
        |> Map.put(:kind, if(value(attrs, :kind) in [:child, "child"], do: "child", else: "root"))

      %__MODULE__{
        directory: Path.join([Path.dirname(path), ".incidents", header]),
        root_header_id: header,
        subject: subject
      }
    end
  end

  def context(_, _, _), do: nil

  @doc "Publishes the first observation for an identity without replacing it."
  def record(context, attrs)
  def record(nil, _attrs), do: :ok

  def record(%__MODULE__{} = context, attrs) when is_map(attrs) do
    with {:ok, event} <- event(context, attrs),
         encoded = Formata.JSON.encode!(event),
         true <- byte_size(encoded) <= @max_bytes,
         :ok <- publish(context.directory, event.event_id, encoded) do
      :ok
    else
      false -> failed(:record_too_large)
      {:error, reason} -> failed(bounded_reason(reason))
    end
  rescue
    _ -> failed(:record_failed)
  catch
    _, _ -> failed(:record_failed)
  end

  def record(_, _), do: failed(:invalid_context)

  @doc false
  def record_tool(nil, _, _), do: :ok

  def record_tool(context, run_id, %{role: :tool_result} = message) do
    result = message |> value(:metadata) |> value(:structured_result)
    failure = tool_failure([{result, 0}], 128)

    if value(message, :is_error) == true or failure do
      failure = failure || result || %{}

      record(context, %{
        kind: :tool_failure,
        stage: :tool_result,
        run_id: run_id,
        tool_call_id: value(message, :tool_call_id),
        tool_name: value(message, :tool_name),
        error: value(failure, :error),
        exit_code: value(failure, :exit_code)
      })
    else
      :ok
    end
  rescue
    _ -> failed(:record_failed)
  catch
    _, _ -> failed(:record_failed)
  end

  def record_tool(_, _, _), do: :ok

  @doc false
  def record_provider(context, run_id, attempt_id, error) do
    record(context, %{
      kind: :provider_failure,
      stage: :provider_response,
      run_id: run_id,
      provider_attempt_id: attempt_id,
      error: error
    })
  end

  defp event(context, attrs) do
    kind = value(attrs, :kind)

    case Map.fetch(@summaries, kind) do
      {:ok, summary} ->
        fields =
          attrs
          |> project(@identity_fields, &identifier/1)
          |> Map.merge(project(attrs, @label_fields, &label/1))
          |> Map.merge(project(attrs, [:incarnation, :exit_code], &integer/1))

        identity =
          {context.root_header_id, context.subject, kind,
           Map.take(fields, @identity_fields ++ [:stage, :incarnation])}

        id =
          :crypto.hash(:sha256, :erlang.term_to_binary(identity)) |> Base.encode16(case: :lower)

        source = fields[:source_run_id] || fields[:run_id]

        incident_id =
          :crypto.hash(
            :sha256,
            :erlang.term_to_binary({context.root_header_id, context.subject, source})
          )
          |> Base.encode16(case: :lower)

        {:ok,
         fields
         |> Map.merge(%{
           format: "sigma.incident",
           schema_version: 1,
           incident_id: incident_id,
           event_id: id,
           root_header_id: context.root_header_id,
           subject: context.subject,
           kind: kind,
           summary: summary,
           observed_at: DateTime.to_iso8601(DateTime.utc_now()),
           versions: versions(),
           error: error_projection(value(attrs, :error)),
           evidence_refs: references(value(attrs, :evidence_refs))
         })}

      :error ->
        {:error, :invalid_kind}
    end
  end

  # Only typed classifications and known codes survive. Provider bodies and
  # Runtime details/causes are deliberately never traversed.
  defp error_projection(error) do
    %{}
    |> put_present(:class, member(value(error, :class) || value(error, :kind), @classes))
    |> put_present(:code, member(value(error, :code) || value(error, :provider_code), @codes))
    |> put_present(:status, status(value(error, :status) || value(error, :http_status)))
  end

  # Native Code Mode may wrap command outcomes in value/output maps. Inspect a
  # bounded tree for structured failures, without storing any of that tree.
  defp tool_failure([{result, depth} | rest], remaining)
       when is_map(result) and depth <= 6 and remaining > 0 do
    exit_code = value(result, :exit_code)

    if value(result, :is_error) == true or value(result, :status) in [:failed, "failed"] or
         (is_integer(exit_code) and exit_code != 0) do
      result
    else
      nested = for {_key, nested} <- Enum.take(result, 32), do: {nested, depth + 1}
      tool_failure(nested ++ rest, remaining - 1)
    end
  end

  defp tool_failure([{result, depth} | rest], remaining)
       when is_list(result) and depth <= 6 and remaining > 0 do
    nested = for nested <- Enum.take(result, 32), do: {nested, depth + 1}
    tool_failure(nested ++ rest, remaining - 1)
  end

  defp tool_failure([_ | rest], remaining) when remaining > 0,
    do: tool_failure(rest, remaining - 1)

  defp tool_failure(_, _), do: nil

  defp publish(directory, id, encoded) do
    with :ok <- File.mkdir_p(directory) do
      path = Path.join(directory, id <> ".json")
      temporary = path <> ".tmp-" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)

      try do
        with :ok <- write_synced(temporary, encoded) do
          case File.ln(temporary, path) do
            :ok -> :ok
            {:error, :eexist} -> :ok
            {:error, _} -> {:error, :publish_failed}
          end
        end
      after
        File.rm(temporary)
      end
    else
      {:error, _} -> {:error, :directory_failed}
    end
  end

  defp write_synced(path, encoded) do
    case :file.open(path, [:write, :binary, :raw, :exclusive]) do
      {:ok, file} ->
        try do
          with :ok <- :file.write(file, encoded), :ok <- :file.sync(file), do: :ok
        after
          :file.close(file)
        end

      {:error, _} ->
        {:error, :write_failed}
    end
  end

  defp references(refs) when is_list(refs),
    do:
      refs |> Enum.take(8) |> Enum.map(&project(&1, @reference_fields, fn v -> identifier(v) end))

  defp references(_), do: []

  defp versions do
    versions =
      for app <- [
            :sigma_agent,
            :backplane_agent_runtime,
            :backplane_ai_protocol,
            :backplane_skill_protocol
          ],
          version = Application.spec(app, :vsn),
          not is_nil(version),
          into: %{},
          do: {app, version |> to_string() |> identifier()}

    commit = :sigma_web |> Application.get_env(:build_info) |> value(:git_sha)

    if is_binary(commit) and Regex.match?(~r/\A[0-9a-fA-F]{7,64}\z/, commit),
      do: Map.put(versions, :sigma_commit, commit),
      else: versions
  end

  defp project(attrs, keys, normalize) do
    Enum.reduce(keys, %{}, fn key, acc -> put_present(acc, key, normalize.(value(attrs, key))) end)
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp value(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp value(_, _), do: nil
  defp integer(value) when is_integer(value), do: value
  defp integer(_), do: nil
  defp status(value) when is_integer(value) and value in 100..599, do: value
  defp status(_), do: nil
  defp member(value, allowed) when is_atom(value), do: member(Atom.to_string(value), allowed)
  defp member(value, allowed), do: if(value in allowed, do: value)
  defp label(value) when is_atom(value) and not is_nil(value), do: label(Atom.to_string(value))
  defp label(value) when is_binary(value), do: if(component?(value), do: value)
  defp label(_), do: nil

  defp identifier(value) when is_binary(value) and byte_size(value) in 1..256,
    do: if(String.valid?(value) and not String.contains?(value, ["\n", "\r", <<0>>]), do: value)

  defp identifier(_), do: nil

  defp component?(value) when is_binary(value) and byte_size(value) in 1..160,
    do: value not in [".", ".."] and Regex.match?(~r/\A[A-Za-z0-9_.-]+\z/, value)

  defp component?(_), do: false

  defp bounded_reason(reason)
       when reason in [:invalid_kind, :directory_failed, :publish_failed, :write_failed],
       do: reason

  defp bounded_reason(_), do: :record_failed

  defp failed(reason) do
    Logger.warning("incident collection failed: #{reason}")
    {:error, reason}
  end
end
