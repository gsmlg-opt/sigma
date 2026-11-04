defmodule Sigma.Agent.BackplaneCommandLauncherTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.Error
  alias Sigma.Agent.Backplane.CommandLauncher

  @moduletag :tmp_dir

  test "a private pinned snapshot survives replacement of the workspace artifact", %{
    tmp_dir: root
  } do
    workspace = Path.join(root, "workspace")
    snapshots = Path.join(root, "snapshots")
    File.mkdir_p!(workspace)
    File.mkdir_p!(snapshots)
    artifact = Path.join(workspace, "launcher")
    File.cp!(Application.app_dir(:sigma_agent, "priv/native/sigma-sandbox-launcher"), artifact)
    original = File.read!(artifact)
    host = start_supervised!({CommandLauncher, source_path: artifact, tmp_root: snapshots})
    assert {:ok, snapshot} = CommandLauncher.path(host, workspace)
    refute String.starts_with?(snapshot, workspace <> "/")
    assert File.read!(snapshot) == original
    assert Bitwise.band(File.stat!(snapshot).mode, 0o777) == 0o500
    assert Bitwise.band(File.stat!(Path.dirname(snapshot)).mode, 0o777) == 0o700

    File.write!(artifact, "#!/bin/sh\nprintf compromised\n")
    assert {:ok, ^snapshot} = CommandLauncher.path(host, workspace)
    assert File.read!(snapshot) == original
    {diagnostic, 125} = System.cmd(snapshot, ["invalid"], stderr_to_stdout: true)
    assert diagnostic =~ "sigma-sandbox-launcher:"
    refute diagnostic =~ "compromised"
    assert :ok = stop_supervised(CommandLauncher)
    refute File.exists?(snapshot)
  end

  test "modified source cannot become a new trusted snapshot", %{tmp_dir: root} do
    artifact = Path.join(root, "modified-launcher")
    File.write!(artifact, "#!/bin/sh\nprintf compromised\n")
    File.chmod!(artifact, 0o755)

    assert {:error, %Error{class: :unsupported_capability}} =
             CommandLauncher.start_link(source_path: artifact, tmp_root: root)

    assert File.ls!(root) == ["modified-launcher"]
  end

  test "nonregular sources fail before a potentially blocking read", %{tmp_dir: root} do
    fifo = Path.join(root, "launcher-fifo")
    assert {_, 0} = System.cmd("mkfifo", [fifo])
    reader = Task.async(fn -> CommandLauncher.start_link(source_path: fifo, tmp_root: root) end)
    result = Task.yield(reader, 500)

    if result == nil do
      # Release a regressed blocking reader before failing the assertion.
      writer = Task.async(fn -> File.write(fifo, "invalid") end)
      Task.yield(reader, 1_000) || Task.shutdown(reader, :brutal_kill)
      Task.yield(writer, 1_000) || Task.shutdown(writer, :brutal_kill)
    end

    assert {:ok, {:error, %Error{class: :unsupported_capability}}} = result
    assert File.ls!(root) == ["launcher-fifo"]
  end

  test "a workspace cannot expose the private snapshot through an ancestor", %{tmp_dir: root} do
    host = start_supervised!({CommandLauncher, tmp_root: root})
    assert {:error, %Error{class: :unsupported_capability}} = CommandLauncher.path(host, root)
    assert {:error, %Error{class: :unsupported_capability}} = CommandLauncher.path(host, "/")
  end

  test "the runtime source follows the relocated application directory", %{tmp_dir: root} do
    original_ebin = Application.app_dir(:sigma_agent, "ebin")
    source = Application.app_dir(:sigma_agent, "priv/native/sigma-sandbox-launcher")
    relocated = Path.join(root, "sigma_agent-relocated")
    ebin = Path.join(relocated, "ebin")
    native = Path.join(relocated, "priv/native")
    File.mkdir_p!(native)
    File.cp_r!(original_ebin, ebin)
    artifact = Path.join(native, "sigma-sandbox-launcher")
    File.write!(artifact, "invalid relocated artifact")

    try do
      assert true = :code.replace_path(:sigma_agent, String.to_charlist(ebin))
      assert Application.app_dir(:sigma_agent, "priv/native/sigma-sandbox-launcher") == artifact

      assert {:error, %Error{class: :unsupported_capability}} =
               CommandLauncher.start_link(tmp_root: root)

      File.cp!(source, artifact)
      host = start_supervised!({CommandLauncher, tmp_root: root})
      assert {:ok, snapshot} = CommandLauncher.path(host, Path.join(root, "workspace"))
      assert File.read!(snapshot) == File.read!(artifact)
      assert :ok = stop_supervised(CommandLauncher)
    after
      assert true = :code.replace_path(:sigma_agent, String.to_charlist(original_ebin))
    end
  end
end
