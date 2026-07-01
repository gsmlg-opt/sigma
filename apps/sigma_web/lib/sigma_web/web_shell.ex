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
    cols = normalize_size(Keyword.get(opts, :cols), 120)
    rows = normalize_size(Keyword.get(opts, :rows), 24)

    with :ok <- validate_cwd(cwd),
         {:ok, shell, shell_args} <- shell_command(opts, cols, rows),
         {:ok, port} <- open_port(shell, shell_args, cwd, cols, rows) do
      owner_ref = Process.monitor(owner)

      {:ok,
       %__MODULE__{
         owner: owner,
         owner_ref: owner_ref,
         cwd: cwd,
         port: port,
         cols: cols,
         rows: rows
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

  defp shell_command(opts, cols, rows) do
    shell = Keyword.get(opts, :shell) || System.get_env("SHELL") || find_default_shell()
    explicit_shell_args? = Keyword.has_key?(opts, :shell_args)
    shell_args = Keyword.get(opts, :shell_args, default_shell_args(shell, pty?: true))

    cond do
      is_nil(shell) ->
        {:error, "No shell executable found"}

      not File.exists?(shell) ->
        {:error, "Shell executable does not exist: #{shell}"}

      explicit_shell_args? ->
        {:ok, shell, shell_args}

      true ->
        {:ok, command, args} = pty_shell_command(shell, shell_args, cols, rows)
        {:ok, command, args}
    end
  end

  defp find_default_shell do
    System.find_executable("zsh") ||
      System.find_executable("bash") ||
      System.find_executable("sh")
  end

  defp default_shell_args(nil, _opts), do: []

  defp default_shell_args(shell, opts) do
    case shell |> Path.basename() |> String.downcase() do
      "bash" -> if opts[:pty?], do: ["-i"], else: ["--noprofile", "--norc", "-i"]
      "fish" -> if opts[:pty?], do: ["-i"], else: ["--no-config", "-i"]
      "zsh" -> if opts[:pty?], do: ["-i"], else: ["-f", "-i"]
      "sh" -> ["-i"]
      _ -> []
    end
  end

  defp pty_shell_command(shell, shell_args, cols, rows) do
    case System.find_executable("script") do
      nil ->
        {:ok, shell, default_shell_args(shell, pty?: false)}

      script ->
        {:ok, script, script_args(shell, shell_args, cols, rows)}
    end
  end

  defp script_args(shell, shell_args, cols, rows) do
    command = pty_bootstrap_command(shell, shell_args, cols, rows)

    case :os.type() do
      {:unix, :linux} ->
        ["-q", "-c", command, "/dev/null"]

      _ ->
        ["-q", "/dev/null", "/bin/sh", "-lc", command]
    end
  end

  defp pty_bootstrap_command(shell, shell_args, cols, rows) do
    shell_command =
      [shell | shell_args]
      |> Enum.map(&shell_escape/1)
      |> Enum.join(" ")

    "stty cols #{cols} rows #{rows} 2>/dev/null || true; exec #{shell_command}"
  end

  defp shell_escape(value) do
    "'" <> String.replace(to_string(value), "'", "'\"'\"'") <> "'"
  end

  defp open_port(shell, shell_args, cwd, cols, rows) do
    port =
      Port.open({:spawn_executable, shell}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        :use_stdio,
        args: shell_args,
        cd: cwd,
        env: terminal_env(cwd, cols, rows)
      ])

    {:ok, port}
  rescue
    error -> {:error, "Could not start shell: #{Exception.message(error)}"}
  end

  defp terminal_env(cwd, cols, rows) do
    %{
      "COLUMNS" => to_string(cols),
      "COLORTERM" => "truecolor",
      "LINES" => to_string(rows),
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
