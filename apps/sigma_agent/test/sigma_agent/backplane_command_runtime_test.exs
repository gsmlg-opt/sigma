defmodule Sigma.Agent.BackplaneCommandRuntimeTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.{Command, Error, ToolRegistry}
  alias Backplane.AgentRuntime.Codex.Session
  alias Sigma.Agent.Backplane.{CommandHost, CommandRuntime}

  @moduletag :tmp_dir

  test "trusted runtime resolves an explicit closure and launches coding utilities", %{
    tmp_dir: workspace
  } do
    assert {:ok, options} = CommandRuntime.resolve(workspace: workspace)
    assert Keyword.fetch!(options, :runtime_layout) in [:nix_closure, :merged_usr]
    roots = Keyword.fetch!(options, :runtime_roots)
    assert roots != []
    refute "/" in roots
    refute "/nix/store" in roots
    refute System.user_home!() in roots
    assert Enum.all?(roots, &File.dir?/1)

    session = start_supervised!({Session, owner_pid: self()})
    authority = %{caller: "runtime-test", run_id: "runtime", grants: [], tool_revision: 1}
    assert {:ok, binding} = Session.bind(session, authority)
    assert :ok = Session.attach(binding, %{authority: authority, registry: %ToolRegistry{}})
    host_opts = Keyword.merge(options, workspace: workspace, owner_pid: self())
    host = start_supervised!({CommandHost, host_opts})
    assert {:ok, command} = CommandHost.bind(host, binding)

    invocation = %{
      executable: "/bin/sh",
      arguments: ["-c", "printf runtime-ok | cat"],
      workspace: workspace,
      environment: %{},
      owner_run_id: binding.owner_id,
      incarnation: binding.incarnation,
      session_id: System.unique_integer([:positive, :monotonic])
    }

    assert :ok = Command.reserve(command, invocation)
    assert {:ok, job} = Command.start(command, invocation)
    result = completed!(command, invocation, job)
    assert result.exit_status == 0
    assert IO.iodata_to_binary(result.output) == "runtime-ok"
    assert :ok = Command.cancel_confirmed(command, invocation, 3_000)
    assert :ok = Command.acknowledge_release(command, invocation)
  end

  test "optional user scripts are not executed or mounted", %{tmp_dir: workspace} do
    bin = Path.join(workspace, "bin")
    File.mkdir!(bin)
    marker = Path.join(workspace, "must-not-exist")
    script = Path.join(bin, "git")
    File.write!(script, "#!/bin/sh\nprintf bad > '#{marker}'\n")
    File.chmod!(script, 0o700)

    assert {:ok, options} = CommandRuntime.resolve(workspace: workspace, path: bin)
    roots = Keyword.fetch!(options, :runtime_roots)
    refute workspace in roots
    refute bin in roots
    refute script in roots
    refute File.exists?(marker)
  end

  test "kernel executes fixed shell and env shebangs inside the sandbox", %{tmp_dir: workspace} do
    File.write!(Path.join(workspace, "shell-script"), "#!/bin/sh\nprintf shell-ok\n")
    File.write!(Path.join(workspace, "env-script"), "#!/usr/bin/env sh\nprintf env-ok\n")
    File.chmod!(Path.join(workspace, "shell-script"), 0o700)
    File.chmod!(Path.join(workspace, "env-script"), 0o700)
    assert {:ok, options} = CommandRuntime.resolve(workspace: workspace)
    assert {:ok, python} = CommandRuntime.canonical_executable(System.find_executable("python3"))
    session = start_supervised!({Session, owner_pid: self()})
    authority = %{caller: "shebang-test", run_id: "shebang", grants: [], tool_revision: 1}
    assert {:ok, binding} = Session.bind(session, authority)
    assert :ok = Session.attach(binding, %{authority: authority, registry: %ToolRegistry{}})

    host =
      start_supervised!(
        {CommandHost, Keyword.merge(options, workspace: workspace, owner_pid: self())}
      )

    assert {:ok, command} = CommandHost.bind(host, binding)

    # subprocess uses execve directly: a shell must not hide a missing kernel
    # interpreter by falling back to interpreting the script itself.
    script =
      "import json,subprocess; print(json.dumps([subprocess.check_output([p],text=True) for p in ['./shell-script','./env-script']]))"

    request = %{
      executable: python,
      arguments: ["-c", script],
      workspace: workspace,
      environment: %{},
      owner_run_id: binding.owner_id,
      incarnation: binding.incarnation,
      session_id: System.unique_integer([:positive, :monotonic])
    }

    assert :ok = Command.reserve(command, request)
    assert {:ok, job} = Command.start(command, request)
    result = completed!(command, request, job)
    assert result.exit_status == 0, inspect(result)
    assert Jason.decode!(IO.iodata_to_binary(result.output)) == ["shell-ok", "env-ok"]
    assert :ok = Command.cancel_confirmed(command, request, 3_000)
    assert :ok = Command.acknowledge_release(command, request)
  end

  test "fixed env executable ignores workspace PATH and contributes its exact runtime closure", %{
    tmp_dir: workspace
  } do
    bin = Path.join(workspace, "bin")
    File.mkdir!(bin)
    marker = Path.join(workspace, "must-not-exist")
    File.write!(Path.join(bin, "env"), "#!/bin/sh\nprintf bad > '#{marker}'\n")
    File.chmod!(Path.join(bin, "env"), 0o700)
    assert {:ok, shell} = CommandRuntime.canonical_executable("/bin/sh")
    assert {:ok, env} = CommandRuntime.canonical_executable("/usr/bin/env")

    assert {:ok, options} =
             CommandRuntime.resolve(workspace: workspace, path: bin, shell: "/bin/sh")

    roots = Keyword.fetch!(options, :runtime_roots)
    assert Enum.any?(roots, &String.starts_with?(env, &1 <> "/"))
    refute bin in roots
    refute File.exists?(marker)

    case Keyword.fetch!(options, :runtime_layout) do
      :nix_closure ->
        assert Keyword.fetch!(options, :runtime_aliases) == %{"sh" => shell, "env" => env}

      :merged_usr ->
        assert Keyword.get(options, :runtime_aliases, %{}) == %{}
    end
  end

  test "required shell outside a supported immutable runtime fails closed", %{tmp_dir: workspace} do
    shell = Path.join(workspace, "user-shell")
    File.write!(shell, "#!/bin/sh\nexit 0\n")
    File.chmod!(shell, 0o700)

    assert {:error, %Error{class: :unsupported_capability}} =
             CommandRuntime.resolve(workspace: workspace, shell: shell)
  end

  test "missing required shell has a typed failure", %{tmp_dir: workspace} do
    assert {:error, %Error{class: :unsupported_capability}} =
             CommandRuntime.resolve(workspace: workspace, shell: Path.join(workspace, "missing"))
  end

  test "old bubblewrap is rejected by a bounded fixed version probe", %{tmp_dir: workspace} do
    binary = Path.join(workspace, "old-bwrap")
    marker = Path.join(workspace, "must-not-launch")

    File.write!(
      binary,
      "#!/bin/sh\nif [ \"$1\" = --version ] && [ \"$#\" = 1 ]; then printf 'bubblewrap 0.9.0\\n'; else printf bad > '#{marker}'; fi\n"
    )

    File.chmod!(binary, 0o700)

    assert {:error, %Error{class: :unsupported_capability, message: message}} =
             CommandRuntime.resolve(workspace: workspace, bwrap_path: binary)

    assert message =~ "0.10.0"
    refute File.exists?(marker)
  end

  defp completed!(command, invocation, job, attempts \\ 300)
  defp completed!(_command, _invocation, _job, 0), do: flunk("runtime fixture did not settle")

  defp completed!(command, invocation, job, attempts) do
    assert {:ok, result} = Command.read(command, invocation, job, cursor: 0)

    if result.status == :running do
      Process.sleep(10)
      completed!(command, invocation, job, attempts - 1)
    else
      result
    end
  end
end
