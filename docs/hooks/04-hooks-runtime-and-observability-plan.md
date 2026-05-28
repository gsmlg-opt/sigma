# ex_pi Hook System — Runtime & Observability Follow-up Plan

> Sequenced after `03-hooks-implementation-plan.md`. PR-sized, code-anchored.
> Targets three gaps surfaced in review: payload env-vars + multi-agent fields,
> agent-event vocabulary for hook execution, chat-UI surfacing of hook runs.

## Guiding principles

- **Single observable channel.** Hook execution is an agent event, not a side telemetry stream. PubSub on `session:#{id}` already carries `message_start`, `tool_execution_*`, `turn_*`; hook events join the same channel so replay, export, and LiveView all stay coherent.
- **Pure decode, impure emit.** `Payload`, `Outcome`, `Matcher` remain pure. The runner is the only impure boundary; event emission threads through `ctx.on_event` so tests can assert event sequences with an in-memory collector.
- **Backwards-compatible payloads.** All new payload fields are additive. Existing Codex/Claude/pi hook scripts must keep working unchanged.
- **No dead surface area.** `SessionContext.@ordered_sources` either gets a producer or loses `:hooks`. Reserved fields rot fast.

## Placement summary

```
apps/ex_pi_coding/lib/ex_pi_coding/hooks/
  payload.ex   # + agent_id, project_id, env-var derivation
  runner.ex    # + on_event emission, env-var injection
  spec.ex      # (unchanged)
  hooks.ex     # + dispatch/4 signature carries ctx.on_event

apps/ex_pi_agent/lib/ex_pi_agent.ex
  # hook_ctx/1 carries on_event + agent_id

apps/ex_pi_session/lib/ex_pi_session/log.ex
  # persist_event/2 accepts new event tags

apps/ex_pi_web/lib/ex_pi_web/live/session_live.ex
  # handle_info for :hook_start/:hook_end/:hook_warning/:turn_blocked

apps/ex_pi_web/lib/ex_pi_web/components/
  hook_run.ex  # new collapsible row component
```

---

## PR 1 — Payload extension: env vars + multi-agent identity  (M-RT-1)

Smallest, lowest-risk landing. Pure additions; existing hooks unaffected.

- `Payload.build/3` adds `agent_id`, `project_id` (both optional) into the common fields block. Pulled from `ctx[:agent_id]` and `ctx[:project_id]`. Omitted via `maybe_put/3` when nil — never `""`.
- New module `PiCoding.Hooks.Env` (pure). One function: `derive(ctx, event) :: [{charlist, charlist}]`. Produces canonical env entries: `PI_SESSION_ID`, `PI_PROJECT_DIR`, `PI_TRANSCRIPT_PATH`, `PI_HOOK_EVENT`, `PI_PERMISSION_MODE`, `PI_AGENT_ID` (if present), `PI_PROJECT_ID` (if present), `PI_TURN_ID` (if present), plus the Claude-compat aliases `CLAUDE_PROJECT_DIR`, `CLAUDE_HOOK_EVENT` for ecosystem hook scripts.
- `Runner.build_env/1` now takes `ctx`, merges `Env.derive/2` over `System.get_env()` (user env wins for explicit overrides — but our `PI_*` keys override inherited values for correctness).
- `hook_ctx/1` in `PiAgent` populates `agent_id` from `state.session_id`'s owning agent (use the GenServer's registered name or a stable id field — pick whichever you've already got; do **not** introduce new identity).

**Acceptance:**
- Existing hook tests pass unchanged (additive).
- New `env_test.exs`: golden table of `(ctx, event) → expected env subset`.
- New `payload_test.exs` cases for `agent_id`/`project_id` presence/absence.
- Manual: a `bash -c 'echo "$PI_PROJECT_DIR / $PI_SESSION_ID"'` hook command echoes the right values.

---

## PR 2 — Runner emits hook lifecycle events  (M-RT-2)

Make hook execution observable. Single-direction additive change to `Runner` + the dispatch facade.

- `Hooks.dispatch/4` gains an optional 5th-arg-via-ctx convention: `ctx[:on_event]` is a 1-arity function (defaults to no-op). Keeping it inside `ctx` avoids changing the public signature again.
- `Runner.run/4` calls `ctx.on_event.({:hook_start, event, spec_label, %{cmd: cmd, dialect: dialect, origin: origin}})` immediately before `Port.open/2`, and `{:hook_end, event, spec_label, outcome, %{duration_ms: d, exit: code, stdout_len: n}}` after decode. On crash/timeout: `{:hook_warning, event, spec_label, reason}`.
- Spec-label format already exists (`spec_label/1`). Reuse — do not duplicate.
- `apply_post_outcome` in `PiCoding.Dispatcher` propagates the same `on_event` from `opts` to `hook_ctx` so post-tool hooks emit too.
- All three new event tags are documented in `PiAgent`'s moduledoc event vocabulary list.

**Acceptance:**
- `runner_test.exs` with an in-memory collector function asserts emission order: `start → end` for success, `start → warning` for timeout, no events for filtered-out specs.
- No telemetry removal in this PR — telemetry and on_event coexist. Consolidation is PR 6.

---

## PR 3 — Persist & replay hook events  (M-RT-3)

Hook runs survive process restart and appear on session reload.

- `PiSession.Log.persist_event/2` already accepts arbitrary event tuples; verify it round-trips the new tags. If the on-disk format is term-based, no change. If JSON, extend the serializer with `:hook_start`/`:hook_end`/`:hook_warning` cases.
- `PiSession.Log.replay/1` — confirm replay surfaces hook events in original order interleaved with messages. Hook events should *not* be inserted into `state.messages` (they aren't messages); they re-emit through the same `on_event` channel that LiveView subscribes to.
- The `session_live` mount path that calls `replay/1` already routes events through PubSub broadcast — verify this still holds for the new tags.

**Acceptance:**
- `log_test.exs`: persist a session containing a `:hook_start`/`:hook_end` pair, replay, assert event order and content.
- Manual: refresh a session page mid-conversation; hook bubbles re-render in their original positions.

---

## PR 4 — LiveView surface for hook runs  (M-RT-4)

The "see hooks in chat UI" deliverable. New component, new stream handlers.

- New `PiWeb.Components.HookRun` functional component. Inputs: `event`, `spec_label`, `outcome` (atom/tuple), `duration_ms`, `expanded?`. Collapsed default shows a single muted line: `⚙ PreToolUse · check-bash.sh · proceed (12ms)`. Expanded reveals: cmd, dialect, origin (`global`/`project`/`local`), full reason/context text, raw stdout snippet (capped, same 10 K char limit as the runner).
- Distinct visual tier from user/assistant/tool messages — `border-l` accent, smaller text, no avatar. This is operator chrome, not conversation.
- `session_live.ex` gets new `handle_info/2` clauses:
  - `{:hook_start, event, label, meta}` — insert a `:running` row into the message stream.
  - `{:hook_end, event, label, outcome, meta}` — update the running row in place (LiveView stream `:update`) with final outcome + duration. If `start` was missed (e.g., very fast hook on initial render), insert directly.
  - `{:hook_warning, event, label, reason}` — render as a yellow-tinted variant of the same component.
- The stream key is `{:hook, event, spec_label, monotonic_id}` to allow multiple concurrent runs of the same spec without collision.

**Acceptance:**
- `session_live_test.exs`: render a session that includes a hook event tuple in its persisted log; assert the `HookRun` component is in the DOM with correct outcome class.
- Manual smoke: configure a `PreToolUse` hook that sleeps 200ms; trigger a tool call; observe the row enter `:running` then transition.

---

## PR 5 — Wire `turn_blocked` and surface warnings  (M-RT-5)

Closes the silent-drop bug.

- Add `handle_info({:turn_blocked, reason}, socket)` in `session_live.ex`. Renders a distinct red `HookRun`-family row carrying the block reason; sets a `flash[:warning]` only if the user is at the bottom of the scroll (avoid intrusive popovers mid-scroll).
- Hook warnings currently logged via `Logger.warning("[hooks] …")` now also flow through `on_event`. The `Logger.warning` call in `PiCoding.Dispatcher.surface_warning/1` is replaced by an `on_event.({:hook_warning, …})` call — Logger is still attached upstream via a telemetry handler if you want shell-level logs, but the canonical path is the event channel.

**Acceptance:**
- A `UserPromptSubmit` hook returning exit 2 produces a visible `turn_blocked` row in the conversation, with the reason text shown.
- An untrusted hook produces a `hook_warning` row, not a silent skip.

---

## PR 6 — Decide `SessionContext.:hooks` bucket  (M-RT-6)

Forcing function for the dead-bucket question. Two routes; pick one in design review before opening the PR.

**Route A — populate.** `PiAgent.start_link/1` (or wherever `SessionContext.new/1` is constructed) calls `PiCoding.Hooks.Discovery.load/1` once, summarises specs into a redacted block (`event`, `matcher`, `origin`, *not* `cmd`) and feeds `hooks: summary` into `SessionContext.new/1`. The model gains visibility into "what this project's hooks enforce" without leaking command strings.

**Route B — remove.** Delete `:hooks` from `@ordered_sources`, `@titles`, and the `injection_type` union. Update docs and the `session_context_test.exs` golden.

Recommendation: **A** if you ever want the model to reason about why an action was blocked ("the project's PreToolUse hook on `Bash` would deny `rm -rf`"). **B** if you treat hooks as purely operator concerns invisible to the model. Either decision is fine; the current half-state isn't.

**Acceptance:**
- `session_context_test.exs` reflects the chosen route.
- Either a `Hooks` reminder block appears in rendered system context (Route A), or no reference to `:hooks` remains in the module (Route B).

---

## PR 7 — Telemetry consolidation  (M-RT-7, optional)

Cleanup, can ship later or be skipped.

- Keep `:telemetry.execute/3` calls in `Runner` (they're free and external observability tools depend on the format).
- Add a single application-level telemetry handler that re-emits selected hook telemetry as `on_event` for sessions that didn't pass `on_event` in `ctx` (background hooks, future scenarios).
- Document the rule: **telemetry = metrics/tracing surface, on_event = UI/persistence surface.** Both are valid; they answer different questions.

**Acceptance:**
- No behavior change in the default path.
- Doc note in `PiCoding.Hooks.Runner` moduledoc clarifying the two channels.

---

## Sequencing & risk

| PR | Risk | Blocking | Why this order |
|----|------|----------|---------------|
| 1 — Env+IDs | Low | None | Pure additions; unblocks all downstream observability work without UI churn |
| 2 — on_event | Low | PR 1 helpful but not strict | Defines the canonical event channel everything else builds on |
| 3 — Persistence | Low | PR 2 | Without persistence, replays would silently lose hook history |
| 4 — UI component | Medium | PR 2, PR 3 | Largest visual surface; lands once events are stable |
| 5 — `turn_blocked` | Low | PR 4 (reuses component) | One-line bug fix elevated by the new component |
| 6 — `:hooks` bucket | Low | None | Independent; can land any time after design decision |
| 7 — Telemetry cleanup | Low | None | Pure docs/refactor |

PRs 1–3 are mechanically uninteresting and should each fit in a single review session. PRs 4–5 are where design feedback matters; expect iteration on the `HookRun` component visual tier.

## Out of scope

- HTTP hook handlers (still parsed-but-unsupported, per M5 in the original plan).
- Sub-agent hooks. If/when `Synapsis` introduces sub-agents, `agent_id` already lands in PR 1, so the payload won't need re-versioning.
- MCP-tool hooks. Defer to a future PR once `backplane`'s MCP surface stabilises.
- Project-wide hook composition (e.g., multiple repos in one Samgita project contributing hooks). Current `Discovery.load/1` walks one `cwd` — multi-repo merging is a Samgita-side concern, not a hook-engine concern.

## Open questions for design review

1. **Origin tagging.** `spec.origin` is `{:global, path} | {:project, path} | {:local, path}` today. Should the UI distinguish these visually (e.g., a "project" badge), or just expose them on expand?
2. **Concurrent hook display.** Five hooks firing in parallel on `PostToolUse` — show as five rows, or one row with a fan-out summary? Recommend five rows for clarity; revisit if it becomes noisy.
3. **Truncated stdout.** 10 K char cap is enforced at runner level. UI should show a `… (truncated)` marker when `stdout_len > 10_000`. Trivial but worth being explicit.
4. **Replay ordering guarantee.** Hooks run via `Task.async_stream(ordered: false)`. Persisted order should follow completion time, not spec order, to match observed reality. Confirm `Log.persist_event/2` is called from the reducer in completion order — quick check during PR 3.
