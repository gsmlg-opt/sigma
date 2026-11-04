defmodule Sigma.Ai.ResponsesCancellation do
  @moduledoc """
  Best-effort cancellation owned outside the stream worker. Only explicit user
  cancellation calls `request/1`; disconnects and worker exits never do so.
  Outcomes are available for five minutes and emitted as telemetry. This is
  process-local state, not a durable cancellation queue.
  """
  use GenServer
  alias Sigma.Ai.ProviderError

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def validate!(options) do
    case options[:responses_cancel] do
      nil ->
        :ok

      %{capability: :openai_background_cancel_v1} = config ->
        timeout = Map.get(config, :timeout_ms, 5_000)

        unless options[:background] == true and is_integer(timeout) and timeout in 1..30_000 do
          invalid!()
        end

      _ ->
        invalid!()
    end
  end

  defp invalid! do
    raise ProviderError,
      kind: :invalid_request,
      retryable: false,
      message:
        "Responses cancellation requires background:true and an explicitly supported cancel capability (timeout 1..30000ms)"
  end

  def register(options, base_url, headers) do
    validate!(options)
    token = make_ref()
    ref = options[:cancellation_ref] || token

    entry = %{
      ref: ref,
      owner: self(),
      monitor: nil,
      id: nil,
      background: false,
      terminal: nil,
      supported: not is_nil(options[:responses_cancel]),
      url: String.trim_trailing(base_url, "/"),
      headers: headers,
      timeout: get_in(options, [:responses_cancel, :timeout_ms]) || 5_000,
      result: nil,
      listeners: [],
      task: nil
    }

    case GenServer.call(__MODULE__, {:register, token, entry}) do
      :ok ->
        token

      :cancelled ->
        raise ProviderError,
          kind: :cancelled,
          retryable: false,
          message: "Turn was cancelled before submission"
    end
  end

  def observe(token, %{"response" => response} = event) when is_map(response),
    do: GenServer.call(__MODULE__, {:observe, token, event})

  def observe(_, _), do: :ok
  def release(token), do: GenServer.cast(__MODULE__, {:release, token})

  def request(ref, listener \\ nil)
  def request(nil, _listener), do: :ok

  def request(ref, listener) do
    GenServer.call(__MODULE__, {:request, ref, listener})
  catch
    :exit, _ ->
      if listener, do: deliver(listener, %{outcome: :unknown, reason: :coordinator_unavailable})
      {:error, :cancellation_unavailable}
  end

  def result(ref) do
    GenServer.call(__MODULE__, {:result, ref})
  catch
    :exit, _ -> [%{outcome: :unknown, reason: :coordinator_unavailable}]
  end

  def local_error(token, recovery) do
    error = Sigma.Ai.ResponsesRecovery.cancelled(recovery)

    %{
      error
      | message:
          "Local stream cancelled; upstream cancellation is best-effort and may remain unconfirmed.",
        raw:
          Map.merge(error.raw || %{}, %{upstream_cancelled: :unknown, cancellation: result(token)})
    }
  end

  @impl true
  def format_status(status), do: %{status | state: :redacted, message: :redacted}

  @impl true
  def init(_), do: {:ok, %{entries: %{}, cancelled: MapSet.new()}}

  @impl true
  def handle_call({:register, token, entry}, _, state) do
    if MapSet.member?(state.cancelled, entry.ref) do
      {:reply, :cancelled, state}
    else
      entry = %{entry | monitor: Process.monitor(entry.owner)}
      {:reply, :ok, put_in(state, [:entries, token], entry)}
    end
  end

  def handle_call({:observe, token, event}, _, state) do
    state =
      update_in(state, [:entries, token], fn
        nil ->
          nil

        entry ->
          response = event["response"] || %{}
          id = response["id"]

          if is_binary(id) and id != "" and (is_nil(entry.id) or entry.id == id) do
            terminal =
              case response["status"] do
                status when status in ["completed", "failed", "incomplete", "cancelled"] -> status
                _ -> entry.terminal
              end

            updated = %{
              entry
              | id: id,
                background: entry.background or response["background"] == true,
                terminal: terminal
            }

            cond do
              entry.result && entry.result[:reason] in [:missing_id, :background_unconfirmed] ->
                cancel(token, updated)

              terminal ->
                %{updated | headers: []}

              true ->
                updated
            end
          else
            entry
          end
      end)

    {:reply, :ok, state}
  end

  def handle_call({:request, ref, listener}, _, state) do
    Process.send_after(self(), {:forget, ref}, 300_000)

    entries =
      Map.new(state.entries, fn {token, entry} ->
        if entry && (entry.ref == ref or token == ref) do
          listeners =
            if listener, do: Enum.uniq([listener | entry.listeners]), else: entry.listeners

          entry = %{entry | listeners: listeners}
          previous = entry.result
          entry = if is_nil(previous), do: cancel(token, entry), else: entry

          if listener && (previous != nil || entry.result[:outcome] == :pending),
            do: deliver(listener, entry.result)

          {token, entry}
        else
          {token, entry}
        end
      end)

    if listener &&
         not Enum.any?(entries, fn {token, e} -> e && (e.ref == ref or token == ref) end),
       do: deliver(listener, %{outcome: :unknown, reason: :missing_checkpoint})

    {:reply, :ok, %{state | entries: entries, cancelled: MapSet.put(state.cancelled, ref)}}
  end

  def handle_call({:result, ref}, _, state) do
    results =
      for {token, entry} <- state.entries,
          entry && (entry.ref == ref or token == ref),
          do: entry.result

    results =
      if results == [], do: [%{outcome: :unknown, reason: :missing_checkpoint}], else: results

    {:reply, results, state}
  end

  defp cancel(token, entry) do
    cond do
      entry.terminal ->
        finish(entry, %{outcome: :already_terminal, status: entry.terminal})

      not entry.supported ->
        finish(entry, %{outcome: :unsupported})

      is_nil(entry.id) ->
        finish(entry, %{outcome: :unknown, reason: :missing_id})

      not entry.background ->
        finish(entry, %{outcome: :unknown, reason: :background_unconfirmed})

      true ->
        parent = self()

        {:ok, pid} =
          Task.Supervisor.start_child(Sigma.Ai.ProviderTaskSupervisor, fn ->
            result = cancel_http(entry)
            send(parent, {:cancel_result, token, result})
          end)

        timer = Process.send_after(self(), {:cancel_timeout, token}, entry.timeout)
        %{entry | task: {pid, timer}, result: %{outcome: :pending}}
    end
  end

  defp cancel_http(entry) do
    url = entry.url <> "/responses/" <> URI.encode(entry.id, &URI.char_unreserved?/1) <> "/cancel"

    case Req.post(url,
           headers: entry.headers,
           json: %{},
           retry: false,
           redirect: false,
           receive_timeout: entry.timeout
         ) do
      {:ok, %{status: status, body: %{"id" => id, "status" => result}}}
      when status in 200..299 and id == entry.id ->
        case result do
          "cancelled" ->
            %{outcome: :confirmed, status: result}

          terminal when terminal in ["completed", "failed", "incomplete"] ->
            %{outcome: :already_terminal, status: terminal}

          _ ->
            %{outcome: :unknown, reason: :unconfirmed_status}
        end

      {:ok, %{status: status}} when status in 200..299 ->
        %{outcome: :unknown, reason: :invalid_response}

      {:ok, %{status: status}} ->
        %{outcome: :failed, http_status: status}

      {:error, _} ->
        %{outcome: :unknown, reason: :transport}
    end
  rescue
    _ -> %{outcome: :unknown, reason: :request_failed}
  end

  defp deliver({pid, tag}, result) when is_pid(pid),
    do: send(pid, {:upstream_cancel_result, tag, result})

  defp finish(entry, result) do
    result = Map.put(result, :response_id, entry.id)
    :telemetry.execute([:sigma, :llm, :upstream_cancel, :stop], %{}, result)
    Enum.each(entry.listeners, &deliver(&1, result))

    headers =
      if result[:reason] in [:missing_id, :background_unconfirmed], do: entry.headers, else: []

    %{entry | result: result, headers: headers, task: nil}
  end

  @impl true
  def handle_cast({:release, token}, state) do
    Process.send_after(self(), {:expire, token}, 300_000)
    {:noreply, state}
  end

  @impl true
  def handle_info({:cancel_result, token, result}, state) do
    {:noreply,
     update_in(state, [:entries, token], fn
       %{task: {_, timer}} = entry ->
         Process.cancel_timer(timer)
         finish(entry, result)

       entry ->
         entry
     end)}
  end

  def handle_info({:cancel_timeout, token}, state) do
    {:noreply,
     update_in(state, [:entries, token], fn
       %{task: {pid, _}} = entry ->
         Process.exit(pid, :kill)
         finish(entry, %{outcome: :unknown, reason: :timeout})

       entry ->
         entry
     end)}
  end

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    for {token, %{monitor: ^monitor}} <- state.entries do
      Process.send_after(self(), {:expire, token}, 300_000)
    end

    {:noreply, state}
  end

  def handle_info({:expire, token}, state) do
    case state.entries[token] do
      %{task: {_, _}} ->
        Process.send_after(self(), {:expire, token}, 30_000)
        {:noreply, state}

      entry ->
        if entry, do: Process.demonitor(entry.monitor, [:flush])
        {:noreply, %{state | entries: Map.delete(state.entries, token)}}
    end
  end

  def handle_info({:forget, ref}, state),
    do: {:noreply, %{state | cancelled: MapSet.delete(state.cancelled, ref)}}
end
