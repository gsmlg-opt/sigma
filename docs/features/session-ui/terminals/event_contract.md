# Terminal Internal Event Contract

Status: T1 contract for the session-terminal feature

Scope: internal runtime, stream, backend-fixture, and UI integration boundaries

Source of truth: [PRD](prd.md) and [implementation plan](implement_plan.md)

This contract does not extend or change Sigma public Protocol V1. Later work may map
these values onto a private LiveView/runtime transport, but must preserve the identity,
fencing, bounds, and error semantics below.

## Identity and revision

A session identity is the tuple `repository_id`, `session_id`, and
`incarnation_id`. A terminal identity adds an opaque `terminal_id`. A run identity
adds a positive `generation`. Restart preserves the terminal identity and increments
the run generation; recovery and attachment never increment it.

Catalog `revision` is monotonically increasing for shared catalog changes. Any
multi-page snapshot is coherent only at one revision. Consumers must discard partial
pages and resync when the revision changes. Terminal labels are display data and are
never identity.

Input and resize commands carry all of:

- session identity and terminal ID;
- run generation;
- expected catalog revision;
- server-established attachment ID;
- control epoch.

The final backend-dispatch boundary validates that complete fence. Validation rejects
scope/incarnation, terminal, generation, revision, attachment, expired lease, and epoch
mismatches as typed errors. Earlier UI or relay validation is not authority.

## Catalog and lifecycle

The closed lifecycle state set is `starting`, `running`, `stopping`, `exited`,
`failed`, and `cleanup_failed`. A separate resource state is `reserved`, `managed`,
`released`, or `unconfirmed`.

Every catalog entry is retained and counted until close cleanup is confirmed and the
entry is explicitly removed. Consequently exited and failed entries count toward the
badge. A session resource pin and managed-run capacity derive from `reserved`,
`managed`, and `unconfirmed` resource states, not from retained count. Exited or
failed records whose resources are confirmed `released` remain retained without
holding a managed-run slot.

Natural shell exit first enters `stopping` while descendant cleanup is checked.
Confirmed cleanup retains an `exited` record and exit status. Failed or indeterminate
cleanup enters `cleanup_failed`, stays `unconfirmed`, and retains its pin and capacity.
Restart is valid only after confirmed release; it clears prior run stream/control
state and increments generation.

Transitions are closed and disposition-aware. `starting` may become `running`, enter
cleanup after startup failure, or enter cleanup after close. `running` enters cleanup
after shell exit or close. Only `stopping`/`cleanup_failed` records originating in
shell exit or startup failure may become retained `exited`/`failed` records after
confirmed cleanup. Cleanup retry returns `cleanup_failed` to `stopping` without losing
its disposition. A close disposition is removed atomically by the T3 catalog after
confirmed cleanup; this reducer deliberately does not manufacture a retained state.

Catalog snapshots are bounded pages. Each page carries session identity, revision,
total retained count, lifecycle counts, entries, and a continuation cursor. A page is
not an authoritative zero when the catalog is unavailable.

## Creation and mutation identity

`ensure_initial` and `create` are different mutations:

- concurrent `ensure_initial` operations on an empty catalog converge on the first
  retained entry, including while it is `starting`;
- `ensure_initial` returns an existing retained entry and never replaces an exited
  or failed entry;
- distinct `create` operation IDs create distinct terminals, subject to capacity;
- replaying one operation ID with its original kind and payload fingerprint returns
  the recorded result without another mutation;
- reusing an operation ID for another kind or payload is `operation_conflict`.

The runtime boundary allocates an opaque terminal ID independently of the operation
ID and passes it into the pure reducer. The reducer never generates randomness. The
winning allocation ID is recorded with the operation result; later retries replay it
even if their unused candidate differs. Reusing an existing terminal ID is rejected.

Each operation is represented by a server-issued ticket containing its issue time in
the server monotonic-time domain. Reducer calls use an injected current time and reject
a ticket whose issue time is in the future. A ticket older than the configured
deduplication window is `operation_expired`. If its timestamp predates the catalog's
known dedup history, its outcome is `operation_outcome_unknown`; the server must not
guess by executing it. Unexpired records are never silently evicted. A full bounded
history rejects new mutations with `operation_history_full` until expiry makes room.

## Control lease

There is zero or one controller per terminal run. Vacant acquisition and takeover
increment the epoch and establish a bounded lease. Takeover requires the current
expected epoch; concurrent takeovers therefore have one winner. Renewal requires the
same attachment and epoch. Release, collapse, selection change, detach, and expiry
vacate control; a release also increments the epoch so queued old frames are fenced.
Observation, focus, and reconnect do not acquire or renew control.

## Output and replay

An output frame contains exactly one run identity, a positive sequence, and arbitrary
raw bytes. Construction rejects payloads above `max_output_frame_bytes`; frames do not
assume UTF-8 boundaries.

Replay state names the earliest retained sequence, latest sequence, and optional
coherent checkpoint sequence. Given a client's last rendered sequence, the decision
is one of:

- `live(next_sequence)` when already current;
- `replay(sequence_range)` when the complete gap remains retained;
- `snapshot_then_replay(checkpoint, range)` for an old gap or future watermark;
- typed `snapshot_unavailable` when a required coherent checkpoint is absent.

A run-generation mismatch is never replayable. Render acknowledgement means parsed
and rendered, not merely received. T4 owns queueing, checkpoint payloads, and
backpressure, but must use these decisions and configured byte bounds.

## Limits and errors

`Sigma.Agent.Terminals.Limits` contains the PRD defaults and allows small injected
values in tests. It also defines a 64 KiB internal output-frame limit and a 64-entry
catalog page limit; these are transport bounds, not measured capacity claims.

Internal failures use `Sigma.Agent.Terminals.Error` with a closed atom code set,
details, and a retryable flag. External strings are resolved through a fixed lookup;
unknown strings become `unknown` and must never create atoms dynamically. At minimum,
integrators preserve distinct errors for unavailable catalog/backend/platform,
startup, cleanup failure/timeout/uncertainty, capacity, control, stale fences,
operation expiry/conflict/unknown outcome, snapshot unavailability, and frame bounds.

## Deterministic fake backend

`Sigma.Agent.Terminals.FakeBackend` is a pure test state machine. Tests explicitly
advance delayed startup, emit arbitrary bytes, receive resize acknowledgements, choose
confirmed/failed/unconfirmed cleanup, and inject owner death. Its ordered event list
is deterministic and contains no timers, processes, ports, or native cleanup claims.
It is a fixture for T3–T6 contract tests and cannot satisfy T0/T2 native evidence.
