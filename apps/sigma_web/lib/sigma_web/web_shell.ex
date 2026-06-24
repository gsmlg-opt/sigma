defmodule Sigma.Web.WebShell do
  @moduledoc """
  Supervised shell process for the browser terminal.
  """

  use GenServer

  defstruct [:owner, :owner_ref, :cwd, :port, :cols, :rows]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def child_spec(opts) do
    %{
      id: {__MODULE__, make_ref()},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  def open(opts) do
    DynamicSupervisor.start_child(Sigma.Web.WebShellSupervisor, {__MODULE__, opts})
  end

  def input(pid, data) when is_pid(pid) and is_binary(data) do
    GenServer.cast(pid, {:input, data})
  end

  def resize(pid, cols, rows) when is_pid(pid) do
    GenServer.cast(pid, {:resize, cols, rows})
  end

  def stop(pid) when is_pid(pid), do: GenServer.stop(pid, :normal)

  @impl true
  def init(opts) do
    owner = Keyword.fetch!(opts, :owner)
    cwd = opts |> Keyword.get(:cwd, File.cwd!()) |> Path.expand()

    with :ok <- validate_cwd(cwd),
         {:ok, shell, shell_args} <- shell_command(opts),
         {:ok, port} <- open_port(shell, shell_args, cwd) do
      owner_ref = Process.monitor(owner)

      {:ok,
       %__MODULE__{
         owner: owner,
         owner_ref: owner_ref,
         cwd: cwd,
         port: port,
         cols: 120,
         rows: 24
       }}
    else
      {:error, reason} -> {:stop, {:shutdown, reason}}
    end
  end

  @impl true
  def handle_cast({:input, data}, %{port: port} = state) do
    Port.command(port, normalize_input(data))
    {:noreply, state}
  rescue
    _ -> {:noreply, state}
  end

  @impl true
  def handle_cast({:resize, cols, rows}, state) do
    {:noreply, %{state | cols: normalize_size(cols, state.cols), rows: normalize_size(rows, state.rows)}}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port, owner: owner} = state) do
    send(owner, {:web_shell_output, self(), data})
    {:noreply, state}
  end

  @impl true
  def handle_info({port, {:exit_status, status}}, %{port: port, owner: owner} = state) do
    send(owner, {:web_shell_exit, self(), status})
    {:stop, :normal, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state) do
    {:stop, :normal, state}
  end

  @impl true
  def terminate(_reason, %{port: port, owner_ref: owner_ref}) do
    Process.demonitor(owner_ref, [:flush])
    close_port(port)
    :ok
  end

  defp validate_cwd(cwd) do
    if File.dir?(cwd) do
      :ok
    else
      {:error, "Working directory does not exist: #{cwd}"}
    end
  end

  defp shell_command(opts) do
    shell = Keyword.get(opts, :shell) || System.get_env("SHELL") || find_default_shell()
    shell_args = Keyword.get(opts, :shell_args, default_shell_args(shell))

    cond do
      is_nil(shell) ->
        {:error, "No shell executable found"}

      not File.exists?(shell) ->
        {:error, "Shell executable does not exist: #{shell}"}

      true ->
        {:ok, shell, shell_args}
    end
  end

  defp find_default_shell do
    System.find_executable("zsh") ||
      System.find_executable("bash") ||
      System.find_executable("sh")
  end

  defp default_shell_args(nil), do: []

  defp default_shell_args(shell) do
    case shell |> Path.basename() |> String.downcase() do
      name when name in ["bash", "fish", "sh", "zsh"] -> ["-i"]
      _ -> []
    end
  end

  defp open_port(shell, shell_args, cwd) do
    port =
      Port.open({:spawn_executable, shell}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        :use_stdio,
        args: shell_args,
        cd: cwd,
        env: terminal_env(cwd)
      ])

    {:ok, port}
  rescue
    error -> {:error, "Could not start shell: #{Exception.message(error)}"}
  end

  defp terminal_env(cwd) do
    %{
      "COLORTERM" => "truecolor",
      "PS1" => "\\w $ ",
      "PWD" => cwd,
      "TERM" => "xterm-256color"
    }
    |> Enum.map(fn {key, value} -> {to_charlist(key), to_charlist(value)} end)
  end

  defp normalize_input(data), do: String.replace(data, "\r", "\n")

  defp normalize_size(value, _fallback) when is_integer(value) and value > 0, do: value

  defp normalize_size(value, fallback) when is_binary(value) do
    case Integer.parse(value) do
      {size, ""} when size > 0 -> size
      _ -> fallback
    end
  end

  defp normalize_size(_value, fallback), do: fallback

  defp close_port(port) do
    Port.close(port)
  rescue
    _ -> :ok
  end
end
