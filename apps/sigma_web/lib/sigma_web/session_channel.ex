defmodule Sigma.Web.SessionChannel do
  @moduledoc "Phoenix Channel adapter for the shared Protocol V1 command boundary."

  use Phoenix.Channel

  alias Sigma.Agent.{ProtocolSubscription, PublicRuntime}
  alias Sigma.Protocol.{Codec, Envelope, Error}
  alias Sigma.Session.SessionFiles

  @impl true
  def join("session:" <> session_id, _payload, socket) do
    if SessionFiles.valid_session_id?(session_id) do
      {:ok, assign(socket, session_id: session_id, subscription_ids: MapSet.new())}
    else
      {:error, %{reason: "invalid_session_id"}}
    end
  end

  @impl true
  def handle_in("command", %{"data" => encoded}, socket) when is_binary(encoded) do
    case Codec.decode(encoded) do
      {:ok, %Envelope{kind: :command, session_id: session_id} = command}
      when session_id == socket.assigns.session_id ->
        {result, socket} = execute_command(command, socket)
        push_result(socket, result)
        {:noreply, socket}

      {:ok, %Envelope{kind: :command}} ->
        push_result(socket, {:error, protocol_error(socket, "session_mismatch")})
        {:noreply, socket}

      {:ok, %Envelope{}} ->
        push_result(socket, {:error, protocol_error(socket, "command_required")})
        {:noreply, socket}

      {:error, _reason} ->
        push_result(socket, {:error, protocol_error(socket, "decode_failed")})
        {:noreply, socket}
    end
  end

  def handle_in("command", _payload, socket) do
    push_result(socket, {:error, protocol_error(socket, "invalid_command_payload")})
    {:noreply, socket}
  end

  @impl true
  def handle_info({:sigma_protocol, _subscription_id, %Envelope{} = event}, socket) do
    push_result(socket, {:ok, event})
    {:noreply, socket}
  end

  @impl true
  def terminate(_reason, socket) do
    Enum.each(socket.assigns[:subscription_ids] || [], fn subscription_id ->
      ProtocolSubscription.detach(subscription_id, self())
    end)

    :ok
  end

  defp execute_command(command, socket) do
    context = %{
      repo_path: socket.assigns.workdir,
      sessions_dir: socket.assigns.sessions_dir,
      subscriber: self(),
      interactive_approvals: true,
      session_opts: protocol_session_opts(socket)
    }

    result = PublicRuntime.execute(command, context)
    {result, track_subscription(socket, command, result)}
  end

  defp protocol_session_opts(socket) do
    case Application.get_env(:sigma_web, :protocol_session_opts) do
      opts when is_list(opts) -> opts
      resolver when is_function(resolver, 1) -> resolver
      _opts ->
        fn snapshot ->
          Sigma.Web.ProtocolSessionOptions.resolve(
            snapshot,
            socket.assigns.workdir,
            socket.assigns.sessions_dir,
            socket.assigns.session_id
          )
        end
    end
  end

  defp track_subscription(
         socket,
         %Envelope{type: "subscription.attach"},
         {:ok, %Envelope{payload: %{"subscriptionId" => subscription_id}}}
       ) do
    assign(
      socket,
      :subscription_ids,
      MapSet.put(socket.assigns.subscription_ids, subscription_id)
    )
  end

  defp track_subscription(
         socket,
         %Envelope{type: "subscription.detach"},
         {:ok, %Envelope{payload: %{"subscriptionId" => subscription_id}}}
       ) do
    assign(
      socket,
      :subscription_ids,
      MapSet.delete(socket.assigns.subscription_ids, subscription_id)
    )
  end

  defp track_subscription(socket, _command, _result), do: socket

  defp push_result(socket, {_status, %Envelope{} = event}) do
    case Codec.encode(event) do
      {:ok, encoded} -> push(socket, "event", %{"data" => encoded})
      {:error, reason} -> push_encode_error(socket, reason)
    end
  end

  defp push_encode_error(socket, reason) do
    error = Error.new("envelope_encode_failed", "The protocol response exceeded transport bounds.")

    {:ok, event} =
      Envelope.event("session.error", socket.assigns.session_id, %{
        "reason" => if(is_atom(reason), do: Atom.to_string(reason), else: "encoding_failed")
      }, error: error)

    {:ok, encoded} = Codec.encode(event)
    push(socket, "event", %{"data" => encoded})
  end

  defp protocol_error(socket, code) do
    error = Error.new(code, "The WebSocket protocol command failed.")

    {:ok, event} =
      Envelope.event("session.error", socket.assigns.session_id, %{}, error: error)

    event
  end
end
