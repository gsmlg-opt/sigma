defmodule Sigma.Agent.Hooks.ModelRequest do
  @moduledoc false

  alias Sigma.Agent.Hooks
  alias Sigma.Ai.ProviderUsage

  def start(specs, context, request) do
    if Enum.any?(specs, &(&1.event in [:pre_model_request, :post_model_request])) do
      worker = self()

      observer =
        spawn(fn ->
          monitor = Process.monitor(worker)

          receive do
            :registered -> observe(monitor, specs, context, request, false)
            {:DOWN, ^monitor, :process, ^worker, _reason} -> :ok
          end
        end)

      case track(context[:hook_async_runtime], observer) do
        :ok ->
          send(observer, :registered)
          Hooks.dispatch(:pre_model_request, specs, context)
          observer

        {:error, :closed} ->
          Process.exit(observer, :kill)
          nil
      end
    end
  end

  defp track(runtime, observer) when is_pid(runtime),
    do: Sigma.Coding.Hooks.AsyncRuntime.track(runtime, observer)

  defp track(_runtime, _observer), do: :ok

  def progress(nil, _request), do: :ok
  def progress(observer, request), do: send(observer, {:progress, request})

  def finish(observer, request, error \\ nil)
  def finish(nil, _request, _error), do: :ok

  def finish(observer, request, error) do
    ref = make_ref()
    monitor = Process.monitor(observer)
    send(observer, {:finish, self(), ref, request, error})

    receive do
      {^ref, :ok} -> Process.demonitor(monitor, [:flush])
      {:DOWN, ^monitor, :process, ^observer, _reason} -> :ok
    end
  end

  defp observe(monitor, specs, context, request, finished?) do
    receive do
      {:progress, request} ->
        observe(monitor, specs, context, request, finished?)

      {:finish, from, ref, request, error} ->
        unless finished?, do: dispatch(specs, context, request, error)
        send(from, {ref, :ok})
        observe(monitor, specs, context, request, true)

      {:DOWN, ^monitor, :process, _worker, _reason} ->
        unless finished?, do: dispatch(specs, context, %{request | status: :cancelled}, nil)
    end
  end

  defp dispatch(specs, context, request, error) do
    status = if request.status == :running, do: :cancelled, else: request.status

    Hooks.dispatch(:post_model_request, specs, context, %{
      status: status,
      error: error_text(error),
      token_usage: token_usage(request.usage)
    })
  end

  defp token_usage(%ProviderUsage{usage_status: :unknown}), do: nil

  defp token_usage(%ProviderUsage{} = usage) do
    %{
      input_tokens: usage.input_tokens || 0,
      cached_input_tokens: usage.cache_read_tokens || 0,
      output_tokens: usage.output_tokens || 0,
      reasoning_output_tokens: usage.reasoning_tokens || 0,
      total_tokens: usage.total_tokens || 0
    }
  end

  defp token_usage(_), do: nil
  defp error_text(nil), do: nil

  defp error_text(error) do
    if is_exception(error), do: Exception.message(error), else: inspect(error)
  end
end
