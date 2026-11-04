#!/usr/bin/env python3
"""Exercise native helpers from an unpacked Linux x86_64 release, without Mix.

Requires bubblewrap >= 0.10 and a working user/PID/network namespace setup.
This calls the packaged launcher directly; it does not establish production
LocalCommand sandbox integration or concurrent cleanup acceptance.
"""

import base64
import json
import os
from pathlib import Path
import platform
import secrets
import selectors
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time


SANDBOX_PAYLOAD = r"""
import errno, json, os, pathlib, socket, sys
workspace = pathlib.Path.cwd()
home = pathlib.Path.home()
private = home / 'installed-release-private'
assert not private.exists(), 'a fresh sandbox inherited private home state'
private.write_text('private')
marker = workspace / 'installed-release-workspace'
previous = marker.read_text() if marker.exists() else None
marker.write_text(sys.argv[3])
assert home == pathlib.Path('/home/sigma')
assert not pathlib.Path(sys.argv[1]).exists(), 'host home is visible'
assert not pathlib.Path(sys.argv[2]).exists(), 'sibling data is visible'
assert 'SIGMA_NATIVE_SMOKE_AMBIENT' not in os.environ
assert os.statvfs(sys.executable).f_flag & os.ST_RDONLY, 'runtime mount is writable'
try:
    descriptor = os.open(sys.executable, os.O_WRONLY)
except OSError as error:
    assert error.errno in (errno.EROFS, errno.EACCES), error
else:
    os.close(descriptor)
    raise AssertionError('runtime executable is writable')
for family in (socket.AF_INET, socket.AF_INET6, socket.AF_UNIX):
    try:
        connection = socket.socket(family, socket.SOCK_STREAM)
    except OSError as error:
        assert error.errno == errno.EPERM, error
    else:
        connection.close()
        raise AssertionError('network/socket creation was allowed')
print(json.dumps({'round': sys.argv[3], 'previous': previous,
                  'workspace': str(workspace), 'home': str(home)}))
sys.exit(23)
"""


LAUNCHER_SMOKE = r'''
{:ok, _} = Application.ensure_all_started(:crypto)
alias Sigma.Agent.Backplane.CommandLauncher
root = System.fetch_env!("SIGMA_NATIVE_SMOKE_ROOT")
release = System.fetch_env!("SIGMA_NATIVE_SMOKE_RELEASE")
workspace = Path.join(root, "workspace")
source = Application.app_dir(:sigma_agent, "priv/native/sigma-sandbox-launcher")
true = String.starts_with?(source, Path.join(release, "lib") <> "/")
beam = CommandLauncher |> :code.which() |> List.to_string()
true = String.starts_with?(beam, Path.join(release, "lib") <> "/")
bytes = File.read!(source)
{:ok, host} = CommandLauncher.start_link(tmp_root: root)

try do
  {:ok, snapshot} = CommandLauncher.path(host, workspace)
  false = String.starts_with?(snapshot, workspace <> "/")
  true = File.read!(snapshot) == bytes
  true = Bitwise.band(File.stat!(snapshot).mode, 0o777) == 0o500
  true = Bitwise.band(File.stat!(Path.dirname(snapshot)).mode, 0o777) == 0o700
  config = System.fetch_env!("SIGMA_NATIVE_SMOKE_CONFIG") |> Jason.decode!()

  for {round, previous} <- [{"first", nil}, {"second", "first"}] do
    config = Map.update!(config, "args", &(&1 ++ [round]))
    {output, 23} = System.cmd(snapshot, ["--config-json", Jason.encode!(config)],
      stderr_to_stdout: true, env: [{"SIGMA_NATIVE_SMOKE_AMBIENT", "must-not-leak"}])
    result = Jason.decode!(output)
    ^round = result["round"]
    ^previous = result["previous"]
    ^workspace = result["workspace"]
  end

  candidate = Path.join(workspace, "candidate-launcher")
  File.write!(candidate, bytes)
  {:ok, other} = CommandLauncher.start_link(source_path: candidate, tmp_root: root)
  try do
    {:ok, retained} = CommandLauncher.path(other, workspace)
    File.write!(candidate, "modified artifact")
    {:ok, ^retained} = CommandLauncher.path(other, workspace)
    true = File.read!(retained) == bytes
    {:error, %Backplane.AgentRuntime.Error{class: :unsupported_capability}} =
      CommandLauncher.start_link(source_path: candidate, tmp_root: root)
    :ok = GenServer.stop(other, :normal)
    false = File.exists?(retained)
  after
    if Process.alive?(other), do: GenServer.stop(other, :normal)
  end

  :ok = GenServer.stop(host, :normal)
  false = File.exists?(snapshot)
  IO.puts(Jason.encode!(%{check: "packaged_launcher", source: source, beam: beam,
    sha256: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower),
    rounds: 2, exit_status: 23, cleanup: true, tamper_rejected: true}))
after
  if Process.alive?(host), do: GenServer.stop(host, :normal)
end
'''


def checked_run(command, *, timeout=30, **options):
    process = subprocess.Popen(command, start_new_session=True, **options)
    try:
        output, error = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.communicate()
        raise AssertionError(f"command timed out: {command[0]}") from None
    if process.returncode:
        raise AssertionError(
            f"command failed ({process.returncode}): {command[0]}\n"
            f"{output or ''}\n{error or ''}"
        )
    return output


def program(name):
    path = shutil.which(name)
    if path is None:
        raise AssertionError(f"required smoke prerequisite is missing: {name}")
    return Path(path).resolve(strict=True)


def runtime_config(python, bwrap, workspace, sibling):
    if python.is_relative_to("/nix/store"):
        store_root = Path("/nix/store") / python.relative_to("/nix/store").parts[0]
        # Nix dispatches its multicall CLI by argv[0]; keep nix-store's basename.
        nix_store = shutil.which("nix-store")
        assert nix_store is not None, "nix-store is a required smoke prerequisite"
        output = checked_run(
            [nix_store, "--query", "--requisites", str(store_root)],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        roots = output.splitlines()
        layout = "nix_closure"
    else:
        assert python.is_relative_to("/usr"), f"unsupported smoke runtime: {python}"
        roots = ["/usr"]
        layout = "merged_usr"
    return {
        "version": 1, "workspace": str(workspace), "cwd": str(workspace),
        "executable": str(python),
        "args": ["-c", SANDBOX_PAYLOAD, str(Path.home()), str(sibling)],
        "runtime_roots": roots, "runtime_layout": layout,
        "env": {}, "bwrap": str(bwrap),
    }


def terminal_smoke(helper, python, workspace):
    payload = (
        "import json,os,sys; "
        "print('SIGMA_PACKAGED_PTY '+json.dumps({'tty':os.isatty(0),"
        "'size':list(os.get_terminal_size(0)),'input':sys.stdin.readline()}),flush=True); "
        "sys.exit(17)"
    )
    process = subprocess.Popen(
        [str(helper), "--cwd", str(workspace), "--rows", "25", "--cols", "91",
         "--", str(python), "-c", payload],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        start_new_session=True,
    )
    incoming = "  中文 PTY  \n"
    frames, output, pending = [], bytearray(), bytearray()
    deadline = time.monotonic() + 15
    try:
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ)
            while True:
                remaining = deadline - time.monotonic()
                assert remaining > 0, "packaged PTY helper timed out"
                assert selector.select(remaining), "packaged PTY helper timed out"
                chunk = os.read(process.stdout.fileno(), 65536)
                if not chunk:
                    break
                pending.extend(chunk)
                while b"\n" in pending:
                    line, _, pending = pending.partition(b"\n")
                    frame = json.loads(line)
                    frames.append(frame)
                    if frame["event"] == "started":
                        process.stdin.write(json.dumps({
                            "op": "input", "data": base64.b64encode(incoming.encode()).decode()
                        }).encode() + b"\n")
                        process.stdin.flush()
                    if frame["event"] == "output":
                        output.extend(base64.b64decode(frame["data"], validate=True))
        process.stdin.close()
        assert process.wait(timeout=2) == 0, process.stderr.read().decode()
        assert not pending, "incomplete terminal JSON frame"
        assert len([f for f in frames if f["event"] == "started"]) == 1
        assert [f["status"] for f in frames if f["event"] == "shell_exit"] == [17]
        assert [f["result"]["complete"] for f in frames if f["event"] == "cleanup"] == [True]
        reported = [line for line in output.decode().splitlines()
                    if line.startswith("SIGMA_PACKAGED_PTY ")]
        assert len(reported) == 1, output.decode()
        data = json.loads(reported[0].removeprefix("SIGMA_PACKAGED_PTY "))
        assert data == {"tty": True, "size": [91, 25], "input": incoming}, data
        return {"check": "packaged_pty", "rows": 25, "cols": 91,
                "exact_input": True, "exit_status": 17, "cleanup": True}
    finally:
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
        for stream in (process.stdin, process.stdout, process.stderr):
            stream.close()


def main():
    assert len(sys.argv) == 2, "usage: verify-release-native-smoke.py INSTALLED_RELEASE_ROOT"
    assert platform.system() == "Linux" and platform.machine() == "x86_64", (
        "native sandbox release acceptance requires Linux x86_64"
    )
    release = Path(sys.argv[1]).resolve(strict=True)
    applications = list((release / "lib").glob("sigma_agent-*"))
    assert len(applications) == 1, "expected one packaged sigma_agent application"
    native = applications[0] / "priv/native"
    helpers = [native / name for name in ("sigma-terminal-helper", "sigma-sandbox-launcher")]
    for helper in helpers:
        mode = helper.lstat().st_mode
        assert stat.S_ISREG(mode) and mode & 0o111, f"missing executable artifact: {helper}"
    python, bwrap = program("python3"), program("bwrap")
    with tempfile.TemporaryDirectory(prefix="sigma-release-native-smoke-") as directory:
        root = Path(directory)
        workspace, sibling = root / "workspace", root / "host-private"
        workspace.mkdir()
        sibling.write_text("must-not-be-visible")
        config = runtime_config(python, bwrap, workspace, sibling)
        env = dict(os.environ, PHX_SERVER="false", RELEASE_DISTRIBUTION="none",
                   SECRET_KEY_BASE=secrets.token_urlsafe(64),
                   SIGMA_NATIVE_SMOKE_ROOT=str(root), SIGMA_NATIVE_SMOKE_RELEASE=str(release),
                   SIGMA_NATIVE_SMOKE_CONFIG=json.dumps(config))
        output = checked_run(
            [str(release / "bin/sigma"), "eval", LAUNCHER_SMOKE],
            timeout=45, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        reports = []
        for line in output.splitlines():
            try:
                report = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(report, dict) and report.get("check") == "packaged_launcher":
                reports.append(report)
        assert len(reports) == 1 and reports[0]["check"] == "packaged_launcher", output
        assert list(root.glob("sigma-command-launcher-*")) == [], "launcher snapshots leaked"
        reports.append(terminal_smoke(helpers[0], python, workspace))
        for report in reports:
            print(json.dumps(report, ensure_ascii=False), flush=True)
    print("release native smoke ok", flush=True)


if __name__ == "__main__":
    main()
