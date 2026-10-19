# Sigma Protocol V1

Sigma Protocol V1 is the stable command/event boundary for LiveView, direct
Elixir integrations, JSON Lines automation, and remote WebSocket clients. All
adapters call `Sigma.Agent.PublicRuntime`; transports do not own Agent lifecycle
rules. Synapsis / Samgita integration cookbook:
[public-runtime-integration.md](public-runtime-integration.md).

## Envelope

Every JSON envelope contains:

```json
{
  "version": 1,
  "id": "request-or-event-id",
  "sessionId": "session-id",
  "turnId": "optional-turn-id",
  "timestamp": 1788249600000,
  "kind": "command",
  "type": "prompt.submit",
  "payload": {},
  "error": null
}
```

`kind` is `command` or `event`. Unknown versions and types are rejected without
creating atoms. Encoded envelopes are limited to 64 KiB. Payloads never contain
PIDs, references, ports, functions, exception structs, or internal OTP names.

The initial command and event sets are available from
`Sigma.Protocol.Envelope.commands/0` and `events/0`.

## Capabilities and compatibility

Protocol V1 remains envelope version `1`. Session snapshots advertise the
server's closed capability set in `capabilities`:

- `metrics.v1`
- `skills.v1`
- `subagents.v1`
- `subscription.cursor.v1`
- `subscription.resync.v1`

Clients put capabilities they require in `requiredCapabilities` on
`subscription.attach` (and may assert them on `session.status`). The attach
snapshot returns the accepted, de-duplicated list as `enabledCapabilities`.
An unknown or malformed requirement fails with `session.error`; the
`unsupported_capabilities` error includes `missing` and `supported` lists.

`metrics.changed` is capability-gated because older Protocol V1 clients may
implement the event type as a closed enum. A subscription that omits
`metrics.v1` receives the original V1 event set and never receives
`metrics.changed`; metrics facts do not consume its cursor. This is the legacy
compatibility mode. Requesting `metrics.v1` is the explicit opt-in to the
additive event type.

Unknown envelope versions and types are still rejected. Do not send a V2
envelope to this endpoint or infer capability support from envelope version
alone.

## Direct Elixir API

Build a command with `Sigma.Protocol.Envelope.command/4` and pass it to
`Sigma.Agent.PublicRuntime.execute/2`. The trusted context supplies repository
paths and runtime provider configuration; those process-local values are never
serialized.

```elixir
{:ok, command} =
  Sigma.Protocol.Envelope.command(
    "prompt.submit",
    "session-id",
    %{"content" => "Inspect the repository"}
  )

Sigma.Agent.PublicRuntime.execute(command, %{
  repo_path: repo_path,
  sessions_dir: sessions_dir
})
```

Attach a subscriber with `subscription.attach`. Events arrive as
`{:sigma_protocol, subscription_id, envelope}`. A subscriber disconnect removes
only its relay and never cancels the active turn. Intermediate events may be
dropped for a lagging subscriber; ordered terminal events are retained.

The attach response is an atomic snapshot boundary. It contains `cursor: 0`
for a new relay and a matching `watermark`; every subsequently delivered event
contains a strictly increasing `cursor`. A `session.status` command containing
the owned `subscriptionId` returns a fresh snapshot and the relay's current
cursor/watermark. A different subscriber PID cannot query or detach that relay.

If the sink queue overflows or a metrics entity revision skips a value, the
relay sends `session.error` with `error.code == "resync_required"` and
`snapshotRequired: true` before the next deliverable event. The client must stop
applying deltas, fetch `session.status` with its `subscriptionId`, replace its
projection with that snapshot, then continue with events after the returned
watermark. Duplicate identical metrics facts are suppressed.

## Subagents V1

Clients request `subagents.v1` in `requiredCapabilities` on each full snapshot
command (`session.create`, `session.resume`, `session.status`, `session.switch`,
`session.fork`, or `subscription.attach`). Only opted-in snapshots include
`subagents`; only opted-in subscriptions receive `subagents.changed`. Roster
facts consume no cursor for legacy subscriptions.

The snapshot roster is the committed journal projection, with `revision`,
`agents` (safe display rows), and `counts`: `created`, `executing`, `pending`,
`stopped`, and `unknown`. Counts come from that same projection. Rows identify
`agent_id`, `agent_path`, parent/root/child session identities, `run_id`,
`incarnation`, lifecycle `status`, `activity`, `closure`, and the last committed
`event_id`, `revision`, and `observer_incarnation`. Only allowlisted fields and
validated scalar values enter payloads; arbitrary host maps are not serialized.

`subagents.changed` carries `fact`, `data`, `event_id`, `revision`, and
`observer_incarnation` (plus the relay `cursor`). Facts are `registered`,
`run_started`, `run_finished`, `closed`, and `recovered`. Completion and closure
are separate observations; terminal status does not imply closure.

Attachment subscribes before reading the journal, seeds the roster revision
from the attachment snapshot, and suppresses buffered facts already covered by
that revision. Duplicate/old revisions, stale runs, and retired observer
incarnations are suppressed. Revision gaps or an unacknowledged observer change
require resync. A fresh owned `session.status` snapshot resets this roster
watermark. Queue overflow can drop even terminal roster increments and requires
resync; roster events and their error marker respect the sink queue bound.
A single pending retry timer checks for sink capacity until the marker can be
delivered, even when the dropped terminal fact is the last event. Successful
resync snapshots and relay shutdown cancel that retry. A lifecycle delta that
fails final codec validation is withheld and triggers the same bounded resync
notification; committed journal values are not truncated.

PublicRuntime validates the final snapshot envelope after adding runtime and
subscription fields. A roster that exceeds the protocol collection or 64 KiB
encoding limit returns an encodable `session.error` with `payload_too_large`.
Failed attachment snapshots detach their newly created relay. An owned status
snapshot validates the exact response inside the relay before reseeding its
watermark; a rejected response leaves the relay blocked until a valid resync.
Rows and counts
are preserved completely for in-range snapshots; oversized snapshots are not
truncated, and this version provides no roster pagination.

This observation slice does not admit or execute child agents. Production host
integration remains blocked on [gsmlg-opt/backplane#71](https://github.com/gsmlg-opt/backplane/issues/71); the host adapter must
supply acknowledged lifecycle facts and authoritative live ownership before
T3/T5 integration is complete. Journal replay currently marks previously active
rows `unknown_outcome` on owner recovery. It does not infer a running child from
a recovered journal or replay child side effects. Stdio and WebSocket inherit
the PublicRuntime contract; LiveView host wiring remains pending.

## Metrics V1

With `metrics.v1` enabled, durable and live request, turn, tool, compaction, and
operation facts arrive as `metrics.changed`:

```json
{
  "schemaVersion": 1,
  "fact": "request_finished",
  "data": { "request_id": "request-id", "revision": 1 },
  "cursor": 7
}
```

Supported fact names are `request_started`, `request_finished`,
`request_usage`, `turn_started`, `turn_finished`, `tool_finished`,
`compaction`, `operation_started`, and `operation_finished`. Request and turn
identities plus `revision` make corrections replaceable rather than additive.

`session.snapshot.metrics` is the durable projection. It includes own,
active-lineage, and inherited usage, coverage, bounded request/turn summaries,
and compaction state. It does not contain the transient active request.
`runtimeSnapshot.metrics.activeRequest` is the live overlay for an in-flight
request. Request and turn summaries are capped at 10; nested values are bounded
and summary strings are UTF-8-safe at 128 bytes.

Request metrics use a wire allowlist. It covers identity, provider/model,
purpose/status/revision, normalized usage and timing, semantic provenance, and
retry relation. Credentials, authorization headers, raw provider payloads, and
arbitrary adapter metadata are excluded both from journal request facts and
`metrics.changed`. Provenance is reduced to recognized semantic source/counting
values; it is not a container for raw provider data.

## Retry, Resend, and Fork

`session.retry` is a controlled operation, not another `prompt.submit`. It
selects a persisted user message, restores the checkpoint before that turn,
creates a replacement branch and turn, and returns the new `turnId`,
`retryOfTurnId`, `sourceEntryId`, and `checkpointEntryId`. `messageId` is
required. If the original model is no longer selected, the client must provide
an explicit valid `providerId` and `modelId`; unavailable attachment material is
rejected rather than guessed.

Resend has no separate protocol command. A client that intentionally wants to
append the old text to the current active leaf uses `prompt.submit`; it must not
label that behavior Retry.

`session.fork` creates a separate target session at `messageId` (or the whole
selected branch when omitted). The child retains selected-lineage request facts
as inherited usage while child own usage starts at zero. Retry and Fork accept
`operationId`, `expectedSourceRevision`, and `expectedSourceLeaf`. The command
envelope ID is the fallback operation ID, so an identical repeat is idempotent;
reusing it with different arguments is a conflict. Busy or stale-source
operations fail instead of performing the requested branch mutation; durable
operation audit facts may still record the attempt and result.

Retry, Resend, and Fork never roll back files, Git state, tool effects, or
external services. Forked sessions share the selected working directory unless
the host explicitly arranges isolation.

## Journal compatibility and downgrade

Metrics are versioned operational records in the existing v3 JSONL journal.
They are folded independently of conversation messages: they do not enter model
context and do not advance the conversation active leaf. The current reader
keeps unknown non-message entries in branch structure but out of model context;
unknown metrics fact names are ignored without creating atoms or moving the
active leaf. Legacy messages with missing timing or usage remain readable and
surface partial/unknown metrics rather than fabricated zeroes.

This is a reader compatibility guarantee for the current code, not a blanket
promise that every previously released binary can safely write a journal after
a newer binary has touched it. Before binary downgrade, stop writers and back
up the JSONL file. Use a legacy Protocol V1 client without `metrics.v1` when only
wire compatibility is required. Unsupported envelope versions are explicitly
rejected; there is no silent protocol reinterpretation.

## JSON Lines stdio

`Sigma.Agent.Stdio.run/3` reads one encoded command per line and writes encoded
response and subscription event envelopes. EOF disconnects the adapter without
cancelling a running turn. Callers embedding the adapter provide the same trusted
runtime context as the direct API.

## WebSocket

Phoenix exposes Protocol V1 at `/agent/websocket`. Connect with the Base64-URL
repository key as the `repository` parameter and a capability token as `token`,
then join `session:<session-id>`. The server token comes from
`SIGMA_PROTOCOL_TOKEN` (at least 32 bytes); when it is absent the Agent socket is
disabled. Only repositories already registered in Sigma are accepted.

Send channel event `command` with `%{"data" => encoded_envelope}`. Responses and
stream events use channel event `event` with the same shape. Reconnecting clients
can issue `session.status` for the current snapshot and then
`subscription.attach` to resume future event consumption.

Reconnect snapshots retain the latest five bounded messages and report
`messageCount` plus `messagesTruncated`; complete history remains available
through the session dump operation. Protocol dump/export paths are confined to
the registered repository (or a trusted adapter-supplied artifact root), and
replacement requires an explicit trusted adapter capability.

Interactive approval clients attach a subscription before prompting. They
receive `permission.required` and answer with `permission.resolve`. With no
resolver attached, an explicit `ask` policy produces a structured
`approval_required` error; allow-all remains the default.
