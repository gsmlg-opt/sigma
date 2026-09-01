# ADR 0001: Session journal and operations V2

- Status: Accepted
- Date: 2026-09-01
- Scope: `sigma_session`, `sigma_agent`, and session-facing LiveViews

## Context

Sigma previously combined append-only JSONL messages with behavioral sidecar
state and route-driven session switching. That left no single boundary able to
reject unsafe transitions, flush acknowledged writes, validate a target, or
publish forks and relocations transactionally.

## Decision

`sigma_session` owns journal validation, replay, stable-length dump/export,
bounded summary reads, and atomic session file operations. A serialized
`Sigma.Session.Writer` remains the only append commit boundary for each running
session.

`Sigma.Agent.RepositoryProcess` owns lifecycle operations for running sessions.
It serializes switch, fork, rename, delete, and adoption requests. An Agent
mailbox operation lock atomically excludes prompt admission, rejects active turn
phases with `session_busy`, and flushes the writer before an idle operation.
Successful rename/delete terminates the old session subtree so no Writer can
retain a stale persistence target. Errors are tagged domain values; runtime
boundaries do not expose file contents or process terms.

Sigma keeps one supervised subtree per session. Therefore an OTP-native switch
validates the target snapshot and authorizes client navigation instead of
rebinding a mutable Agent process to another journal. The source subtree remains
usable and may hibernate independently. This differs from runtimes that keep one
mutable session object, while preserving the required flush, rejection, target
validation, and rollback contracts.

Dump and Markdown export capture the source byte length before reading and
publish through a same-directory temporary file. Session summaries read at most
64 KiB from the prefix and tail of each journal and return partial fields rather
than escalating to full replay. Explicit adoption preserves conversation bytes,
updates structural `cwd` metadata, and rolls target publication back if source
cleanup fails.

Existing V3 journals, legacy double-header forks, and behavioral sidecar
fallbacks remain readable without eager rewriting. New forks contain one fresh
header and only the selected branch.

## Consequences

- LiveView and future headless clients share one lifecycle command boundary.
- Busy operations are visible and non-mutating.
- Read-only artifacts cannot accidentally include appends accepted after the
  operation began.
- Repository session lists remain bounded even for large transcripts and keep
  orphaned sessions visible for explicit recovery.
- Cross-session switching retains separate OTP ownership rather than coupling
  two persistence targets to one process.
