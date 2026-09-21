# Backplane runtime integration

**Goal:** Run Sigma turns by default through the published Backplane Agent Runtime 1.6.0 while retaining Sigma's session and Protocol V1 boundaries.

**Architecture:** `Sigma.Agent` retains prompt admission, session queues, canonical journal events, provider configuration, hooks, and compaction. `execution_engine: :backplane` selects one `Backplane.AgentRuntime.Conversation` per turn; `:backplane` is the default and `:sigma` remains an explicit fallback. The shared path uses Sigma's real provider facade and coding dispatcher, with a separate acknowledged runtime-record sidecar beside the transcript.

**Scope:** `sigma_agent`, its dependency lock, the boot-time engine selector, focused integration tests, and integration documentation. The user authorized making Backplane the default on 2026-09-21. No UI redesign, historical JSONL rewrite, legacy-engine removal, live provider invocation, commit, or deployment.

## Implementation and verification

- [x] Pin `backplane_agent_runtime` to 1.6.0 and fetch without upgrading unrelated dependencies.
- [x] Add the selectable engine with existing event, metrics, context, permission, steering, cancellation, and follow-up semantics.
- [x] Add a serialized file-backed Store adapter with atomic snapshots, revision checks, incarnation fencing, and explicit recovery boundaries.
- [x] Verify the Store against the upstream conformance harness and real reopen/failure tests.
- [x] Verify `PublicRuntime` → Sigma Agent → Backplane → real Sigma dispatcher → file output → provider continuation → journal and Protocol V1 terminal events.
- [x] Verify streaming, permissions, cancellation, unsupported-schema rejection, and Sigma fallback regressions with scoped tests.
- [x] Document activation, supported guarantees, limitations, and remaining rollout gates.
- [x] Make Backplane the default; verify real public-command execution without an engine option, explicit Sigma fallback, application fallback, and per-session precedence.

## Acceptance boundaries

The selected path must run the package's loop rather than call the old loop behind a new name. Runtime snapshots must never contain provider credentials, functions, PIDs, or references. A failed runtime commit must prevent dependent effects. Interrupted mutations must not be replayed automatically.

Tools execute sequentially on the Backplane path. Unsupported MCP schemas fail explicitly without removing constraints. Existing session JSONL remains Sigma-owned; runtime recovery evidence does not itself resume an interrupted turn. Default enablement is user-authorized. Deletion of the legacy engine requires further live-provider/browser and operational evidence. Fallback remains explicit; failed Backplane turns are not automatically replayed.

## Local validation

- Scoped suite: `mix test apps/sigma_agent/test apps/sigma_protocol/test` — 223 agent tests and 13 protocol tests passed, including 25 new Backplane integration/store tests.
- Regression coverage includes real dispatcher file writes, streaming Protocol V1 events, journal persistence and sidecar reopen, approve/deny/cancel correlation, immediate steering and follow-ups, provider-worker crash/cancellation metrics, rich prompt hooks, stop-hook recursion prevention, unsupported-schema rejection, and store startup/ownership lifecycle.
- Store coverage includes upstream conformance, revision races, incarnation fencing, failed writes, corrupt records, private permissions, and nested Sigma struct serialization without process handles.
- Formatting and `git diff --check` passed; `MIX_ENV=test mix compile --warnings-as-errors` passed. Boot selector checks passed for `backplane`, `sigma`, and invalid values.
- Browser, live-provider, distributed/power-loss, and production rollout acceptance remain outside this local gate.
