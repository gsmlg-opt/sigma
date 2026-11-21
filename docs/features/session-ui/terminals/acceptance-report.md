# Session terminal acceptance report

## 2026-11-21 recovery and rendering repair

Verified on Linux x86_64 against main `d15a160` plus the working-tree repair. The browser used Chromium 152 at 1440×900, a separate local BEAM on port 14680, and a JavaScript bundle built from the working tree for the test page. Bundle SHA-256 was `f720634e5882f433c0860334f2fb378156567f7ec7e0f3918b9c1e1afb069122`. The installed native helper SHA-256 was `d3632cf3849ffee8874c3f2f0c0d4c906d9c3157edbb34027089894dcfcf9c49`.

| Check | Result |
| --- | --- |
| Rendered output | Five alternating Chromium trials per workload produced identical xterm buffer digests for direct writes and the Sigma hook. On 491,520 bytes from a real PTY `cat` in 90 chunks, median time was 61 ms directly and 66 ms through Sigma, with 9 cumulative acknowledgements. On 120 one-byte chunks it was 3 ms and 1 ms respectively, with 2 acknowledgements. The complete LiveView path displayed the last line and marker from the 491,520-byte file in 1,113 ms in the final run. |
| Window lifecycle and replay | Reload restored the expanded panel as an observer. Explicit open acquired the vacant lease. After all pages closed, the same shell produced 1,200,000 bytes. A fresh page restored the original terminal and generation, the same shell PID, the last output marker, and dimensions of 112×15. Two views at the same acknowledged sequence had equal cursor positions and recent text. |
| Device replies and input | Zero, one, and two connected views each yielded exactly one response to each of DSR 5, CPR and primary DA. The PTY received an exact 42,012-byte bracketed paste with mixed ASCII and UTF-8. Native tests additionally cover private CPR and secondary DA. |
| Snapshot boundaries and exit | Native tests cover partial UTF-8, CSI, OSC and control strings, alternate screen restoration, resize and single-row wrap. The browser restored the final output marker and exit status 7 in a read-only view after OS cleanup. |

The final focused run passed 34 Bun tests, 26 native Rust tests, and 41 selected ExUnit tests. The installed helper build, test-environment warnings-as-errors compilation, Elixir formatting and integrated diff checks passed. The single-row parser crash found during browser qualification required updating only `vt100` to 0.17.0. The terminal transport hook sends ACKs through a separate DOM element so LiveView can apply recovery state while acknowledgements are in flight.

Scope of current evidence is the local test server. Published assets, remote CI and execution on other platforms require separate verification.

## 2026-09-14 historical acceptance

Reviewed baseline: `bba9564a09a04b6903b728fdc8ce144da8b68eb6`

Tested source: the baseline above plus the uncommitted repair diff on
`codex/terminal-correctness-repair`. No commit, push, merge, or deployment was
performed as part of this acceptance run.

Status: the requested repair is complete on NixOS x86_64. Native, umbrella,
asset, release, and real-browser checks pass. The repaired tree has not been
published, so a same-source GitHub Actions run is `NOT RUN`. Linux arm64 and
macOS amd64/arm64 execution are also `NOT RUN`; those platform gaps do not
invalidate the verified NixOS x86_64 result.

## Repair findings

| Area | Status | Evidence |
| --- | --- | --- |
| Clean test baseline | PASS | The Test workflow now builds and installs `sigma-terminal-helper` before ExUnit. Both native Elixir suites use the installed `apps/sigma_agent/priv/native/sigma-terminal-helper` path, and the fixture resolves `cat` portably. Ledger fault tests use test-owned state; the one application-supervised restart test restores the global application safely. |
| Web operation errors | PASS | `Sigma.Web.OperationError` maps typed terminal/session failures to fixed actionable text with a safe fallback. Repository/session LiveView regressions cover cleanup uncertainty, unavailable/untrusted accounting, draining, active-resource guards, and malformed IDs while keeping the LiveView alive and files unchanged. |
| Window-local selection | PASS | Hook and LiveView tests cover explicit creator selection, restored valid selection, deterministic removal, delayed reply fencing, repeated tab switches, collapse/reopen, and incarnation scoping. A real two-window run kept Terminal 2 selected in the 1440x900 window while Terminal 1 remained selected in the 900x700 window. |
| Canonical dimensions | PASS | Resize and snapshot dimensions cross the complete Worker/Binding/LiveView/hook boundary. Only the visible synchronized controller measures with FitAddon; observers apply confirmed dimensions. In the browser run both windows rendered Terminal 1 at `80x4`, and the PTY returned `4 80` from `stty size`. Maximize converged both renderers at `113x29`; restore returned both to `80x4` and the bottom dock. |
| Recovery and render acknowledgement | PASS | Stable recovery IDs, immutable callback fences, ordered render acknowledgements, deduplication, gap resync, bounded queues, and snapshot-before-bytes behavior have server and hook regressions. A real detached marker appeared after reopen, and refresh reconstructed the earlier live, takeover, and detached markers without creating a shell. |
| Retained read-only history | PASS | Confirmed OS cleanup retains bounded Worker/ScreenStream state, revokes input/resize/control, and releases managed-run capacity. A real shell printed `FINAL_EXIT_MARKER_0914`, exited `7`, lost its helper process, and restored the marker plus `exit 7` after refresh with no Take-control action. Explicit close removed the retained tab/history without a second backend cleanup. |
| Lifecycle, isolation, privacy | PASS | Manager, supervision, resource-ledger, and LiveView tests retain unknown cleanup/accounting, reject unsafe automatic stop, preserve the core agent/writer, and keep terminal bytes out of logs, JSONL, context, and browser storage. |
| DuskMoon confirmation hook | PASS with upstream workaround | Browser console inspection found generated confirm-action buttons carrying `WebComponentHook` without IDs. The dependency issue is `duskmoon-dev/phoenix-duskmoon-ui#165`; confirmed native buttons now omit the unnecessary hook locally, with a DOM regression. A fresh rebuilt-release page reported no browser console warnings or errors. |

## Real-browser and native evidence

The real-browser workflow ran against the packaged release at
`http://localhost:4582`, using the release-embedded native helper.

- Viewports: `1440x900`, `900x700`, and narrow mobile `390x844`.
- Layout: the terminal panel remained inside `.sigma-session-main` after the
  composer. At mobile size the composer ended at `y=517.5` and the terminal
  occupied `y=517.5..844`, preserving full-width bottom docking.
- Creation and identity: terminal IDs `5` and `9`, helper PIDs `510791` and
  `512710`, and shell PIDs `510792` and `512711` remained stable across tab
  selection and collapse/reopen. Reopen did not change the helper count.
- Authority and resize: takeover moved control to the 900x700 window. Both
  visible renderers converged on `80x4`; `stty size` returned `4 80`.
  Maximize/restore converged `113x29 -> 80x4` in both windows.
- Recovery: `LIVE_MARKER_FINAL_0914`, `SECOND_MARKER_FINAL_0914`,
  `TAKEOVER_MARKER_FINAL_0914`, and `DETACHED_MARKER_FINAL_0914` were observed
  in the matching xterm buffers. The detached marker recovered after reopen,
  and the same-run screen recovered after refresh.
- Exit retention: `FINAL_EXIT_MARKER_0914` and exit code `7` remained visible
  after refresh. Helper count changed `2 -> 1` on natural exit and `1 -> 0`
  when the remaining live tab was explicitly closed. Closing the already
  exited tab did not attempt a second native cleanup.
- Desktop and narrow-mobile screenshots were captured in the browser task
  output. The final rebuilt-release console audit reported no warnings or
  errors. The visually hidden Phoenix reconnect alert was not treated as a
  transport failure; server logs and current-hook traffic confirmed WebSocket
  attachment during the workflow.

## Verification record

Current host:

- NixOS 26.05 (Yarara), Linux `6.18.48`, x86_64
- Elixir 1.18.4, Erlang/OTP 28
- Rust/Cargo 1.95.0
- Bun 1.3.13, Node 24.19.0

Commands completed with exit status 0 unless noted:

```text
rm -rf native/sigma_terminal_helper/target
cargo build --locked --manifest-path native/sigma_terminal_helper/Cargo.toml
cargo test --locked --manifest-path native/sigma_terminal_helper/Cargo.toml
                                                                  14 passed
cargo fmt --manifest-path native/sigma_terminal_helper/Cargo.toml -- --check
cargo clippy --locked --manifest-path native/sigma_terminal_helper/Cargo.toml --all-targets -- -D warnings
scripts/build-terminal-helper.sh debug
mix test apps/sigma_coding/test/sigma_coding/terminal/native_test.exs
                                                                   8 passed
mix test apps/sigma_agent/test/sigma_agent/terminals/native_stream_integration_test.exs
                                                                   2 passed
mix format --check-formatted
mix compile --warnings-as-errors
mix test --seed 569368                                           961 passed
mix test --seed 90210                                            961 passed
mix test --seed 1                                                961 passed
bun test ./apps/sigma_web/assets/js/hooks/session_terminals_test.js
                                                                  26 passed
mix assets.build
mix test --include assets apps/sigma_web/test/sigma_web/assets_build_test.exs
                                                                   5 passed
mix sigma.rel-build
_build/dev/sigma_rel/rel/sigma/bin/sigma eval 'IO.puts(:release_boot_ok)'
                                                          release_boot_ok
git diff --check
```

The packaged helper is an executable ELF64 x86-64 binary at
`_build/dev/sigma_rel/rel/sigma/lib/sigma_agent-0.1.0/priv/native/sigma-terminal-helper`.
It is byte-identical to both the Cargo release binary and app-priv install:
SHA-256 `392bf163c35fab4d1730fe70ab31dfb76947d63daf34efc8b81a571fcc0c3f93`.

## GitHub Actions state

The latest reviewed-baseline runs are:

- CI run `34775538351` at `bba9564a09a0`: PASS.
- Test run `34775538381` at `bba9564a09a0`: FAIL, 187 tests with 9 failures.
  The log includes the `String.Chars` crash for
  `%Sigma.Agent.Terminals.Error{code: :cleanup_unconfirmed}` plus ledger-driven
  terminal test contamination. Those failure classes are covered by this
  repair and pass locally at the failing seed.

Because the repair is intentionally uncommitted and unpushed, no remote run can
represent the tested source yet. Do not report the baseline CI success as proof
of the repaired tree.

## Remaining limitations

- A same-source GitHub Actions Test/CI result is `NOT RUN` until the repaired
  tree is committed and pushed.
- Linux arm64 and macOS amd64/arm64 native/release execution are `NOT RUN` in
  this task.
- The managed boundary remains a Unix session, not a sandbox. A deliberate
  descendant `setsid` escape and abrupt helper `SIGKILL` remain outside the
  documented cleanup guarantee in `backend-adr.md`.
