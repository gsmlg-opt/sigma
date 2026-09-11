# Session terminal acceptance report

Date: 2026-09-11

Baseline: `main@85a810075fb5f30360c8dea6a5c90d54202a6c7d` plus the uncommitted T0-T8 implementation.

Status: conditionally complete. All server, native-helper, release, LiveView, and browser-hook checks run on the current macOS x86_64 host pass. Real browser interaction is `NOT RUN` because the available Chrome automation connection timed out while opening the healthy local server, and no in-app browser was available. NixOS and arm64 native execution are also `NOT RUN`. These gaps do not conceal a cleanup, ownership, fencing, replay, or data-isolation failure.

`PASS` means the cited automated or native check ran successfully. `PARTIAL` means the implemented behavior has passing automated coverage but one requested environment or real-browser observation was unavailable. Fake, native, hook, and LiveView evidence are identified explicitly.

## Acceptance scenarios

| Scenario | Status | Evidence |
| --- | --- | --- |
| A01 | PASS | `contracts_test.exs`: simultaneous ensure-initial convergence; `manager_test.exs`: simultaneous pending first-open; `session_live_test.exs`: two windows share one catalog. |
| A02 | PARTIAL | Hook test proves browser disposal never closes the backend and server-declared reopen overrides persisted collapse; LiveView open/close test proves creation is explicit. Real navigation/refresh process-identity observation was blocked by browser tooling. |
| A03 | PASS | `contracts_test.exs`: explicit creates remain distinct and operation retries replay; `manager_test.exs`: deduplication and pre-effect limits. |
| A04 | PASS | `contracts_test.exs`: retained lifecycle counts; `manager_test.exs`: shared catalog revisions; component tests: lifecycle breakdown and zero/unavailable badge states. |
| A05 | PASS | `contracts_test.exs` and `manager_test.exs`: exited retention and explicit generation-incrementing restart. |
| A06 | PASS (native macOS) | Rust: foreground pipeline and job-control cleanup; signal-resistant cleanup on control EOF; Coding native tests: natural exit and concurrent idempotent close. |
| A07 | PASS | `manager_test.exs`: cleanup uncertainty retains tab, pin, and capacity until truthful retry. |
| A08 | PASS | `manager_test.exs`: worker death is contained without restart; Coding native owner-death test proves helper and shell disappear; `supervision_test.exs`: core session survives terminal branch failure. |
| A09 | PASS | `supervision_test.exs`: terminal branch failure leaves core processes alive and ledger occupancy visible; ledger-down summary reports unknown rather than zero. |
| A10 | PASS | `terminal_operation_test.exs`: delete closes admission before cleanup and filesystem mutation; `manager_test.exs`: drain rejects concurrent create. |
| A11 | PASS | `terminal_operation_test.exs`: hibernate preserves the terminal; `manager_test.exs`: automatic stop rejects managed or unconfirmed resources. |
| A12 | PASS | `terminal_operation_test.exs`: fork, model change, active-turn cancellation, and compaction leave the catalog unchanged. Idle cancel remains `{:error, :no_active_turn}`. |
| A13 | PASS | `terminal_operation_test.exs`: identity-changing rename/adoption reject live resources before mutation; manager requires acknowledgement for released volatile history. |
| A14 | PASS | `controller_lease_test.exs` and `stream_control_test.exs`: one controller, atomic takeover, and final-dispatch stale input/resize rejection; LiveView forged scope test. |
| A15 | PASS | `stream_control_test.exs`: observer death, lease expiry, heartbeat, and reacquisition preserve a single controller. |
| A16 | PASS (native macOS) | Hook test gates resize by controller/resync/visibility; Coding native test observes `41 132` through `stty`; Rust full-screen program observes live kernel resize. |
| A17 | PASS (native macOS) | Native stream integration proves alternate-screen checkpoint/watermark and explicit gap resync; Rust tests restore active alternate and inactive normal screens with bounded scrollback. |
| A18 | PASS (native macOS) | Native high-volume integration uses a five-byte slow-observer budget, keeps the healthy viewer live, pauses the slow viewer, leaves manager queue below 10, and serves catalog in under 100 ms. |
| A19 | PASS (native macOS) | Rust fragmented UTF-8/CSI checkpoint test plus stream-control test for fragmented UTF-8/CSI and single device response. |
| A20 | PASS (hook) | Hook regression proves a disposed connection and a reconnect before controller/resync cannot emit buffered input; there is no offline input queue. |
| A21 | PASS | `controller_lease_test.exs` rejects stale session, terminal, generation, revision, attachment, and epoch; LiveView rejects forged repository scope. |
| A22 | PASS | Resource-ledger and manager tests cover atomic node/retained quotas, failed start, unconfirmed cleanup, and retry accounting; native close is idempotent. |
| A23 | PARTIAL | LiveView test proves shared catalog/rename with window-local selection; hook tests cover local panel/height/maximize/unread state and accessible controls. Real two-tab visual observation was blocked by browser tooling. |
| A24 | PARTIAL | Current macOS 15.7.9 x86_64 Rust suite passes 14/14 and the packaged helper is executable. Linux x86_64 is recorded as passed in `backend-adr.md` from the T2 run, but was not rerun in T8. NixOS and both arm64 targets are `NOT RUN`. |
| A25 | PARTIAL | Operation test proves a recreated runtime gets a new incarnation and rejects stale clients; generation-keyed browser state and non-persistent catalogs prevent resurrection. A complete browser reconnect across an application restart was not run. |
| A26 | PASS | LiveView sentinel test proves terminal bytes do not enter captured default logs or the session JSONL; catalog notifications carry no content; browser storage test excludes output and authority. |

## Completion gates

| Gate | Status | Evidence |
| --- | --- | --- |
| G1 Ownership | PASS | Session-supervised terminal branch, manager convergence tests, worker/native owner-death cleanup, and hook disposal-without-close. Production source has no `WebShell`, `WebShellSupervisor`, `WebShellTerminal`, or `web_shell` reference. |
| G2 Native cleanup | PASS (macOS) | Rust cleanup cases, Coding native close/exit/owner-death cases, and repeated adapter runs; no helper or zombie remained after bounded settling. |
| G3 Fault isolation | PASS | Manager and supervision tests cover leaf/branch failure and core-session failure semantics. |
| G4 Control | PASS | Lease and stream-control concurrency/fence suites plus LiveView forged-scope rejection. |
| G5 Replay | PASS server/native; PARTIAL browser | Native detached output, alternate screen, fragmentation, resize ordering, checkpoint failure, and gap resync pass. Actual xterm reconnect/TUI rendering was not available. |
| G6 Bounds | PASS | Injected catalog/replay/input/checkpoint/attachment bounds, high-volume slow-observer isolation, and measured manager responsiveness pass. |
| G7 UI | PARTIAL | Component, LiveView, assets, and hook suites pass, including shared catalog/local selection and accessible controls. Desktop/mobile screenshots and actual keyboard interaction are `NOT RUN`. |
| G8 Lifecycle | PASS | Delete/create admission, rename/adopt guards, hibernate/cancel/compact/fork invariants, and sentinel isolation pass. |
| G9 Packaging | PARTIAL | `MIX_ENV=prod mix sigma.rel-build` succeeds. Release helper is executable, resolves through `Application.app_dir/2`, has the same SHA-256 as the Cargo and app-priv binaries, and reports required capabilities. NixOS/arm64 release execution is `NOT RUN`. |

## Verification record

Current host:

- macOS 15.7.9 (Darwin 24.6.0), x86_64
- Elixir 1.20.1, Erlang/OTP 29, Mix 1.20.1
- Rust/Cargo 1.97.0, Bun 1.4.0, Node 24.11.1
- Docker 29.8.0 and Nix 2.34.7 installed; neither implies NixOS or arm64 execution

Commands completed with exit status 0 unless noted:

```text
mix test <sigma_agent terminal core files>                         54 passed
mix test apps/sigma_agent/test/sigma_agent/terminals/supervision_test.exs
                                                                  3 passed
mix test apps/sigma_coding/test/sigma_coding/terminal              8 passed
mix test <focused sigma_web terminal/session/release files>       84 passed, 1 excluded
mix test --include assets apps/sigma_web/test/sigma_web/assets_build_test.exs
                                                                  5 passed
bun test apps/sigma_web/assets/js/hooks/session_terminals_test.js 14 passed
cargo test --locked --manifest-path native/sigma_terminal_helper/Cargo.toml
                                                                 14 passed
cargo fmt --manifest-path native/sigma_terminal_helper/Cargo.toml -- --check
cargo clippy --locked --manifest-path native/sigma_terminal_helper/Cargo.toml --all-targets -- -D warnings
mix compile --warnings-as-errors
mix format --check-formatted
mix assets.build
git diff --check
MIX_ENV=prod mix sigma.rel-build
```

The supervision suite first produced the known `ledger_untrusted` order failure while multiple umbrella test processes were started concurrently. After all competing BEAM test commands stopped, the isolated authoritative run passed 3/3.

The Coding native suite was then run repeatedly (`--repeat-until-failure 5`): all 48 executed cases passed. Before and after snapshots contained no `sigma-terminal-helper`; the final system process snapshot contained no zombie. This covers test-owned runs only and does not select or kill processes by broad executable/PPID patterns.

The release helper is `_build/prod/sigma_rel/rel/sigma/lib/sigma_agent-0.1.0/priv/native/sigma-terminal-helper`, mode executable, Mach-O x86_64. Its SHA-256 is `66c1b281514d4070065548b3d42a56ee1897b400d670ebb42247aa857ac267c0`, identical to `apps/sigma_agent/priv/native/sigma-terminal-helper` and the Cargo release binary. Release `eval` reports `real_pty`, `resize`, `checkpoints`, and `independent_control_eof_cleanup` true; `abrupt_helper_cleanup` is explicitly false. Release evaluation requires the normal production `SECRET_KEY_BASE` runtime variable.

The development endpoint started successfully on `http://localhost:4580`. Chrome automation selected the browser but timed out opening both `localhost` and `127.0.0.1`; the automation kernel reset, and an in-app browser was unavailable. Therefore no desktop/mobile screenshot, browser console audit, or actual two-window xterm workflow is claimed.

## Remaining limitations

- Run the existing required release/native workflow on Linux x86_64 again, NixOS, Linux arm64, and macOS arm64 before declaring those targets verified.
- Repeat A02, A17, A23, and A25 in a functioning real browser at desktop and narrow-mobile sizes, including actual xterm input/output, collapse/reopen, refresh, takeover, resize/maximize, and reconnect.
- The managed boundary is a Unix session, not a sandbox. A deliberate descendant `setsid` escape and abrupt helper `SIGKILL` are outside the cleanup guarantee, as documented in `backend-adr.md`.
