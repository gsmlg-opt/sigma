# ex_pi Session Lifecycle — Correctness Plan

> Sequenced after `04-hooks-runtime-and-observability-plan.md`.
> Fixes two firing-frequency bugs in `SessionStart` / `Stop` hooks and
> introduces explicit session states (`:active | :idle | :stopped`) with
> two reopen modes (`:full_history`, `:summary`).

## Problem statement

| Hook | Current behavior | Intended behavior |
|------|------------------|-------------------|
| `SessionStart` | Fires inside `execute_turn/2` — **every turn** | Once, when the agent process is first started for a `session_id` |
| `Stop` | Fires when the LLM emits an assistant message with no tool calls — **every model-turn end** | Once, when the *session* ends: explicit close or idle-timeout |

Root cause: `PiAgent.init/1` does not own session lifecycle. `execute_turn/2` and `run_turn_loop/1` conflate "agent loop iteration" with "session lifecycle event". The terminology in `01-hooks-design.md` line 33 reinforces the confusion by mapping `SessionStart` to `emit({:agent_start, cwd})`, which is itself per-turn.

Missing concepts:
- No persistent session-state machine (`:active | :idle | :stopped`).
- No idle detector.
- No explicit "close session" command.
- No reopen path — reusing a `session_id` silently restarts from disk via `PiSession.Log.replay/1`, but `SessionStart` then fires with `source: :startup` instead of `:resume`, and the user has no choice of resume mode.

## Guiding principles

- **Lifecycle is owned by the supervisor tree, not the turn loop.** `PiAgent` reacts to lifecycle messages from `PiWeb.SessionManager`; the turn loop has no opinion on session boundaries.
- **State machine is explicit, persisted, and observable.** A `session.meta.json` sidecar holds `state`, `opened_at`, `closed_at`, `closed_reason`, `last_activity_at`. Crash recovery reads it; `SessionManager` writes it.
- **Diverge cleanly from Claude Code on Stop semantics.** Repurposing `:stop` silently would break ecosystem hooks; instead introduce `:session_end` for the new semantics and decide whether to keep `:stop` for upstream parity (recommended: drop it, document the divergence).
- **Reopen modes are first-class.** `:full_history` and `:summary` are two distinct user-visible flows, not internal optimizations.

## Placement summary

```
apps/ex_pi_agent/lib/ex_pi_agent.ex
  # init/1 fires SessionStart with source from opts[:resume_source]
  # remove run_session_start_hook call from execute_turn/2
  # remove run_stop_hook call from run_turn_loop/1
  # add terminate/2 → run_session_end_hook
  # add handle_call(:close, ...) and handle_info(:idle_timeout, ...)
  # add :last_activity_at tracking on every user-facing turn

apps/ex_pi_coding/lib/ex_pi_coding/hooks/
  spec.ex      # add :session_end event atom
  payload.ex   # add event_specific(:session_end, ...) - reason field
  discovery.ex # parse "SessionEnd" → :session_end
  outcome.ex   # decode_decision(:session_end, ...) - observe-only

apps/ex_pi_session/lib/ex_pi_session/
  session_meta.ex   # NEW. read/write session.meta.json sidecar.
  log.ex            # add summarize/2 for reopen-with-summary mode

apps/ex_pi_web/lib/ex_pi_web/
  session_manager.ex   # close_session/1, reopen_session/2, idle scan
  live/session_live.ex # handle close button + reopen mode prompt
```

---

## PR 1 — Lift `SessionStart` out of the turn loop  (M-LC-1)

Smallest correctness fix. No new events.

- `PiAgent.init/1` receives `opts[:resume_source]` (`:startup | :resume | :compact | :clear`, default `:startup`).
- After `state` is built, `init/1` returns `{:ok, state, {:continue, :session_start}}`.
- New `handle_continue(:session_start, state)` invokes `run_session_start_hook(state)` exactly once. Effects (developer context prepend) are applied to `state.messages` before any user message arrives.
- **Remove** the call from `execute_turn/2` at line 307. The reset of `stop_hook_active` stays.
- `hook_ctx/1` is unchanged.

**Acceptance:**
- A session that runs three turns fires `SessionStart` exactly once. Add `agent_test.exs` case: assert hook command invocation count via a mock command writing to a temp file.
- Existing tests that asserted per-turn `SessionStart` (if any) are updated to per-session expectations.

---

## PR 2 — Introduce `:session_end` event and `terminate/2` wiring  (M-LC-2)

New event, no behavior change to existing `:stop` yet (deprecated in PR 4).

- Add `:session_end` to `Spec.event()` union, `Discovery.event_name_map` (`"SessionEnd"` / `"session_end"`), and `Payload.event_name(:session_end) → "SessionEnd"`.
- `Payload.event_specific(:session_end, _ctx, data) → %{"reason" => to_string(Map.get(data, :reason, "user_close")), "last_activity_at" => Map.get(data, :last_activity_at, "")}`.
- `Outcome.decode_decision(:session_end, ...)` is observe-only — returns `:proceed`. Hooks can still populate `additionalContext` (logged / persisted) but cannot block; the session is already ending.
- `PiAgent.terminate/2` invokes `run_session_end_hook(state, reason)` synchronously with a short, hard timeout (e.g., 2 s, separate from per-hook timeouts) so OTP shutdown isn't blocked.
- Hooks that crash or time out during `terminate/2` are logged via `Logger.warning`, never re-raised.

**Acceptance:**
- `agent_test.exs`: a configured `SessionEnd` hook fires when the agent receives `:close` or `:shutdown`.
- A 10-second-sleeping `SessionEnd` hook does not block shutdown beyond the 2 s budget.

---

## PR 3 — Session state machine and meta sidecar  (M-LC-3)

Make session state explicit and persisted across restarts.

- New module `PiSession.SessionMeta`. Functions: `load/1`, `write/2`, `touch_activity/1`, `mark_idle/1`, `mark_stopped/2` (reason). On-disk format: JSON sidecar `<storage_path>/session.meta.json` alongside the existing log.
- Schema:
  ```
  %{
    "state" => "active" | "idle" | "stopped",
    "opened_at" => iso8601,
    "last_activity_at" => iso8601,
    "closed_at" => iso8601 | null,
    "closed_reason" => "user_close" | "idle" | "crash" | null,
    "schema_version" => 1
  }
  ```
- `PiAgent.init/1` calls `SessionMeta.write` with state `:active`. `terminate/2` calls `mark_stopped` with the reason from the shutdown trigger.
- Every user message and tool completion calls `SessionMeta.touch_activity/1` (debounced — write at most once per 10 s to avoid disk churn).
- `SessionMeta` is pure-ish: state transitions are functions returning the new struct; the only impure ops are `read_file!`/`write_file!`. Keep it that way for testability.

**Acceptance:**
- `session_meta_test.exs`: round-trip a meta file; assert state transitions are monotonic (`:active → :idle → :stopped`, never backwards within a single agent lifetime).
- Integration: kill an agent with `Process.exit(:kill)`, restart, observe `state: "stopped"` with `closed_reason: "crash"` written by the supervisor or next-mount logic (see PR 5 for crash detection ownership).

---

## PR 4 — Idle detection and explicit close  (M-LC-4)

Wire the two triggers that lead to `:session_end`.

- `PiAgent` state gains `idle_timeout_ms` (default `3_600_000` = 1 h, configurable per-session via `opts[:idle_timeout_ms]`).
- After every activity (touch in PR 3), `Process.send_after(self(), :check_idle, idle_timeout_ms)` schedules an idle check. The ref is stored in state; subsequent activity cancels the previous timer with `Process.cancel_timer/1` before scheduling a new one.
- `handle_info(:check_idle, state)`: if `now - state.last_activity_at >= idle_timeout_ms`, mark meta as `:idle`, run `session_end` hook with `reason: :idle`, then `{:stop, :normal, state}`.
- `handle_call(:close, _from, state)`: same path with `reason: :user_close`. Returns `:ok` to caller before the stop so the LiveView can acknowledge.
- `PiWeb.SessionManager` gains `close_session/1` that calls `GenServer.call(agent, :close)` and waits for the supervisor `:DOWN` monitor message before returning.
- `session_live.ex` adds a "Close session" menu item (the `SessionMenuHook` JS hook already exists per line 227) that triggers `PiWeb.SessionManager.close_session/1`.
- **Deprecate `:stop`**: keep parsing it (`Discovery` still maps `"Stop"` to `:stop`) but log a one-line warning on load: "Stop hook is deprecated; use SessionEnd for end-of-session or PostToolUse for end-of-turn behavior." The execution path stays so legacy hooks continue working — but it's no longer documented or recommended.

**Acceptance:**
- An idle session with no activity for `idle_timeout_ms + 1 s` triggers `:session_end` with `reason: :idle`, and the supervisor entry is evicted from `SessionManager`.
- Clicking "Close session" in LiveView triggers `:session_end` with `reason: :user_close`. The LiveView page navigates away cleanly.
- An existing project with `Stop` hooks configured shows a deprecation warning but the hooks still fire on the legacy code path.

---

## PR 5 — Reopen with full history  (M-LC-5)

The simpler of the two reopen modes; uses the existing `PiSession.Log.replay/1` path.

- `PiWeb.SessionManager.reopen_session/2` with signature `(session_id, opts)` where `opts[:mode]` is `:full_history`.
- Flow:
  1. Read `session.meta.json`; assert `state == "stopped"` (else return `{:error, :not_stopped}`).
  2. `PiSession.Log.replay/1` → message list.
  3. Start a new `PiAgent` via the same `start_session/3` path used today, with `messages: replayed`, `resume_source: :resume`.
  4. Mark meta `state: "active"`, clear `closed_at` / `closed_reason`.
- `init/1`'s `handle_continue(:session_start, state)` (PR 1) passes `source: :resume` into the payload — hooks see the right source.
- On crash-recovery (meta says `"stopped"`, `closed_reason: "crash"`), the user is prompted: "This session ended unexpectedly. Reopen?" rather than silently resuming.

**Acceptance:**
- Open a session, run two turns, close, reopen with `:full_history`. The new agent's `state.messages` matches the old one; `SessionStart` fires with `source: :resume`.
- Reopen of an `:active` session returns `{:error, :not_stopped}` — there is no "force reopen".

---

## PR 6 — Reopen with summary  (M-LC-6)

The harder mode. Reuses the existing PreCompact path conceptually but at session-resume time.

- New function `PiSession.Log.summarize/2` with signature `(storage_path, opts) :: {:ok, summary_msg} | {:error, term}`. Pure-ish: takes the persisted log, calls a configurable summarizer (default: the same provider/model used by `PiAgent.maybe_compact/1`), returns a single synthetic `Message.user` containing the summary, tagged with `meta.kind: :resume_summary`.
- Summarization runs **outside** the new `PiAgent` process — it's a one-shot call from `SessionManager.reopen_session/2` when `opts[:mode] == :summary`. This avoids dragging the live agent into a long-running summarization before its first turn.
- The new `PiAgent` starts with `messages: [summary_msg]`, `resume_source: :compact`. The model sees a single context-laden user-role turn explaining where the conversation left off.
- LiveView UI for reopen: a modal asking "How do you want to resume? [Full history] [Summary]" — wired to the two `mode` values.
- If summarization fails, surface the error to the user with a retry option; do **not** silently fall back to `:full_history` (the user may have requested summary for context-window reasons).

**Acceptance:**
- Reopen with `:summary` produces a single-message starting state and `SessionStart` fires with `source: :compact`.
- Summarization failures present a UI error, not a silent full-history fallback.
- Token-count of the summary is reasonably bounded (set a target in the summarizer prompt; assert in test via mock provider).

---

## PR 7 — UI: session list with state indicators  (M-LC-7)

Make state visible. Small but high-impact.

- The home / project sidebar lists sessions with a state badge: `active` (green dot), `idle` (yellow), `stopped` (grey). Source: `SessionMeta.load/1` for each session.
- Stopped sessions show a "Reopen" button; clicking opens the mode-selection modal from PR 6.
- Active sessions show "Open" (existing behavior) and "Close" (new — calls `SessionManager.close_session/1`).
- Idle sessions are clickable to resume; activity-touch on the new turn transitions state back to `:active`. **Idle does not require explicit reopen** — it's a soft state below the timeout threshold for `:session_end`.

**Acceptance:**
- The session list correctly reflects state for sessions in all three states.
- Closing a session updates its badge to grey within one render cycle.

---

## PR 8 — Update `01-hooks-design.md`  (M-LC-8)

Documentation correctness. Should land alongside PR 1, not be deferred.

- Fix line 33: `SessionStart` is no longer mapped to `emit({:agent_start, cwd})`. Map it to `init/1` / `handle_continue(:session_start, …)`.
- Add a new row for `:session_end`: triggered by `terminate/2` from `:close` or `:idle_timeout`.
- Update the "Stop" row to mark it deprecated and link to `:session_end`.
- Add a new section "Session lifecycle states" describing the `:active → :idle → :stopped` machine, the meta sidecar, and the two reopen modes.
- Update the source enum on line 158 of the doc: `SessionStart.source` values `startup | resume | compact | clear` are correct; clarify which triggers which.

**Acceptance:**
- The design doc accurately describes implemented behavior. A reader can predict from the doc when each hook fires without reading code.

---

## Sequencing & risk

| PR | Risk | Blocking | Why this order |
|----|------|----------|---------------|
| 1 — Lift SessionStart | Low | None | One-line fix; ship first |
| 2 — `:session_end` event | Low | None (parallel with 1) | Adds new event without behavior change |
| 3 — Meta sidecar | Low | PR 1 helpful | Foundation for everything else; mostly pure code |
| 4 — Idle + close | Medium | PR 2, PR 3 | Wires the two triggers; deprecates `:stop` |
| 5 — Reopen full history | Low | PR 3, PR 4 | Reuses existing replay |
| 6 — Reopen summary | Medium | PR 5 | Touches summarizer plumbing |
| 7 — UI state indicators | Low | PR 3, PR 4 | Cosmetic but user-facing |
| 8 — Doc update | Low | PR 1 (ship together) | Prevents the design from re-diverging |

PRs 1–3 are mechanical. PR 4 is where the deprecation decision becomes user-visible and may need a brief announcement. PR 6 is the largest semantically — give it its own review pass.

## Out of scope

- **Sub-agent lifecycle** (Synapsis). When sub-agents land, each one is its own session under a parent `agent_id`; the same state machine applies per sub-agent. No re-versioning needed if PR 1 in `04-...` already added `agent_id` to the payload.
- **Cross-process session migration** (e.g., resume on a different node). The meta sidecar is local-disk; distributed resume needs a different storage backend. Not addressed.
- **Multi-window concurrent sessions**. If two LiveView tabs open the same `session_id`, the existing `SessionManager` returns the same agent pid; behavior is unchanged. The "Close" button from either tab closes for both — accept this for now, revisit if it becomes a UX problem.

## Open questions for design review

1. **Idle threshold default.** 1 hour matches the user's stated intent. Worth making it configurable per project (in `.pi/config.json` or similar) since some workflows want very long idle tolerance (overnight) and others want short (15 min for shared machines).
2. **What happens to in-flight turns at close?** Recommendation: `:close` waits for the current turn task to finish (up to a bounded `current_turn_grace_ms`, e.g., 10 s) before invoking `session_end`. `:idle_timeout` should not fire during an in-flight turn at all — touch activity at turn start, so an active turn keeps deferring the idle timer.
3. **`:stop` removal timeline.** If keeping `:stop` for one minor version then dropping it: announce in the design doc; if dropping immediately: announce louder in the PR 4 description. Recommend the one-version deprecation cycle.
4. **Summary storage.** Should the resume-summary be persisted into the new session's log as the first message (so subsequent reopens of *that* session see it) or kept ephemeral? Recommend persisted — otherwise reopening a summary-resumed session degrades context further on each reopen.
5. **Crash recovery loop.** If a `SessionEnd` hook itself crashes during `terminate/2`, the agent still stops, but the meta sidecar may be inconsistent. Recommend: write `mark_stopped(:crash)` to meta *before* invoking the hook, then update to the real reason on hook success. Worst case is over-reporting crashes, which is safe.
