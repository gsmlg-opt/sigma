# Sigma Session-Owned Terminals — PRD

Status: Product decisions approved; implementation not started by this document
Date: 2026-09-11
Repository: `gsmlg-opt/sigma`
Reviewed baseline: `85a810075fb5f30360c8dea6a5c90d54202a6c7d`
Suggested repository location: `docs/features/session-ui/terminals/prd.md`
Companion: [Implementation Plan](implement_plan.md)

## 1. Purpose and evidence boundary

Provide session-owned, multi-tab interactive terminals. The session owns the terminal resources; a browser attaches to them. Opening a panel, changing tabs, refreshing a page, or losing a browser connection must not accidentally spawn or terminate a shell.

This document records the product decisions approved in the conversation. Requirements below describe **target behavior**, not existing capabilities. Numeric defaults are initial engineering choices, not measured capacity claims. The implementation plan identifies mechanisms that still require a real-platform proof.

At the reviewed baseline, the browser shell is started under the global web application's `WebShellSupervisor`, receives the LiveView as its owner, forwards output to that owner, and closes its Port on termination. It is not a child of the agent session supervision subtree. The existing session supervisor uses `one_for_all` with `max_restarts: 0`. Repository operations include identity-changing rename, adoption, and deletion; successful rename/delete finalization terminates the session subtree. These facts establish integration constraints, not a new runtime reproduction of the reported orphan processes. [R1–R6]

No repository tests or target-machine process-cleanup tests were run when preparing this PRD.

## 2. Product scope

### Required in version 1

- Multiple interactive terminals per session, with a server-authoritative catalog and a badge showing all retained tabs.
- A tabbed panel with explicit creation, selection, renaming, collapse, close, restart-after-exit, resizing, and maximize/restore actions.
- Browser refresh/navigation recovery, bounded recent output, and meaningful terminal screen restoration.
- Multiple observers with one input/PTY-size controller per terminal.
- Verified cleanup of managed OS resources on terminal close or session shutdown, including abnormal-owner paths.
- Session lifecycle guards, resource limits, fault isolation, diagnostics, and native integration tests.

### Not in version 1

Terminal restoration across application/host restart; command re-execution after a restart; split panes; cross-session terminal transfer; remote-host terminals; persistent full-session recording; terminal output becoming LLM context; a new user/authentication system; a general session idle-stop scheduler; migration of every Bash tool call into a terminal tab; extraction into Backplane's shared runtime package.

A reusable PTY boundary is desirable, but this work must not become a Bash-tool rewrite or a terminal platform.

## 3. Terms and ownership

| Term | Meaning |
| --- | --- |
| Session | The repository-qualified agent session, not its LiveView process. |
| Terminal | A retained tab with a stable identity; it can outlive one shell execution. |
| Terminal run | One explicitly started shell execution within a terminal; restart creates a new run generation. |
| Attachment | A server-established browser connection to observe a terminal. |
| Controller | The one attachment currently permitted to send input and change the PTY size. |
| Retained tab | Any terminal not yet successfully closed, including exited, failed, and cleanup-failed terminals. |
| Managed resources | The PTY, helper, shell, and jobs covered by the backend's verified ownership boundary. |

**OWN-01.** Each terminal belongs to exactly one repository-qualified session and one session runtime incarnation. A supervisor-level terminal branch must be part of that session's resource tree. The LiveView is a client, never the sole lifetime owner.

**OWN-02.** No application-level catalog may silently turn a missing session runtime into a new session or recreate a shell during reconnection. A stale runtime incarnation requires resynchronization and an explicit new user action.

**OWN-03.** A terminal is not an OS security sandbox. The startup directory is not a filesystem jail. The backend must document which descendants it can contain and reap; process-group cleanup must not be advertised as confinement of arbitrary daemonized descendants. Unsupported cleanup capability must be explicit, not hidden behind a successful close response.

## 4. Entry point, badge, and tabs

### 4.1 Panel opening and terminal creation

**UI-01.** Clicking the terminal icon opens the panel. If retained terminals exist, select the browser's last selected valid terminal, or the first retained terminal in stable creation order. Do not start another shell.

If there are no retained terminals, this explicit click atomically ensures one initial terminal and selects it. Concurrent first-open requests must converge on one terminal, including while its shell is still starting. If only exited tabs exist, open those tabs; do not silently create a replacement.

**UI-02.** The tab-bar `+` action creates a distinct terminal. One user action has one operation identity; retries within the supported operation window must not create duplicates. Separate deliberate `+` actions may create separate terminals. Browser mounts, reconnect hooks, and hidden-panel restoration must never issue automatic create commands.

### 4.2 Badge semantics

**UI-03.** Badge count equals the number of retained tabs for the session. It does not mean shell processes, child jobs, active connections, or terminals controlled by this browser.

Starting, running, stopping, exited, failed, and cleanup-failed tabs count until removed. For example, three tabs with one exited shell show badge `3`; the accessible label/tooltip explains the breakdown. Hide the visual numeric badge at zero but preserve an accessible zero count. On unavailable state show an explicit unavailable indicator; never present an unknown catalog as zero.

Catalog changes must update the badge in every connected session page, including when its terminal panel is collapsed. Refresh obtains an authoritative snapshot rather than reconstructing counts from browser click history.

### 4.3 Tab behavior

**UI-04.** Stable creation order is the version-1 ordering. Default labels are `Terminal 1`, `Terminal 2`, etc.; labels do not define identity. Renaming is a session-shared operation with length validation and escaped rendering. Display the startup directory as startup information, not as an asserted current shell directory after `cd`.

**UI-05.** A tab shows its lifecycle state, exit status when known, control/observation mode, and an unread-output indicator. Unread state belongs to the browser and clears only when the selected, visible terminal has rendered the relevant output.

**UI-06.** The panel supports height adjustment and maximize/restore. Tab selection, panel visibility/height, scroll position, and unread indicators remain browser-window-local. Changing tabs in one window must not switch tabs in another.

**UI-07.** Use existing DuskMoon components and styling conventions. Provide accessible tab semantics, keyboard navigation when the tab bar is focused, visible focus, and non-color-only status indicators. Do not intercept ordinary terminal control keys to implement page shortcuts. [R7]

## 5. Hide, detach, close, exit, and restart

| User/system action | Required result |
| --- | --- |
| Collapse panel | Hide UI; release this view's active input control; preserve terminals. |
| Navigate away, refresh, close browser | Detach or expire attachments; preserve terminal runs. |
| Change selected tab | Change display/input target; preserve all runs. |
| Close a live tab | Confirm termination, initiate cleanup, retain `stopping` until cleanup is confirmed, then remove. |
| Close an exited/failed tab with confirmed cleanup | Remove retained metadata/history without a live-process warning. |
| Shell exits | Reap remaining managed resources, then retain a read-only tab with output and exit information. |
| Cleanup fails or is indeterminate | Keep tab and resource accounting; show the failure and retry action. |
| Restart an exited/failed tab | Explicitly start a fresh run after prior cleanup is confirmed. |

**LIFE-01.** Use a collapse control for the panel and a separate close control for each tab. There is no implicit “terminate all” action attached to panel collapse.

**LIFE-02.** Version 1 confirms closing any live terminal rather than trying to infer whether a foreground command is important. A session-delete confirmation may cover the listed terminals as a group. Confirmation is a UI safeguard; server-side identity, revision, and lifecycle checks are still required.

**LIFE-03.** Close is idempotent. A tab is removed only after all resources in its declared managed scope are confirmed gone. A helper exit or shell exit alone is insufficient. When the shell exits but managed jobs remain, show a cleanup state and retain the session pin.

**LIFE-04.** Restart preserves the tab identity and custom label, increments `run_generation`, resets control and stream state, and visibly starts a new execution. It does not replay shell history or commands. Clear the old run's buffer after an explicit restart warning; persistent history is not part of this release. Never auto-restart a shell after failure.

**LIFE-05.** Losing a browser must not depend on a successful browser-unload message. Monitors and attachment expiry must handle abrupt disconnects. Losing the BEAM owner, terminal worker, or session must trigger managed-resource cleanup through a mechanism independent of that process's `terminate/2` callback. [R8]

## 6. Session lifecycle and failure isolation

**SESSION-01.** Hibernation does not close terminals. Any automatic session-stop decision must be inhibited by starting/running/stopping terminals or unresolved cleanup. “No browser attached” and “no output recently” are not sufficient reasons to kill terminals.

This feature adds a lifecycle guard and a visible retained-resource reason. It does not require introducing a new 24-hour reaper or changing the existing hibernation policy.

**SESSION-02.** Explicit session stop/delete closes admission for new terminal runs before cleanup begins. Confirm affected live terminals, drain and verify resources, and only then complete the destructive operation. A concurrent creation cannot slip between the resource check and deletion. Preserve existing agent-operation admission and journal durability requirements. Cleanup failure prevents a successful delete acknowledgement; show partial effects honestly if a later persistence/filesystem step fails.

**SESSION-03.** Forked sessions receive no terminals. Model changes, prompt cancellation, context reload, compaction, and selecting a different session page do not close or clone terminals. A cancelled agent turn is not a terminal-close request.

**SESSION-04.** Identity-changing session rename/adoption or repository relocation cannot silently detach existing resources from their ownership key. The safe version-1 policy is to reject these operations while live or cleanup-pending terminals exist, with a clear close-first explanation. With only exited retained tabs, require acknowledgement before an operation that discards their volatile history. A title-only edit that does not change identity remains allowed.

**SESSION-05.** Normal shell exit and one terminal worker failure must not stop the agent, writer, other terminals, or repository runtime. A terminal subsystem failure may make terminals unavailable and initiate their cleanup, but must not silently restart shells or consume the core session's restart budget. Preserve existing core agent/writer failure semantics. [R4, R9]

**SESSION-06.** Application/host restart does not restore old terminal processes, control leases, or volatile output. Old attachments must be rejected. Graceful application shutdown still requires bounded managed cleanup. Abrupt VM/helper failure behavior and any platform limits must be reported accurately; no process-survival guarantee is implied.

## 7. Multi-window observation and control

**CTRL-01.** Multiple authorized session views can observe a terminal. Exactly one attachment may write input and change its PTY dimensions at a time. This is concurrency control, not user authentication.

**CTRL-02.** Creating a terminal grants initial control to the initiating attachment. Selecting a terminal may request vacant control as an explicit user action. Attaching, receiving output, page focus changes, or background reconnection do not steal occupied control. Observers have a clearly labeled `Take control` action.

**CTRL-03.** A takeover is atomic and increments a control epoch. The previous controller becomes read-only. Input and resize must be checked against the active attachment, current epoch, session incarnation, and terminal run at the final server-side execution boundary. Delayed messages from an old controller cannot execute after takeover acknowledgement.

**CTRL-04.** Release control when the controlling view collapses the panel, changes away from that terminal, or detaches. Abrupt disconnect is handled by monitoring and lease expiry. A returning browser must reacquire control; an old browser ID is not a credential. Concurrent takeovers use expected-epoch conflict detection rather than repeated silent stealing.

**CTRL-05.** Every observer renders the terminal's canonical dimensions. An observer's viewport cannot resize the PTY. A newly granted controller may request a valid size. Hidden terminals must not send zero-sized or guessed resize requests.

## 8. Output, replay, and real PTY resizing

**STREAM-01.** A returning browser reconnects to the same terminal run and restores its screen plus bounded recent history, even if nobody was connected while it produced output. Saving the last few text lines or replaying an arbitrary tail of ANSI bytes is not sufficient.

Use a tested server-side terminal-state representation and checkpoint/replay strategy. Validate normal and alternate screen buffers, cursor/attributes, resize ordering, split UTF-8 and control sequences. A native/server-side implementation is selected and packaged during the plan's feasibility gate. The xterm project documents headless terminal state plus serialization as a reference approach, not an already-installed Sigma dependency. [R10]

**STREAM-02.** Attach provides a coherent snapshot/checkpoint with a sequence watermark, followed by later output without silent gaps, duplication, or cross-terminal delivery. Client acknowledgements advance after output is parsed/rendered, not just received. A replay gap must trigger a fresh coherent snapshot. An unavailable snapshot is an explicit degraded state, not a fabricated complete screen.

**STREAM-03.** Output/history, pending transport frames, parser work, and every subscriber queue have explicit bounds. A slow observer is paused/detached and resynchronized rather than causing unbounded server memory, blocking healthy observers, or silently losing arbitrary screen-control bytes. When local processing cannot keep up, apply controlled PTY read backpressure rather than unlimited buffering. [R11]

**STREAM-04.** Lost or unacknowledged keyboard input is not automatically retransmitted after reconnect. Warn that completion may be unknown. Do not queue input while offline or while read-only. Terminal device replies must not be generated independently by every observer or replayed as user input.

**STREAM-05.** Changing size updates the actual PTY window size through the backend and produces a confirmed canonical dimension event. Updating CSS, Elixir fields, environment variables, or merely sending `SIGWINCH` is not acceptance. Test `stty size` and a full-screen program after live resize. Preserve the dedicated unpadded xterm host and measure with the fit addon rather than fixed character-width guesses.

## 9. Limits, privacy, and operational state

**OPS-01.** Enforce server-side per-session retained-tab limits and node-wide managed-run limits atomically before starting OS resources. Starting reservations and unresolved cleanup consume capacity. Exited tabs consume retained-tab/history capacity but not a confirmed-released OS-run slot. Limits are not LLM-controlled.

Initial tunable engineering defaults:

| Setting | Default |
| --- | --- |
| Retained tabs per session | 8 |
| Managed runs/reservations across the node | 32 |
| Retained terminal records across the node | 128 |
| Observers per terminal | 4 |
| Recent raw replay tail | 1 MiB per terminal |
| Server terminal-state/snapshot budget | 2 MiB per terminal |
| Aggregate terminal retention budget | 128 MiB per node, with allocation overhead measured separately |
| Pending output per attachment | 256 KiB |
| Maximum input frame | 16 KiB; large paste is explicitly chunked |
| Canonical dimensions | 2–500 columns; 1–300 rows; initial 120 × 24 |
| Controller lease / renewal interval | 15 seconds / 5 seconds |
| Mutation deduplication window | 10 minutes, with bounded records and explicit expired/unknown results |
| Default managed cleanup budget | 5 seconds; expiry means unresolved cleanup, not success |

Do not evict live terminals or unclosed tabs silently to satisfy a limit. Bound/truncate old history with a visible marker; reject new allocations when preserving valid screen state would exceed a hard budget. Test behavior with small injected budgets. These values are starting policies to validate, not a performance guarantee.

**OPS-02.** Catalog unavailable, backend missing, unsupported platform, startup failure, loss of control, output resync, cleanup timeout, and capacity exhaustion each have distinct UI states and typed errors. Log resource identity/generation, operation ID, timings, and result classification—not keystrokes, full output, environment values, or secrets by default.

**OPS-03.** Terminal bytes remain outside agent prompts, compaction summaries, skill invocation records, and the session conversation JSONL unless a later feature explicitly adds that behavior. Browser-local storage may retain presentation preferences but not terminal output or authority tokens. Terminal-originated text and links are untrusted; do not turn OSC titles, clipboard requests, or link content into privileged UI actions.

**OPS-04.** Do not add anonymous terminal endpoints. All operations must validate the active session scope and server-established attachment. Existing deployment authentication remains an external concern where applicable; this feature does not claim to repair the previously identified global UI/API authentication gaps.

## 10. Acceptance scenarios

Every scenario is required for the integrated feature; fake-backend tests do not replace native OS tests.

| ID | Scenario and expected result | Requirements |
| --- | --- | --- |
| A01 | Two windows first-open an empty session: one retained terminal/run; both catalogs agree. | UI-01–03 |
| A02 | Repeated open/collapse, navigation, and refresh keep run identity and process count. | OWN-01–02, UI-01, LIFE-01 |
| A03 | Two explicit `+` actions create two runs; a replayed operation does not add a third. | UI-02, OPS-01 |
| A04 | Badge includes exited/error tabs and updates while every panel is collapsed. | UI-03 |
| A05 | Exit retains output/code; explicit restart changes generation without executing old commands. | LIFE-03–04 |
| A06 | Close with foreground/background jobs, including signal-resistant jobs, verifies managed cleanup before removal. | LIFE-03, OPS-01 |
| A07 | Cleanup failure keeps tab/pin/capacity; retry reaches a truthful terminal result. | LIFE-03, OPS-02 |
| A08 | Kill a terminal worker: cleanup runs; other terminals, agent, and writer survive. | LIFE-05, SESSION-05 |
| A09 | Kill the terminal subsystem: core session survives; UI says unavailable and unresolved resources remain accounted for. | SESSION-05, OPS-02 |
| A10 | Session delete races with create: admission is closed and no resource appears after successful deletion. | SESSION-02 |
| A11 | Hibernate preserves terminal; automatic-stop admission rejects live or unconfirmed resources. | SESSION-01 |
| A12 | Fork/model change/compaction/turn cancellation leave existing terminal ownership unchanged. | SESSION-03 |
| A13 | Identity-changing rename/adopt rejects active resources before file mutation. | SESSION-04 |
| A14 | Two observers, one controller: stale input and resize are rejected after takeover. | CTRL-01–03 |
| A15 | Abrupt controller disconnect, lease expiry, and reacquisition never create two controllers. | CTRL-04 |
| A16 | Different observer viewport sizes do not resize the PTY; granted controller resize is visible to `stty`/TUI. | CTRL-05, STREAM-05 |
| A17 | Output while detached, alternate-screen use, resize, then reconnect: coherent screen, ordered subsequent output. | STREAM-01–02 |
| A18 | High output and slow observer: all budgets hold, healthy viewer/control remain responsive, gap resync is explicit. | STREAM-03, OPS-01 |
| A19 | Split multibyte/control sequences and replay do not corrupt rendering or duplicate terminal query responses. | STREAM-01–04 |
| A20 | Unconfirmed input is not replayed after disconnect. | STREAM-04 |
| A21 | Cross-session/stale-incarnation/stale-generation IDs and forged controller epochs are rejected server-side. | OWN-02, CTRL-03, OPS-04 |
| A22 | Quotas, start failure, and close retry do not leak or prematurely release capacity. | OPS-01 |
| A23 | Tab selection/panel state are window-local; rename/status/catalog are shared. | UI-04–07 |
| A24 | Packaged Linux/NixOS and macOS builds pass their declared PTY/cleanup/resize capability tests. | LIFE-05, STREAM-05, OPS-02 |
| A25 | Application restart does not resurrect shells; stale browser reconnection is safe and explicit. | SESSION-06 |
| A26 | Terminal content never appears in prompt/journal/default application logs. | OPS-02–03 |

## 11. Definition of done

The feature is done only when the acceptance matrix has traceable automated tests or recorded native/browser verification, the old LiveView-owned spawn path is removed from production use, release packaging contains the selected runtime dependencies, documentation matches observed platform guarantees, and no critical cleanup/replay/isolation requirement is hidden as a silent fallback.

A missing backend proof may block production enablement. It does not justify substituting `Port.close`, a single guessed process-group kill, a raw-tail replay, or a fake-backend-only test suite and declaring the feature complete.

## References

Repository references are pinned to the reviewed baseline. They are evidence of existing code, not proof of the proposed feature.

- [R1 — Web application supervision](https://github.com/gsmlg-opt/sigma/blob/85a810075fb5f30360c8dea6a5c90d54202a6c7d/apps/sigma_web/lib/sigma_web/application.ex)
- [R2 — Existing WebShell](https://github.com/gsmlg-opt/sigma/blob/85a810075fb5f30360c8dea6a5c90d54202a6c7d/apps/sigma_web/lib/sigma_web/web_shell.ex)
- [R3 — SessionLive shell entry points](https://github.com/gsmlg-opt/sigma/blob/85a810075fb5f30360c8dea6a5c90d54202a6c7d/apps/sigma_web/lib/sigma_web/live/session_live.ex)
- [R4 — SessionSupervisor](https://github.com/gsmlg-opt/sigma/blob/85a810075fb5f30360c8dea6a5c90d54202a6c7d/apps/sigma_agent/lib/sigma_agent/session_supervisor.ex)
- [R5 — Runtime operations](https://github.com/gsmlg-opt/sigma/blob/85a810075fb5f30360c8dea6a5c90d54202a6c7d/apps/sigma_agent/lib/sigma_agent/runtime.ex)
- [R6 — RepositoryProcess operation ordering and finalization](https://github.com/gsmlg-opt/sigma/blob/85a810075fb5f30360c8dea6a5c90d54202a6c7d/apps/sigma_agent/lib/sigma_agent/repository_process.ex)
- [R7 — Repository contributor/UI conventions](https://github.com/gsmlg-opt/sigma/blob/85a810075fb5f30360c8dea6a5c90d54202a6c7d/AGENTS.md)
- [R8 — OTP Ports and Port Drivers](https://www.erlang.org/doc/system/ports.html)
- [R9 — OTP supervision principles](https://www.erlang.org/doc/system/sup_princ.html)
- [R10 — xterm.js headless state and serialization](https://github.com/xtermjs/xterm.js#nodejs-support)
- [R11 — xterm.js flow control](https://xtermjs.org/docs/guides/flowcontrol/)
