defmodule Sigma.Agent.Backplane.CommandHost do
  @moduledoc """
  Session-owned Linux command adapter with a fail-closed sandbox launcher.

  The public LocalCommand adapter owns ports and cleanup receipts. This process
  serializes admission with rebinding and retains cleanup obligations independently
  of the current run binding. The launcher supports Linux x86_64 only. No
  permission grants or PTY capability are provided.
  """
  use GenServer, restart: :temporary, shutdown: 10_000

  @behaviour Backplane.AgentRuntime.Command

  alias Backplane.AgentRuntime.{Command, Error}
  alias Backplane.AgentRuntime.Codex.Session
  alias Backplane.AgentRuntime.Tools.LocalCommand
  alias Sigma.Agent.Backplane.CommandRuntime

  def start_link(opts) do
    with {:ok, config} <- configuration(opts) do
      GenServer.start_link(__MODULE__, config)
    end
  end

  def bind(host, binding), do: call(host, {:bind, binding})

  @impl Backplane.AgentRuntime.Command
  def start(command, invocation, opts), do: invoke(command, {:start, invocation, opts})

  @impl Backplane.AgentRuntime.Command
  def read(command, invocation, job, opts), do: invoke(command, {:read, invocation, job, opts})

  @impl Backplane.AgentRuntime.Command
  def write(command, invocation, job, chars),
    do: invoke(command, {:write, invocation, job, chars})

  @impl Backplane.AgentRuntime.Command
  def cancel(command, invocation), do: invoke(command, {:cancel, invocation})

  @impl Backplane.AgentRuntime.Command
  def cancel_confirmed(command, invocation, timeout),
    do: invoke(command, {:cancel_confirmed, invocation, timeout})

  @impl Backplane.AgentRuntime.Command
  def reserve(command, invocation), do: invoke(command, {:reserve, invocation})

  @impl Backplane.AgentRuntime.Command
  def acknowledge_release(command, invocation), do: invoke(command, {:acknowledge, invocation})

  @impl Backplane.AgentRuntime.Command
  def validate_refusal(command, invocation, error),
    do: invoke(command, {:validate_refusal, invocation, error})

  @impl Backplane.AgentRuntime.Command
  def capabilities(_command), do: %{}

  @impl true
  def init(config) do
    Process.flag(:trap_exit, true)

    # TODO(upstream): gsmlg-opt/backplane#95
    # Preparation only: bootstrap executables and the handshake script must be
    # pinned outside the workspace before this adapter can replace production.
    with {:ok, backend} <- LocalCommand.start_link(name: nil),
         {:ok, command} <-
           Command.new(%{adapter: LocalCommand, server: backend, allowed_environment: %{}}) do
      {:ok,
       Map.merge(config, %{
         backend: command,
         monitor: Process.monitor(config.owner),
         binding: nil,
         route: nil,
         cleanup_token: make_ref(),
         obligations: %{},
         released: [],
         dispatched_floor: 0,
         refusal_key: :crypto.strong_rand_bytes(32)
       })}
    else
      {:error, error} -> {:stop, {:shutdown, error}}
    end
  end

  @impl true
  def handle_call({:bind, binding}, {caller, _}, state) do
    with true <- caller == state.owner or forbidden("only the command host owner can bind"),
         :ok <- valid_binding(state, binding) do
      route = %{binding: binding, generation: make_ref(), cleanup_token: state.cleanup_token}

      {:ok, command} =
        Command.new(%{
          adapter: __MODULE__,
          server: self(),
          workspace_key: route,
          allowed_environment: %{}
        })

      {:reply, {:ok, command}, %{state | route: route, binding: binding}}
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:invoke, route, {:reserve, invocation}}, _from, state) do
    case authorize(state, route, invocation) do
      :ok ->
        case identity(invocation) do
          {:ok, key} ->
            result = backend(fn -> Command.reserve(state.backend, invocation) end)

            obligations =
              if result == :ok,
                do:
                  Map.put_new(state.obligations, key, %{
                    invocation: invocation,
                    job: nil,
                    dispatch: :none
                  }),
                else: state.obligations

            result = translate_refusal(state, invocation, invocation, result, :not_created)
            {:reply, result, %{state | obligations: obligations}}

          error ->
            {:reply, refusal(state, invocation, error, :not_created), state}
        end

      error ->
        {:reply, refusal(state, invocation, error, reservation(state, invocation)), state}
    end
  end

  def handle_call({:invoke, route, {:start, invocation, opts}}, _from, state) do
    result =
      with :ok <- authorize(state, route, invocation),
           {:ok, key} <- identity(invocation),
           {:ok, obligation} <- fetch_obligation(state, key),
           true <-
             obligation.dispatch in [:none, :never_started] or
               forbidden("command session launch was already attempted"),
           {:ok, request} <- sandbox_request(state, invocation) do
        case backend(fn -> Command.start(state.backend, request, opts) end) do
          {:ok, job} ->
            next = Map.put(state.obligations, key, %{obligation | job: job, dispatch: :started})
            {:launched, job, next, max(state.dispatched_floor, invocation.session_id)}

          error ->
            translated = translate_refusal(state, invocation, request, error, :created)

            dispatch =
              case translated do
                {:error, %Error{cause: {:sigma_sandbox_refusal, _}}} -> :never_started
                _ -> :uncertain
              end

            next = Map.put(state.obligations, key, %{obligation | dispatch: dispatch})

            {:backend_result, translated, next,
             max(state.dispatched_floor, invocation.session_id)}
        end
      end

    case result do
      {:launched, job, obligations, floor} ->
        {:reply, {:ok, job}, %{state | obligations: obligations, dispatched_floor: floor}}

      {:backend_result, result, obligations, floor} ->
        {:reply, result, %{state | obligations: obligations, dispatched_floor: floor}}

      error ->
        {:reply, refusal(state, invocation, error, reservation(state, invocation)), state}
    end
  end

  def handle_call({:invoke, route, {:read, invocation, job, opts}}, _from, state) do
    result =
      with :ok <- authorize(state, route, invocation),
           :ok <- authorized_job(state, invocation, job) do
        backend(fn -> Command.read(state.backend, invocation, job, opts) end)
      end

    {:reply, result, state}
  end

  def handle_call({:invoke, route, {:write, invocation, job, chars}}, _from, state) do
    result =
      with :ok <- authorize(state, route, invocation),
           :ok <- authorized_job(state, invocation, job) do
        backend(fn -> Command.write(state.backend, invocation, job, chars) end)
      end

    {:reply, result, state}
  end

  # Cleanup is an obligation established before launch, not permission for a new
  # effect. A recorded identity remains usable after its run binding is revoked.
  def handle_call({:invoke, route, {:cancel_confirmed, invocation, timeout}}, _from, state) do
    result =
      with :ok <- cleanup_route(state, route),
           {:ok, key} <- identity(invocation) do
        if key in state.released do
          :ok
        else
          with {:ok, _} <- fetch_obligation(state, key) do
            backend(fn -> Command.cancel_confirmed(state.backend, invocation, timeout) end)
          end
        end
      end

    {:reply, result, state}
  end

  def handle_call({:invoke, route, {:acknowledge, invocation}}, _from, state) do
    with :ok <- cleanup_route(state, route),
         {:ok, key} <- identity(invocation) do
      if key in state.released do
        {:reply, :ok, state}
      else
        with {:ok, _} <- fetch_obligation(state, key),
             :ok <- backend(fn -> Command.acknowledge_release(state.backend, invocation) end) do
          {:reply, :ok,
           %{
             state
             | obligations: Map.delete(state.obligations, key),
               released: Enum.take([key | state.released], 256)
           }}
        else
          error -> {:reply, error, state}
        end
      end
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:invoke, route, {:cancel, invocation}}, _from, state) do
    owned? =
      Enum.any?(state.obligations, fn {{_id, owner, _incarnation}, _} ->
        owner == invocation.owner_run_id
      end)

    result =
      with :ok <- cleanup_route(state, route),
           true <- owned? or forbidden("command cleanup identity is unknown") do
        backend(fn -> Command.cancel(state.backend, invocation) end)
      end

    {:reply, result, state}
  end

  def handle_call({:invoke, route, {:validate_refusal, invocation, error}}, _from, state) do
    result =
      with :ok <- cleanup_route(state, route) do
        case error do
          %Error{cause: {:sigma_sandbox_refusal, proof}}
          when is_binary(proof) and byte_size(proof) == 32 ->
            expected = refusal_proof(state, invocation, %{error | cause: nil})

            if safe_nonexecution?(state, invocation) and :crypto.hash_equals(proof, expected),
              do: :ok,
              else: unknown("unverified refusal")

          _ ->
            unknown("unverified refusal")
        end
      end

    {:reply, result, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _owner, _reason}, %{monitor: ref} = state),
    do: {:stop, :normal, state}

  def handle_info({:EXIT, pid, reason}, %{backend: %{server: pid}} = state),
    do: {:stop, {:command_backend_unavailable, reason}, state}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if Process.alive?(state.backend.server),
      do: GenServer.stop(state.backend.server, :normal, 5_000)

    :ok
  catch
    :exit, _ -> :ok
  end

  defp authorize(state, route, invocation) do
    with true <- (route == state.route and not is_nil(route)) or forbidden("stale command route"),
         true <-
           (invocation.owner_run_id == state.binding.owner_id and
              Map.get(invocation, :incarnation) == state.binding.incarnation) or
             forbidden("command invocation owner differs from Session"),
         {:ok, _} <-
           Session.validate(state.binding, %{
             run_id: state.binding.run_id,
             incarnation: state.binding.run_incarnation
           }) do
      :ok
    end
  catch
    :exit, _ -> forbidden("command Session is unavailable")
  end

  defp valid_binding(state, %{
         session: session,
         owner_id: binding_owner,
         incarnation: binding_incarnation
       }) do
    with %{owner_id: owner, incarnation: incarnation, phase: phase} <- Session.status(session),
         true <- owner == binding_owner and incarnation == binding_incarnation,
         true <- phase in [:reserved, :active],
         true <- is_nil(state.binding) or state.binding.session == session do
      :ok
    else
      _ -> forbidden("foreign or closed command Session")
    end
  catch
    :exit, _ -> forbidden("command Session is unavailable")
  end

  defp valid_binding(_state, _binding), do: forbidden("command Session binding is required")

  defp cleanup_route(state, %{
         cleanup_token: token,
         binding: %{session: session, owner_id: owner, incarnation: incarnation}
       }) do
    if token == state.cleanup_token and state.binding != nil and
         session == state.binding.session and owner == state.binding.owner_id and
         incarnation == state.binding.incarnation,
       do: :ok,
       else: forbidden("foreign command cleanup route")
  end

  defp cleanup_route(_state, _route), do: forbidden("command cleanup capability is required")

  defp sandbox_request(state, invocation) do
    with true <-
           Map.get(invocation, :tty, false) == false or forbidden("sandbox PTY is unavailable"),
         true <-
           Map.get(invocation, :environment, %{}) == %{} or
             forbidden("command environment is fixed"),
         cwd when is_binary(cwd) <- Map.get(invocation, :workspace),
         true <- within?(cwd, state.workspace) or forbidden("command cwd is outside workspace"),
         {:ok, executable} <- canonical(invocation.executable),
         true <-
           Enum.any?(state.runtime_roots, &within?(executable, &1)) or
             forbidden("command executable is outside runtime closure") do
      config = %{
        version: 1,
        workspace: state.workspace,
        cwd: cwd,
        executable: executable,
        args: invocation.arguments,
        runtime_roots: state.runtime_roots,
        runtime_layout: state.runtime_layout,
        runtime_aliases: state.runtime_aliases,
        env: %{"PATH" => runtime_path(state)},
        bwrap: state.bwrap
      }

      {:ok,
       %{
         invocation
         | executable: state.launcher,
           arguments: ["--config-json", Jason.encode!(config)],
           environment: %{}
       }
       |> Map.put(:owner_pid, self())}
    else
      nil -> forbidden("command cwd is required")
      error -> error
    end
  end

  defp identity(%{session_id: id, owner_run_id: owner, incarnation: incarnation})
       when is_integer(id) and id > 0 and is_binary(owner) and is_integer(incarnation),
       do: {:ok, {id, owner, incarnation}}

  defp identity(_), do: forbidden("command session identity is required")

  defp authorized_job(state, invocation, job) do
    with {:ok, key} <- identity(Map.put(invocation, :session_id, Map.get(job, :session_id))),
         {:ok, %{job: recorded}} <- fetch_obligation(state, key),
         true <- (not is_nil(recorded) and job == recorded) or forbidden("foreign command job") do
      :ok
    end
  end

  defp fetch_obligation(state, key) do
    case Map.fetch(state.obligations, key) do
      {:ok, obligation} -> {:ok, obligation}
      :error -> forbidden("command cleanup identity is unknown")
    end
  end

  defp reservation(state, invocation) do
    case identity(invocation) do
      {:ok, key} -> if Map.has_key?(state.obligations, key), do: :created, else: :not_created
      _ -> :not_created
    end
  end

  defp translate_refusal(state, original, wrapped, {:error, %Error{} = error}, reservation) do
    if backend(fn -> Command.validate_refusal(state.backend, wrapped, error) end) == :ok do
      actual = Map.get(error.details, :reservation, reservation)
      refusal(state, original, {:error, %{error | cause: nil}}, actual)
    else
      {:error, error}
    end
  end

  defp translate_refusal(_state, _original, _wrapped, result, _reservation), do: result

  defp refusal(state, invocation, {:error, %Error{} = error}, reservation) do
    if safe_nonexecution?(state, invocation) do
      error = %{
        error
        | details:
            Map.merge(error.details || %{}, %{
              launch_status: :never_started,
              reservation: reservation
            }),
          cause: nil
      }

      {:error,
       %{error | cause: {:sigma_sandbox_refusal, refusal_proof(state, invocation, error)}}}
    else
      {:error,
       %{
         error
         | cause: nil,
           details: Map.drop(error.details || %{}, [:launch_status, :reservation])
       }}
    end
  end

  defp safe_nonexecution?(state, invocation) do
    case identity(invocation) do
      {:ok, {id, _owner, _incarnation} = key} ->
        case Map.get(state.obligations, key) do
          nil -> id > state.dispatched_floor and key not in state.released
          %{job: nil, dispatch: dispatch} -> dispatch in [:none, :never_started]
          _ -> false
        end

      _ ->
        false
    end
  end

  defp refusal_proof(state, invocation, error),
    do:
      :crypto.mac(
        :hmac,
        :sha256,
        state.refusal_key,
        :erlang.term_to_binary(
          {Map.take(invocation, [
             :session_id,
             :owner_run_id,
             :incarnation,
             :executable,
             :arguments,
             :workspace,
             :environment,
             :tty,
             :terminal
           ]), error}
        )
      )

  defp configuration(opts) do
    workspace = Keyword.get(opts, :workspace)
    owner = Keyword.get(opts, :owner_pid)
    roots = Keyword.get(opts, :runtime_roots)
    layout = Keyword.get(opts, :runtime_layout, :nix_closure)

    with true <-
           (:os.type() == {:unix, :linux} and
              String.starts_with?(
                List.to_string(:erlang.system_info(:system_architecture)),
                "x86_64-"
              )) or
             unavailable("sandbox requires Linux x86_64"),
         true <-
           (is_pid(owner) and Process.alive?(owner)) or
             unavailable("sandbox requires a live owner"),
         true <-
           (is_binary(workspace) and Path.type(workspace) == :absolute and File.dir?(workspace)) or
             unavailable("sandbox workspace is unavailable"),
         true <-
           not Enum.any?(["/bin", "/usr"], &(within?(workspace, &1) or within?(&1, workspace))) or
             unavailable("sandbox workspace overlaps interpreter aliases"),
         true <-
           valid_roots?(layout, roots) or
             unavailable("sandbox runtime closure is required"),
         {:ok, aliases} <- runtime_aliases(layout, Keyword.get(opts, :runtime_aliases), roots),
         {:ok, launcher} <- executable(Keyword.get(opts, :launcher_path)),
         {:ok, bwrap} <- executable(Keyword.get(opts, :bwrap_path)) do
      {:ok,
       %{
         workspace: Path.expand(workspace),
         owner: owner,
         runtime_roots: Enum.uniq(roots),
         runtime_layout: layout,
         runtime_aliases: aliases,
         launcher: launcher,
         bwrap: bwrap
       }}
    else
      error -> error
    end
  end

  defp runtime_root?(root),
    do: is_binary(root) and String.match?(root, ~r{\A/nix/store/[^/]+\z}) and File.dir?(root)

  defp valid_roots?(:nix_closure, roots),
    do: is_list(roots) and roots != [] and Enum.all?(roots, &runtime_root?/1)

  defp valid_roots?(:merged_usr, ["/usr"]), do: File.dir?("/usr")
  defp valid_roots?(_layout, _roots), do: false

  defp runtime_aliases(layout, aliases, _roots)
       when layout in [:nix_closure, :merged_usr] and aliases in [nil, %{}],
       do: {:ok, nil}

  defp runtime_aliases(:nix_closure, %{"sh" => sh, "env" => env} = aliases, roots)
       when map_size(aliases) == 2 do
    Enum.reduce_while([{"sh", sh}, {"env", env}], {:ok, %{}}, fn {name, path}, {:ok, acc} ->
      with {:ok, canonical} <- executable(path),
           true <- canonical == path and Enum.any?(roots, &within?(canonical, &1)) do
        {:cont, {:ok, Map.put(acc, name, canonical)}}
      else
        _ ->
          {:halt,
           unavailable("sandbox interpreter aliases require canonical runtime executables")}
      end
    end)
  end

  defp runtime_aliases(_layout, _aliases, _roots),
    do: unavailable("sandbox interpreter aliases require only sh and env in a Nix runtime")

  defp runtime_path(%{runtime_layout: :merged_usr}), do: "/usr/bin:/usr/sbin"
  defp runtime_path(state), do: Enum.map_join(state.runtime_roots, ":", &Path.join(&1, "bin"))

  defp executable(path) when is_binary(path) do
    with {:ok, path} <- canonical(path),
         {:ok, %{type: :regular, mode: mode}} <- File.stat(path),
         true <- Bitwise.band(mode, 0o111) != 0 do
      {:ok, path}
    else
      _ -> unavailable("sandbox executable is unavailable")
    end
  end

  defp executable(_), do: unavailable("sandbox executable is required")

  defp canonical(path) do
    case CommandRuntime.canonical_executable(path) do
      {:ok, executable} -> {:ok, executable}
      {:error, _} -> forbidden("command executable is unavailable")
    end
  end

  defp within?(path, root),
    do:
      Path.type(path) == :absolute and
        (path == root or String.starts_with?(Path.expand(path), root <> "/"))

  defp invoke(command, operation),
    do: call(command.server, {:invoke, command.workspace_key, operation})

  defp call(server, message), do: backend(fn -> GenServer.call(server, message, :infinity) end)

  defp backend(fun) do
    fun.()
  catch
    :exit, _ -> unknown("sandbox command backend outcome is unknown")
  end

  defp forbidden(message), do: {:error, Error.new(:forbidden, message)}
  defp unavailable(message), do: {:error, Error.new(:unsupported_capability, message)}
  defp unknown(message), do: {:error, Error.new(:unknown_outcome, message)}
end
