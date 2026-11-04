defmodule Sigma.Agent.Backplane.CommandLauncher do
  @moduledoc """
  Application-lifetime snapshot of the build-pinned native launcher.

  The private executable is outside every admitted workspace. Replacing a
  workspace build artifact cannot refresh an existing snapshot. Normal shutdown
  removes this process's own files; abrupt VM death can leave temporary files.
  """
  use GenServer, restart: :temporary
  alias Backplane.AgentRuntime.Error

  @source Path.expand("../../../priv/native/sigma-sandbox-launcher", __DIR__)
  @external_resource @source
  @manifest (case File.read(@source) do
               {:ok, bytes} -> {byte_size(bytes), :crypto.hash(:sha256, bytes)}
               _ -> nil
             end)

  def start_link(opts) do
    source =
      Keyword.get(
        opts,
        :source_path,
        Application.app_dir(:sigma_agent, "priv/native/sigma-sandbox-launcher")
      )

    with {:ok, bytes} <- pinned_bytes(source),
         {:ok, root} <- private_root(Keyword.get(opts, :tmp_root, System.tmp_dir!())) do
      GenServer.start_link(__MODULE__, {root, bytes}, Keyword.take(opts, [:name]))
    end
  end

  def open(workspace) do
    case Registry.lookup(Sigma.Agent.RepositoryRegistry, {__MODULE__, @manifest}) do
      [{pid, _}] ->
        path(pid, workspace)

      [] ->
        with {:ok, root} <- private_root(System.tmp_dir!()),
             :ok <- outside(root, workspace) do
          name = {:via, Registry, {Sigma.Agent.RepositoryRegistry, {__MODULE__, @manifest}}}

          case DynamicSupervisor.start_child(
                 Sigma.Agent.DynamicSupervisor,
                 {__MODULE__, name: name, tmp_root: root}
               ) do
            {:ok, pid} -> path(pid, workspace)
            {:error, {:already_started, pid}} -> path(pid, workspace)
            error -> error
          end
        end
    end
  catch
    :exit, _ -> unavailable("trusted launcher snapshot is unavailable")
  end

  def path(pid, workspace), do: GenServer.call(pid, {:path, workspace})

  @impl true
  def init({root, bytes}) do
    Process.flag(:trap_exit, true)

    directory =
      Path.join(
        root,
        "sigma-command-launcher-" <>
          Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
      )

    file = Path.join(directory, "sigma-sandbox-launcher")

    case File.mkdir(directory) do
      :ok ->
        with :ok <- File.chmod(directory, 0o700),
             :ok <- write_snapshot(file, bytes) do
          {:ok, %{directory: directory, file: file}}
        else
          _ ->
            File.rm(file)
            File.rmdir(directory)

            {:stop,
             {:shutdown, elem(unavailable("trusted launcher snapshot creation failed"), 1)}}
        end

      _ ->
        {:stop, {:shutdown, elem(unavailable("trusted launcher snapshot directory failed"), 1)}}
    end
  end

  @impl true
  def handle_call({:path, workspace}, _from, state) do
    with :ok <- outside(state.file, workspace),
         {:ok, %{type: :regular, mode: mode}} <- File.lstat(state.file),
         true <- Bitwise.band(mode, 0o777) == 0o500 do
      {:reply, {:ok, state.file}, state}
    else
      _ -> {:reply, unavailable("trusted launcher snapshot is not isolated or available"), state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    File.rm(state.file)
    File.rmdir(state.directory)
    :ok
  end

  defp pinned_bytes(source) do
    case @manifest do
      {size, digest} ->
        with {:ok, %{type: :regular, size: ^size}} <- File.lstat(source),
             {:ok, file} <- :file.open(String.to_charlist(source), [:read, :binary, :raw]) do
          result = :file.read(file, size + 1)
          closed = :file.close(file)

          case {result, closed} do
            {{:ok, bytes}, :ok} when byte_size(bytes) == size ->
              if :crypto.hash_equals(:crypto.hash(:sha256, bytes), digest),
                do: {:ok, bytes},
                else: unavailable("launcher differs from its compiled manifest")

            _ ->
              unavailable("launcher differs from its compiled manifest")
          end
        else
          _ -> unavailable("build-pinned launcher must be an available regular file")
        end

      nil ->
        unavailable("launcher was absent when this module was compiled")
    end
  end

  defp write_snapshot(path, bytes) do
    with {:ok, file} <- :file.open(String.to_charlist(path), [:write, :binary, :raw, :exclusive]) do
      result =
        with :ok <- :file.write(file, bytes), :ok <- File.chmod(path, 0o500), do: :file.sync(file)

      closed = :file.close(file)
      if result == :ok and closed == :ok, do: :ok, else: {:error, :snapshot_write_failed}
    end
  end

  defp private_root(root) when is_binary(root) do
    root = Path.expand(root)
    components = Path.split(root) |> Enum.scan(fn part, acc -> Path.join(acc, part) end)

    if Enum.all?(components, &match?({:ok, %{type: :directory}}, File.lstat(&1))),
      do: {:ok, root},
      else: unavailable("snapshot parent must be a real directory")
  end

  defp private_root(_), do: unavailable("snapshot parent is unavailable")

  defp outside(path, workspace) when is_binary(workspace) do
    expanded = Path.expand(workspace)

    if Path.type(workspace) == :absolute and expanded != "/" and
         path != expanded and not String.starts_with?(path, expanded <> "/"),
       do: :ok,
       else: unavailable("workspace would expose the trusted launcher snapshot")
  end

  defp outside(_path, _workspace), do: unavailable("snapshot requires an absolute workspace")

  defp unavailable(message), do: {:error, Error.new(:unsupported_capability, message)}
end
