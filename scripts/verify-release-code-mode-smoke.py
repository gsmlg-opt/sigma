#!/usr/bin/env python3
"""Exercise the relocated Code Mode runner without development executables."""

import json
import os
from pathlib import Path
import selectors
import subprocess
import sys
import tempfile
import time


def verify(release_root):
    runner_root = release_root.resolve() / "backplane_code_mode_runner"
    executable = runner_root / "bin/backplane-code-mode-runner"
    assert executable.is_file() and os.access(executable, os.X_OK), executable
    assert len(list(runner_root.glob("erts-*/bin/erlexec"))) == 1
    assert len(list(runner_root.glob("lib/duskmoon_quickbeam-*/priv/lib/Elixir.QuickBEAM.Native.so"))) == 1
    assert len(list(runner_root.glob("lib/backplane_agent_runtime-*/priv/codex/code_mode_quickbeam.js"))) == 1
    assert not any(path.is_symlink() for path in runner_root.rglob("*")), "runner references build-tree symlinks"

    if sys.platform == "darwin":
        helpers = list(release_root.resolve().glob("lib/backplane_agent_runtime-*/priv/bin/backplane-local-command-session"))
        assert len(helpers) == 1 and os.access(helpers[0], os.X_OK), "missing macOS host process helper"
        identity = subprocess.run(
            [str(helpers[0]), "--process", str(os.getpid())],
            check=True, capture_output=True, text=True,
        ).stdout.split()
        assert len(identity) == 2 and identity[1] == "R", identity

    with tempfile.TemporaryDirectory(prefix="sigma-code-mode-smoke-") as temporary:
        with open(Path(temporary) / "stderr", "w+b") as error:
            process = subprocess.Popen(
                [str(executable)],
                cwd=temporary,
                env={"PATH": "", "HOME": temporary, "TMPDIR": temporary},
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=error,
            )
            selector = selectors.DefaultSelector()
            selector.register(process.stdout, selectors.EVENT_READ)
            buffered = bytearray()
            deadline = time.monotonic() + 30

            def receive():
                while b"\n" not in buffered:
                    remaining = deadline - time.monotonic()
                    assert remaining > 0 and selector.select(remaining), "runner frame timed out"
                    data = os.read(process.stdout.fileno(), 65536)
                    assert data, "runner exited before its expected frame"
                    buffered.extend(data)
                    assert len(buffered) <= 1048576, "runner frame exceeds its bound"
                line, _, rest = buffered.partition(b"\n")
                buffered[:] = rest
                return json.loads(line)

            def send(command):
                process.stdin.write(json.dumps(command).encode() + b"\n")
                process.stdin.flush()

            try:
                ready = receive()
                assert ready["type"] == "ready" and ready["protocol"] == 1, ready
                assert ready["engine"], ready
                send({
                    "type": "execute",
                    "code": 'text("packaged runner"); const next = yield 41; return next + 1;',
                    "tools": [],
                    "stored": {},
                })
                output = receive()
                assert output == {"type": "output", "item": {"type": "text", "text": "packaged runner"}}, output
                yielded = receive()
                assert yielded == {"type": "yield", "value": 41}, yielded
                send({"type": "configure", "revision": 1, "tools": [], "stored": {}})
                configured = receive()
                assert configured == {"type": "configured", "revision": 1}, configured
                send({"type": "resume", "value": 41})
                completed = receive()
                assert completed == {"type": "complete", "value": 42}, completed
                process.stdin.close()
                process.wait(timeout=10)
                assert process.returncode == 0, process.returncode
                assert not buffered and process.stdout.read() == b"", "unexpected runner output"
            except BaseException:
                if process.poll() is None:
                    process.kill()
                process.wait(timeout=10)
                error.seek(0)
                sys.stderr.write(error.read().decode(errors="replace"))
                raise
            finally:
                selector.close()
                process.stdout.close()
                if not process.stdin.closed:
                    process.stdin.close()


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: verify-release-code-mode-smoke.py RELEASE_ROOT")
    verify(Path(sys.argv[1]))
    print("installed Code Mode runner smoke ok")
