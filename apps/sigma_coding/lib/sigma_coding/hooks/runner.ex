defmodule Sigma.Coding.Hooks.Runner do
  @moduledoc """
  Runs Codex command/MCP hooks with separate output streams and absolute deadlines.

  Sessions supply ctx[:hook_async_runtime] to queue async commands with session
  ownership and a concurrency limit. Standalone callers without it run directly
  under the task supervisor without session ownership or that limit.
  Async control directives are ignored; the host may consume later context/diagnostics with
  ctx[:hook_async_callback] (arity 2: context text or nil, warnings).
  A trusted ctx[:hook_async_callback_factory] instead binds that callback before
  queueing, using the handler's index in the complete specs list and its spec.
  A rejected factory prevents execution rather than falling back to the legacy callback.

  Host adaptation: Unix subprocess ownership uses setsid process groups. Linux
  uses util-linux `setsid`; hosts without it (macOS) use the packaged
  `sigma-setsid` helper. Hosts without either report an execution error instead
  of running an unowned command.
  Output capture is bounded to 1 MB per stream; context uses Outcome's host limit.
  """

  alias Sigma.Coding.Hooks.{AsyncRuntime, Execution, Matcher, Outcome, Payload, Spec, Trust}
  alias Sigma.Coding.Hooks.Spec.{Command, McpTool}

  @max_output_bytes 1_000_000
  @cleanup_wait_ms 1_000

  def run(event, specs, ctx, event_data \\ %{}) do
    payload = Payload.build(event, ctx, event_data)
    match_context = Map.merge(ctx, event_data)

    {selected, skipped} =
      specs
      |> Enum.with_index()
      |> Enum.reduce({[], []}, fn {spec, index}, {selected, warnings} ->
        cond do
          spec.event != event or not Matcher.match?(spec, match_context) ->
            {selected, warnings}

          spec.unsupported_reason != nil ->
            {selected, warnings ++ ["Skipping hook: #{spec.unsupported_reason}"]}

          not Trust.trusted?(spec) ->
            {selected, warnings ++ ["Skipping untrusted project hook: approve it first"]}

          match?(%Command{}, spec.handler) or match?(%McpTool{}, spec.handler) ->
            {selected ++ [{index, spec}], warnings}

          true ->
            {selected, warnings ++ ["Skipping unsupported hook handler."]}
        end
      end)

    selected =
      Enum.filter(selected, fn {index, _spec} ->
        not is_pid(ctx[:hook_execution]) or
          Execution.reserve(ctx.hook_execution, effect_id(event, index), hook_name(event)) == :ok
      end)

    {async, sync} = Enum.split_with(selected, fn {_index, spec} -> async?(spec) end)

    background_warnings =
      Enum.flat_map(async, fn {index, spec} ->
        schedule_async(index, spec, event, payload, ctx)
      end)

    {outcomes, warnings} =
      sync
      |> Task.async_stream(
        fn {index, spec} ->
          execute(spec, payload, effect_context(ctx, event, index))
        end,
        max_concurrency: max(length(sync), 1),
        timeout: :infinity,
        ordered: false
      )
      |> Enum.reduce({[], []}, fn
        {:ok, {:ok, raw, spec, _cleanup}}, {outcomes, warnings} ->
          {outcome, diagnostics} = Outcome.evaluate(event, raw, spec.dialect)
          emit(event, spec, outcome, diagnostics)

          {outcomes ++ [outcome], warnings ++ diagnostics}

        {:ok, {:error, reason, spec, _cleanup}}, {outcomes, warnings} ->
          emit(event, spec, :proceed, [reason])
          {outcomes, warnings ++ [reason]}

        {:exit, reason}, {outcomes, warnings} ->
          {outcomes, warnings ++ ["Hook crashed: #{inspect(reason)}"]}
      end)

    {Outcome.fold(outcomes), skipped ++ background_warnings ++ warnings}
  end

  defp effect_id(event, index), do: "#{event}:#{index}"

  defp effect_context(ctx, event, index),
    do: Map.put(ctx, :hook_effect, %{event: event, id: effect_id(event, index)})

  defp hook_name(event) do
    case Enum.find(Sigma.Coding.Hooks.Catalog.events(), &(&1.event == event)) do
      %{name: name} -> name
      nil -> Atom.to_string(event)
    end
  end

  # Persist the decoded host outcome, never implicit stdout/stderr or command text.
  defp outcome_value(outcome) do
    control =
      case Outcome.control(outcome) do
        {decision, value} -> %{"decision" => Atom.to_string(decision), "value" => value}
        decision -> %{"decision" => Atom.to_string(decision)}
      end

    %{"control" => control}
  end

  defp async?(%Spec{event: :session_end}), do: false
  defp async?(%Spec{handler: %Command{async: async}}), do: async
  defp async?(_), do: false

  defp schedule_async(index, spec, event, payload, ctx) do
    ctx = effect_context(ctx, event, index)

    case async_callback(ctx, index, spec) do
      {:ok, callback} ->
        schedule_async_callback(spec, event, payload, ctx, callback)

      {:error, warning} ->
        discard_effect(ctx)
        [warning]
    end
  end

  defp async_callback(ctx, index, spec) do
    case Map.fetch(ctx, :hook_async_callback_factory) do
      :error ->
        {:ok, ctx[:hook_async_callback]}

      {:ok, factory} when is_function(factory, 2) ->
        build_async_callback(factory, index, spec)

      {:ok, _} ->
        {:error, "Skipping async hook: callback factory must be an arity-2 function."}
    end
  end

  defp build_async_callback(factory, index, spec) do
    case factory.(index, spec) do
      callback when is_function(callback, 2) ->
        {:ok, callback}

      _ ->
        {:error, "Skipping async hook: callback factory did not return an arity-2 function."}
    end
  rescue
    error -> {:error, "Skipping async hook: callback factory failed: #{Exception.message(error)}"}
  catch
    kind, reason ->
      {:error, "Skipping async hook: callback factory failed (#{kind}): #{inspect(reason)}"}
  end

  defp schedule_async_callback(spec, event, payload, ctx, callback) do
    fun = fn ->
      {outcome, warnings} =
        case execute(spec, payload, ctx) do
          {:ok, raw, _spec, _cleanup} -> Outcome.evaluate_async(event, raw, spec.dialect)
          {:error, reason, _spec, _cleanup} -> {:proceed, [reason]}
        end

      emit(event, spec, :proceed, warnings)

      if is_function(callback, 2), do: callback.(Outcome.context(outcome), warnings)
    end

    if is_pid(ctx[:hook_async_runtime]) do
      AsyncRuntime.schedule(ctx.hook_async_runtime, fun)
      []
    else
      supervisor = Map.get(ctx, :hook_task_supervisor, Sigma.Coding.Dispatcher.TaskSupervisor)

      case Task.Supervisor.start_child(supervisor, fun) do
        {:ok, _pid} ->
          []

        {:error, reason} ->
          discard_effect(ctx)
          ["Could not start async hook: #{inspect(reason)}"]
      end
    end
  catch
    :exit, reason -> ["Could not start async hook: #{inspect(reason)}"]
  end

  defp execute(%Spec{handler: %Command{} = command} = spec, payload, ctx) do
    {result, cleanup} =
      owned_worker(spec, ctx, fn owner_ref -> run_command(command, payload, ctx, owner_ref) end)

    case result do
      {:ok, raw} -> {:ok, raw, spec, cleanup}
      {:error, reason} -> {:error, reason, spec, cleanup}
    end
  end

  defp execute(%Spec{handler: %McpTool{} = handler} = spec, payload, ctx) do
    with executor when is_function(executor, 4) <- ctx[:mcp_hook_executor],
         {:ok, input} <- expand_input(handler.input, payload) do
      {result, cleanup} =
        owned_worker(spec, ctx, fn owner_ref ->
          run_mcp_hook(executor, handler, input, ctx, owner_ref)
        end)

      case result do
        {:ok, raw} -> {:ok, raw, spec, cleanup}
        {:error, reason} -> {:error, reason, spec, cleanup}
      end
    else
      {:error, reason} ->
        discard_effect(ctx)
        {:error, reason, spec, {:ok, %{status: :confirmed, completion: :not_started}}}

      _ ->
        discard_effect(ctx)

        {:error, "MCP hook executor is not connected.", spec,
         {:ok, %{status: :confirmed, completion: :not_started}}}
    end
  rescue
    error -> {:error, Exception.message(error), spec, :mcp_cleanup_not_observed}
  end

  defp owned_worker(spec, ctx, run) do
    owner = self()
    start_ref = make_ref()
    supervisor = Map.get(ctx, :hook_task_supervisor, Sigma.Coding.Dispatcher.TaskSupervisor)

    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        Process.flag(:trap_exit, true)
        owner_ref = Process.monitor(owner)

        {result, settlement} =
          receive do
            {:run_hook_command, ^start_ref} -> run.(owner_ref)
            {:skip_hook_command, ^start_ref} -> cancelled_before_launch()
            {:DOWN, ^owner_ref, :process, _pid, _reason} -> cancelled_before_launch()
            {:EXIT, _pid, _reason} -> cancelled_before_launch()
          end

        if is_pid(ctx[:hook_async_runtime]),
          do: AsyncRuntime.command_settled(ctx.hook_async_runtime, settlement)

        report_effect(ctx, spec, result, settlement)

        {result, settlement}
      end)

    worker_ref = Process.monitor(task.pid)

    registered =
      if is_pid(ctx[:hook_async_runtime]),
        do: AsyncRuntime.track_command(ctx.hook_async_runtime, task.pid),
        else: :ok

    registered =
      if registered == :ok and is_pid(ctx[:hook_execution]),
        do: Execution.track(ctx.hook_execution, ctx.hook_effect.id, task.pid),
        else: registered

    case registered do
      :ok ->
        send(task.pid, {:run_hook_command, start_ref})

        {result, cleanup} =
          case Task.yield(task, :infinity) do
            {:ok, {result, cleanup}} ->
              {result, cleanup}

            {:exit, reason} ->
              {{:error, "Hook process worker failed: #{inspect(reason)}"},
               {:error, {:hook_worker_exit, reason}}}
          end

        receive do
          {:DOWN, ^worker_ref, :process, _pid, :normal} ->
            {result, cleanup}

          {:DOWN, ^worker_ref, :process, _pid, reason} ->
            {result, {:error, {:hook_worker_exit, reason, cleanup}}}
        end

      {:error, :closed} ->
        # The startup gate is still closed, so no subprocess can need cleanup.
        send(task.pid, {:skip_hook_command, start_ref})
        Task.yield(task, :infinity)
        receive do: ({:DOWN, ^worker_ref, :process, _pid, _reason} -> :ok)
        {{:error, "Hook cancelled."}, {:ok, %{status: :confirmed, completion: :not_started}}}
    end
  end

  defp discard_effect(%{hook_execution: scope, hook_effect: %{id: id}}) when is_pid(scope),
    do: Execution.discard(scope, id)

  defp discard_effect(_ctx), do: :ok

  defp report_effect(%{hook_execution: scope, hook_effect: effect}, spec, result, cleanup)
       when is_pid(scope) do
    value =
      case result do
        {:ok, raw} ->
          {outcome, _warnings} =
            if async?(spec),
              do: Outcome.evaluate_async(effect.event, raw, spec.dialect),
              else: Outcome.evaluate(effect.event, raw, spec.dialect)

          %{"exit_status" => raw.exit, "outcome" => outcome_value(outcome)}

        {:error, reason} ->
          %{"status" => "failed", "reason" => reason}
      end

    Execution.completed(scope, effect.id, value, cleanup)
  end

  defp report_effect(_ctx, _spec, _result, _cleanup), do: :ok

  defp run_mcp_hook(executor, handler, input, ctx, owner_ref) do
    task =
      Task.Supervisor.async_nolink(
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

    ref = Process.monitor(task.pid)
    task_ref = task.ref

    result =
      receive do
        {^task_ref, result} ->
          Process.demonitor(task_ref, [:flush])
          {:result, result}

        {:DOWN, ^task_ref, :process, _pid, cause} ->
          {:failed, cause}

        {:DOWN, ^owner_ref, :process, _pid, _reason} ->
          Task.shutdown(task, :brutal_kill)
          :cancelled

        {:EXIT, _pid, _reason} ->
          Task.shutdown(task, :brutal_kill)
          :cancelled
      after
        handler.timeout_ms ->
          Task.shutdown(task, :brutal_kill)
          :timeout
      end

    receive do
      {:DOWN, ^ref, :process, _pid, cause} ->
        case {result, cause} do
          {{:result, {status, value, cleanup}}, :normal} when status in [:ok, :error] ->
            {{status, value}, cleanup}

          {{:result, {:ok, raw}}, :normal} when is_map(raw) ->
            {{:ok, raw}, {:ok, %{status: :confirmed, completion: :mcp_result}}}

          {:timeout, _cause} ->
            {{:error, "MCP hook timed out after #{handler.timeout_ms}ms."},
             {:error, {:mcp_hook_cleanup_unconfirmed, result, cause}}}

          _ ->
            {{:error, "MCP hook failed: #{inspect(result)}"},
             {:error, {:mcp_hook_cleanup_unconfirmed, result, cause}}}
        end
    end
  end

  defp run_command(handler, payload, ctx, owner_ref) do
    with setsid when is_binary(setsid) <- setsid_executable(),
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
              {{:error, "Hook timed out after #{handler.timeout_ms}ms."},
               cleanup_processes(killer, nil, os_pid)}

            :cancelled ->
              {{:error, "Hook cancelled."}, cleanup_processes(killer, nil, os_pid)}

            {:error, reason} ->
              {{:error, reason}, cleanup_processes(killer, nil, os_pid)}
          end
        after
          if Port.info(port), do: Port.close(port)
        end
      after
        File.rm_rf(directory)
      end
    else
      _ ->
        {{:error, "Hook execution requires setsid and kill for managed subprocess cleanup."},
         {:ok, %{status: :confirmed, completion: :not_started}}}
    end
  rescue
    error ->
      {{:error, "Hook execution failed: #{Exception.message(error)}"},
       {:error, {:command_lifecycle_exception, error}}}
  catch
    kind, reason ->
      {{:error, "Hook execution failed: #{inspect({kind, reason})}"},
       {:error, {:command_lifecycle_failure, kind, reason}}}
  end

  defp cancelled_before_launch do
    {{:error, "Hook cancelled."}, {:ok, %{status: :confirmed, completion: :not_started}}}
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
          {{:ok,
            %{
              exit: exit,
              stdout: String.replace_invalid(stdout),
              stderr: read_output(stderr_path)
            }}, observe_completion(process_group, os_pid)}

        :timeout ->
          {{:error, "Hook timed out after #{timeout_ms}ms."},
           cleanup_processes(killer, process_group, os_pid)}

        :cancelled ->
          {{:error, "Hook cancelled."}, cleanup_processes(killer, process_group, os_pid)}
      end
    catch
      kind, reason ->
        cleanup = cleanup_processes(killer, process_group, os_pid)

        {{:error, "Hook execution failed: #{inspect({kind, reason})}"},
         {:error, {:command_lifecycle_failure, kind, reason, cleanup}}}
    end
  end

  defp cleanup_processes(killer, process_group, os_pid) do
    # Stop the setsid waiter before its group, so a successful group kill cannot
    # race the waiter's natural exit and obscure the actual signal result.
    targets =
      [Integer.to_string(os_pid)] ++
        if(is_integer(process_group) and process_group > 0, do: ["-#{process_group}"], else: [])

    signals =
      Enum.map(targets, fn target ->
        try do
          {output, status} = System.cmd(killer, ["-KILL", "--", target], stderr_to_stdout: true)
          %{target: target, status: status, output: output}
        rescue
          error -> %{target: target, failure: {:exception, error}}
        catch
          kind, reason -> %{target: target, failure: {kind, reason}}
        end
      end)

    observed =
      await_processes_closed(
        process_group,
        os_pid,
        System.monotonic_time(:millisecond) + @cleanup_wait_ms
      )

    cond do
      not is_integer(process_group) ->
        {:error, {:command_process_group_unavailable, %{signals: signals, observation: observed}}}

      Enum.all?(signals, &(Map.get(&1, :status) == 0)) and observed == :ok ->
        {:ok, %{status: :confirmed, completion: :cancelled, signals: signals}}

      true ->
        {:error, {:command_cleanup_unconfirmed, %{signals: signals, observation: observed}}}
    end
  end

  defp observe_completion(process_group, os_pid) do
    case active_processes(process_group, os_pid) do
      {:ok, []} -> {:ok, %{status: :confirmed, completion: :collected_exit}}
      {:ok, active} -> {:error, {:command_processes_still_active, active}}
      {:error, cause} -> {:error, {:command_process_observation_failed, cause}}
    end
  end

  defp await_processes_closed(process_group, os_pid, deadline) do
    case active_processes(process_group, os_pid) do
      {:ok, []} ->
        :ok

      {:ok, active} ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, {:command_processes_still_active, active}}
        else
          Process.sleep(10)
          await_processes_closed(process_group, os_pid, deadline)
        end

      {:error, cause} ->
        {:error, {:command_process_observation_failed, cause}}
    end
  end

  defp setsid_executable do
    System.find_executable("setsid") || Application.get_env(:sigma_coding, :setsid_path) ||
      packaged_setsid()
  end

  defp packaged_setsid do
    with path when is_list(path) <- :code.priv_dir(:sigma_agent),
         helper = Path.join(List.to_string(path), "native/sigma-setsid"),
         true <- File.regular?(helper) do
      helper
    else
      _ -> nil
    end
  end

  # Linux /proc (or `ps` on macOS) proves absence of runnable managed processes;
  # zombies no longer execute effects. Unsupported/unreadable observation remains
  # unconfirmed.
  defp active_processes(process_group, os_pid) do
    case :os.type() do
      {:unix, :darwin} -> active_processes_ps(process_group, os_pid)
      _ -> active_processes_proc(process_group, os_pid)
    end
  end

  defp active_processes_ps(process_group, os_pid) do
    case System.cmd("/bin/ps", ["-A", "-o", "pid=,pgid=,stat="], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.reduce_while({:ok, []}, fn line, {:ok, active} ->
          case String.split(line) do
            [pid, group, state | _] ->
              with {pid, ""} <- Integer.parse(pid),
                   {group, ""} <- Integer.parse(group) do
                live =
                  not String.starts_with?(state, "Z") and
                    (pid == os_pid or (is_integer(process_group) and group == process_group))

                {:cont, {:ok, if(live, do: [pid | active], else: active)}}
              else
                _ -> {:halt, {:error, {:invalid_process_listing, line}}}
              end

            _ ->
              {:halt, {:error, {:invalid_process_listing, line}}}
          end
        end)

      {output, status} ->
        {:error, {:process_listing_unavailable, status, output}}
    end
  rescue
    error -> {:error, {:process_listing_unavailable, error}}
  end

  defp active_processes_proc(process_group, os_pid) do
    with {:ok, names} <- File.ls("/proc") do
      Enum.reduce_while(names, {:ok, []}, fn name, {:ok, active} ->
        case Integer.parse(name) do
          {pid, ""} ->
            case process_identity(pid) do
              {:ok, state, group} ->
                live =
                  state not in ["Z", "X"] and
                    (pid == os_pid or (is_integer(process_group) and group == process_group))

                {:cont, {:ok, if(live, do: [pid | active], else: active)}}

              :gone ->
                {:cont, {:ok, active}}

              {:error, cause} ->
                {:halt, {:error, cause}}
            end

          _ ->
            {:cont, {:ok, active}}
        end
      end)
    end
  end

  defp process_identity(pid) do
    path = "/proc/#{pid}/stat"

    case File.read(path) do
      {:ok, stat} ->
        case Regex.run(~r/\A[0-9]+ \(.*\) ([A-Za-z]) [0-9]+ ([0-9]+) /s, stat) do
          [_, state, group] -> {:ok, state, String.to_integer(group)}
          _ -> {:error, {:invalid_process_stat, path}}
        end

      {:error, :enoent} ->
        :gone

      {:error, :esrch} ->
        :gone

      {:error, cause} ->
        {:error, {:process_stat_unavailable, path, cause}}
    end
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
