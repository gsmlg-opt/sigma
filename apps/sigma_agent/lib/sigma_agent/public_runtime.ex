defmodule Sigma.Agent.PublicRuntime do
  @moduledoc """
  Stable direct Elixir command boundary shared by headless and UI clients.

  The boundary accepts Protocol V1 command envelopes and returns Protocol V1
  event envelopes. Context contains trusted runtime dependencies such as the
  repository path, sessions directory, provider resolver, and subscriber PID;
  none of those internal terms enter protocol payloads.
  """

  alias Sigma.Agent.{ProtocolEventMapper, ProtocolSubscription, Runtime}
  alias Sigma.Protocol.Envelope

  def execute(command, context \\ %{})

  def execute(%Envelope{kind: :command} = command, context) when is_map(context) do
    case dispatch(command, context) do
      {:ok, %Envelope{} = event} -> {:ok, event}
      {:error, %Envelope{} = event} -> {:error, event}
      {:error, reason} -> {:error, error_event(command, reason)}
    end
  rescue
    exception -> {:error, error_event(command, {:command_exception, exception.__struct__})}
  catch
    kind, reason -> {:error, error_event(command, {:command_failure, kind, reason})}
  end

  def execute(%Envelope{} = envelope, _context),
    do: {:error, error_event(envelope, :command_required)}

  def execute(_command, _context), do: {:error, :invalid_command}

  defp dispatch(%Envelope{type: "session.create"} = command, context) do
    with {:ok, repo_path, sessions_dir} <- paths(command, context),
         {:ok, cwd} <- create_cwd(command.payload["cwd"] || repo_path, repo_path, context),
         {:ok, storage_path} <- session_path(sessions_dir, command.session_id),
         metadata <- Map.put(command.payload["metadata"] || %{}, "cwd", cwd),
         create_snapshot <- create_snapshot(command.payload, cwd),
         {:ok, session_opts} <-
           runtime_session_opts(context, create_snapshot, storage_path, repo_path),
         :ok <-
           apply(Sigma.Session.SessionFiles, :create, [
             sessions_dir,
             command.session_id,
             metadata,
             cwd,
             initial_model_opts(command.payload)
           ]) do
      result = resume(command, Map.put(context, :session_opts, session_opts), repo_path, storage_path)

      case result do
        {:ok, _event} -> result
        {:error, _reason} = error -> rollback_failed_create(sessions_dir, command.session_id, error)
      end
    end
  end

  defp dispatch(%Envelope{type: "session.resume"} = command, context) do
    with {:ok, repo_path, sessions_dir} <- paths(command, context),
         {:ok, storage_path} <- session_path(sessions_dir, command.session_id) do
      resume(command, context, repo_path, storage_path)
    end
  end

  defp dispatch(%Envelope{type: "session.status"} = command, context) do
    with {:ok, repo_path, sessions_dir} <- paths(command, context),
         {:ok, storage_path} <- session_path(sessions_dir, command.session_id),
         {:ok, snapshot} <- apply(Sigma.Session.Log, :snapshot, [storage_path]) do
      runtime_status = Runtime.session_status(repo_path, command.session_id)
      agent_status = agent_status(repo_path, command.session_id)

      snapshot_event(command.session_id, snapshot, %{
        "runtime" => public_runtime_status(runtime_status),
        "turn" => agent_status
      })
    end
  end

  defp dispatch(%Envelope{type: "session.switch"} = command, context) do
    with {:ok, repo_path, sessions_dir} <- paths(command, context),
         target_id when is_binary(target_id) and target_id != "" <- command.payload["targetSessionId"],
         {:ok, %{snapshot: snapshot}} <-
           Runtime.switch_session(
             repo_path,
             command.session_id,
             target_id,
             sessions_dir
           ),
         {:ok, target_path} <- session_path(sessions_dir, target_id),
         {:ok, target_command} <- Envelope.command("session.resume", target_id),
         {:ok, _target_event} <- resume(target_command, context, repo_path, target_path) do
      snapshot_event(target_id, snapshot)
    else
      nil -> {:error, :missing_target_session_id}
      false -> {:error, :missing_target_session_id}
      {:error, _reason} = error -> error
    end
  end

  defp dispatch(%Envelope{type: "session.fork"} = command, context) do
    with {:ok, repo_path, sessions_dir} <- paths(command, context),
         target_id when is_binary(target_id) and target_id != "" <- command.payload["targetSessionId"],
         {:ok, %{session_id: ^target_id}} <-
           Runtime.fork_session(
             repo_path,
             command.session_id,
             target_id,
             sessions_dir,
             command.payload["messageId"] || :all,
             fallback_cwd: repo_path
           ),
         {:ok, target_path} <- session_path(sessions_dir, target_id),
         {:ok, snapshot} <- apply(Sigma.Session.Log, :snapshot, [target_path]) do
      snapshot_event(target_id, snapshot)
    else
      nil -> {:error, :missing_target_session_id}
      false -> {:error, :missing_target_session_id}
      {:error, _reason} = error -> error
    end
  end

  defp dispatch(%Envelope{type: "session.dump"} = command, context) do
    read_only_artifact(command, context, :dump)
  end

  defp dispatch(%Envelope{type: "session.export"} = command, context) do
    read_only_artifact(command, context, :export)
  end

  defp dispatch(%Envelope{type: "prompt.submit"} = command, context),
    do: admit_prompt(command, context, :submit)

  defp dispatch(%Envelope{type: "prompt.steer"} = command, context),
    do: admit_prompt(command, context, :steer)

  defp dispatch(%Envelope{type: "prompt.follow_up"} = command, context),
    do: admit_prompt(command, context, :follow_up)

  defp dispatch(%Envelope{type: "turn.cancel"} = command, context) do
    with {:ok, agent} <- running_agent(command, context),
         result <- Sigma.Agent.cancel(agent),
         {:ok, payload} <- cancel_payload(result),
         {:ok, event} <-
           Envelope.event("session.snapshot", command.session_id, %{"cancellation" => payload},
             turn_id: payload["turnId"]
           ) do
      {:ok, event}
    end
  end

  defp dispatch(%Envelope{type: "permission.resolve"} = command, context) do
    with {:ok, agent} <- running_agent(command, context),
         request_id when is_binary(request_id) <- command.payload["requestId"],
         {:ok, reply} <- permission_reply(command.payload["decision"]),
         :ok <- Sigma.Agent.answer_user_question(agent, request_id, reply) do
      status_event(command.session_id, agent)
    else
      nil -> {:error, :missing_request_id}
      {:error, _reason} = error -> error
    end
  end

  defp dispatch(%Envelope{type: "mcp.elicitation.resolve"} = command, context) do
    with {:ok, agent} <- running_agent(command, context),
         request_id when is_binary(request_id) <- command.payload["requestId"],
         {:ok, reply} <- elicitation_reply(command.payload),
         :ok <- Sigma.Agent.answer_mcp_elicitation(agent, request_id, reply) do
      status_event(command.session_id, agent)
    else
      nil -> {:error, :missing_request_id}
      {:error, _reason} = error -> error
    end
  end

  defp dispatch(%Envelope{type: "model.select"} = command, context) do
    resolver = context[:model_resolver]

    with true <- is_function(resolver, 2),
         provider_id when is_binary(provider_id) <- command.payload["providerId"],
         model_id when is_binary(model_id) <- command.payload["modelId"],
         {:ok, provider, model, options} <- resolver.(provider_id, model_id),
         {:ok, repo_path, _sessions_dir} <- paths(command, context),
         :ok <-
           Runtime.change_model(
             repo_path,
             command.session_id,
             provider_id,
             model_id,
             provider,
             model,
             options
           ) do
      status_event(command.session_id, Runtime.lookup(repo_path, command.session_id, :agent))
    else
      false -> {:error, :model_resolver_unavailable}
      nil -> {:error, :invalid_model_selection}
      {:error, _reason} = error -> error
    end
  end

  defp dispatch(%Envelope{type: "subscription.attach"} = command, context) do
    sink = context[:subscriber] || self()

    with true <- is_pid(sink),
         {:ok, agent} <- running_agent(command, context),
         {:ok, subscription_id} <-
           ProtocolSubscription.attach(agent, command.session_id, sink,
             max_sink_queue: context[:max_subscriber_queue] || 256
           ),
         {:ok, event} <-
           Envelope.event("session.snapshot", command.session_id, %{
             "subscriptionId" => subscription_id,
             "attached" => true
           }) do
      {:ok, event}
    else
      false -> {:error, :subscriber_required}
      {:error, _reason} = error -> error
    end
  end

  defp dispatch(%Envelope{type: "subscription.detach"} = command, context) do
    sink = context[:subscriber] || self()

    with subscription_id when is_binary(subscription_id) <- command.payload["subscriptionId"],
         :ok <- ProtocolSubscription.detach(subscription_id, sink),
         {:ok, event} <-
           Envelope.event("session.snapshot", command.session_id, %{
             "subscriptionId" => subscription_id,
             "attached" => false
           }) do
      {:ok, event}
    else
      nil -> {:error, :missing_subscription_id}
      {:error, _reason} = error -> error
    end
  end

  defp resume(command, context, repo_path, storage_path) do
    with {:ok, snapshot} <- apply(Sigma.Session.Log, :snapshot, [storage_path]),
         :ok <- require_session_header(snapshot),
         :ok <- ensure_runtime_session(command, context, repo_path, storage_path, snapshot) do
      snapshot_event(command.session_id, snapshot)
    end
  end

  defp ensure_runtime_session(command, context, repo_path, storage_path, snapshot) do
    if is_pid(Runtime.lookup(repo_path, command.session_id, :agent)) do
      :ok
    else
      with {:ok, session_opts} <- runtime_session_opts(context, snapshot, storage_path, repo_path),
           {:ok, _handle} <- Runtime.get_session(repo_path, command.session_id, session_opts) do
        :ok
      end
    end
  end

  defp runtime_session_opts(context, snapshot, storage_path, repo_path) do
    opts =
      case context[:session_opts] do
        resolver when is_function(resolver, 1) -> resolver.(snapshot)
        opts when is_list(opts) -> opts
        nil -> []
        _opts -> :invalid
      end

    if is_list(opts) and is_map(opts[:model]) and is_atom(opts[:provider]) do
      {:ok,
       opts
       |> Keyword.put(:messages, snapshot.messages)
       |> Keyword.put(:cwd, opts[:cwd] || snapshot.cwd || repo_path)
       |> Keyword.put(:transcript_path, storage_path)}
    else
      {:error, :runtime_session_options_required}
    end
  end

  defp admit_prompt(command, context, mode) do
    with {:ok, agent} <- running_agent(command, context),
         content when is_binary(content) or is_list(content) <- command.payload["content"],
         result <- call_prompt(agent, mode, content, prompt_opts(context, agent)),
         {:ok, status, info} <- admission_payload(result),
         {:ok, event} <-
           Envelope.event(
             "prompt.admitted",
             command.session_id,
             Map.put(info, "status", status),
             turn_id: info["turnId"]
           ) do
      {:ok, event}
    else
      nil -> {:error, :missing_prompt_content}
      {:error, _reason} = error -> error
    end
  end

  defp call_prompt(agent, :submit, content, opts), do: Sigma.Agent.prompt(agent, content, opts)
  defp call_prompt(agent, :steer, content, opts), do: Sigma.Agent.steer(agent, content, opts)
  defp call_prompt(agent, :follow_up, content, opts), do: Sigma.Agent.follow_up(agent, content, opts)

  defp prompt_opts(context, agent) do
    permission_resolver =
      case context[:interactive_approvals] do
        true -> &request_tool_permission(agent, &1)
        _mode -> context[:permission_resolver]
      end

    dispatcher_opts =
      []
      |> maybe_put_resolver(:permission_request_fn, permission_resolver)
      |> maybe_put_resolver(:ask_user_question_fn, context[:question_resolver])

    if dispatcher_opts == [], do: [], else: [dispatcher_opts: dispatcher_opts]
  end

  defp maybe_put_resolver(opts, _key, nil), do: opts
  defp maybe_put_resolver(opts, key, resolver) when is_function(resolver), do: Keyword.put(opts, key, resolver)
  defp maybe_put_resolver(opts, _key, _resolver), do: opts

  defp request_tool_permission(agent, tool_call) do
    request = %{
      kind: :permission,
      question: "Allow #{tool_call.name} for this tool call?",
      options: [
        %{label: "Allow once", value: "allow_once", description: "Run only this call"},
        %{label: "Deny once", value: "deny_once", description: "Do not run this call"}
      ],
      allow_freeform: false
    }

    case Sigma.Agent.ask_user_question(agent, request) do
      {:ok, "allow_once"} -> :allow
      {:ok, "deny_once"} -> {:deny, :denied_once}
      {:error, reason} -> {:deny, reason}
      _reply -> {:deny, :invalid_approval_response}
    end
  end

  defp admission_payload({status, info})
       when status in [:accepted, :queued_as_steering, :queued_as_follow_up] and is_map(info) do
    {:ok, Atom.to_string(status), %{"messageId" => info.message_id, "turnId" => info.turn_id}}
  end

  defp admission_payload({:rejected, reason}), do: {:error, {:prompt_rejected, reason}}
  defp admission_payload(_result), do: {:error, :invalid_admission_result}

  defp cancel_payload({status, turn_id})
       when status in [:cancelling, :already_cancelling, :already_cancelled],
    do: {:ok, %{"status" => Atom.to_string(status), "turnId" => turn_id}}

  defp cancel_payload({:error, reason}), do: {:error, reason}
  defp cancel_payload(_result), do: {:error, :invalid_cancel_result}

  defp permission_reply("allow"), do: {:ok, {:ok, "allow_once"}}
  defp permission_reply("deny"), do: {:ok, {:ok, "deny_once"}}
  defp permission_reply(_decision), do: {:error, :invalid_permission_decision}

  defp elicitation_reply(%{"action" => "accept", "content" => content}) when is_map(content),
    do: {:ok, {:accept, content}}

  defp elicitation_reply(%{"action" => "decline"}), do: {:ok, :decline}
  defp elicitation_reply(%{"action" => "cancel"}), do: {:ok, :cancel}
  defp elicitation_reply(_payload), do: {:error, :invalid_elicitation_response}

  defp read_only_artifact(command, context, operation) do
    with {:ok, repo_path, sessions_dir} <- paths(command, context),
         {:ok, storage_path} <- session_path(sessions_dir, command.session_id),
         requested_path when is_binary(requested_path) <- command.payload["outputPath"],
         :ok <- validate_protocol_replace(command.payload["replace"], context),
         {:ok, output_path} <- protocol_output_path(requested_path, repo_path, context),
         {:ok, ^output_path} <-
           apply(Sigma.Session.Log, operation, [
             storage_path,
             output_path,
             [replace: command.payload["replace"] == true]
           ]),
         {:ok, event} <-
           Envelope.event("session.snapshot", command.session_id, %{
             "artifact" => Atom.to_string(operation),
             "outputPath" => output_path
           }) do
      {:ok, event}
    else
      nil -> {:error, :missing_output_path}
      {:error, _reason} = error -> error
    end
  end

  defp status_event(session_id, agent) when is_pid(agent) do
    {:ok, event} =
      Envelope.event("session.snapshot", session_id, %{"turn" => agent_status(agent)})

    {:ok, event}
  end

  defp status_event(_session_id, _agent), do: {:error, :session_not_running}

  defp snapshot_event(session_id, snapshot, extra \\ %{}) do
    payload = Map.merge(ProtocolEventMapper.snapshot_payload(snapshot), extra)

    case Envelope.event("session.snapshot", session_id, payload) do
      {:ok, event} -> {:ok, event}
      {:error, _reason} = error -> error
    end
  end

  defp running_agent(command, context) do
    with {:ok, repo_path, _sessions_dir} <- paths(command, context),
         agent when is_pid(agent) <- Runtime.lookup(repo_path, command.session_id, :agent) do
      {:ok, agent}
    else
      nil -> {:error, :session_not_running}
      {:error, _reason} = error -> error
    end
  end

  defp paths(command, context) do
    repo_path = context[:repo_path] || command.payload["repoPath"]
    sessions_dir = context[:sessions_dir] || command.payload["sessionsDir"]

    if is_binary(repo_path) and is_binary(sessions_dir) do
      {:ok, Path.expand(repo_path), Path.expand(sessions_dir)}
    else
      {:error, :session_paths_required}
    end
  end

  defp session_path(sessions_dir, session_id) do
    apply(Sigma.Session.SessionFiles, :jsonl_path, [sessions_dir, session_id])
  end

  defp initial_model_opts(%{"providerId" => provider_id, "modelId" => model_id})
       when is_binary(provider_id) and is_binary(model_id),
       do: [model: {provider_id, model_id}]

  defp initial_model_opts(_payload), do: []

  defp create_snapshot(payload, cwd) do
    %{
      cwd: cwd,
      provider_id: payload["providerId"],
      model_id: payload["modelId"],
      messages: [],
      mcp_server_ids: []
    }
  end

  defp rollback_failed_create(sessions_dir, session_id, error) do
    case apply(Sigma.Session.SessionFiles, :delete, [sessions_dir, session_id]) do
      :ok -> error
      cleanup_error -> {:error, {:session_create_rollback_failed, error, cleanup_error}}
    end
  end

  defp create_cwd(cwd, _repo_path, %{allow_external_cwd: true}) when is_binary(cwd),
    do: {:ok, Path.expand(cwd)}

  defp create_cwd(cwd, repo_path, _context) when is_binary(cwd) do
    case Sigma.Coding.Utils.PathUtils.safe_resolve(cwd, repo_path) do
      {:ok, resolved} -> {:ok, resolved}
      {:error, _reason} -> {:error, :cwd_outside_repository}
    end
  end

  defp create_cwd(_cwd, _repo_path, _context), do: {:error, :invalid_cwd}

  defp validate_protocol_replace(true, %{allow_artifact_replace: true}), do: :ok
  defp validate_protocol_replace(true, _context), do: {:error, :artifact_replace_not_allowed}
  defp validate_protocol_replace(_replace, _context), do: :ok

  defp protocol_output_path(requested_path, repo_path, context) do
    root = Path.expand(context[:artifact_root] || repo_path)

    case Sigma.Coding.Utils.PathUtils.safe_resolve(requested_path, root) do
      {:ok, output_path} -> {:ok, output_path}
      {:error, _reason} -> {:error, :artifact_path_outside_root}
    end
  end

  defp require_session_header(%{header: header}) when is_map(header), do: :ok
  defp require_session_header(_snapshot), do: {:error, :missing_session_header}

  defp agent_status(repo_path, session_id) do
    case Runtime.lookup(repo_path, session_id, :agent) do
      agent when is_pid(agent) -> agent_status(agent)
      nil -> %{"phase" => "stopped"}
    end
  end

  defp agent_status(agent) do
    status = Sigma.Agent.status(agent)

    %{
      "phase" => Atom.to_string(status.phase),
      "turnId" => status.turn_id,
      "steeringQueueCount" => status.steering_queue_count,
      "followUpQueueCount" => status.follow_up_queue_count
    }
  end

  defp public_runtime_status(status) do
    %{
      "status" => status |> Map.get(:status, :unknown) |> to_string(),
      "messageCount" => Map.get(status, :message_count),
      "eventCount" => Map.get(status, :event_count)
    }
  end

  defp error_event(command, reason) do
    error = ProtocolEventMapper.public_error(reason)
    turn_id = if is_struct(command, Envelope), do: command.turn_id, else: nil
    session_id = if is_struct(command, Envelope), do: command.session_id, else: "unknown"

    {:ok, event} =
      Envelope.event("session.error", session_id, %{}, turn_id: turn_id, error: error)

    event
  end
end
