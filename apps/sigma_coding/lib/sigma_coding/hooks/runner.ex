defmodule Sigma.Coding.Hooks.Runner do
  @moduledoc """
  Runs Codex command/MCP hooks with separate output streams and absolute deadlines.

  Sessions supply ctx[:hook_async_runtime] to queue async commands with session
  ownership and a concurrency limit. Standalone callers without it run directly
  under the task supervisor without session ownership or that limit.
  Async control directives are ignored; the host may consume later context/diagnostics with
  ctx[:hook_async_callback] (arity 2: context text or nil, warnings).

  Host adaptation: Unix subprocess ownership uses setsid process groups. Hosts
  without setsid report an execution error instead of running an unowned command.
  Output capture is bounded to 1 MB per stream; context uses Outcome's host limit.
  """

  alias Sigma.Coding.Hooks.{AsyncRuntime, Matcher, Outcome, Payload, Spec, Trust}
  alias Sigma.Coding.Hooks.Spec.{Command, McpTool}

  @max_output_bytes 1_000_000

  def run(event, specs, ctx, event_data \\ %{}) do
    payload = Payload.build(event, ctx, event_data)
    match_context = Map.merge(ctx, event_data)

    {selected, skipped} =
      Enum.reduce(specs, {[], []}, fn spec, {selected, warnings} ->
        cond do
          spec.event != event or not Matcher.match?(spec, match_context) ->
            {selected, warnings}

          spec.unsupported_reason != nil ->
            {selected, warnings ++ ["Skipping hook: #{spec.unsupported_reason}"]}

          not Trust.trusted?(spec) ->
            {selected, warnings ++ ["Skipping untrusted project hook: approve it first"]}

          match?(%Command{}, spec.handler) or match?(%McpTool{}, spec.handler) ->
            {selected ++ [spec], warnings}

          true ->
            {selected, warnings ++ ["Skipping unsupported hook handler."]}
        end
      end)

    {async, sync} = Enum.split_with(selected, &async?/1)
    background_warnings = Enum.flat_map(async, &schedule_async(&1, event, payload, ctx))

    {outcomes, warnings} =
      sync
      |> Task.async_stream(fn spec -> execute(spec, payload, ctx) end,
        max_concurrency: max(length(sync), 1),
        timeout: :infinity,
        ordered: false
      )
      |> Enum.reduce({[], []}, fn
        {:ok, {:ok, raw, spec}}, {outcomes, warnings} ->
          {outcome, diagnostics} = Outcome.evaluate(event, raw, spec.dialect)
          emit(event, spec, outcome, diagnostics)
          {outcomes ++ [outcome], warnings ++ diagnostics}

        {:ok, {:error, reason, spec}}, {outcomes, warnings} ->
          emit(event, spec, :proceed, [reason])
          {outcomes, warnings ++ [reason]}

        {:exit, reason}, {outcomes, warnings} ->
          {outcomes, warnings ++ ["Hook crashed: #{inspect(reason)}"]}
      end)

    {Outcome.fold(outcomes), skipped ++ background_warnings ++ warnings}
  end

  defp async?(%Spec{event: :session_end}), do: false
  defp async?(%Spec{handler: %Command{async: async}}), do: async
  defp async?(_), do: false

  defp schedule_async(spec, event, payload, ctx) do
    fun = fn ->
      {outcome, warnings} =
        case execute(spec, payload, ctx) do
          {:ok, raw, _spec} -> Outcome.evaluate_async(event, raw, spec.dialect)
          {:error, reason, _spec} -> {:proceed, [reason]}
        end

      emit(event, spec, :proceed, warnings)

      if is_function(ctx[:hook_async_callback], 2),
        do: ctx.hook_async_callback.(Outcome.context(outcome), warnings)
    end

    if is_pid(ctx[:hook_async_runtime]) do
      AsyncRuntime.schedule(ctx.hook_async_runtime, fun)
      []
    else
      supervisor = Map.get(ctx, :hook_task_supervisor, Sigma.Coding.Dispatcher.TaskSupervisor)

      case Task.Supervisor.start_child(supervisor, fun) do
        {:ok, _pid} -> []
        {:error, reason} -> ["Could not start async hook: #{inspect(reason)}"]
      end
    end
  catch
    :exit, reason -> ["Could not start async hook: #{inspect(reason)}"]
  end

  defp execute(%Spec{handler: %Command{} = command} = spec, payload, ctx) do
    case command(command, payload, ctx) do
      {:ok, raw} -> {:ok, raw, spec}
      {:error, reason} -> {:error, reason, spec}
    end
  end

  defp execute(%Spec{handler: %McpTool{} = handler} = spec, payload, ctx) do
    with executor when is_function(executor, 4) <- ctx[:mcp_hook_executor],
         {:ok, input} <- expand_input(handler.input, payload) do
      task =
        Task.Supervisor.async(
          Map.get(ctx, :hook_task_supervisor, Sigma.Coding.Dispatcher.TaskSupervisor),
          fn ->
            try do
              executor.(handler.server, handler.tool, input, handler.timeout_ms)
            rescue
              error -> {:error, Exception.message(error)}
            catch
              kind, reason -> {:error, {kind, reason}}
            end
          end
        )

      result = Task.yield(task, handler.timeout_ms) || Task.shutdown(task, :brutal_kill)

      case result do
        {:ok, {:ok, raw}} when is_map(raw) -> {:ok, raw, spec}
        {:ok, {:error, reason}} -> {:error, "MCP hook failed: #{inspect(reason)}", spec}
        nil -> {:error, "MCP hook timed out.", spec}
        other -> {:error, "MCP hook failed: #{inspect(other)}", spec}
      end
    else
      nil -> {:error, "MCP hook executor is not connected.", spec}
      {:error, reason} -> {:error, reason, spec}
      _ -> {:error, "MCP hook executor is not connected.", spec}
    end
  rescue
    error -> {:error, Exception.message(error), spec}
  end

  defp command(handler, payload, ctx) do
    owner = self()
    supervisor = Map.get(ctx, :hook_task_supervisor, Sigma.Coding.Dispatcher.TaskSupervisor)

    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        Process.flag(:trap_exit, true)
        owner_ref = Process.monitor(owner)
        run_command(handler, payload, ctx, owner_ref)
      end)

    case Task.yield(task, :infinity) do
      {:ok, result} -> result
      {:exit, reason} -> {:error, "Hook process worker failed: #{inspect(reason)}"}
    end
  end

  defp run_command(handler, payload, ctx, owner_ref) do
    with setsid when is_binary(setsid) <- System.find_executable("setsid"),
         killer when is_binary(killer) <- System.find_executable("kill") do
      directory =
        Path.join(
          System.tmp_dir!(),
          "sigma-hook-" <> Base.encode16(:crypto.strong_rand_bytes(12))
        )

      File.mkdir!(directory)
      File.chmod!(directory, 0o700)
      stdin_path = Path.join(directory, "stdin.json")
      stderr_path = Path.join(directory, "stderr")
      File.write!(stdin_path, Jason.encode!(payload))
      File.write!(stderr_path, "")

      try do
        shell = ctx[:hook_shell] || System.get_env("SHELL") || "/bin/sh"
        # The child cannot execute until the owner knows its process group. If
        # cancelled before readiness, closing the port gives read EOF instead.
        script =
          ~S(printf 'sigma-hook-ready:%s\n' "$$" || exit 1; IFS= read -r signal || exit 1; [ "$signal" = run ] || exit 1; exec "$1" -c "$2" < "$3" 2> "$4")

        port =
          Port.open({:spawn_executable, setsid}, [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: [
              "--fork",
              "--wait",
              "/bin/sh",
              "-c",
              script,
              "sigma-hook",
              shell,
              handler.cmd,
              stdin_path,
              stderr_path
            ],
            cd: ctx[:cwd] || File.cwd!()
          ])

        {:os_pid, os_pid} = Port.info(port, :os_pid)

        try do
          deadline = System.monotonic_time(:millisecond) + handler.timeout_ms

          case await_ready(port, deadline, owner_ref, "") do
            {:ok, process_group} ->
              collect_started(
                port,
                process_group,
                os_pid,
                killer,
                stderr_path,
                deadline,
                owner_ref,
                handler.timeout_ms
              )

            :timeout ->
              cleanup_processes(killer, nil, os_pid)
              {:error, "Hook timed out after #{handler.timeout_ms}ms."}

            :cancelled ->
              cleanup_processes(killer, nil, os_pid)
              {:error, "Hook cancelled."}

            {:error, reason} ->
              cleanup_processes(killer, nil, os_pid)
              {:error, reason}
          end
        after
          if Port.info(port), do: Port.close(port)
        end
      after
        File.rm_rf(directory)
      end
    else
      _ -> {:error, "Hook execution requires setsid and kill for managed subprocess cleanup."}
    end
  rescue
    error -> {:error, "Hook execution failed: #{Exception.message(error)}"}
  end

  defp await_ready(port, deadline, owner_ref, output) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    if remaining == 0 do
      :timeout
    else
      receive do
        {^port, {:data, chunk}} ->
          output = output <> chunk

          cond do
            byte_size(output) > 100 ->
              {:error, "Hook process did not publish a valid startup identity."}

            String.contains?(output, "\n") ->
              case Regex.run(~r/\Asigma-hook-ready:([0-9]+)\n\z/, output) do
                [_, pid] -> {:ok, String.to_integer(pid)}
                _ -> {:error, "Hook process did not publish a valid startup identity."}
              end

            true ->
              await_ready(port, deadline, owner_ref, output)
          end

        {^port, {:exit_status, exit}} ->
          {:error, "Hook process exited before startup with code #{exit}."}

        {:DOWN, ^owner_ref, :process, _pid, _reason} ->
          :cancelled

        {:EXIT, _pid, _reason} ->
          :cancelled
      after
        remaining -> :timeout
      end
    end
  end

  defp collect_started(
         port,
         process_group,
         os_pid,
         killer,
         stderr_path,
         deadline,
         owner_ref,
         timeout_ms
       ) do
    try do
      true = Port.command(port, "run\n")

      case collect(port, deadline, "", owner_ref) do
        {:ok, exit, stdout} ->
          {:ok,
           %{exit: exit, stdout: String.replace_invalid(stdout), stderr: read_output(stderr_path)}}

        :timeout ->
          cleanup_processes(killer, process_group, os_pid)
          {:error, "Hook timed out after #{timeout_ms}ms."}

        :cancelled ->
          cleanup_processes(killer, process_group, os_pid)
          {:error, "Hook cancelled."}
      end
    catch
      kind, reason ->
        cleanup_processes(killer, process_group, os_pid)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp cleanup_processes(killer, process_group, os_pid) do
    if is_integer(process_group) and process_group > 0,
      do: System.cmd(killer, ["-KILL", "--", "-#{process_group}"], stderr_to_stdout: true)

    System.cmd(killer, ["-KILL", "--", "#{os_pid}"], stderr_to_stdout: true)
  end

  defp collect(port, deadline, output, owner_ref) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    if remaining == 0 do
      :timeout
    else
      receive do
        {^port, {:data, chunk}} ->
          room = max(@max_output_bytes - byte_size(output), 0)

          collect(
            port,
            deadline,
            output <> binary_part(chunk, 0, min(byte_size(chunk), room)),
            owner_ref
          )

        {^port, {:exit_status, exit}} ->
          {:ok, exit, output}

        {:DOWN, ^owner_ref, :process, _pid, _reason} ->
          :cancelled

        {:EXIT, _pid, _reason} ->
          :cancelled
      after
        remaining -> :timeout
      end
    end
  end

  defp read_output(path) do
    case File.open(path, [:read, :binary]) do
      {:ok, file} ->
        try do
          case IO.binread(file, @max_output_bytes) do
            :eof -> ""
            data when is_binary(data) -> String.replace_invalid(data)
            _ -> ""
          end
        after
          File.close(file)
        end

      _ ->
        ""
    end
  end

  defp expand_input(template, payload) do
    {:ok, resolve(template, payload)}
  rescue
    error in ArgumentError -> {:error, Exception.message(error)}
  end

  defp resolve(value, payload) when is_map(value),
    do: Map.new(value, fn {key, item} -> {key, resolve(item, payload)} end)

  defp resolve(value, payload) when is_list(value), do: Enum.map(value, &resolve(&1, payload))

  defp resolve(value, payload) when is_binary(value) do
    pattern = ~r/\$\{([^{}]+)\}/

    case Regex.run(~r/^\$\{([^{}]+)\}$/, value) do
      [_, path] ->
        resolve_path(payload, path)

      nil ->
        Regex.replace(pattern, value, fn _match, path ->
          case resolve_path(payload, path) do
            text when is_binary(text) -> text
            other -> Jason.encode!(other)
          end
        end)
    end
  end

  defp resolve(value, _payload), do: value

  defp resolve_path(payload, path) do
    Enum.reduce(String.split(path, "."), payload, fn key, value ->
      case value do
        %{^key => item} -> item
        _ -> raise ArgumentError, "Hook input placeholder `\${#{path}}` was not found."
      end
    end)
  end

  defp emit(event, spec, outcome, warnings) do
    {origin, _} = spec.origin || {:unknown, ""}

    :telemetry.execute([:sigma, :hook, :run, :stop], %{}, %{
      event: event,
      origin: origin,
      dialect: spec.dialect,
      decision:
        case Outcome.control(outcome) do
          value when is_atom(value) -> value
          {tag, _} -> tag
        end,
      warnings: warnings
    })
  end
end
