#!/usr/bin/env bash

set -euo pipefail

# This provisions an ephemeral GitHub Linux runner, not a developer host.
if [[ "${GITHUB_ACTIONS:-}" != true || "${RUNNER_OS:-}" != Linux || "$(uname -m)" != x86_64 ]]; then
  echo "setup-ci-bubblewrap.sh requires a GitHub Actions Linux x86_64 runner" >&2
  exit 64
fi

version=0.11.2
sha256=69abc30005d2186baf7737feacd8da35633b93cf5af38838ecff17c5f8e924f6
archive="bubblewrap-${version}.tar.xz"
build_root="$(mktemp -d "${RUNNER_TEMP:?}/sigma-bubblewrap.XXXXXXXX")"
trap 'rm -rf "$build_root"' EXIT

sudo apt-get update
sudo apt-get install --yes --no-install-recommends build-essential libcap-dev meson ninja-build
curl --fail --location --show-error --connect-timeout 10 --max-time 60 --retry 2 \
  "https://github.com/containers/bubblewrap/releases/download/v${version}/${archive}" \
  --output "$build_root/$archive"
printf '%s  %s\n' "$sha256" "$build_root/$archive" | sha256sum --check --strict
tar -xJf "$build_root/$archive" -C "$build_root"
meson setup "$build_root/build" "$build_root/bubblewrap-$version" \
  --buildtype=release -Dsupport_setuid=false -Dman=disabled -Dtests=false \
  -Dbash_completion=disabled -Dzsh_completion=disabled -Dselinux=disabled
meson compile -C "$build_root/build"
sudo install -o root -g root -m 0755 "$build_root/build/bwrap" /usr/local/bin/bwrap
test "$(bwrap --version)" = "bubblewrap $version"

# Ubuntu 24.04 can restrict unprivileged user namespaces through AppArmor.
# Grant userns only to this root-owned binary; never disable the global policy.
if [[ -r /proc/sys/kernel/apparmor_restrict_unprivileged_userns ]] &&
  [[ "$(</proc/sys/kernel/apparmor_restrict_unprivileged_userns)" == 1 ]]; then
  command -v apparmor_parser >/dev/null
  sudo tee /etc/apparmor.d/sigma-ci-bwrap >/dev/null <<'APPARMOR'
abi <abi/4.0>,
include <tunables/global>

profile sigma-ci-bwrap /usr/local/bin/bwrap flags=(unconfined) {
  userns,
}
APPARMOR
  sudo apparmor_parser --replace /etc/apparmor.d/sigma-ci-bwrap
fi

# Exercise the launcher's FD execution and native FD mounts, not --help alone.
timeout 30s /usr/bin/python3 - "$build_root" <<'PYTHON'
import json
import os
from pathlib import Path
import sys

root = Path(sys.argv[1])
workspace = root / "workspace"
readonly = root / "readonly"
workspace.mkdir()
readonly.mkdir()
namespaces = {name: os.readlink(f"/proc/self/ns/{name}")
              for name in ("user", "pid", "net", "ipc", "uts", "mnt")}
fds = [os.open(path, os.O_PATH | os.O_DIRECTORY | os.O_NOFOLLOW)
       for path in ("/usr", workspace, readonly)]
for fd in fds:
    os.set_inheritable(fd, True)
bwrap_fd = os.open("/usr/local/bin/bwrap", os.O_RDONLY | os.O_NOFOLLOW)
check = """
import errno, json, os, pathlib, sys
for name, original in json.loads(sys.argv[1]).items():
    assert os.readlink('/proc/self/ns/' + name) != original, name
pathlib.Path('/workspace/probe').write_text('fd mounts ok')
try:
    pathlib.Path('/readonly/probe').write_text('unexpected write')
except OSError as error:
    assert error.errno == errno.EROFS, error
else:
    raise AssertionError('read-only FD mount was writable')
"""
args = ["/usr/local/bin/bwrap", "--unshare-user", "--unshare-pid",
        "--unshare-net", "--unshare-ipc", "--unshare-uts",
        "--die-with-parent", "--new-session", "--disable-userns",
        "--cap-drop", "ALL", "--clearenv", "--proc", "/proc", "--dev", "/dev",
        "--tmpfs", "/tmp", "--ro-bind-fd", str(fds[0]), "/usr",
        "--symlink", "usr/bin", "/bin", "--symlink", "usr/sbin", "/sbin",
        "--symlink", "usr/lib", "/lib", "--symlink", "usr/lib64", "/lib64",
        "--bind-fd", str(fds[1]), "/workspace",
        "--ro-bind-fd", str(fds[2]), "/readonly",
        "--", "/usr/bin/python3", "-c", check, json.dumps(namespaces)]
pid = os.fork()
if pid == 0:
    os.execve(bwrap_fd, args, {})
_, status = os.waitpid(pid, 0)
for fd in [*fds, bwrap_fd]:
    os.close(fd)
if status != 0:
    raise SystemExit(f"bubblewrap namespace/FD-mount preflight failed: wait status {status}")
assert (workspace / "probe").read_text() == "fd mounts ok"
assert not (readonly / "probe").exists()
print("bubblewrap namespace/FD-mount preflight passed")
PYTHON
