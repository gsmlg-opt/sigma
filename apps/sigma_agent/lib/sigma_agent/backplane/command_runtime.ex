defmodule Sigma.Agent.Backplane.CommandRuntime do
  @moduledoc """
  Trusted runtime catalog for native sandbox commands.

  The host selects a fixed set of available programs, never PATH directories.
  Nix programs contribute their exact store closure; merged-/usr hosts use one
  read-only /usr mount and fixed compatibility aliases. User scripts are skipped
  for optional programs and cannot supply a required shell. Resolution occurs
  once when session resources are created, outside model-controlled arguments.
  """

  alias Backplane.AgentRuntime.{Command, Error}
  alias Backplane.AgentRuntime.Tools.LocalCommand
  alias Sigma.Agent.Backplane.CommandLauncher

  @programs ~w(sh bash zsh cat git rg grep sed find awk python3 node elixir erl mix deno cargo rustc)
  @query_timeout 5_000
  @query_output 1_048_576

  def resolve(opts) do
    workspace = Keyword.get(opts, :workspace)
    path = Keyword.get(opts, :path, System.get_env("PATH") || "")
    selected_shell = Keyword.get(opts, :shell, System.get_env("SHELL"))
    shells = Enum.uniq(Enum.reject(["/bin/sh", selected_shell], &(&1 in [nil, ""])))

    with true <-
           (is_binary(workspace) and Path.type(workspace) == :absolute and File.dir?(workspace)) or
             unavailable("sandbox runtime requires an existing workspace"),
         true <- is_binary(path) or unavailable("sandbox runtime PATH is malformed"),
         {:ok, required} <- required_programs(shells),
         {:ok, env} <- canonical_executable("/usr/bin/env"),
         {:ok, layout} <- layout(required ++ [env]),
         {:ok, launcher} <- CommandLauncher.open(workspace),
         {:ok, bwrap} <-
           canonical_executable(Keyword.get(opts, :bwrap_path, System.find_executable("bwrap"))),
         :ok <- trusted_bwrap(bwrap, layout, workspace, Keyword.has_key?(opts, :bwrap_path)),
         {:ok, version} <- probe(bwrap, ["--version"], workspace),
         :ok <- supported_bwrap(version),
         {:ok, roots} <-
           roots(layout, required ++ [env] ++ optional_programs(path, layout), workspace) do
      aliases = if layout == :nix_closure, do: %{"sh" => hd(required), "env" => env}, else: %{}

      {:ok,
       [
         launcher_path: launcher,
         bwrap_path: bwrap,
         runtime_layout: layout,
         runtime_roots: roots,
         runtime_aliases: aliases
       ]}
    else
      error -> error
    end
  end

  @doc false
  def canonical_executable(path) when is_binary(path) do
    with true <- Path.type(path) == :absolute,
         {:ok, path} <- resolve_links(Path.split(Path.expand(path)), "/", 40),
         {:ok, %{type: :regular, mode: mode}} <- File.stat(path),
         true <- Bitwise.band(mode, 0o111) != 0 do
      {:ok, path}
    else
      _ -> unavailable("sandbox runtime executable is unavailable")
    end
  end

  def canonical_executable(_), do: unavailable("sandbox runtime executable is required")

  defp required_programs(paths) do
    Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, acc} ->
      case canonical_executable(path) do
        {:ok, executable} -> {:cont, {:ok, acc ++ [executable]}}
        error -> {:halt, error}
      end
    end)
  end

  defp layout(required) do
    cond do
      Enum.all?(required, &(store_root(&1) != nil)) ->
        {:ok, :nix_closure}

      Enum.all?(required, &String.starts_with?(&1, "/usr/")) and merged_usr?() ->
        {:ok, :merged_usr}

      true ->
        unavailable("required shells do not share a supported sandbox runtime layout")
    end
  end

  defp merged_usr? do
    match?({:ok, %{type: :directory}}, File.lstat("/usr")) and
      Enum.all?(~w(bin sbin lib lib64), fn name ->
        case File.read_link("/" <> name) do
          {:ok, target} ->
            Path.expand(target, "/") == "/usr/" <> name and File.dir?("/usr/" <> name)

          _ ->
            false
        end
      end)
  end

  defp optional_programs(path, layout) do
    directories =
      String.split(path, ":", trim: true) |> Enum.filter(&(Path.type(&1) == :absolute))

    Enum.flat_map(@programs, fn name ->
      candidate =
        Enum.find_value(directories, fn dir ->
          candidate = Path.join(dir, name)

          case File.stat(candidate) do
            {:ok, %{type: :regular, mode: mode}} ->
              if Bitwise.band(mode, 0o111) != 0, do: candidate

            _ ->
              nil
          end
        end)

      case canonical_executable(candidate) do
        {:ok, executable} -> if included?(layout, executable), do: [executable], else: []
        _ -> []
      end
    end)
  end

  defp included?(:nix_closure, executable), do: store_root(executable) != nil
  defp included?(:merged_usr, executable), do: String.starts_with?(executable, "/usr/")

  # An explicit override is trusted constructor input used by probe fixtures;
  # automatic discovery must resolve to immutable software outside the workspace.
  defp trusted_bwrap(_path, _layout, _workspace, true), do: :ok

  defp trusted_bwrap(path, layout, workspace, false) do
    workspace = Path.expand(workspace)

    if included?(layout, path) and path != workspace and
         not String.starts_with?(path, workspace <> "/"),
       do: :ok,
       else: unavailable("automatically discovered bubblewrap is not trusted immutable software")
  end

  defp roots(:merged_usr, _programs, _workspace), do: {:ok, ["/usr"]}

  defp roots(:nix_closure, programs, workspace) do
    selected = programs |> Enum.map(&store_root/1) |> Enum.uniq()

    with {:ok, query} <- canonical_executable(System.find_executable("nix-store")),
         true <-
           store_root(query) != nil or unavailable("trusted Nix store query is unavailable"),
         # Recent Nix packages make nix-store an argv[0]-selected symlink to nix.
         # Execute the canonical immutable binary with its matching public CLI.
         arguments =
           if(Path.basename(query) == "nix",
             do: [
               "--extra-experimental-features",
               "nix-command",
               "path-info",
               "--recursive" | selected
             ],
             else: ["--query", "--requisites" | selected]
           ),
         {:ok, output} <- probe(query, arguments, workspace),
         closure = String.split(output, "\n", trim: true),
         true <-
           (closure != [] and Enum.all?(closure, &valid_root?/1)) or
             unavailable("Nix returned an invalid runtime closure"),
         true <-
           Enum.all?(selected, &(&1 in closure)) or
             unavailable("Nix runtime closure omitted a selected program") do
      {:ok, Enum.uniq(selected ++ Enum.sort(closure))}
    end
  end

  defp store_root(path) do
    case Path.split(path) do
      ["/", "nix", "store", root | _] ->
        candidate = "/nix/store/" <> root
        if valid_root?(candidate), do: candidate

      _ ->
        nil
    end
  end

  defp valid_root?(path),
    do:
      is_binary(path) and
        String.match?(path, ~r|\A/nix/store/[0-9abcdfghijklmnpqrsvwxyz]{32}-[^/]+\z|) and
        match?({:ok, %{type: :directory}}, File.lstat(path))

  defp supported_bwrap(output) do
    case Regex.run(~r{\Abubblewrap\s+(\d+\.\d+\.\d+)\s*\z}, output) do
      [_, version] ->
        with {:ok, parsed} <- Version.parse(version),
             true <- Version.compare(parsed, "0.10.0") in [:eq, :gt] do
          :ok
        else
          _ -> unavailable("bubblewrap 0.10.0 or newer is required")
        end

      _ ->
        unavailable("bubblewrap version could not be verified")
    end
  end

  defp probe(executable, arguments, workspace) do
    # TODO(upstream): gsmlg-opt/backplane#95
    # Runtime probes require the same trusted bootstrap as sandbox launches.
    with {:ok, server} <- LocalCommand.start_link(name: nil),
         {:ok, command} <-
           Command.new(%{
             adapter: LocalCommand,
             server: server,
             allowed_environment: %{},
             deadline_limit: @query_timeout,
             output_limit: @query_output
           }) do
      invocation = %{
        executable: executable,
        arguments: arguments,
        workspace: workspace,
        environment: %{},
        owner_pid: self(),
        owner_run_id: "sigma-runtime-catalog",
        incarnation: 1,
        session_id: System.unique_integer([:positive, :monotonic])
      }

      result =
        case Command.reserve(command, invocation) do
          :ok ->
            result =
              with {:ok, job} <- Command.start(command, invocation) do
                query_result(
                  command,
                  invocation,
                  job,
                  System.monotonic_time(:millisecond) + @query_timeout
                )
              end

            case cleanup_query(command, invocation) do
              :ok -> result
              error -> error
            end

          error ->
            error
        end

      case stop_query(server) do
        :ok -> result
        error -> error
      end
    end
  catch
    :exit, _ -> unknown("trusted runtime probe outcome is unknown")
  end

  defp query_result(command, invocation, job, deadline) do
    with {:ok, result} <- Command.read(command, invocation, job, cursor: 0) do
      cond do
        result.status == :running and System.monotonic_time(:millisecond) < deadline ->
          receive do
          after
            10 -> query_result(command, invocation, job, deadline)
          end

        result.status == :running ->
          unavailable("trusted runtime probe exceeded its deadline")

        # Public LocalCommand output is a list of lines, as consumed by the
        # public Codex adapter. Store paths are shorter than its line chunk cap.
        result.exit_status == 0 and result.output_limit_exceeded? == false ->
          {:ok, Enum.join(result.output, "\n")}

        true ->
          unavailable("trusted runtime probe failed or exceeded its output limit")
      end
    end
  end

  defp cleanup_query(command, invocation) do
    with :ok <- Command.cancel_confirmed(command, invocation, 4_000),
         :ok <- Command.acknowledge_release(command, invocation),
         do: :ok
  end

  defp stop_query(server) do
    GenServer.stop(server, :normal, 5_000)
    :ok
  catch
    :exit, _ -> unknown("trusted runtime probe cleanup is unconfirmed")
  end

  defp resolve_links([], current, _remaining), do: {:ok, current}
  defp resolve_links(_parts, _current, 0), do: unavailable("runtime symlink limit exceeded")

  defp resolve_links(["/" | rest], current, remaining),
    do: resolve_links(rest, current, remaining)

  defp resolve_links([part | rest], current, remaining) do
    next = Path.join(current, part)

    case File.read_link(next) do
      {:ok, target} ->
        expanded = Path.expand(target, current)
        resolve_links(Path.split(Path.join([expanded | rest])), "/", remaining - 1)

      {:error, :einval} ->
        resolve_links(rest, next, remaining)

      _ ->
        unavailable("runtime executable path is unavailable")
    end
  end

  defp unavailable(message), do: {:error, Error.new(:unsupported_capability, message)}
  defp unknown(message), do: {:error, Error.new(:unknown_outcome, message)}
end
