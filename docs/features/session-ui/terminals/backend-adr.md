# ADR: Session terminal PTY backend

Status: Accepted for implementation behind the terminal backend behaviour; production UI cutover remains gated on Linux/NixOS native verification.

Date: 2026-09-11

Baseline: `85a810075fb5f30360c8dea6a5c90d54202a6c7d`

## Decision

Use the repository-built `sigma-terminal-helper` process as the production PTY boundary. The helper is implemented in Rust with these lockfile-resolved dependencies:

- `portable-pty 0.9.0` for `openpty`, `setsid`, controlling-TTY assignment, byte I/O, and `TIOCSWINSZ`.
- `vt100 0.16.2` for a bounded, server-side screen model and ANSI checkpoint serialization.
- `sysinfo 0.37.2` plus `libc` for native process identity, SID membership, signaling, and cleanup verification on supported Unix platforms.

`native/sigma_terminal_helper/Cargo.lock` is the authoritative transitive dependency pin. The helper uses newline-delimited JSON control/events and base64 for byte fields. It never interprets PTY bytes as UTF-8.

The BEAM-side production adapter must start this executable as a Port with stdio attached. Closing the Port control channel produces EOF, which independently initiates helper cleanup even when an Elixir worker's `terminate/2` is not called. A missing helper or unsupported native capability is a typed unavailable/start failure; there is no fallback to `script` or a pipe-only shell.

## Why this backend

The existing `Sigma.Web.WebShell` launches the platform `script` program and records only the Erlang Port. Its resize operation changes Elixir fields without changing the kernel PTY, and its cleanup closes the wrapper Port without a verified shell/job resource identity. It cannot satisfy LIFE-03, LIFE-05, STREAM-05, or G2.

`portable-pty`'s Unix implementation establishes the shell as a session leader with `setsid`, assigns the slave PTY as its controlling terminal with `TIOCSCTTY`, and resizes the master using `TIOCSWINSZ`. These are the required kernel mechanisms. A separate helper is preferable to a blocking in-VM NIF because the OS channel and helper continue to own cleanup when the terminal worker dies.

## Managed-resource boundary

At successful start the helper records `{pid, sid, started_at}` before acknowledging the run. The shell PID must equal its SID. The helper itself and the BEAM are outside the managed session.

Managed resources are all processes that still report the recorded SID. This includes the shell, foreground pipelines, and interactive background jobs even when job control assigns them distinct PGIDs. Cleanup revokes input, repeatedly enumerates exact SID members, sends HUP and TERM, escalates remaining members to KILL after 60% of the five-second budget, and reports success only after the SID scan is empty. PID, PGID, SID, and start time are separate facts; the implementation never derives a PGID from a Port PID and never selects processes by executable name or a broad PPID pattern.

This is resource management, not confinement:

- A descendant that deliberately calls `setsid` leaves the managed SID and is not contained or reaped. The UI/runtime must not describe the terminal as a sandbox. T2 native tests must own and explicitly clean such an escape fixture.
- On Linux, a future systemd scope/cgroup could provide stronger containment, but cgroup delegation is not assumed by this backend and is not required for the documented SID scope.
- On macOS there is no parent-death signal or generally available per-terminal containment primitive. Normal BEAM/Port loss closes stdin and exercises the independent EOF cleanup path. An uncatchable helper kill or host crash can leave descendants; application restart must diagnose only recorded/recoverable facts and must not use broad process killing.
- Shell exit is not cleanup success. The helper/session manager must keep the run accounted while any managed SID member remains.

## Screen checkpoints

The helper feeds every output fragment into a persistent `vt100::Parser`, whether or not a browser is attached. A checkpoint contains the parser's ANSI-formatted screen, canonical rows/columns, and the output sequence watermark. The proof restores an alternate-screen checkpoint into a fresh parser and verifies its contents.

This is meaningful terminal-state restoration rather than an arbitrary byte tail. T4 still owns the snapshot-to-live ordering, retained scrollback budget, acknowledgements, device-response policy, and parser backpressure. Resizes are applied to the kernel PTY first and then to the parser before the resize acknowledgement, so later checkpoints use the confirmed canonical dimensions.

The current browser lock resolves `@xterm/xterm 6.0.0` and `@xterm/addon-fit 0.11.0`. The client must retain the dedicated unpadded `.web-shell-terminal-host` and fit addon. No browser serialization dependency is selected because the authoritative checkpoint is server-side.

## Packaging

`scripts/build-terminal-helper.sh release` builds with Cargo `--locked` and installs the executable into `apps/sigma_agent/priv/native/`. Mix release assembly therefore places it under `lib/sigma_agent-*/priv/native/sigma-terminal-helper`.

The release workflow builds the helper on Linux amd64/arm64 and macOS amd64/arm64 and rejects an archive without the executable. The development Nix environment already supplies pinned nixpkgs `cargo` and `rustc`; it does not download a helper at runtime. Native capability tests must execute on every declared platform before production cutover, and a missing helper is a failure rather than a skipped test.

## Capability evidence

| Capability | macOS 15.7.9 x86_64 | Linux x86_64 (Docker/Debian) | NixOS | Required follow-up |
| --- | --- | --- | --- | --- |
| Real PTY, controlling TTY, PID/SID identity | Passed | Passed | Unverified | Run locked native suite in required platform jobs. |
| Byte preservation including NUL/non-UTF-8/control bytes | Passed | Passed | Unverified | Same suite; no text conversion is allowed. |
| Kernel resize observed by `stty size` | Passed (`41 132`) | Passed (`41 132`) | Unverified | Same suite plus packaged TUI smoke. |
| Cleanup across distinct job-control PGIDs | Passed | Passed | Unverified | Same suite, foreground pipeline coverage in T2. |
| HUP/TERM-resistant cleanup after control EOF | Passed | Passed | Unverified | Same suite plus BEAM worker/session-kill tests in T2. |
| Detached alternate-screen checkpoint restoration | Passed | Passed | Unverified | Same suite; T4 adds fragmented UTF-8/CSI and ordering cases. |
| Packaged release contains executable | Verified locally after release assembly | CI configured, not run here | Unverified | Required platform release jobs must pass. |
| Deliberate `setsid` descendant containment | Not supported | Not supported by SID boundary | Not supported by SID boundary | Keep the limitation visible; do not claim cleanup outside the SID. |
| Abrupt helper `SIGKILL` cleanup | Not guaranteed | Not yet verified; no guarantee selected | Not yet verified | Report as capability limit; never silently fall back. |

The local evidence was produced on Darwin kernel `24.6.0`, macOS `15.7.9`, x86_64, Rust `1.97.0`, Cargo `1.97.0`. Linux evidence was produced by Docker Engine `28.4.0` on its real Linux/x86_64 VM using `rust:1.88-bookworm` image digest `sha256:af306cfa71d987911a781c37b59d7d67d934f49684058f96cf72079c3626bfe0`. No NixOS builder was configured (`nix show-config` reported no builders or extra platforms), so NixOS execution remains unverified and was not simulated.

## Verification

The following commands completed with exit status 0 on the current platform:

```sh
cargo test --locked --manifest-path native/sigma_terminal_helper/Cargo.toml
# 5 passed; 0 failed

cargo clippy --locked --manifest-path native/sigma_terminal_helper/Cargo.toml --all-targets -- -D warnings

scripts/build-terminal-helper.sh release

docker run --rm --platform linux/amd64 -v "$PWD:/workspace:ro" -w /tmp \
  rust:1.88-bookworm sh -c \
  'cp -R /workspace/native/sigma_terminal_helper /tmp/sigma_terminal_helper && \
  /usr/local/cargo/bin/cargo test --locked \
  --manifest-path /tmp/sigma_terminal_helper/Cargo.toml'
# 5 passed; 0 failed on Linux x86_64
```

The native cases prove:

1. raw non-UTF-8, NUL, and ANSI bytes survive PTY-to-protocol framing;
2. `pid == sid` is recorded with process start time;
3. `TIOCSWINSZ` produces `stty size` output `41 132`;
4. an alternate-screen checkpoint replays into a fresh server-side parser;
5. control-channel EOF cleans a signal-resistant shell and background member; and
6. cleanup spans interactive job-control processes with different PGIDs in the same SID.

## Consequences for later work

T2 owns the BEAM adapter, final protocol hardening, partial-start cleanup, natural-exit handling, and native lifecycle matrix. T3/T4 own accounting and screen-stream bounds. T7 must remove the `script` production path and must not enable the backend on a platform whose packaged native suite has not passed. This ADR does not authorize a production UI cutover.
