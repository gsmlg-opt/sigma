# Session UI Information Implementation Plan

> **For agentic workers:** Use subagent-driven-development to implement this approved design. Each worker owns disjoint files; the coordinator runs Mix commands serially. No commits, pushes or deployment.

**Goal:** Make conversation primary, remove repeated statistics, and preserve accurate request/turn/session scopes.

**Architecture:** SessionLive composes the existing runtime projection and refreshes affected stream rows on metrics changes. SessionObservability renders compact turn summaries and a unified details panel. A session-scoped browser hook controls responsive navigation/focus without changing runtime behavior.

**Tech Stack:** Elixir, Phoenix LiveView, DuskMoon custom elements, scoped CSS, browser JavaScript and ExUnit.

**Workspace:** `/home/gao/Workspace/gsmlg-opt/sigma/.trees/session-ui`, branch `codex/session-ui`.

## Task 1 — Baseline and terminal metrics regression

Owner: SessionLive worker. Files: `apps/sigma_web/lib/sigma_web/live/session_live.ex`, `apps/sigma_web/test/sigma_web/live/session_live_test.exs`.

- [x] Run the existing scoped baseline through the coordinator.
- [x] Add a test that streams an assistant message while its turn is running, then sends a terminal metrics fact and asserts the rendered turn becomes completed without reload. Repeat with a later request usage correction; terminal status must remain completed.
- [x] Use the existing metrics fold, retain rendered message identity and reinsert only affected rows. Do not infer completion from request completion, reset the stream or replay the journal.
- [x] Cover failed/cancelled/tool-only turns and multiple assistant steps: exactly one visible summary per turn, including when no final text answer exists.

Validation command: `devenv shell --no-tui -- mix test apps/sigma_web/test/sigma_web/live/session_live_test.exs`.

## Task 2 — Observability components

Owner: component worker. Files: `apps/sigma_web/lib/sigma_web/components/session_observability.ex`, `apps/sigma_web/test/sigma_web/components/session_observability_test.exs`.

- [x] Keep public component entry points compatible. `turn_summary(summary: map)` renders state, wall duration, input and output; request/tool counts appear for multi-step execution. Request diagnostics are enclosed in native details elements.
- [x] `session_overview_rail(snapshot: map)` renders session own usage, coverage, timing, inherited usage and lineage; remove duplicated current model/context/runtime groups.
- [x] `context_budget_card(policy: map, successful_compactions: value, last_compaction: map)` owns all context and compaction presentation; new attributes have defaults for existing callers. Use runtime values for window/threshold/remaining/overflow, never recalculate policy.
- [x] Test 19,798 estimate / 20,176 measured / 409,600 threshold / 389,802 remaining labels, unknown and stale inputs, hard-budget warnings, partial usage and inherited statistics. Keep existing request details accessible.

Validation command: `devenv shell --no-tui -- mix test apps/sigma_web/test/sigma_web/components/session_observability_test.exs`.

## Task 3 — Shell and browser behavior

Owners: SessionLive worker owns HEEX/events; coordinator owns `apps/sigma_web/assets/css/app.css`, `apps/sigma_web/assets/js/app.js`, and new `apps/sigma_web/assets/js/hooks/session_panels.js` / `session_panels_test.js`.

- [x] Use one navigation node and one details node across breakpoints, with hooks controlling local expanded state. Keep server-driven content and DOM IDs stable.
- [x] Shell contract: `#session-panels` with `phx-hook="SessionPanels"`; navigation `[data-session-panel="navigation"]`, details `[data-session-panel="details"]`; native action buttons use `data-session-panel-toggle="navigation|details"`, close buttons `data-session-panel-close`, scrim `data-session-panel-backdrop`. Hook reflects `data-navigation-open`, `data-details-open` on shell. Desktop defaults: navigation open >=768px, details open >=1280px. Narrow panels are modal, mutually exclusive, Escape-close, focus-trapped and restore opener focus.
- [x] Focus traversal supports custom-element shadow roots; backdrop makes background inert only in modal mode. Resize removes stale dialog/inert states. LiveView updates must preserve local open state.
- [x] Use session-scoped surface tokens, independently scrollable panels, wrapping header controls and normal text sizes. Preserve central grid and terminal dock directly after composer.
- [x] Inspect installed dm_chat_input public CSS/property contract. Use supported editor sizing only; if unavailable, report upstream blocker and continue independent tasks. Never patch dependency private shadow DOM.
- [x] Add focused JS tests for breakpoint state, exclusivity, Escape and cleanup. Verify real focus behavior in browser.

Validation command: `bun test apps/sigma_web/assets/js/hooks/session_panels_test.js apps/sigma_web/assets/js/chat_submission_test.js apps/sigma_web/assets/js/chat_attachments_test.js`.

## Task 4 — SessionLive composition

Owner: SessionLive worker, same files as Task 1. Depends on agreed component and shell contracts.

- [x] Resolve title from existing session summaries; use Untitled session with short ID fallback, full identity in metadata. Consolidate workdir/effective_cwd into project details, preserving their distinction.
- [x] Header: title, phase label, model selector, navigation/details toggles and terminal trigger. Move Compact into context section; expose budget warning when details closed.
- [x] Replace repeated metadata cards with unified overview/context/metadata sections. MCP shows configured count and unavailable connection status unless reliable status already exists.
- [x] Remove per-user-message side-effect warning. Keep Retry/Fork warnings in execution dialogs; provide accessible Resend explanation at its action.
- [x] Update scoped assertions for removed intentional duplicates, responsive access, stable summary identities and terminal placement.

## Task 5 — Review and acceptance

Owner: coordinator, independent read-only reviewer.

- [x] Sync only relevant display rules in `docs/features/session-ui/prd.md` and record evidence in `docs/superpowers/specs/2026-09-29-session-ui-information-acceptance.md`.
- [x] Review approved design coverage first, then code quality; resolve actionable findings within scope.
- [x] Run scoped component/LiveView/terminal tests and affected JS checks serially with asset compilation. No live providers and no broad unrelated suite.
- [x] Browser: isolated fixture, 320/390/1024/1440/1920 widths, short height, light/dark, long code/input, both drawers, focus/keyboard, scroll and terminal dock/maximize/restore. Capture screenshots and report browser evidence separately.
- [x] Stop after in-scope gates pass; list any remaining blocker accurately. Leave changes uncommitted for user review.

## Outcome

Unblocked tasks complete and independently reviewed. Compact auto-grow sizing is blocked by duskmoon-dev/duskmoon-elements#81; no dependency/private-shadow workaround. See the acceptance record for exact scope, tests and browser evidence.
