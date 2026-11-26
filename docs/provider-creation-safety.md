# Provider creation and interrupted streams

Current execution-policy changes and validation are tracked in
[Codex execution policy alignment](features/codex-execution-policy-alignment.md).

OpenAI Responses and Anthropic Messages create remote work with
POST requests. A timeout, connection reset, HTTP 408 or gateway error does not
prove that this work was never accepted. Retrying that POST can create another
generation, with additional cost and different tool calls.

## Request retries and replacement generations (2026-11-26)

`Sigma.Ai.CreationRequest` classifies request-layer retries for both adapters.
An initial POST can be followed by four retries after transport failures or HTTP
5xx. Delays start at 200 ms, double with jitter, and honor Retry-After delta seconds or HTTP-date.
Redirects, HTTP 408/429 and other 4xx do not gain request-layer retries.
`retry: false` disables automatic request and replacement retries. Each attempted
submission remains potentially billable: no generation idempotency key or remote
cancellation guarantee is claimed. Transport failures retain submission-attempt
metadata; failures waiting for headers can remain `:submission_uncertain` even
when policy allows another submission.

After a request has streamed output, an interrupted connection or missing
response terminal is a typed `:stream_interrupted` failure, with known response
identity and partial output retained. Malformed JSON/SSE, invalid requests,
cancellation, and explicit failed/incomplete terminal outcomes do not acquire
generic reconnect loops. Incomplete length-limited
responses retain their existing terminal behavior. A completed tool-call frame
without a completed response never authorizes execution of that call.

The additive Runtime `provider_retry` policy handles replacement generation,
separately from the four request retries. Sigma root and managed-child sampling
select five ordinary stream retries and unbounded connection retries. Connection
backoff is 5, 10, 20, 40, then 60 seconds, capped at 60 seconds. Timeout and stream
failures use the bounded stream budget. A typed retry classification is required;
exception-message guessing alone cannot enable replacement. Compaction remains
bounded and does not inherit unbounded sampling retries.

Each replacement has a fresh durable attempt identity. The failed attempt's
actual partial output, observed usage, original error and known response ID are
preserved. Runtime settlement, actual worker retirement and the host Writer ACK
must succeed before a cancellable backoff can release another request. Failed
attempt tool calls remain in the raw journal but are excluded from Provider
input; no tool result is fabricated. Previously settled tool calls/results remain
in context and are not re-executed. Display history and Provider context are
separate projections.

Same-ID background GET recovery below takes precedence when explicitly enabled.
Its exhausted/failed replay does not fall through to a replacement POST. Reload,
cold restore and history reads never restart a Provider attempt or a retry timer.
The policy does not settle uncertain historical effects or repair an old session
whose required lifecycle ACKs are missing.

The comparison uses Codex `af71942309704997f4bdc86c020717646423c080`.
The matching retry contract is publicly available in Backplane Runtime 1.10.102,
published on 2026-11-26. Public tarball checksums and documentation availability
have been verified. Sigma now locks that public package under `~> 1.10`; strict
compilation, matching dev-service restart and loaded-module readback passed.
The existing session's historical recovery gate remains unchanged; no new model
request was submitted during restart verification. Qualification, service evidence
and remaining validation limits are tracked in the
[alignment document](features/codex-execution-policy-alignment.md).

## Explicit in-process background recovery

Recovery is disabled by default. Set these **provider options**, only after the
configured endpoint (including any Backplane route) has been verified to support
OpenAI's background streaming GET contract:

```elixir
[
  background: true,
  responses_recovery: %{
    capability: :openai_background_stream_v1,
    max_attempts: 5,
    delay_ms: 250,
    max_elapsed_ms: 120_000
  }
]
```

The capability is an operator assertion about this endpoint, not automatic
capability discovery. Unknown declarations, missing explicit `background: true`,
and use on Anthropic fail before HTTP. Codex OAuth and arbitrary
compatible endpoints must not be opted in without verifying the contract. The
creation response must confirm `background: true` and an ID before recovery is
possible. Default requests do not gain a background field; `store: false` remains
unchanged. No Backplane server configuration or repository is modified here.

`ResponsesRecovery` keeps the ID and last successfully reduced event cursor in
the live provider stream alongside output, Codec and Hosted state. A cursor is
advanced only after that event passes those reducers; Stream.resource emits the
batch before it can request another connection. No reconnect occurs after a
consumer stops/raises. On transport loss, idle timeout, or HTTP EOF without a
terminal event, the adapter retrieves the **same** ID using
`GET /responses/{id}?stream=true&starting_after=N`. It retains the original
endpoint and headers and resets only the transport framer. Unterminated frames
are replayed from the last complete event. Complete invalid JSON/SSE fails.

Keepalive counters never advance the cursor. Events at or below the applied
cursor are discarded before any text, tool or Hosted reducer sees them. Missing
sequence numbers and a changed response ID fail closed. Retry delay doubles up
to five seconds; attempts and elapsed time are bounded per interruption.
The elapsed-time window starts with the first recovery attempt, so healthy
streaming does not consume it. Successfully applied new sequence numbers reset
the interruption budget; duplicate replay and keepalives do not. GET transport failures
can consume another attempt, but HTTP errors (including expired/missing response
or cursor errors) terminate recovery and preserve status and checkpoint details.
No branch of recovery submits a new creation POST. Failed, cancelled, incomplete
and completed response terminal events do not reconnect.

The time bound is an application budget, not a guarantee about upstream replay
retention. Object retention is not an SSE replay guarantee. Background responses
can use `store=false`; upstream data is still temporarily retained. See the
[OpenAI background guide](https://developers.openai.com/api/docs/guides/background)
and [retrieve reference](https://developers.openai.com/api/reference/resources/responses/methods/retrieve).

### Process and side-effect boundaries

This checkpoint is **in memory**, not a durable transaction with the session
Writer. Process/VM loss stops recovery. Importing `response_id` or
`starting_after` into a fresh stream is rejected before HTTP, because the ID and
cursor alone cannot reconstruct output, Codec/Hosted state or tool settlements.
Reopening a session is not permission to reissue its old POST. A separate explicit
new generation remains a new operation and may duplicate upstream work.

Durable restart recovery still needs an atomic session checkpoint containing the
original route/credential reference, response identity, applied cursor, reducer
state/output and tool-execution ledger. This patch neither adds that transaction
nor claims exactly-once external effects. Existing Runtime tool dispatch still
requires a completed response; duplicate streamed tool events are filtered
before that boundary. Hosted history replay remains separate from SSE recovery.

## Explicit upstream cancellation

Opt in separately from replay, only after verifying the actual upstream route:

```elixir
[background: true,
 responses_cancel: %{capability: :openai_background_cancel_v1, timeout_ms: 5_000}]
```

Nothing enables background or storage implicitly. Root Agent Stop/turn.cancel
and cancel_prompt register intent before terminating the runtime worker. The
independent supervised cancellation task uses the original URL and headers to
POST `/responses/{id}/cancel` with no redirects or automatic retries. It survives
the stream worker being killed. Repeated Stop shares one attempt. A confirmed
background ID is required; an ID arriving just after Stop can still be cancelled.
A Stop preceding stream registration prevents that stream's creation.

The cancellation Response must match the ID. `cancelled` is confirmed;
`completed`, `failed` and `incomplete` are already-terminal outcomes, never
rewritten as cancelled. Missing ID/background confirmation, malformed replies,
transport failure and timeout remain unknown; HTTP failures and unsupported
routes are distinct. No cancellation SSE event is required. Unconfirmed results
are not automatically polled or retried. This makes no billing guarantee.

Results are exposed through `Sigma.Ai.ResponsesCancellation.result(ref)` and
`[:sigma, :llm, :upstream_cancel, :stop]` telemetry without credentials. The existing
UI/protocol turn.cancelled event still means **local turn cancellation**; its
payload explicitly says `scope: local`. Independent `provider.cancellation`
events report pending, confirmed, already-terminal, unsupported, failed or unknown
outcomes and preserve the cancelled run ID without changing the active turn.
LiveView presents the same distinctions in an informational flash; asynchronous
results identify the target child rather than claiming the current turn stopped. Cooperative provider errors also carry cancellation
outcomes. Entries survive worker exit for five minutes; process/VM restart loses
them and does not replay cancels or creations. Missing checkpoints are unknown.
Disconnects, recovery, consumer death and ordinary steer never initiate cancel.
Foreground streams only close their transport; this does not guarantee the
upstream stopped generating. Managed-child interruption uses the Runtime's acknowledged live `:interrupted`
event. It runs after local Runtime settlement; the coordinator retains the ID
past worker death. Keys include child session, run ID and incarnation so a queued
followup/new run and siblings are unaffected. Snapshot status, generic settlement,
ordinary steer and cleanup uncertainty do not trigger this hook. If interruption
fails before Runtime emits its acknowledgement, or that event is lost, upstream
cancellation remains unconfirmed; this patch does not guess from terminal status.

Backplane main `a20069cb0567b97a37559baa9230a41f96243870` implements the ordinary
lifecycle route, but requires `responses_lifecycle: true` on the chosen ProviderApi
**at creation time**, native Responses/API-key support, the same authenticated
client identity and `llm::invoke`. Default-disabled routes and Codex OAuth are
unsupported. Sigma's package update alone does not enable a deployed proxy. No
Backplane deployment configuration or live upstream was available to verify;
operator attestation must not be inferred from version or URL. No Backplane
repository changes are necessary for the documented ordinary route.

## Historical dependency update (1.10.55 to 1.10.56)

Five Backplane packages move from 1.10.55 to 1.10.56, with four direct minima
updated and only those five lock entries changed. Their published `lib/` trees
are byte-identical to 1.10.55; package checksums and release dependency metadata
were verified, and all existing nonoptional requirements remain satisfied.
The AI checks compile and run against the actual 1.10.56 AI Protocol package.

The 19 direct Hex packages were checked using their actual package names
(`websock_adapter` resolves to `gaoxy_websock_adapter`). Req stays at stable
0.7.5; 0.8.0-rc.0 is a prerelease. Finch 0.24.0, duskmoon_bundler 10.0.9 and
phoenix_duskmoon 10.0.12 already match their current stable releases. lazy_html
0.1.14 exists but requires a Fine NIF transition from 0.1.x to 0.2.x; it remains
at 0.1.13 pending native/Web validation in a complete build environment.

The normal Hex registry fetch fails in this environment. Updated lock metadata
comes from verified official release tarballs/API metadata, with no network
policy changes. A complete `mix deps.get`/umbrella build is still required in an
environment with working registry access; this is not a claim of full resolver
or deployment validation.

## Verification

The 2026-11-26 regressions in `activity_transport_test.exs` and
`creation_retry_test.exs` use actual local TCP upstreams. They verify keepalive
and partial-frame activity, POST/5xx retry counts, explicit opt-out, 429,
Retry-After and cancellation, partial-output retention and observed usage.
`creation_safety_test.exs` retains no-resubmission assertions under explicit
`retry: false`, framing validation and terminal-response requirements. Public
Runtime and root/child Writer checks are listed in the alignment document.
These are controlled local checks, not online-provider or deployment acceptance.

The following records describe the earlier lifecycle change and its original
validation environment; they are not the current dependency versions or the
new policy's acceptance gate.


`creation_safety_test.exs` uses TCP mock upstreams which read the entire POST,
then drop headers, delay headers, return errors/redirects, or truncate SSE. They
keep accepting connections to count duplicate submissions. Tests also cover
partial text/reasoning, invalid JSON, missing terminal events, failure/cancel
statuses and duplicate terminal frames, including native Codec and Hosted paths.
A completed namespaced custom tool item without a response terminal still fails.
These are local simulations, not live
provider or Backplane integration tests.

`responses_recovery_test.exs` additionally exercises same-ID GET resumption, partial
frames, keepalives, duplicate text/custom events, Hosted continuation, expiry,
missing checkpoints, unsupported adapters, cancellation and worker loss.

`responses_cancellation_test.exs` covers explicit capability, missing ID,
background confirmation, pre-registration cancellation, late ID, duplicate Stop,
terminal races, mismatched replies, HTTP errors/redirects, timeouts and worker
exit. A TCP integration fixture streams a real Responses ID, kills its consuming
worker after explicit Stop, and verifies a separate same-ID cancel POST completes.
Root Agent edits are source-reviewed; full Agent/umbrella runtime testing remains
blocked by the dependency registry failure described above.

The process-local registry and UI flashes are not durable. After coordinator/VM
restart, a cancellation lookup or new explicit Stop without a checkpoint returns
unknown; no old cancel or create request is replayed. A pending request at restart
may have reached the upstream, and its eventual confirmation may be lost. A new
connection must not treat the historical local turn cancellation as evidence of
remote cancellation. Durable recovery would require writing cancellation intent,
original route/credential reference, response ID and confirmed outcome to the
session journal before execution, with a supported same-ID status query after
restart. That transaction is not implemented here.

Managed-child event tests cover exact run/incarnation isolation, sibling/followup
isolation, snapshot/steer/uncertainty exclusion and missing-checkpoint feedback.
Shared UI wording and actual ProtocolEventMapper/Codec tests cover pending,
confirmed, already-terminal, failure/unknown and late child-result correlation.
The full ChildIO/Subagents/LiveView execution tests still require the complete
umbrella dependencies; source-only hook inspection is not end-to-end acceptance.

The dedicated LiveView handler test is
`apps/sigma_web/test/sigma_web/live/upstream_cancel_feedback_test.exs`; its run
stops at Mix dependency checking (Phoenix LiveView and other umbrella dependencies
are missing), so it is authored but not executed in this environment. The isolated
AI + Protocol sources compile with warnings-as-errors; 49 lifecycle/feedback/event
tests and 87 selected existing functional tests pass. These are mock/local checks,
not live provider qualification or a complete application build.
