defmodule PiCoding.Hooks.Runner do
  @moduledoc """
  Executes command-type hook specs as subprocesses.

  Each hook receives the payload JSON on stdin. stdout/stderr are captured and
  returned as a raw result map for `Outcome.decode/3`.

  Hooks run concurrently via `Task.async_stream`. A crashed or timed-out hook
  degrades to `:proceed` with a user-visible warning — it never aborts a turn.

  Deduplication: identical `cmd` + event combos within a single dispatch are
  run once.
  """

  alias PiCoding.Hooks.Spec
  alias PiCoding.Hooks.Spec.Command
  alias PiCoding.Hooks.Outcome
  alias PiCoding.Hooks.Payload
  alias PiCoding.Hooks.Trust

  @max_output_chars 10_000

  @doc """
  Run matching, trusted command specs against an event.

  Returns `{folded_outcome, warnings}` where `warnings` is a list of
  human-readable strings for specs that crashed, timed out, or are unsupported.
  """
  @spec run(atom(), [Spec.t()], map(), map()) ::
          {Outcome.outcome(), warnings :: [String.t()]}
  def run(event, specs, ctx, event_data \\ %{}) do
    payload_map = Payload.build(event, ctx, event_data)
    payload_json = Jason.encode!(payload_map)

    {to_run, warnings_skip} = filter_specs(specs, event, ctx)
    to_run = dedup(to_run)

    {outcomes, warnings_run} =
      to_run
      |> Task.async_stream(
        fn spec -> run_spec(spec, payload_json, ctx) end,
        max_concurrency: 16,
        timeout: max_timeout(to_run),
        on_timeout: :kill_task,
        ordered: false
      )
      |> Enum.reduce({[], []}, fn
        {:ok, {:ok, raw, spec}}, {outs, warns} ->
          outcome = Outcome.decode(event, raw, spec.dialect)
          emit_telemetry(event, spec, outcome)
          {[outcome | outs], warns}

        {:ok, {:error, reason, spec}}, {outs, warns} ->
          label = spec_label(spec)
          warn = "Hook warning (#{label}): #{reason}"
          emit_telemetry_error(event, spec, reason)
          {outs, [warn | warns]}

        {:exit, reason}, {outs, warns} ->
          {outs, ["Hook crashed: #{inspect(reason)}" | warns]}
      end)

    folded = Outcome.fold(outcomes)
    {folded, warnings_run ++ warnings_skip}
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp filter_specs(specs, event, ctx) do
    alias PiCoding.Hooks.Matcher

    Enum.reduce(specs, {[], []}, fn spec, {run_acc, warn_acc} ->
      cond do
        spec.event != event ->
          {run_acc, warn_acc}

        not Matcher.match?(spec, ctx) ->
          {run_acc, warn_acc}

        spec.unsupported_reason != nil ->
          warn = "Skipping hook (#{spec_label(spec)}): #{spec.unsupported_reason}"
          {run_acc, [warn | warn_acc]}

        not Trust.trusted?(spec) ->
          warn = "Skipping untrusted project hook (#{spec_label(spec)}): approve it first"
          {run_acc, [warn | warn_acc]}

        match?(%Command{}, spec.handler) ->
          {[spec | run_acc], warn_acc}

        true ->
          warn = "Skipping non-command hook (#{spec_label(spec)}): HTTP not supported in v1"
          {run_acc, [warn | warn_acc]}
      end
    end)
  end

  defp dedup(specs) do
    Enum.uniq_by(specs, fn %Spec{handler: %Command{cmd: cmd}, event: event} ->
      {event, cmd}
    end)
  end

  defp max_timeout([]), do: 5_000

  defp max_timeout(specs) do
    specs
    |> Enum.map(fn %Spec{handler: %Command{timeout_ms: t}} -> t end)
    |> Enum.max()
    # Add a small buffer so the outer task doesn't race the inner timeout
    |> Kernel.+(500)
  end

  defp run_spec(
         %Spec{handler: %Command{cmd: cmd, timeout_ms: timeout_ms}} = spec,
         payload_json,
         ctx
       ) do
    cwd = ctx[:cwd] || File.cwd!()

    try do
      port =
        Port.open({:spawn, cmd}, [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          {:cd, cwd},
          {:env, build_env()}
        ])

      Port.command(port, payload_json)

      # Separate stderr: use a two-port approach isn't available via Port
      # directly, so we capture combined output and split later if needed.
      # For now, stdout+stderr are merged (stderr_to_stdout above).
      {output, exit_code} = collect_port(port, timeout_ms, "")
      output = String.slice(output, 0, @max_output_chars)

      {:ok, %{exit: exit_code, stdout: output, stderr: ""}, spec}
    rescue
      e -> {:error, Exception.message(e), spec}
    catch
      kind, reason -> {:error, "#{kind}: #{inspect(reason)}", spec}
    end
  end

  defp collect_port(port, timeout_ms, acc) do
    receive do
      {^port, {:data, data}} ->
        collect_port(port, timeout_ms, acc <> data)

      {^port, {:exit_status, code}} ->
        {acc, code}
    after
      timeout_ms ->
        Port.close(port)
        {acc, 1}
    end
  end

  defp build_env do
    # Inherit parent environment — convert to charlist tuples for Port
    System.get_env()
    |> Enum.map(fn {k, v} -> {to_charlist(k), to_charlist(v)} end)
  end

  defp spec_label(%Spec{handler: %Command{cmd: cmd}, event: event}) do
    "#{event} #{String.slice(cmd, 0, 60)}"
  end

  defp spec_label(%Spec{event: event}), do: to_string(event)

  defp emit_telemetry(event, spec, outcome) do
    {origin_type, _} = spec.origin || {:unknown, ""}

    :telemetry.execute(
      [:ex_pi, :hook, :run, :stop],
      %{},
      %{
        event: event,
        origin: origin_type,
        dialect: spec.dialect,
        decision: outcome_tag(outcome)
      }
    )
  end

  defp emit_telemetry_error(event, spec, reason) do
    {origin_type, _} = spec.origin || {:unknown, ""}

    :telemetry.execute(
      [:ex_pi, :hook, :run, :stop],
      %{},
      %{
        event: event,
        origin: origin_type,
        dialect: spec.dialect,
        decision: :error,
        error: inspect(reason)
      }
    )
  end

  defp outcome_tag(:proceed), do: :proceed
  defp outcome_tag({tag, _}), do: tag
end
