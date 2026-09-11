# Sigma Session-Owned Terminals — Implementation Plan

Status: Proposed engineering plan for approved product requirements
Date: 2026-09-11
Repository: `gsmlg-opt/sigma`
Reviewed baseline: `85a810075fb5f30360c8dea6a5c90d54202a6c7d`
Suggested repository location: `docs/features/session-ui/terminals/implement_plan.md`
Product authority: [PRD](prd.md)

## 1. Execution contract

Implement the approved session-owned multi-terminal feature, not the entire repository improvement report. The PRD controls user-visible behavior. This plan supplies the proposed implementation boundaries and a testable dependency order.

Re-read `AGENTS.md`, the current branch, and local changes before editing. The baseline was inspected remotely; no checkout was compiled and no OS-cleanup, browser, or release tests were executed when drafting these documents. Do not report the existing leak as independently reproduced until a real fixture demonstrates it. Do not assume that the upstream branch or the user's local worktree still matches the baseline.

The PTY backend and terminal-state checkpoint mechanism are deliberately a **first implementation gate**. Their required behavior is settled; their exact library versions, platform adapter details, and release packaging must be proved before production enablement. Do not turn this into an open-ended redesign: select and lock one supported implementation in T0, record the evidence, then implement it behind the contracts below.

Do not introduce application code that depends on `sigma_web` from `sigma_agent` or `sigma_coding`. Do not add an umbrella application solely for this feature unless the verified backend packaging makes that unavoidable. Keep functional policy/reducer modules separate from the OTP processes that own effects.

## 2. Baseline integration map

| Existing location | Observed responsibility / required touch point |
| --- | --- |
| `apps/sigma_web/lib/sigma_web/application.ex` | Starts global `WebShellSupervisor`; remove its production shell ownership at final cutover. |
| `apps/sigma_web/lib/sigma_web/web_shell.ex` | Current LiveView-owned shell/Port implementation; replace or retire rather than leaving a second hidden spawn path. |
| `apps/sigma_web/lib/sigma_web/live/session_live.ex` | Contains panel visibility, shell creation, input/resize, exit forwarding, and owner state; reduce to a client adapter. |
| `apps/sigma_web/assets/js/app.js` | Existing `WebShellTerminal` hook integration; extract the new hook into a dedicated module. |
| `apps/sigma_web/assets/css/app.css` | Existing terminal container styles; preserve the unpadded measured host behavior. |
| `apps/sigma_agent/lib/sigma_agent/session_supervisor.ex` | Existing core children, `one_for_all`, `max_restarts: 0`; add an isolated optional resource branch without changing core-failure semantics. |
| `apps/sigma_agent/lib/sigma_agent/session_process.ex` | Lifecycle/status/hibernate integration; add terminal availability/pin reporting, not high-volume terminal output handling. |
| `apps/sigma_agent/lib/sigma_agent/runtime.ex` | Repository-qualified runtime access, rename/delete/adopt/fork operations; add resource access and lifecycle guards. |
| `apps/sigma_agent/lib/sigma_agent/repository_process.ex` | Serialized session operations; existing rename/delete finalization stops the session **after** the file-operation result. Insert admission closure and verified cleanup before destructive effects. |
| `apps/sigma_agent/mix.exs` | Already depends on `sigma_coding`; low-level terminal backend can sit below the agent runtime. |
| `apps/sigma_web/test/sigma_web/web_shell_test.exs` | Existing tests cover direct I/O and initial PTY sizing, not complete resource teardown. |
| `apps/sigma_web/test/sigma_web/session_supervisor_test.exs` and `apps/sigma_agent/test/sigma_agent/runtime_test.exs` | Extend runtime integration and core-failure regression coverage. |

The current asset package/lockfile location and exact xterm versions were not established in this review. Locate them in T0; do not create a guessed `assets/package.json` or replace the repository's build system.

Pinned source references are collected at the end of the PRD. Inspect exact functions rather than relying on old line numbers.

## 3. Proposed module boundaries

Names below are proposed, not claims that these modules already exist.

| Boundary | Suggested modules | Responsibility |
| --- | --- | --- |
| Public internal API | `Sigma.Agent.Terminals` | Repository/session-qualified operations; no Phoenix dependency and no browser-supplied PID access. |
| Session resource branch | `Sigma.Agent.Terminals.Subsystem`, `Manager`, `Worker` | Catalog/admission, terminal-run lifecycle, attachments, subscriptions, monitors, and backend effects. |
| Pure rules | `TerminalState`, `ControlLease`, `ReplayPlan` under `Sigma.Agent.Terminals` | Typed state transitions, validation, counts, epochs, replay decisions, and policy checks. |
| Node accounting/safety | `Sigma.Agent.Terminals.ResourceLedger` | Atomic node quota reservations and unresolved-cleanup records keyed by session/run; this is a safety ledger, not the lifetime owner or an alternate spawn API. |
| OS/PTY effects | `Sigma.Coding.Terminal.Backend` and one production adapter | Start, raw input, real resize, termination, cleanup evidence, and backend capabilities. |
| Screen restoration | `Sigma.Coding.Terminal.ScreenState` boundary | Canonical terminal state, resize/output ordering, and bounded coherent checkpoints using the selected tested implementation. |
| Web adapter | `Sigma.Web.Session.TerminalBinding` | Resolve server-established session/attachment context, translate commands/events, and reconcile snapshots. |
| Presentation | `Sigma.Web.Session.TerminalComponents` | Badge, tabs, controls, error states, confirmations; DuskMoon composition. |
| Browser terminal | `assets/js/hooks/session_terminals.js` | Stable xterm instances, fit, render acknowledgements, local view state, and control-aware input. |

Avoid splitting every pure function into its own module. The table defines responsibility boundaries, not a mandatory file-count target.

### 3.1 Supervision and fault containment

Recommended minimum change:

```text
Sigma.Agent application
  ResourceLedger                         # reservations / cleanup evidence only
  repository runtime
    SessionSupervisor                    # existing core failure policy preserved
      existing writer/session/policy/tasks/agent children
      Terminals.Subsystem                # temporary child at this boundary
        Manager                          # session terminal catalog / coordinator
        TerminalDynamicSupervisor
          Worker terminal A              # temporary execution owner
          Worker terminal B              # temporary execution owner
```

Add the terminal branch after existing core children so orderly session shutdown reaches terminals before the writer. Set the branch's parent-facing child spec explicitly: `restart: :temporary`, `type: :supervisor`, supervisor-appropriate shutdown. Workers under the terminal DynamicSupervisor are temporary; shell execution is never an OTP automatic-restart workload.

Within the terminal branch, the initial safe policy is fail-stop for an unrecoverable coordinator/supervisor failure rather than automatically rebuilding an empty catalog and starting replacement shells. Ordinary leaf-worker death is contained by the DynamicSupervisor and reconciled by the Manager. Natural shell exit should normally keep a read-only worker/state holder alive until its tab is closed, without keeping a live OS-run slot.

A branch-level failure must leave the core session alive but mark terminal service unavailable. The session's resource summary and node ledger must retain last-known occupancy/unconfirmed cleanup until reconciled. Listing an unavailable subsystem returns a typed unavailable result, never an authoritative empty list. Re-enabling a failed branch is allowed only after resource reconciliation and an explicit action; automatic resurrection is out of scope.

This is intentionally different from changing the whole existing session tree to `one_for_one`. Prove both directions: a terminal failure does not stop the agent; a core failure still stops its owned terminals. OTP restart type and shutdown ordering are part of the contract, not incidental defaults. [PRD R4, R9]

### 3.2 The resource ledger is not a second owner

Reserve global capacity before side effects; associate each reservation with session incarnation, terminal/run identity, operation identity, and a verifiable backend resource handle. Confirm a slot release only after cleanup is established or startup is proved to have created no resource.

Monitor session/terminal owners and reconcile helper/OS exit evidence independently of the worker that can crash. A reservation is not released merely because its BEAM monitor fired. On ledger failure or uncertain reconstruction, deny new starts until reconciliation; do not reset capacity counters to zero.

For orderly session termination, the session branch performs cleanup. For an unexpectedly dead worker, the helper/control-channel lifetime mechanism and safety ledger provide independent cleanup/accounting. The ledger must not keep a terminal alive after the owning session ends or become a way to attach to a deleted session.

## 4. Data, ordering, and operation contracts

### 4.1 Identity and catalog

A terminal's externally visible identity is scoped by:

`repository_key + session_id + session_incarnation + terminal_id + run_generation`

Use an opaque terminal ID; do not encode a PID or trust the display label. A session incarnation changes when its owning runtime is recreated. Run generation changes on explicit restart. Catalog revision and control epoch serve different purposes and must not be conflated.

Catalog records should include: label, stable creation order/time, startup directory, lifecycle state, run generation, shell exit information, cleanup state, controller summary, canonical dimensions, and typed failure information. Retain no credential-bearing backend handles in browser payloads.

Keep lifecycle state small: `starting`, `running`, `stopping`, `exited`, `failed`, `cleanup_failed`; successful close removes the record and may retain a bounded operation tombstone. Track shell exit separately from managed-resource cleanup. An exited shell with remaining managed work is not yet a safely reaped run.

Derived counts are pure functions over catalog/resource state. Badge counts retained records; live resource pins include reservations and uncertainty. Catalog updates are low-frequency, bounded full snapshots with revisions for the initial release, avoiding complicated partial-count reconciliation. Output uses a different stream.

### 4.2 Internal operations

| Operation | Required behavior |
| --- | --- |
| `list` / `subscribe_catalog` | Read or subscribe to an existing session incarnation; obtain coherent revisioned snapshot; never spawn. |
| `ensure_initial_terminal` | Explicit first-open action; serialize catalog check and starting reservation; return an existing retained tab when another request won. |
| `create_terminal` | Deliberate `+`; reserve catalog/node capacity and operation identity before async backend start. |
| `rename_terminal` | Validate scope/record revision and label; mutate shared metadata only. |
| `close_terminal` | Validate run/revision; revoke input, move to stopping, verify cleanup, then remove; idempotent retry. |
| `restart_terminal` | Require confirmed prior cleanup and explicit intent; increment generation; no command replay. |
| `attach` / `detach` | Establish/release a monitored attachment and bounded output relay; never define run lifetime. |
| `claim_control` / `take_control` / `release_control` | Compare expected control epoch, fence old authority, acknowledge new authority. |
| `input` | Validate active attachment/epoch/run and bounded raw bytes at final dispatch; reject stale/duplicate input sequence. |
| `resize` | Same authority checks, dimension validation, backend resize, then confirmed canonical-size publication. |
| `begin_drain` / `cleanup_all` | Freeze new resource admission for a session lifecycle operation and report verified cleanup or unresolved evidence. |

Command responses distinguish accepted/start-in-progress from completed side effects. A timeout is not proof that a command failed to take effect. For ambiguous mutations, reconcile by operation ID/catalog before issuing another deliberate action.

Bound mutation deduplication records. Use server-issued expiring operation tickets or an equivalent bounded replay-safe scheme so an expired request is rejected rather than silently reinterpreted as a new create. New explicit `+` intent receives a new operation identity. Admission, failed startup, close, and deduplication must be tested together under races.

Use typed errors such as `session_unavailable`, `terminal_not_found`, `stale_session_incarnation`, `stale_run`, `operation_conflict`, `operation_expired`, `not_controller`, `stale_control_epoch`, `session_draining`, `terminal_limit_reached`, `backend_unavailable`, `cleanup_unconfirmed`, and `replay_required`. This is an internal feature contract; do not silently expand the public Protocol V1 codec in this change.

### 4.3 Control fencing and transport

The component that ultimately dispatches PTY input/resize must serialize authority changes and validate the active epoch. A LiveView check alone is insufficient. A takeover acknowledgement is sent only after the new fence is effective at that boundary. Already-dispatched bytes are not reversible; do not promise to undo input accepted before takeover.

Monitor the attachment owner and implement expiring leases. Takeover credentials are returned only to the winning attachment, not broadcast with catalog metadata. Epoch checks cover delayed resize/input, old LiveViews, recreated runtimes, and explicit terminal restarts.

Keep the LiveView transport adapter initially, with a bounded relay between terminal output and each browser consumer. Do not broadcast high-volume raw output through the session chat event path. Browser disconnect releases only attachments and control. Avoid assuming that `disableStdin` or the browser UI alone provides server-side exclusion.

### 4.4 Output and screen checkpoints

Use one ordered per-run stream for output and successful resize changes. Frames carry run identity and sequence; raw bytes must survive the transport, for example via bounded base64 binary frames when using JSON. Do not apply the old blanket carriage-return-to-newline normalization to raw PTY input.

A reference attach flow:

1. Register a bounded attachment relay and reserve its replay window under the run's serializer.
2. Obtain a screen checkpoint corresponding to an acknowledged parser watermark S, with canonical dimensions and a bounded recent-history segment.
3. Send the checkpoint in bounded frames; buffer subsequent stream events with a hard cap.
4. Browser creates/resets the xterm state, applies the checkpoint, and acknowledges its rendered watermark.
5. Deliver events after S in order; advance acknowledgements after terminal parsing/rendering callbacks.
6. On overflow/gap, invalidate the replay attempt and obtain a new coherent checkpoint; never apply arbitrary missing ANSI bytes as though complete.

Snapshot correctness includes the parser state at the checkpoint boundary. A write callback does not automatically prove that there is no partial UTF-8/VT sequence. The chosen implementation must preserve pending decoder/control state or checkpoint only at a proven safe boundary. Test resize interleavings and alternate buffers rather than asserting that a serializer exports every required state by default.

A tested headless VT implementation is preferred to building a partial Elixir escape-sequence emulator. The xterm project documents `@xterm/headless` plus serialization as a reference; selecting it entails packaging a real server-side JavaScript runtime/helper, not just a browser dependency. The T0 decision must state that operational cost and lock compatible versions. [PRD R10]

Choose one authority for terminal-generated protocol replies. Prefer the server-side terminal model, especially while no browser is attached. Prove that browser rendering/replay and multiple observers do not emit duplicate device-status replies or turn replay data into input. Keep this separate from the user's keyboard input path.

## 5. Lifecycle integration sequence

The important race is creation versus stop/delete, not just deletion versus a previously counted list.

For a destructive operation, retain the existing repository/agent operation admission, then atomically obtain a terminal drain token and close resource admission. Snapshot the affected resources under that token, revoke controllers, start cleanup, and await a bounded terminal result outside any mailbox cycle. Only after verified cleanup may the operation perform its destructive filesystem/runtime work and acknowledge success.

A new create must consult the same authoritative drain gate used by the operation. An idle-stop check must acquire the gate and revalidate occupancy; `list -> empty -> stop` is not sufficient. Future reapers call this boundary, not `DynamicSupervisor.terminate_child` after an unlocked read.

Do not make a child synchronously ask its parent to terminate its own subtree. Keep whole-session orchestration at the repository/runtime boundary. Avoid circular calls where RepositoryProcess waits on a terminal component that calls back synchronously into RepositoryProcess. Prefer bounded asynchronous completion with operation correlation where needed. [PRD R9]

On failure, release or retain the drain gate according to actual effects. Reopen admission only if the session is intact and no destructive transition remains pending. Already-closed terminals are not resurrected as rollback. Do not overwrite existing operation-journal recovery semantics or report file deletion as rolled back when it already happened.

Identity-changing rename/adoption uses the PRD's close-first guard. Do not implement transparent migration of live PTYs. Fork, compaction, model change, and turn cancellation do not traverse or copy the terminal catalog. The terminal stream never becomes a journal message.

## 6. Implementation work packages

### T0 — Baseline and production-backend feasibility gate

Owner: integration/backend lead. Dependencies: none.

Read contributor instructions, current supervision, runtime operation ordering, shell hook/tests, actual asset manifests/locks, and Nix/release definitions. Record the implementation commit and any relevant uncommitted terminal-fit changes; do not overwrite them.

Select one production PTY backend behind the proposed behavior. Prefer an external, explicitly managed helper over a blocking in-VM NIF. It must own a real PTY, support kernel window-size changes, preserve bytes, expose stable process identity, and perform bounded cleanup on owner/control-channel loss. A mature dependency is acceptable when it proves these properties; replacing `script` with another wrapper is not proof.

Define the managed-resource boundary on Linux/NixOS and macOS. Prove shell job-control groups and background jobs; distinguish PID, PGID, SID, process descendants, and any stronger containment primitive used. Do not infer PGID from Port `os_pid`, kill the parent before discovering ownership, or use broad `pkill` patterns. Record what happens for deliberate `setsid`/daemonization and whether the backend contains it or declares a narrower scope. A platform cannot pass with a silent leak-prone fallback.

Prove screen restoration with a compatible tested state/serialization implementation while no browser is connected. Locate the actual xterm versions; avoid a speculative asset manifest. Package any runtime helper in the release/Nix environment rather than fetching it at runtime.

Deliverables: short backend decision/ADR, executable cleanup/resize/checkpoint fixtures, pinned dependencies, platform capability table, and failure evidence. No UI production cutover until this gate is satisfied. Work on fake-backed contracts/UI can proceed in parallel.

### T1 — Pure contracts, reducers, and deterministic fake backend

Owner: runtime contributor. Dependencies: PRD; parallel with T0.

Implement identity, catalog states, count/pin derivation, operation identity, typed errors, controller-lease rules, replay decisions, and configurable limits. Write pure transition tests with injected time. Use a deterministic fake backend able to delay start, emit bytes/resize acknowledgements, fail cleanup, and simulate owner death; it is not a substitute for T0/native evidence.

Define bounded catalog snapshots and output frames before parallel browser work. Test simultaneous ensure-initial, distinct creates, retries, stale generation, expiry, and count semantics. Keep protocol schema changes confined to the feature's internal boundary.

Deliverables: contract module/types, fixtures, test helpers, and a short shared event-contract section adjacent to the feature docs.

### T2 — Managed PTY backend and independent cleanup

Owner: backend contributor. Dependencies: T0, T1.

Implement the selected production backend and native helper packaging. Start asynchronously after a catalog/capacity reservation exists. Record resource identity at creation; no guessed identity at shutdown. Handle partial startup so a helper that exists before shell initialization is still tracked and reclaimed.

Implement close as input revocation, backend termination request, graceful wait/escalation, and reaping verification. Treat cleanup failure/unknown state as first-class. Make shutdown deadlines and outer supervisor budgets compatible; no unbounded work inside `terminate/2`.

Add independent cleanup on abrupt BEAM worker/session loss and documented VM/helper-failure behavior. Keep it idempotent when monitor-based cleanup and an explicit close race. Release capacity only on confirmed cleanup. Keep all real process tests scoped to unique test-owned identities and clean their fixtures in failure paths.

Native tests cover actual default PTY launch, foreground pipelines, background jobs, TERM/HUP-resistant processes, shell exit with descendants, blocked/closed I/O, helper crash, worker kill, and session shutdown. The old `shell_args: []` shortcut bypasses the original default wrapper and cannot be the only regression fixture. Verify kernel resize with `stty size` and a small TUI fixture.

Deliverables: backend/adapter, native helper, release integration, and native integration tests with explicit capability failures.

### T3 — Session catalog, resource accounting, and isolated supervision

Owner: runtime contributor. Dependencies: T1; fake-first, integrates T2.

Implement the session-qualified facade, Manager, temporary Workers, isolated Subsystem, and node ResourceLedger. Wire the branch into SessionSupervisor with explicit restart/shutdown policy. Add availability monitoring and resource-summary reporting without sending output through SessionProcess.

Implement retained catalog, server-side atomic first-open/create, rename, explicit restart, close-after-cleanup, failed-start records, quota reservation, operation deduplication, and session pin derivation. Keep natural-exit state/history until close. Make subsystem loss visible and preserve unknown reservations rather than advertising zero terminals.

Test manager/branch failure separately from a single worker crash. A deliberate restart must increment generation; supervisor recovery must never replay an old shell command. Under global-ledger recovery, deny new starts until occupancy is trustworthy.

Deliverables: working fake-backed catalog and lifecycle, followed by production-backend integration. Core agent/writer crash tests must retain their existing behavior.

### T4 — Attachments, single-controller fencing, and bounded replay

Owner: streaming contributor. Dependencies: T1 and T0 screen proof; integrates T2/T3.

Implement monitored observer attachments, atomic control leases/takeovers, epoch fencing at final dispatch, detach/expiry, bounded output relays, ordered screen-state checkpoints, and render acknowledgements. Reconnect never creates a run or resends unacknowledged input.

Maintain canonical PTY dimensions independently of browser viewport dimensions. Keep output processing active when detached. Suppress duplicate automatic terminal responses across observers and during replay. Cap both slow-viewer queues and server/parser backlog; use controlled resync/backpressure, not arbitrary byte dropping.

Test low injected limits, slow/missing acknowledgements, concurrent takeover, delayed old-window frames, size changes during checkpointing, UTF-8/control-sequence fragmentation, alternate-screen restoration, and device queries while detached.

Deliverables: stream/control integration tests and a coherent snapshot-to-live protocol exercised by a headless client fixture.

### T5 — DuskMoon panel, tabs, badge, and browser hook

Owner: UI contributor. Dependencies: T1 fixtures; integrates T3/T4 later.

Build components and a dedicated hook in new files first. Keep SessionLive modifications owned by one integrator to avoid parallel edits to its large module. Use existing asset tooling and DuskMoon conventions; do not add a competing component library.

Implement the agreed icon action, retained-tab badge, `+`, stable tab ordering, tab rename, state/exit labels, close confirmation, cleanup-error retry, restart warning, collapse, height/maximize controls, and unread markers. Keep the catalog subscription while the panel is collapsed. With zero tabs after a close, show an empty panel and explicit create action; do not reflexively create a new shell.

Keep xterm instances keyed by terminal/run identity. Switching/hiding tabs must not invoke backend create/stop. Fit only a visible, unpadded host and only send actual PTY resize requests from the current controller. Read-only observers use canonical dimensions. Dispose subscriptions/hooks on actual teardown without sending close.

Use browser-window-local presentation storage, keyed by repository/session incarnation; do not store output or control tokens there. Resync after reconnect before enabling keyboard input. Do not queue offline input or steal control on focus.

Deliverables: component/LiveView tests, hook tests, and browser verification at desktop and narrow mobile layouts.

### T6 — Session operations and idle-stop admission

Owner: integration contributor. Dependencies: T3; integrates T2 for cleanup completion.

Add drain/admission guards to the existing repository-owned stop/delete path before destructive filesystem effects. Apply identity-change policy to rename/adoption and any repository rekey/removal path that can bypass it. Preserve existing journal/idempotency behavior.

Expose a reusable `can_stop`/drain admission contract with terminal-specific reasons. The existing hibernation behavior stays intact; do not add a periodic reaper as part of this work. Test automatic-stop admission with active and cleanup-failed runs, and verify stopped/exited tabs follow the PRD history-discard policy.

Test create-versus-delete races using barriers, not timing luck. Test failures at each drain/cleanup/flush/file-operation stage. Cover session recreation with the same ID and rejection of stale browser frames. Fork/model/compaction/cancel regression tests assert no terminal side effects.

Deliverables: safe operation integration and lifecycle race tests.

### T7 — Production cutover, release behavior, and operational diagnostics

Owner: integration/backend lead. Dependencies: T2–T6.

Replace the LiveView-owned production path with TerminalBinding. Remove global WebShellSupervisor ownership and eliminate hidden direct Port spawning from the session UI. A temporary compatibility shim may delegate to the new facade, but must not create independent shells or preserve LiveView ownership.

Introduce a controlled feature gate for staged deployment. A disabled/missing backend should yield a clear unavailable feature without preventing ordinary agent sessions from starting. Do not fall back silently to the old unverified wrapper. Once accepted, enable the new path and remove obsolete state/events/tests.

Treat the upgrade as a controlled release/restart, not live adoption of arbitrary existing `script` processes. Previously orphaned, untracked PIDs need operator verification; never bulk-kill processes by executable name or PPID. Document that application restart loses volatile terminal state and does not replay commands.

Add telemetry for create outcomes, live/reserved/retained counts, attach/detach, control transfer/conflict, resize failure, buffered bytes, resync count, and cleanup duration/failure. Diagnostics carry scoped IDs and generations, not content. Validate package execution on Linux/NixOS and macOS without relying on a developer's global Node/Rust/shell paths.

Deliverables: release checklist, operator documentation, backend capability reporting, and no second production shell-lifecycle path.

### T8 — End-to-end verification and completion report

Owner: test/integration contributor. Dependencies: integrated T2–T7; fixtures can be authored from T1.

Map every PRD scenario A01–A26 to a test or explicit verification record. Run pure/ExUnit/LiveView suites, actual native PTY tests, browser reconnect/TUI tests, and release smoke tests. Native tests must fail a required platform job when their backend is missing; do not turn a missing executable into a green skip.

Run repeated create/close cycles and compare test-owned BEAM/Port/OS-resource counts with baseline after bounded settling. Include zombie/reaping checks and process birth identity rather than relying only on `kill -0` against a reusable PID. Test high output with one slow and one healthy observer using deliberately small budgets.

Record the final commit, exact commands, platform/backend versions, passed/failed counts, screenshots/traces where useful, observed memory/queue bounds, and unresolved limitations. No real LLM/provider is needed for this feature's acceptance tests.

Deliverables: completed acceptance matrix and honest completion report. Unexecuted native/browser checks remain unverified; passing fake-backend tests alone does not qualify as done.

## 7. Parallelization and PR ordering

| Track | Can begin after | Owned work | Shared-file rule |
| --- | --- | --- | --- |
| Backend | T0 contract agreement | T0, T2; T7 packaging | Own backend/native files and dependency decisions. |
| Runtime | T1 start | T1, T3 | Own session runtime/resource modules. |
| Stream/control | T1 event contracts and T0 screen proof | T4 | Own stream/lease/replay modules; coordinate worker authority changes with runtime owner. |
| UI | T1 fixtures | T5 | Own new components/hook/styles; integrator alone patches SessionLive/import wiring. |
| Integration/tests | T1 fixtures, progressively integrated dependencies | T6–T8 | Own repository-operation edits, final SessionLive cutover, and acceptance matrix. |

Suggested merge sequence: contracts and decision record; backend with native tests; session lifecycle/catalog; attach/control/replay; tabbed UI; lifecycle-operation guards; production cutover and release verification. UI construction and test-fixture authoring can run in parallel without enabling an incomplete backend.

Do not divide work so that two agents independently design incompatible terminal IDs, output sequence models, or controller tokens. Freeze T1 contracts first. Keep unrelated skill/config cache/refactor/security-report changes out of these PRs.

## 8. Validation commands and evidence rules

Use the repository's existing commands once a checkout and dependencies are available:

```sh
mix format --check-formatted
mix compile --warnings-as-errors
mix test
mix assets.build
```

After the feature introduces its integration tag, add required platform jobs that run the new terminal tests, for example:

```sh
mix test --include terminal_integration
```

The second command is a proposed test convention, not an existing verified repository capability. T0 must locate the actual browser test runner and Nix/release commands; document those exact commands rather than inventing a working setup.

Required targeted evidence:

| Gate | Evidence |
| --- | --- |
| G1: Ownership | Worker/Port/helper ownership records and session-close teardown; navigation preserves identity. |
| G2: Native cleanup | Test-owned shell/jobs are gone and reaped on close, worker death, and session termination; uncertainty retains accounting. |
| G3: Fault isolation | Leaf and branch failures leave the core session behavior as specified; core failure closes its terminals. |
| G4: Control | Concurrent takeover and stale-frame tests prove one final-dispatch authority. |
| G5: Replay | Detached output, alternate-screen state, fragmented input/output, and resize-to-checkpoint ordering restore correctly. |
| G6: Bounds | Measured queues/retention stay within injected policies under sustained output and slow consumers. |
| G7: UI | Shared catalog with local selection, truthful badge, explicit close/restart, accessible tabs, no duplicate xterm event delivery. |
| G8: Lifecycle | Create/delete races and rename/adoption guards precede destructive effects; no terminal data in forks/prompts. |
| G9: Packaging | Required platform jobs use packaged helpers and report capability failures rather than silent fallbacks. |

## 9. Completion handoff format

The implementing agent should return: final commit/PRs; completed work packages; changed boundaries; selected backend and ownership guarantees; exact verification results for G1–G9 and A01–A26; remaining blockers with reproducible evidence; and any deliberate deviations from the PRD.

Write concise durable documentation under `docs/features/session-ui/terminals/` and link it from the session-UI documentation index. A separate short backend ADR is appropriate for the T0 choice. Do not add chronological task logs to Agent Note; only record durable approved decisions or verified limitations when the relevant tool/skill is available.

Do not mark the feature complete while OS cleanup is unverified, old browser frames can still write, screen restoration is only an arbitrary output tail, or shell execution still depends on a LiveView process lifetime.
