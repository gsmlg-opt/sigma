defmodule Sigma.Agent.Stdio do
  @moduledoc "JSON Lines Protocol V1 adapter for headless automation."

  alias Sigma.Agent.PublicRuntime
  alias Sigma.Protocol.{Codec, Envelope, Error}

  @default_linger_ms 250

  def run(input \\ :stdio, output \\ :stdio, context \\ %{}) when is_map(context) do
    owner = self()
    reader = spawn_link(fn -> read_lines(input, owner) end)

    loop(%{
      context: Map.put(context, :subscriber, owner),
      linger_ms: Map.get(context, :stdio_linger_ms, @default_linger_ms),
      output: output,
      reader: reader
    })
  end

  defp read_lines(input, owner) do
    case IO.read(input, :line) do
      :eof -> send(owner, {:stdio_eof, self()})
      {:error, reason} -> send(owner, {:stdio_read_error, self(), reason})
      line when is_binary(line) ->
        send(owner, {:stdio_line, self(), line})
        read_lines(input, owner)
    end
  end

  defp loop(state) do
    receive do
      {:stdio_line, reader, line} when reader == state.reader ->
        line |> String.trim() |> handle_line(state)
        loop(state)

      {:sigma_protocol, _subscription_id, %Envelope{} = event} ->
        write_event(state.output, event)
        loop(state)

      {:stdio_eof, reader} when reader == state.reader ->
        linger(state, System.monotonic_time(:millisecond) + state.linger_ms)

      {:stdio_read_error, reader, reason} when reader == state.reader ->
        write_protocol_error(state.output, {:stdio_read_error, reason})
        {:error, :stdio_read_failed}
    end
  end

  defp linger(state, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:sigma_protocol, _subscription_id, %Envelope{} = event} ->
        write_event(state.output, event)
        linger(state, deadline)
    after
      remaining -> :ok
    end
  end

  defp handle_line("", _state), do: :ok

  defp handle_line(line, state) do
    case Codec.decode(line) do
      {:ok, %Envelope{kind: :command} = command} ->
        case PublicRuntime.execute(command, state.context) do
          {:ok, event} -> write_event(state.output, event)
          {:error, %Envelope{} = event} -> write_event(state.output, event)
          {:error, reason} -> write_protocol_error(state.output, reason)
        end

      {:ok, %Envelope{}} ->
        write_protocol_error(state.output, :command_required)

      {:error, reason} ->
        write_protocol_error(state.output, reason)
    end
  end

  defp write_protocol_error(output, reason) do
    error = Error.new("protocol_decode_error", "The protocol command could not be decoded.")

    {:ok, event} =
      Envelope.event("session.error", "unknown", %{"reason" => reason_code(reason)}, error: error)

    write_event(output, event)
  end

  defp write_event(output, event) do
    case Codec.encode(event) do
      {:ok, encoded} -> IO.binwrite(output, encoded <> "\n")
      {:error, reason} -> write_protocol_error(output, {:encode_failed, reason})
    end
  end

  defp reason_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_code({reason, _detail}) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_code(_reason), do: "invalid_command"
end
