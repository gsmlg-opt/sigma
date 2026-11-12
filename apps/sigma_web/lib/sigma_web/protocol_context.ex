defmodule Sigma.Web.ProtocolContext do
  @moduledoc "Builds the PublicRuntime context and prepares commands for Protocol V1 hosts."

  alias Sigma.Protocol.Envelope
  alias Sigma.Session.{SkillExpander, SkillInvocationStore}

  @type scope :: %{
          workdir: String.t(),
          sessions_dir: String.t(),
          session_id: String.t(),
          subscriber: pid()
        }

  @spec build(scope(), keyword()) :: map()
  def build(%{workdir: workdir, sessions_dir: sessions_dir, session_id: session_id} = scope, opts) do
    context = %{
      repo_path: workdir,
      sessions_dir: sessions_dir,
      subscriber: scope.subscriber,
      interactive_approvals: Keyword.get(opts, :interactive_approvals, true),
      session_opts: session_opts(scope, Keyword.get(opts, :initial_metadata)),
      session_id: session_id,
      skill_invocation_store: %{
        find: fn session_id, request_key ->
          SkillInvocationStore.find(sessions_dir, session_id, request_key)
        end,
        list: fn session_id ->
          SkillInvocationStore.list(sessions_dir, session_id)
        end,
        reserve: fn session_id, record ->
          SkillInvocationStore.reserve(sessions_dir, session_id, record)
        end,
        update: fn session_id, invocation_id, changes ->
          SkillInvocationStore.update(sessions_dir, session_id, invocation_id, changes)
        end
      },
      skill_expander: &SkillExpander.expand/2
    }

    Map.merge(context, Sigma.Agent.SkillInvocationService.callbacks(context))
  end

  @spec prepare(Envelope.t(), String.t()) :: {:ok, Envelope.t()} | {:error, term()}
  def prepare(%Envelope{type: "session.create"} = command, _workdir) do
    with {:ok, payload} <- Sigma.Web.ProtocolSessionOptions.prepare_create(command.payload),
         do: {:ok, %{command | payload: payload}}
  end

  def prepare(%Envelope{type: type} = command, workdir)
      when type in [
             "prompt.submit",
             "prompt.steer",
             "prompt.follow_up",
             "skill.invoke",
             "session.retry"
           ] do
    case Sigma.Agent.Runtime.lookup(workdir, command.session_id, :agent) do
      nil ->
        {:ok, command}

      agent ->
        with :ok <- Sigma.Web.ProtocolSessionOptions.validate_agent_model(agent),
             do: {:ok, command}
    end
  end

  def prepare(command, _workdir), do: {:ok, command}

  defp session_opts(scope, initial_metadata) do
    case Application.get_env(:sigma_web, :protocol_session_opts) do
      opts when is_list(opts) ->
        opts

      resolver when is_function(resolver, 1) ->
        resolver

      _opts ->
        fn snapshot ->
          Sigma.Web.ProtocolSessionOptions.resolve(
            snapshot,
            scope.workdir,
            scope.sessions_dir,
            scope.session_id,
            initial_metadata
          )
        end
    end
  end
end
