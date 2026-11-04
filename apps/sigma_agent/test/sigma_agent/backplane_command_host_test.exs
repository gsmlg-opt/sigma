defmodule Sigma.Agent.BackplaneCommandHostTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.{Command, Error, ToolRegistry}
  alias Backplane.AgentRuntime.Codex.Session
  alias Sigma.Agent.Backplane.{CommandHost, CommandRuntime}

  @moduletag :tmp_dir

  test "missing native launcher fails closed", %{tmp_dir: workspace} do
    assert {:error, %Error{class: :unsupported_capability}} =
             CommandHost.start_link(options(workspace, launcher_path: workspace <> "/missing"))

    refute File.exists?(Path.join(workspace, "effect"))
  end

  test "host rejects incomplete unknown and workspace-controlled interpreter aliases", %{
    tmp_dir: workspace
  } do
    base = options(workspace)
    assert {:ok, sh} = CommandRuntime.canonical_executable("/bin/sh")
    assert {:ok, env} = CommandRuntime.canonical_executable("/usr/bin/env")

    for aliases <- [
          %{"sh" => sh},
          %{"sh" => sh, "env" => env, "python" => sh},
          %{"sh" => sh, "env" => Path.join(workspace, "env")}
        ] do
      assert {:error, %Error{class: :unsupported_capability}} =
               CommandHost.start_link(Keyword.put(base, :runtime_aliases, aliases))
    end
  end

  test "workspace is writable and ambient home and sibling directories are isolated", %{
    tmp_dir: root
  } do
    original_secret = System.get_env("SIGMA_HOST_SECRET")
    System.put_env("SIGMA_HOST_SECRET", "must-not-enter-payload")

    on_exit(fn ->
      if original_secret,
        do: System.put_env("SIGMA_HOST_SECRET", original_secret),
        else: System.delete_env("SIGMA_HOST_SECRET")
    end)

    workspace = Path.join(root, "workspace")
    File.mkdir!(workspace)
    outside = Path.join(root, "outside-secret")
    File.write!(outside, "secret")
    {host, binding, command} = host!(workspace)

    request =
      invocation(
        binding,
        workspace,
        "printf work > result; test ! -e '#{outside}' || exit 80; " <>
          "test \"$HOME\" = /home/sigma || exit 81; " <>
          "test -z \"$SIGMA_HOST_SECRET\" || exit 82; printf sandbox-ok"
      )

    assert :ok = Command.reserve(command, request)
    assert {:ok, job} = Command.start(command, request)
    assert %{exit_status: 0, output: output} = completed!(command, request, job)
    assert IO.iodata_to_binary(output) == "sandbox-ok"
    assert File.read!(Path.join(workspace, "result")) == "work"
    assert :ok = Command.cancel_confirmed(command, request, 3_000)
    assert :ok = Command.acknowledge_release(command, request)
    assert :ok = Command.acknowledge_release(command, request)
    assert :ok = Command.cancel_confirmed(command, request, 3_000)
    assert {:error, %Error{class: :unsupported_capability}} = Command.terminal(command)
    assert Process.alive?(host)
  end

  test "detached routes cannot start or write but recorded cleanup still works", %{
    tmp_dir: workspace
  } do
    {_host, binding, command} = host!(workspace)
    request = invocation(binding, workspace, "IFS= read -r line; printf '%s' \"$line\"")
    assert :ok = Command.reserve(command, request)
    assert {:ok, job} = Command.start(command, request)
    assert :ok = Session.prepare_detach(binding)
    assert {:ok, %{status: :retained}} = Session.detach(binding)

    assert {:error, %Error{class: :forbidden}} = Command.write(command, request, job, "late\n")
    assert {:error, %Error{class: :forbidden}} = Command.start(command, request)
    assert :ok = Command.cancel_confirmed(command, request, 3_000)
    assert :ok = Command.acknowledge_release(command, request)
  end

  test "retained pipe uses a new actual run binding and rejects stale or forged jobs", %{
    tmp_dir: workspace
  } do
    {host, binding, first} = host!(workspace)
    request = invocation(binding, workspace, "IFS= read -r line; printf '%s' \"$line\"")
    assert :ok = Command.reserve(first, request)
    assert {:ok, job} = Command.start(first, request)
    assert :ok = Session.prepare_detach(binding)
    assert {:ok, %{status: :retained}} = Session.detach(binding)
    next = binding!(binding.session, "second-run")
    assert {:ok, command} = CommandHost.bind(host, next)

    assert {:error, %Error{class: :forbidden}} = Command.write(first, request, job, "stale\n")

    assert {:error, %Error{class: :forbidden}} =
             Command.write(command, request, Map.put(job, :port, make_ref()), "forged\n")

    assert :ok = Command.write(command, request, job, "fresh\n")
    assert %{exit_status: 0, output: output} = completed!(command, request, job)
    assert IO.iodata_to_binary(output) == "fresh"
    assert :ok = Command.cancel_confirmed(command, request, 3_000)
    assert :ok = Command.acknowledge_release(command, request)
  end

  test "out of workspace cwd and environment widening never execute", %{tmp_dir: workspace} do
    {_host, binding, command} = host!(workspace)
    request = invocation(binding, workspace, "printf bad > effect")
    outside = %{request | workspace: Path.dirname(workspace)}
    assert :ok = Command.reserve(command, outside)
    assert {:error, %Error{class: :forbidden} = refusal} = Command.start(command, outside)
    assert :ok = Command.validate_refusal(command, outside, refusal)

    assert {:error, %Error{class: :unknown_outcome}} =
             Command.validate_refusal(command, request, refusal)

    assert :ok = Command.cancel_confirmed(command, outside, 3_000)
    assert :ok = Command.acknowledge_release(command, outside)

    assert {:error, %Error{class: :forbidden}} =
             Command.start(command, %{request | environment: %{"LD_PRELOAD" => "bad"}})

    refute File.exists?(Path.join(workspace, "effect"))
  end

  test "launched identities never acquire nonexecution proof on duplicate or stale requests", %{
    tmp_dir: workspace
  } do
    {_host, binding, command} = host!(workspace)
    request = invocation(binding, workspace, "IFS= read -r line; printf '%s' \"$line\"")
    assert :ok = Command.reserve(command, request)
    assert {:ok, _job} = Command.start(command, request)

    for attempted <- [
          request,
          %{request | workspace: Path.dirname(workspace)},
          %{request | environment: %{"LD_PRELOAD" => "bad"}}
        ] do
      assert {:error, %Error{} = error} = Command.start(command, attempted)

      assert {:error, %Error{class: :unknown_outcome}} =
               Command.validate_refusal(command, attempted, error)

      refute error.details[:launch_status] == :never_started
    end

    assert :ok = Session.prepare_detach(binding)
    assert {:ok, %{status: :retained}} = Session.detach(binding)
    assert {:error, %Error{} = stale} = Command.start(command, request)

    assert {:error, %Error{class: :unknown_outcome}} =
             Command.validate_refusal(command, request, stale)

    assert :ok = Command.cancel_confirmed(command, request, 3_000)
    assert :ok = Command.acknowledge_release(command, request)
    assert {:error, %Error{} = released} = Command.start(command, request)

    assert {:error, %Error{class: :unknown_outcome}} =
             Command.validate_refusal(command, request, released)
  end

  test "cleanup requires the Session capability and malformed refusal proofs are typed", %{
    tmp_dir: workspace
  } do
    {_host, binding, command} = host!(workspace)
    request = invocation(binding, workspace, "IFS= read -r line")
    assert :ok = Command.reserve(command, request)
    assert {:ok, job} = Command.start(command, request)
    forged = %{command | workspace_key: %{command.workspace_key | cleanup_token: make_ref()}}

    assert {:error, %Error{class: :forbidden}} =
             Command.cancel_confirmed(forged, request, 3_000)

    assert {:error, %Error{class: :forbidden}} = Command.cancel(forged, request)
    assert {:error, %Error{class: :forbidden}} = Command.acknowledge_release(forged, request)
    assert {:ok, %{status: :running}} = Command.read(command, request, job, cursor: 0)

    for proof <- [nil, 123, <<>>, <<1>>, :crypto.strong_rand_bytes(32)] do
      error = %{Error.new(:forbidden, "forged") | cause: {:sigma_sandbox_refusal, proof}}

      assert {:error, %Error{class: :unknown_outcome}} =
               Command.validate_refusal(command, request, error)
    end

    assert Process.alive?(command.server)
    assert :ok = Session.prepare_detach(binding)
    assert {:ok, %{status: :retained}} = Session.detach(binding)
    assert :ok = Command.cancel_confirmed(command, request, 3_000)
    assert :ok = Command.acknowledge_release(command, request)
  end

  test "abrupt host death closes its public port and recorded OS descendants", %{
    tmp_dir: workspace
  } do
    {host, binding, command} = host!(workspace)
    request = invocation(binding, workspace, "printf 'sandbox-ready\\n'; IFS= read -r line")
    assert :ok = Command.reserve(command, request)
    assert {:ok, job} = Command.start(command, request)
    running!(command, request, job)
    identities = process_tree!(job)
    monitor = Process.monitor(host)

    Process.exit(host, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^host, :killed}, 5_000
    stopped!(job.port, identities)
  end

  test "host owner exit cleans its waiting command and recorded OS descendants", %{
    tmp_dir: workspace
  } do
    session = start_supervised!({Session, owner_pid: self()}, id: make_ref())
    binding = binding!(session, "owner-exit")
    parent = self()
    opts = options(workspace)

    owner =
      spawn(fn ->
        {:ok, host} = CommandHost.start_link(Keyword.put(opts, :owner_pid, self()))
        {:ok, command} = CommandHost.bind(host, binding)
        send(parent, {:owned_host, self(), host, command})
        receive do: (:stop -> :ok)
      end)

    on_exit(fn -> if Process.alive?(owner), do: send(owner, :stop) end)
    assert_receive {:owned_host, ^owner, host, command}, 5_000
    request = invocation(binding, workspace, "printf 'sandbox-ready\\n'; IFS= read -r line")
    assert :ok = Command.reserve(command, request)
    assert {:ok, job} = Command.start(command, request)
    running!(command, request, job)
    identities = process_tree!(job)
    monitor = Process.monitor(host)

    send(owner, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^host, :normal}, 5_000
    stopped!(job.port, identities)
  end

  defp host!(workspace) do
    session = start_supervised!({Session, owner_pid: self()}, id: make_ref())
    binding = binding!(session, "first-run")
    host = start_supervised!({CommandHost, options(workspace)}, id: make_ref())
    assert {:ok, command} = CommandHost.bind(host, binding)
    {host, binding, command}
  end

  defp binding!(session, run) do
    authority = %{caller: "sandbox-host-test", run_id: run, grants: [], tool_revision: 1}
    assert {:ok, binding} = Session.bind(session, authority, incarnation: 7)
    assert :ok = Session.attach(binding, %{authority: authority, registry: %ToolRegistry{}})
    binding
  end

  defp invocation(binding, workspace, script) do
    %{
      executable: shell(),
      arguments: ["-c", script],
      owner_run_id: binding.owner_id,
      incarnation: binding.incarnation,
      owner_pid: self(),
      session_id: System.unique_integer([:positive, :monotonic]),
      workspace: workspace,
      environment: %{}
    }
  end

  defp options(workspace, overrides \\ []) do
    assert {:ok, runtime} =
             CommandRuntime.resolve(workspace: workspace, path: "", shell: "/bin/sh")

    runtime
    |> Keyword.merge(workspace: workspace, owner_pid: self())
    |> Keyword.merge(overrides)
  end

  defp shell do
    assert {:ok, path} = CommandRuntime.canonical_executable("/bin/sh")
    path
  end

  defp running!(command, request, job, attempts \\ 300)
  defp running!(_command, _request, _job, 0), do: flunk("sandbox payload did not become ready")

  defp running!(command, request, job, attempts) do
    assert {:ok, result} = Command.read(command, request, job, cursor: 0)
    assert result.status == :running

    unless String.contains?(IO.iodata_to_binary(result.output), "sandbox-ready") do
      Process.sleep(10)
      running!(command, request, job, attempts - 1)
    end
  end

  # The OS PID comes only from the returned public port. /proc is an external
  # observer; no dependency process state is inspected. These are captured live
  # descendants, not a claim about every possible future descendant or IPC path.
  defp process_tree!(job) do
    assert {:os_pid, root} = :erlang.port_info(job.port, :os_pid)

    entries =
      for name <- File.ls!("/proc"),
          {pid, ""} <- [Integer.parse(name)],
          entry = process(pid),
          entry != nil,
          into: %{},
          do: {pid, entry}

    ids = descendant_ids(entries, MapSet.new([root]))
    assert MapSet.size(ids) >= 2
    Enum.map(ids, fn pid -> {pid, Map.fetch!(entries, pid).started} end)
  end

  defp descendant_ids(entries, known) do
    next =
      Enum.reduce(entries, known, fn {pid, entry}, acc ->
        if MapSet.member?(known, entry.parent), do: MapSet.put(acc, pid), else: acc
      end)

    if next == known, do: known, else: descendant_ids(entries, next)
  end

  defp process(pid) do
    with {:ok, stat} <- File.read("/proc/#{pid}/stat"),
         [_prefix, tail] <- String.split(stat, ") ", parts: 2),
         fields = String.split(tail),
         {parent, ""} <- Integer.parse(Enum.at(fields, 1)),
         {started, ""} <- Integer.parse(Enum.at(fields, 19)) do
      %{parent: parent, started: started, state: hd(fields)}
    else
      _ -> nil
    end
  end

  defp stopped!(port, identities, attempts \\ 400)
  defp stopped!(_port, _identities, 0), do: flunk("owned sandbox OS process remains alive")

  defp stopped!(port, identities, attempts) do
    live? =
      Enum.any?(identities, fn {pid, started} ->
        case process(pid) do
          %{started: ^started, state: state} -> state not in ["Z", "X"]
          _ -> false
        end
      end)

    if :erlang.port_info(port) != :undefined or live? do
      Process.sleep(10)
      stopped!(port, identities, attempts - 1)
    end
  end

  defp completed!(command, request, job, attempts \\ 200)
  defp completed!(_command, _request, _job, 0), do: flunk("sandbox command did not settle")

  defp completed!(command, request, job, attempts) do
    assert {:ok, result} = Command.read(command, request, job, cursor: 0)

    if result.status == :running do
      Process.sleep(10)
      completed!(command, request, job, attempts - 1)
    else
      result
    end
  end
end
