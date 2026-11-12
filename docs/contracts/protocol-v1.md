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
Outgoing payload nesting is bounded at 16 levels, including message and tool
argument containers, so native question options survive the complete envelope.

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
- `questions.v1`
- `async_interactions.v1`
- `async_interactions.pages.v1`
- `async_interactions.uploads.v1`
- `provider_hosted.v1`
- `provider_hosted.pages.v1`
- `plugins.install.v1`

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

### Questions and durable async interactions

`questions.v1` adds `pendingQuestions` to capable snapshots and the
`question.required` / `question.resolved` events. The snapshot contains currently
live generic waiters, not restart-restorable requests. Answer with
`question.resolve` and exactly `requestId`, `action: "answer"`, `answer`; cancel
with exactly `requestId`, `action: "cancel"`. The reply must match the current
session and waiter; text is validated without trimming it. Generic questions
cannot approve permissions: `permission.required` / `permission.resolve` retain
their separate channel.

`async_interactions.v1` adds durable `asyncInteractions` cards and
`asyncInteractionLeafId` to snapshots, plus `async_interactions.updated` events
with complete `items` and `leafId`. Unlike synchronous waiters, these cards remain
available while the agent continues and after a service restart. Questions form
an ordered batch; every question needs a nonblank answer. Notifications permit an
optional text reply or dismissal. Neither capability sends its new events or
snapshot fields to legacy subscriptions.

Send `async_interaction.reply` with this payload:

```json
{
  "requiredCapabilities": ["async_interactions.v1"],
  "itemId": "item-from-the-snapshot",
  "expectedLeafId": "current-asyncInteractionLeafId",
  "reply": {
    "replyId": "stable-client-reply-id",
    "answers": [{"questionIndex": 0, "answer": "exact user text"}]
  }
}
```

A notification reply replaces `answers` with `text`. Dismiss with
`async_interaction.dismiss`, the same capability/item/expected-leaf fields and no
`reply`. Clients cannot provide internal message/turn IDs or correlation metadata.
The command response is `async_interactions.updated` with an `acknowledgement`
containing `itemId` and the current status. A saved or admitted reply is not yet
confirmed consumed. Exact retries reuse the receipt; conflicting text or stale
leaf/session identities are rejected. The host steers active work or starts a
new turn while idle, retaining exact answer text.

Cards expose `open`, `notice`, `saved`, `dispatching`, `admitted`, `consumed`,
`dismissed` or `delivery_unknown` status and authoritative `can_reply`. Optional
`delivery` retains immutable `run_id` and `runtime_message_id` from the host's
public Runtime admission. Confirmed consumption requires both the selected
correlated canonical user and that Runtime checkpoint message with complete
matching content; canonical history or steering admission alone is insufficient.
A missing consumption proof after interruption remains uncertain and is never
automatically redispatched. Cancelled/failed origins close pending questions;
completed questions remain answerable. Selected snapshots suppress off-branch
cards and sibling replies while retaining global deduplication receipts.

The durable inbox has no lifetime card/fact ceiling, and retains global dedup
receipts. Reply validation permits 32 KiB per answer, 96 KiB aggregate answer text,
128 KiB encoded answers, 256 KiB complete reply content and a 384 KiB saved-reply
fact; full original titles and ordered answers are retained. Other facts remain
bounded to 128 KiB. These journal budgets do not enlarge Protocol V1's wire limits.
Complete cards must fit the final 64 KiB envelope, collection limit of 200 and
32 KiB strings in `async_interactions.v1`. They are never individually
truncated. Invalid/oversized payloads produce explicit `async_payload_rejected`
or `async_payload_too_large` errors. After subscription overflow, fetch a valid
capable `session.status` snapshot before expecting more async updates. A failed
snapshot cannot clear the blocked state, and failed attachment cleans its relay.

### Paged async inbox

`async_interactions.pages.v1` is an alternative to `async_interactions.v1`;
requesting both returns `incompatible_protocol_capabilities`. Uploads require the
paged mode as described below. A paged snapshot includes `asyncInteractionInbox` and
omits the legacy `asyncInteractions` / `asyncInteractionLeafId` fields:

```json
{"version":1,"revision":"<64 lowercase SHA256 hex characters>","leafId":"selected leaf or null","itemCount":225}
```

The revision hashes deterministic JSON of the complete selected cards and leaf,
including status, reply, delivery identity, order and `can_reply`. It identifies
the selected view, not all journal facts or a subscription cursor. Equal selected
views have equal revisions across process restarts. A new leaf or any visible
card change invalidates earlier reads; unrelated hidden history need not do so.

Send `async_interactions.list` with `requiredCapabilities` containing the paged
capability, required `expectedRevision`, optional `offset` (default 0) and `limit`
(default 20, range 1–50). `async_interactions.page` returns `inbox`, `offset`,
`nextOffset` (null at the end) and `items`. Each summary contains only `itemId`,
`sequence`, `kind` (`questions` or `message`), `status`, `canReply`, `byteLength`
and `sha256`. It is a directory descriptor, not a truncated card. Pages may
contain fewer than the requested limit to fit the actual encoded envelope.

Send `async_interaction.read` with the same capability and `expectedRevision`,
required `itemId` and optional `byteOffset` (default 0). Its
`async_interaction.chunk` response contains `inbox`, `itemId`,
`encoding: "base64-json"`, `sha256`, `byteLength`, `byteOffset`, `nextByteOffset`
and `data`. Each chunk holds at most 12,288 raw bytes. Concatenate decoded bytes,
verify the complete length/SHA256, then decode JSON; chunks may split UTF-8.
Object keys sort recursively, while array/card order remains unchanged. Offsets
equal to the total size return an empty terminal page/chunk; greater offsets
are invalid. Only the documented fields and ordinary `repoPath` / `sessionsDir`
routing fields are accepted. Stale views return `async_inbox_stale`; fetch a
fresh snapshot and restart the read. Unknown items return `async_item_not_found`.

Live notifications use `async_interactions.changed` with an `inbox` descriptor.
They are invalidation hints: a queued earlier event may arrive after a newer
queried snapshot, so never replace a newer projection solely from a notification.
List/read commands always check the current view. Reply/dismiss retain the
existing exact item, expected-leaf and durable deduplication contract; paged
responses use `async_interactions.changed` with descriptor and acknowledgement.
If the mutation succeeded but a later snapshot read, validation or encoding
fails, `session.error` retains its `acknowledgement` and `snapshotRequired: true`;
the error message explicitly confirms acceptance. This also applies to legacy
async replies. A refresh failure does not mean the accepted operation was undone.

Resync snapshots bind to the subscriber, attached Agent/session and async mode.
A failed or mismatched snapshot cannot unblock dropped async delivery. The final
64 KiB envelope, collection/string/depth limits remain unchanged.

### Chunked async replies

`async_interactions.uploads.v1` requires `async_interactions.pages.v1`; requesting
uploads alone or with the legacy inbox mode returns
`incompatible_protocol_capabilities`. It adds three commands without enlarging
the existing V1 wire or durable reply limits:

- `async_interaction.reply_chunk`: required `uploadId`, `itemId`,
  `expectedLeafId` (string or null), `sha256` (64 lowercase hex characters),
  `byteLength` (1–262,144), `byteOffset` and canonical base64 `data`.
- `async_interaction.reply_commit`: the same identity, length, hash and current
  leaf fields, without `byteOffset` / `data`.
- `async_interaction.reply_cancel`: required `uploadId` only; this discards staged
  bytes, so it also works after the card closes or the branch changes.

Each command requires both capabilities and permits only its documented fields
plus ordinary `repoPath` / `sessionsDir` routing fields. Upload UTF-8 JSON bytes
for the complete existing `reply` object, including `replyId` and ordered original
answers or notice `text`; each chunk contains 1–12,288 raw bytes. Chunks may split
UTF-8 sequences. Start at byte offset zero and append contiguously. An exact
already-contained byte segment is retry-safe; gaps, partial overlaps, different
bytes or changed item/length/hash reject without changing the buffer. The final
chunk must match the exact complete length and SHA256.

`async_interaction.uploaded` reports `uploadId`, `itemId`, `byteLength`,
`receivedBytes`, `nextByteOffset` and `status` (`receiving` / `complete`). A complete
upload has a null next offset. Cancellation returns only `uploadId` and
`status: "cancelled"`, and is idempotent. These are temporary progress reports,
not durable reply acknowledgements. Neither receiving nor cancelling bytes
reconciles the inbox, writes journal facts or dispatches a Provider request.

One Agent holds at most eight uploads, each expiring five minutes after its first
accepted chunk according to trusted monotonic host time. Retries, later chunks
and commits never renew that deadline. Expired entries are pruned on upload
operations. Agent shutdown/restart loses staged bytes; reupload from zero.
Staged bytes are not persisted or resumed as effects.

Every chunk and commit checks the actual selected Writer leaf, session and visible
card. Dismissed cards and unknown deliveries without a saved reply reject.
`expectedLeafId` is checked anew rather than bound forever to the upload, allowing
an exact commit retry with the current leaf after conversation progress. Commit
decodes complete JSON, applies the existing full reply validation and only then
enters the existing durable save/admission path. Invalid JSON, wrong answer count,
extra fields or an inexact saved reply cannot admit effects. Complete buffers
remain available within the original limits for deduplicated commit retries.

Commit responses use the paged acknowledgement contract above. If dispatch began
but saving `admitted` fails, `session.error` retains the durable `dispatching`
acknowledgement, the actual failure code and `snapshotRequired: true`; it does not
claim confirmed admission or consumption. The same rule applies to ordinary
async replies. Refresh the selected inbox before retrying an uncertain operation.

### Provider-hosted observations and results

`provider_hosted.v1` exposes the complete validated
`message.metadata.openai_responses_hosted` envelope in live messages and selected
snapshot message summaries. Only this metadata key is exposed; unrelated host
metadata stays private. The envelope retains its `version`, `origin`,
`response_id` and ordered native `items`, including search actions and URL
citations with their original offsets. Generic message-summary text limits still
apply to `content`; consumers requiring full native output read the envelope.

During execution, `provider.hosted` carries
`{"capability":"web_search","event":<unaltered native provider frame>}` with
the normal session/turn IDs and subscription cursor. These are observations,
separate from local `tool.started` / `tool.completed` events. Legacy clients
receive neither the new event nor metadata. Reload/reattachment restores durable
terminal metadata without replaying transient progress observations.

Native provider data can be larger than Protocol V1. Existing Codec limits remain:
64 KiB per final envelope, 16 nesting levels, 200 entries per collection and
32 KiB per string. In `provider_hosted.v1`, complete hosted data either fits or fails with
`provider_hosted_payload_too_large` / `provider_hosted_payload_rejected`; the host
never truncates metadata, frames or citations, or drops their containing message
to make a capable snapshot fit. Validation includes final attachment fields and
live-event cursors. A failed attachment removes its relay; a failed status query
on an existing subscription preserves it. Attachment builds and validates the
final response inside relay activation, before marking it ready or delivering
queued observations. A rejected snapshot cannot briefly publish live events.

### Durable hosted result pages

`provider_hosted.pages.v1` is an alternative to `provider_hosted.v1`; requesting
both fails with `incompatible_protocol_capabilities`. The chosen mode is fixed
to an attached relay. Status with that subscription must retain its mode or
fails with `subscription_mode_mismatch`, without changing the relay.

Snapshots include `providerHostedResults` with `version: 1`, `revision`, `leafId`
and `resultCount`. Messages retain bounded display content and mark validated
native metadata with `providerHosted: true`; the complete metadata is fetched
separately. The directory covers all selected raw journal message ancestors,
including sources before compaction/context resets and outside the last-five
display summaries. It never includes a sibling branch's sources. A single
serialized Writer capture supplies both the snapshot and its directory. Stopped
sessions use the persisted latest branch without starting an Agent; a live Agent
whose Writer is missing fails with `session_unavailable`.

- `provider_hosted.list` requires `expectedRevision`, with optional `offset`
  (default 0) and `limit` (default 20, range 1–50). `provider_hosted.page` returns
  `results` (the descriptor), `offset`, `nextOffset` and `items`. Each item has
  `entryId`, `messageId`, `byteLength` and `sha256`. The server may return a
  smaller page to fit the actual final envelope; `nextOffset: null` ends listing.
- `provider_hosted.read` requires `expectedRevision`, `entryId`, `messageId`,
  with optional `byteOffset` (default 0). `provider_hosted.chunk` returns the same
  descriptor and source identity, `encoding: "base64-json"`, `sha256`,
  `byteLength`, `byteOffset`, `nextByteOffset` and `data`. Each chunk contains at
  most 12,288 raw bytes. Reassembled JSON is the complete validated native
  `openai_responses_hosted` envelope: origin, response ID, ordered output,
  reasoning/encrypted content and citations. Object keys are recursively sorted
  before encoding; array order and original values are preserved. Verify the
  total byte length and SHA-256 before decoding. A terminal offset equal to the
  byte length returns empty data and `nextByteOffset: null`.

Both commands require `requiredCapabilities: ["provider_hosted.pages.v1"]`
(other compatible capabilities are permitted). Unknown fields, malformed IDs,
negative/noninteger or excessive offsets and invalid limits are rejected.
Revisions cover trusted repository/runtime session identity, selected leaf and
every ordered source identity/hash/length. Stale revisions return
`provider_hosted_results_stale`; fetch a new snapshot before resuming. Missing or
mismatched source pairs return `provider_hosted_result_not_found`. Full native
validation uses the complete persisted message, never its display projection;
invalid origin/content/bounds fail explicitly without a partial directory.

After a successfully persisted hosted `message.completed`,
`provider_hosted.changed` carries `snapshotRequired: true` and the usual
session/turn/cursor fields. This is an invalidation hint, not a directory or a
fetchable live source. Refresh the snapshot to discover current sources. This
mode sends no `provider.hosted` raw progress observations and cannot recover
transient frames from final metadata. Reattachment/restart restores durable
results only. Listing/reading does not write journals, reconcile interactions,
invoke tools or call Providers, including when the session is stopped. Original
Protocol V1 bounds and legacy `provider_hosted.v1` semantics remain unchanged.

### Explicit plugin installation

`plugins.install.v1` adds `plugins.requests` and `plugins.install`, with direct
responses `plugins.requests.page` and `plugins.installed`. Include
`requiredCapabilities: ["plugins.install.v1"]` on each command. Both require a
running session and resolve its actual `native_plugins` configuration outside
the Agent callback. An explicit disabled host returns an unconfigured empty page;
it does not fall back to global settings.

`plugins.requests` accepts optional `offset` (default 0), `limit` (default 20,
1–50) and `expectedRevision`. A nonzero offset requires the revision from the
previous page. The application writer reads both request and installation ledgers
together. These are global requests for that configured host, including child
requests, rather than a selected transcript branch. The response contains
`configured`, `registryUrl`, `revision`, `total`, `offset`, `nextOffset` and `items`.
Items expose `requestId`, `pluginId`, `registryUrl`, `requestStatus`, `status` and
`requestedAt`, plus available release/digest/installation timestamps. Exact request
arguments and invocation identity remain in the native history and durable store.
Rows sort newest first; any request or installation change invalidates the revision
with `plugin_requests_stale`. Fetch offset zero again to resync. Pages shrink by
whole rows to fit V1; an individual oversized summary returns `payload_too_large`.

`plugins.install` requires only `requestId` in addition to the common capability
and routing fields. It explicitly installs that immutable durable request through
the existing public PluginProtocol host. `plugins.installed` wraps the saved public
receipt as `installation`; it never refreshes the list or starts plugin MCP.
Exact installed retries return that receipt without repeating HTTP or publication.
If the complete receipt exceeds V1, the response still confirms the actual saved
`requestId` and `status: "installed"`, with `receiptOmitted: true` and
`receiptError: "payload_too_large"`. A committed install is not converted into a
failure because its later projection is too large. Backplane operation errors keep
their class and message. Failed/unconfirmed installation states retain their
existing host recovery semantics; no uncertain effect is automatically retried.

Native `request_plugin_install` remains `requested` in history. Installation
receipts are separate, and installed skills become visible at the next native
binding. Automatic plugin MCP ownership and native completion results remain
separate alignment work. See [the tools contract](codex-tools.md#plugin-catalogs-and-durable-requests).

## Strict turn admission and cancellation

These optional payload fields make a busy or mismatched turn an explicit
rejection instead of queueing or cancelling another turn (mirroring Codex
app-server `TurnSteerParams.expectedTurnId` / `TurnInterruptParams.turnId`).
Omitting them keeps the default behaviour.

- `prompt.submit` `"admission": "reject_if_busy"`: when a turn is running the
  prompt is rejected with `{:prompt_rejected, :turn_active}` and nothing is
  queued. Any other `admission` value fails with `invalid_admission`.
- `prompt.steer` `"expectedTurnId"`: with no running turn, or a running turn under
  a different id, the prompt is rejected with `{:prompt_rejected, :turn_mismatch}`;
  no turn starts and nothing is queued.
- `turn.cancel` `"expectedTurnId"`: when a turn is running under a different id the
  command fails with `turn_mismatch` and the turn keeps running. Otherwise the
  results are unchanged (`cancelling`, `already_cancelling`, `already_cancelled`,
  `no_active_turn`); a strict cancel never closes detached child executions.

`expectedTurnId` must be a non-empty string (`invalid_expected_turn_id`). Prompt
rejections surface as `session.error` with code `prompt_rejected`. The Elixir API
accepts the same options: `Sigma.Agent.prompt/3` and `steer/3` take
`admission: :reject_if_busy` and `expected_turn_id:`, and `Sigma.Agent.cancel/2`
takes `expected_turn_id:`.

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
`messageCount` plus `messagesTruncated`. Ordinary message/tool events also carry
bounded text projections: a JSON-shaped tool result can be a prefix rather than
independently parseable JSON. Treat those event fields as display previews.
Complete canonical history remains available through `session.dump`: its ACK
identifies a host artifact file, rather than streaming the entire dump in the
event envelope. Protocol dump/export paths are confined to
the registered repository (or a trusted adapter-supplied artifact root), and
replacement requires an explicit trusted adapter capability.

Interactive approval clients attach a subscription before prompting. They
receive `permission.required` and answer with `permission.resolve`. With no
resolver attached, an explicit `ask` policy produces a structured
`approval_required` error; allow-all remains the default.
