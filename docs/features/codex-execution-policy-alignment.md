# Codex execution policy alignment

This work follows the policy review of Sigma `54a1061` and
`backplane_agent_runtime` 1.10.101 against Codex
`af71942309704997f4bdc86c020717646423c080` (2026-11-26).
It covers continued execution, command lifetime and output, tool waits,
compaction, transport recovery and independent tool dispatch.

## Behavior

| Area | Required behavior |
| --- | --- |
| Provider lifetime | No total Provider deadline is selected. The renewable idle allowance defaults to 300 seconds and follows an explicit `receive_timeout`. |
| Commands | Standard interactive commands survive polling and large output; finite output buffers retain the beginning and end. Explicit bounded command callers retain their contracts. |
| Tool waits | Runtime execution allowance accommodates the tool's validated wait duration, including the one-hour `wait_agent` maximum. |
| Compaction | Root and managed children compact before requests and tool continuations. Retention and summary size follow available token capacity rather than message-count or 1024-token caps. |
| Recovery | Recovery time starts when an interruption occurs. Same-response cursor replay remains separate from starting another generation. |
| Retries | Four request retries for transport/5xx, five ordinary replacement stream retries, and unbounded sampling connection retries. Same-response recovery keeps its independent five-attempt default and never falls through to a new POST. |
| Dispatch | Independent tools can overlap according to their pinned concurrency contract; exclusive tools retain ordering and complete results are journaled before the next Provider request. |

The existing unlimited work/run defaults and explicit Goal token budgets remain
separate from these policies.

## Provider and tool timing

`Sigma.Agent.Backplane.ExecutionPolicy` supplies identical Provider timing to
root and managed-child Conversations. Runtime renews its idle timer on accepted
normalized Provider events. This is independent of the generic tool effect
allowance and the unlimited run/work policies. Anthropic and Responses HTTP
receive timeouts default to the same 300 seconds.

Root and child hooks select the timeout for admitted native `wait_agent`,
`clock::sleep`, `write_stdin` and Code Mode `wait` calls from their validated
duration, with five seconds for settlement. `wait_agent` retains its public
one-hour maximum; polling is not a total command lifetime. Other tools keep
their existing Runtime effect allowance. Explicitly configured shorter receive
timeouts remain effective.

Successful nonempty HTTP body chunks that produce no semantic event now emit
`response_activity`, including SSE comments and incomplete frames. They renew
Runtime idle without claiming output, usage or time to first token. Root and
child compaction pass an explicit transient activity callback from the active
Runtime worker to the actual summarizer; real Provider progress renews idle.
There is no periodic synthetic heartbeat. A silent summarizer still expires,
and a rejected activity acknowledgement cannot produce a successful summary.

## Interactive commands

The upstream change is tracked by
[backplane#190](https://github.com/gsmlg-opt/backplane/issues/190).
Sigma selects the additive public command options:

```elixir
Command.new(%{
  adapter: PlainCommand,
  server: command_server,
  allowed_environment: %{},
  deadline_limit: :infinity,
  output_policy: :truncate
})
```

The command survives yields, polling and cumulative output beyond the buffer
budget. `Command.OutputBuffer` retains the beginning and recent tail within the
existing 1 MiB byte budget, exposes monotonic cursors and reports omitted bytes.
Polling leaves its cursor before incomplete UTF-8 so the following frame can
complete the character. Model-facing token truncation also retains head/tail.
Actual exit, explicit cancellation and host retirement still settle the process.
Other Backplane callers retain finite deadlines and termination on output
overflow unless they explicitly select the new options.

Both LocalCommand and Sigma PTY adapters use this contract. Linux's native
command helper accepts output cap zero only for the explicit truncation mode;
it must be rebuilt with `mix backplane.pty.build` after adoption. An older
helper refuses that mode. macOS uses the existing session helper.

### JSON numeric command arguments

JSON Schema accepts an integer-valued number such as `412.0` for a command
handle. Backplane's integer-only handle guard previously sent that value into
the opaque-job compatibility path, which returned `session_id is required`
before writing or polling. Because the raw error came from a mutating tool,
Runtime treated it as uncertain and stopped the run. The generic message
`worker stopped; external effects require host reconciliation` did not prove
that a worker had crashed.

[backplane#194](https://github.com/gsmlg-opt/backplane/issues/194) owns command
argument normalization and genuine rejection before dispatch, published in
Runtime 1.10.104. Sigma's root and
child timeout selector also accepts integer-valued floating-point wait durations,
so `yield_time_ms: 60000.0` receives the same 65-second effect allowance as
`60000`. Fractional durations are not truncated by the selector. Canonical
arguments retain their original numeric representation.

The 2026-11-27 09:18 failure in `session_ZRx8Ss-v_ol1fNT3` followed this path
with handle `412.0`. A disposable public Store read preserved all six earlier
command results and the last uncertain `write_stdin` intent without a result.
The earlier 08:36 failure separately recorded `provider lifecycle commit failed`
with cause `enospc`. Neither observation authorizes rewriting the old outcome,
inventing a tool result, or replaying a command. Original transcript and Runtime
file hashes remained unchanged during inspection.

The ENOSPC record was complete ETF inside a valid Zstandard frame. A cold BEAM
rejected its previously unseen `enospc` cause before validating the snapshot.
Store now loads the fixed OTP `erl_posix_msg` module alongside its deployed
application schema, so persisted filesystem failure causes are readable without
deriving atoms from stored data. A separate-BEAM regression preserves the exact
failed snapshot and record bytes; the ordinary completed-Conversation cold-read
regression also passes. Continuation still requires the existing lifetime and
settlement acknowledgements; readable history alone does not supply them.

With the published Runtime 1.10.104 locked, all four actual root/child command
checks, seven execution-policy checks and the two selected cold-read checks
pass. The new command regression rejects fractional input, resumes the retained
command using an integral float, completes the same turn and preserves the
original floating-point arguments in JSONL. Upstream's five command tests also
verify genuine rejection settlement and unchanged post-dispatch uncertainty.
These controlled checks do not submit another model request in the user's
session or establish the outcome of its unfinished historical tool call.

### Commit acknowledgement timeout during a long continuation

The next explicit continuation of `session_ZRx8Ss-v_ol1fNT3` started at
09:53:19 on 2026-11-27 and failed at 10:19:14 with
`timeout: commit acknowledgement timed out`. The last command had already
persisted exit status zero and confirmed cleanup. A read of an independent
Store copy retained all 51 tool results, with no unsettled intents, active
Provider or tool, or pending outbox effects. The earlier numeric-handle and
ENOSPC failures did not recur in this run.

The private Store embedded every complete command input in the current
snapshot file. Conversation checkpoints and completion inputs contain full
conversation history, so rereading and recompressing the accumulated journal
grew quadratically. The latest 921,389-byte compressed record expanded to
995,192,193 bytes. A deterministic checkpoint fixture grew from 1,254,920 raw
bytes at 32 checkpoints to 4,666,456 at 64. The default five-second commit ACK
timer includes Store queueing, decoding, validation and publication; expiring
the caller does not cancel a Store write already in progress.

Sigma now persists a constant-size journal head in the ordinary snapshot and
stores exact command entries in immutable linked blocks. Each block is synced
before the snapshot's atomic rename selects it. Ordinary loads and commits
never walk historical blocks. Explicit public journal reads reconstruct and
validate the complete chain. See the private Store format entry in the
[architecture notes](../agents/architecture-notes.md) for legacy compatibility,
publication failures and the remaining full-export cost.

After the timeout, synchronous Agent reconciliation repeatedly decoded old
ancestry records, delaying status calls. A late status observation could also
replace an already observed terminal phase with the same turn's still-active
worker phase. SessionLive now preserves failed, cancelled and completed phases
for that turn until an explicit turn start or a different turn identity.
Historical timeout and uncertain tool facts remain intact; this repair does
not replay a Provider request or tool.

Cold reopening also exposed a missing host recovery branch. The acknowledged
`provider_completed` transition had consumed the last Provider intent and
cleared the active Provider, while leaving the run `running` between requests.
RunRecovery previously accepted only a run with an active Provider identity.
The affected run instead had 85 consumed intents, 51 settled tool results and
no pending work. All 34 original Providers and the native host, async hooks and
SessionEnd had actual retirement confirmations after orderly shutdown.

Recovery now accepts that empty boundary in `running` or `cancelling`, while
still requiring original run/incarnation identities, no effects/outbox/wait or
unfinished work, and every original Provider and host retirement confirmation.
The existing public Store fence, cancel and confirmed cleanup transitions end
the old run as `cancelled`; they preserve its context, settled results, original
Provider attempts, consumed intents and transcript. A fresh prompt starts a new
run. Missing retirement facts and historical uncertain effects remain blocked.
This is a Sigma guard correction using the published Runtime APIs; no upstream
package change or synthetic acknowledgement is needed.

## Context compaction

`Sigma.Agent.Compaction` shares the existing tool-boundary split and Provider
summarizer between roots and managed children. It keeps complete call/result
groups, sizes retention from the available token capacity (up to 20,000 tokens),
and sizes summary output from the model limit and context window. The previous
20-message retention and 1024-token summary ceilings are removed.

Managed children prepare context before every Provider call, including tool
continuations, using the actual pinned tool catalog and selected Writer branch.
Summarization runs in the Provider worker so ChildIO can process cancellation.
Writer acknowledgement precedes use of a compacted projection. Canonical
journal entries and settled Runtime facts remain the original facts. Failed or
cancelled summaries do not commit a replacement projection or replay tools.

## Transport recovery

Negotiated Responses recovery retains the original response ID and accepted
sequence cursor. Its default 120-second recovery window starts at the first
interruption, rather than response creation. New accepted sequence progress
resets the attempt/window budget; duplicate replay and keepalives do not.
The default is five attempts per interruption, with explicit settings preserved.
The initial creation request plus four retries cover transport failures and HTTP
5xx, with 200 ms exponential backoff, jitter and Retry-After (delta seconds or HTTP-date). They are
potentially distinct billable submissions, not idempotent replay. HTTP 429 is not
retried at that layer. `retry: false` disables automatic request and replacement
retries.

The additive Runtime retry contract is tracked in
[backplane#191](https://github.com/gsmlg-opt/backplane/issues/191).
Runtime's explicit `provider_retry` option admits five replacement stream retries
and unbounded connection retries for root and managed-child sampling. Connection
backoff is 5/10/20/40/60 seconds, then remains at 60 seconds. Compaction keeps a
bounded budget. Original failed output, known response identity, error and
observed usage survive each attempt; unavailable usage remains unknown. The
Provider bridge retains progress even when an adapter later raises.

A failed response never dispatches its tool frames. Its original partial message
is retained for display, while replacement Provider context includes only valid
text/thinking from that failed response. Previously settled tools remain factual
history. Runtime Store settlement, actual worker retirement and host Writer ACK
must precede a fresh attempt. Backoff is cancellable and keyed to the failed
attempt/turn; stale timers and cold restores cannot create requests. Missing
ACKs, terminal provider outcomes and unclassified failures stop automatic retry.
Negotiated same-ID recovery remains first choice and never falls through to a
replacement POST. See [provider creation safety](../provider-creation-safety.md).

### Visible retry feedback

Runtime `provider_retry_scheduled` events now reach the root Agent's live status
and LiveView subscribers. The session shows the bounded failure reason, retry
number and configured delay, with a `Retrying model request…` status. The delay
is the scheduled backoff, not a countdown or a total request deadline. The turn
remains active while waiting and while its replacement request runs; an empty
assistant start does not hide the previous error. Current-turn output, a new
turn or a terminal outcome clears the retry banner. Stale turn events cannot
replace or clear current feedback. Final failures retain the existing error
flash and persisted turn details. Reconnecting to a live Agent reads its retry
status without scheduling another request. Retries inside an individual HTTP
submission remain part of that Provider call rather than separate UI counters.

### Invalid Anthropic tool output

Backplane AI protocol 1.10.102 classifies invalid or non-object JSON at an
Anthropic tool block's completion as a retryable provider observation with code
`invalid_tool_arguments` ([backplane#192](https://github.com/gsmlg-opt/backplane/issues/192)).
Sigma accepts only that typed contract as a stream replacement retry. The same
message without the matching kind, stage, code and retry hint remains terminal;
unrelated malformed streams retain their existing behavior. The existing five
replacement retry limit and `retry: false` apply. Partial commands are never
repaired or dispatched, and failed output remains in display history while its
unfinished tool calls are omitted from replacement Provider context.

The later explicit 20:26 submission in `session_ZRx8Ss-v_ol1fNT3` completed 43
Provider requests and saved 79 tool results before its 44th request failed.
The final tool arguments were 79 bytes of an unterminated JSON string ending at
a shell pipe. That call never reached execution. Its previously terminal error
explains why the task stopped despite having no work-count or wall-time cap.
The original failed turn remains historical; upgrading does not submit or replay
it. A controlled native-command regression verifies a settled command executes
once, replacement sampling succeeds, the original journal prefix and tool result
remain exact, and the incomplete call receives no fabricated result.

With the published 1.10.102 package locked, six selected AI checks and all ten
root/child retry checks pass. The controlled HTTP test feeds a real truncated
Anthropic SSE tool block and verifies preserved partial output, typed retry
metadata and absence of tool completion. The deployment snapshot also passes
forced warnings-as-errors compilation of all 269 umbrella source files; the
upstream package passes its 12 Anthropic projection cases. These controlled
checks do not establish that the external model gateway will return valid JSON
on its next request.

### Cold reload of failed tool calls

The original failed turn also exposed a separate host decoder defect: selected
plan loading decoded every journal message as completed content, rejecting a
failed tool block with `partial_json` and no `arguments`. The decoder now retains
that exact fragment only for assistant error messages carrying `provider_failure`
metadata. Tool identity and a binary partial fragment remain required. Other
messages keep their existing complete-argument validation, and no input is
invented. Plan projection can therefore read earlier confirmed publications
through the failed entry. Provider context retains its existing pairing and
failed-message projection; unfinished calls cannot become executable history.

The 29 decoder cases and 18 selected retry/plan cases pass. Cold session coverage
retires the original host through its public API, starts a fresh repository
process, reads the saved failure and selected plan projection, and verifies no
Provider sampling or journal byte changes. A disposable copy of the actual
session also decodes the original 79-byte fragment without inventing arguments.

If Runtime attachment still fails or its loader exits, the page reads the saved
transcript, title, model and metrics without creating another Runtime. It shows
Failed and a persistent error, with submission disabled. It no longer presents
a readable session as Loading indefinitely. Three selected LiveView checks cover
both failure return forms, unchanged journal bytes and absent Agent/Writer
creation, plus existing missing-model replacement and busy-startup behavior.

### Missing configured models

A session whose historical provider/model pair is no longer configured still
loads its saved transcript, metrics and configured model choices. The composer
requires an explicit selection before submitting. Neither the global default
nor a matching model ID under another provider replaces the historical pair
automatically. A cold view starts no placeholder Provider host; an existing
live Agent can still be observed. Selecting a replacement starts or updates the
normal session through the existing serialized model-change path, preserving
the old journal prefix and synchronizing other open views. Loading the view and
selecting the replacement do not submit a Provider request. Restoring the old
pair in configuration refreshes the choices but leaves a detached view awaiting
explicit selection. The focused LiveView regression covers a model moved to
another provider, restoration of the old pair, two open views, the selection
revision and unchanged historical content.

The selected local checks passed: 10 Agent checks and nine LiveView checks.
The removed-model case was then extended with configuration restoration and
rerun successfully. This is 19 distinct checks; the rerun is not an additional
case. Provider calls in these regressions use controlled fixtures, so this does
not establish recovery of the external model gateway.

The deployed dev snapshot passed strict compilation of all 269 umbrella files.
At that acceptance boundary, Chrome verified that `session_ZRx8Ss-v_ol1fNT3` loads its two historical messages,
accepts the explicit selection `prov_35/MiniMax-M3.1-Flash`, and remains Ready
with `canSubmit: true` after reload, without console errors. Its journal prefix
is unchanged; the sole appended entry is the model change, with no new Provider
requests or tool results. Disabled context fields omitted during LiveView form
recovery are ignored; the extended regression and actual server reconnect both
pass. The running BEAM modules match the compiled snapshot and retain Runtime
1.10.102, the existing agent directory, and disabled code reloading/watchers.

## Parallel dispatch

Runtime overlaps consecutive calls whose pinned descriptors explicitly declare
`parallel_safe`. Unsafe and unknown tools, `tool_search`, `exec` and `wait` form
FIFO barriers. Direct calls retain the Provider's tool call ID, independent
invocation IDs and their own enclosing identity; they are not rewritten into a
synthetic Code Mode call.

The scheduler shares existing owned workers and timers with Code Mode, while
serializing admission, Store commits and Goal acknowledgements. Factual results
can settle in completion order. Canonical tool messages retain the original
response order, and the next Provider/catalog boundary waits for the whole
batch. Cancellation joins active siblings; a failed commit cannot release new
work. The batch projection is ephemeral, so cold restore preserves original
active/settled facts and requires recovery without executing the batch again.

## Validation and adoption

The changes were developed against Sigma `54a1061` and Runtime `1.10.101`.
Upstream Runtime source changes live in the sibling Backplane repository.
Sigma's shipped dependency must be an actual published package; temporary
artifact consumers used for qualification do not change its dependency policy.

Completed local checks:

- 21 Runtime scheduling checks: 11 direct-batch, eight existing Code Mode
  parallel and two backend-context cases, including reversed completion,
  independent deadlines, Store/Goal ACKs, catalog publication, cancellation and
  cold restore.
- Six interactive-command checks, including actual macOS LocalCommand,
  retained stdin/polling after output overflow, UTF-8 and explicit cancellation;
  plus the separate actual Sigma PTY check.
- 16 root compaction checks and three selected managed-child functional checks
  covering real patch/summary/continuation, failure and cancellation. Same-BEAM
  cold reads preserve settled effects and do not call the Provider.
- Four Runtime-backed root/child timing checks.
- 38 HTTP, creation-boundary and Responses recovery checks after the final
  transport defaults changed.

These source-loaded checks are local functional evidence. Linux native-helper
execution, independent-BEAM child compaction recovery, remote CI and production
deployment are separate checks. Actual candidate-package qualification and
service adoption are recorded below when completed.

The extracted Runtime Hex candidate subsequently passed standalone
warnings-as-errors compilation using its unchanged public dependency
requirements and freshly resolved Hex dependencies. Its actual package consumer
passed the same 21 scheduling checks and 14 command/portable checks; three
Linux-only command budget checks were skipped on macOS.

A separate Sigma consumer compiled the extracted candidate and all Sigma apps
with warnings-as-errors. It passed 21 root timing/compaction/actual-PTY checks
and the three selected child compaction cases. After pinning the image fixture's
bitstring size, the actual-image case also passed with warnings-as-errors.
Only this temporary qualification manifest selected the extracted artifact as a
path dependency. Shipped manifests and `mix.lock` retain the public package.

Previous-stage artifact (superseded by the remaining retry/activity changes):
`/tmp/sigma-runtime-qualification-a9hy7ktg/backplane_agent_runtime-1.10.101-candidate-final.tar`,
SHA-256 `d94d916757ec5cc66696efe8f578a371d9a061e63d294e5416f7b0f98ed4185f`.
That artifact qualified commands, dispatch and initial compaction only. It does
not contain the subsequent retry/activity contract. A refreshed candidate and
new public release version are required before adoption; the running stable
service does not select either unpublished candidate.

## Final activity/retry candidate qualification

The remaining activity and replacement-retry changes are now implemented and
qualified locally. The final extracted Runtime candidate contains 109 Elixir
source files. Its `lib/` and native source bytes match the sibling Backplane
checkout; the separate Sigma consumer's source/test bytes match this checkout.
Only the temporary consumer manifest points at the extracted package.

- Forced Runtime and full Sigma umbrella compilation passed with
  `--warnings-as-errors` (109 Runtime and 273 umbrella source files).
- Runtime: 48 passed; three Linux-only command-budget cases skipped on macOS.
- Sigma Agent: 42 passed, including root/ChildIO actual compaction activity,
  silent expiry, failed Writer ACK, failed tool non-execution, backoff cancel,
  bounded summary retry, cold projection and real PTY/child compaction paths.
- Sigma AI: 133 passed, covering actual HTTP retry/keepalive, both Retry-After
  formats, cancellation, partial/failed usage, same-ID recovery (including bare
  DONE and truncated GET errors), existing codec/hosted/image functional paths.
- Scoped formatting and both repository diff checks passed. These are the
  selected functional suites, not a claim of a complete test-suite run.

The extracted candidate's macOS session helper was built with
`mix backplane.command.build` before the actual command/child tests. The first
consumer attempt without that build correctly rejected command/Code Mode
capabilities. A date-based retry regression also exposed an overly short mock
server accept window; the fixture now waits for expected delayed requests and
then checks that no extra submission occurs.

Artifact (version label 1.10.101, unpublished candidate):
`/var/folders/4_/8yyx5sxd0d9073p79001rhvm0000gn/T/sigma-policy-final-vnifiyfk/backplane_agent_runtime-1.10.101-remaining-candidate.tar`

SHA-256: `b4a754e33c3b66094e1de545da72f22e5ad402a3c25ef506ede53bd106fdf6f6`.
Detailed commands/logs and source checks are retained beside the artifact in
`qualification.json`, `ai-test-command.json`, `sigma-source-check.json` and
`payload-source-check.json`.

This supersedes the previous-stage artifact above. Publication requires a new
Runtime version, followed by Sigma's actual public dependency update and matching
service restart. At qualification completion neither checkout had been committed/pushed for this
policy change, and no package had been published. Port 4580 still has the stable snapshot
process (PID 56430); no candidate code, prompts or historical journal mutations
were sent to that service. Linux native execution, independent-BEAM child recovery,
online models and deployed behavior remain separate acceptance boundaries.

## Runtime 1.10.102 publication and adoption

Publication and dev-service adoption were explicitly approved after candidate
qualification. Runtime-only release source is Backplane `3a16822f8060133230e2baa616e3ad06cc236df2`;
other package versions remain unchanged. Its standalone 1.10.102 package and
ExDoc build pass; executable source is identical to the qualified candidate.
The version/changelog metadata changes do not introduce a dependency override.

Release artifact: `/tmp/sigma-policy-release-62d_49ng/backplane_agent_runtime-1.10.102.tar`.
Hex inner checksum: `6021DE71B106E3FD431A282BC30F623C8C0B2DD3E846DD67E31D4E571B8C6FFD`.
Archive SHA-256: `2ff6011834cd1627b6ef1a62654d20116379767bf79c83848f63d477f4b376a7`.

Runtime 1.10.102 was publicly published on 2026-11-26 at
10:15:57 UTC. The public Hex tarball matches both checksums above; release
metadata reports `has_docs: true`, and the public documentation returns HTTP 200.
Readback evidence is retained in
`/tmp/sigma-policy-release-62d_49ng/public-readback.json`.
The broad unified gateway Release workflow was not used for this Runtime-only
publication.

Sigma selects the two-component requirement `~> 1.10`, with `mix.lock` pinning
the verified public Runtime 1.10.102. Other locked package versions remain unchanged.
Sigma commit `8e71b7d5c29a4d9d2392faa5471d36b9c888cb39` is pushed to `origin/main`.
Release qualification passed forced warnings-as-errors compilation for all 109
Runtime source files. Sigma's public-package consumer passed the same strict
compilation for all 269 umbrella source files; `SIGMA_RELEASE=true mix assets.build`
also passed.

The initial policy adoption served port 4580 from the matching private snapshot
`/private/tmp/sigma-policy-1.10.102-20261126-180845` (PID 78041). The previous
stable process (PID 56430) exited. Runtime readback confirms version 1.10.102,
all ten sampled loaded modules matching the snapshot's BEAM files, disabled
code reloading/watchers, the original `~/.pi/agent` configuration/session roots
and HTTP 200. Evidence is retained in
`/tmp/sigma-policy-1.10.102-20261126-180845-run/verified.json` and `preflight.json`.

Chrome reload confirms LiveView connected, chat/composer mounted, no console
errors/warnings and the original recovery gate with an enabled `Fork to continue`.
The journal remains exactly 898,376 bytes with SHA-256
`1cbbb9e1a64a4e3a49f37940568240667b65a4a8b2de0614584bdd549efba443`;
the served asset still matches the SHA-256 recorded below. Integrity evidence is
`/tmp/sigma-policy-release-62d_49ng/post-restart-integrity.json`.
No prompt, retry, Continue or fork was submitted. Historical outcomes and missing
lifecycle acknowledgements remain unchanged. The 223 local functional checks
above qualify behavior; online-model execution, Linux native/other-architecture
execution and full E2E remain unverified.

The subsequent [recovery fork fix](recovery-fork.md) records the current service
snapshot and actual successful browser creation of an independent continuation.

## Session failure during development, 2026-11-26

For `session_CSKN3z3E8LxeS6Z4`, the 16:25:30 local-time submission coincided
with live source recompilation. The dev log records `UndefinedFunctionError`
for unavailable `Sigma.Agent.handle_cast/2`, `Engine.run/2` and
`CodexResources.close/1`; shutdown cleanup was unconfirmed.

The 16:25:52 retry completed its Provider request in 32.3 seconds with 106,949
input tokens. It then retained one started `exec_command` intent with no settled
tool result and ended as `unknown_outcome`. The completed review/spec children
subsequently retained `cleanup_unconfirmed` and unknown closure. The UI's
"Subagent recovery is incomplete" gate therefore prevents sending, continuing
and retrying. This attempt used two work units with an infinite quota; it did
not exhaust the old work-count ceiling.

The running dependency was still Runtime 1.10.101 while edited host source
already selected the new command options and OutputBuffer API. Deploying only
one side is invalid. An isolated public-API reproduction using the actual old
`Codex.call("exec_command")` rejects the infinite deadline with
`command limits must be positive and within declared bounds`, without reaching
the command backend. An admitted unsafe call then produces the exact same
unknown-outcome signature. The real run did not persist its final tool error;
this is a reproduced matching mechanism, not a recovered historical error.

The retry's native closure is confirmed, but its async-hook and SessionEnd ACKs
are absent; both old child hosts also lack complete retirement evidence. The
other confirmed manager/registry receipts do not substitute for those original
host acknowledgements. Qualification must run in an isolated build/consumer; a
usable service must start from one matching, verified source/dependency set.
No historical cleanup or pending tool outcome may be marked successful from
the absence of a worker. A fork is the existing independent continuation path
when the original lifetime cannot be reconciled through public acknowledgements.

### Historical stable development service (superseded)

The affected dev process (PID 35880) was stopped gracefully. A private snapshot
of committed Sigma `54a1061de02e2487b45a6ddb2e4d9860d9a44dfd` temporarily served 4580
with public Runtime 1.10.101 before the verified policy adoption above. It lived at
`/private/tmp/sigma-stable-54a1061-20261126-164652`; its source and dependency
files are isolated from the working checkout. All 267 umbrella source files
passed forced warnings-as-errors compilation. Startup uses:

```sh
SIGMA_RELEASE=true \
SIGMA_GIT_SHA=54a1061de02e2487b45a6ddb2e4d9860d9a44dfd \
mix sigma.run --no-compile
```

`SIGMA_RELEASE=true` selects no code reloader and no watchers in the existing dev
configuration. It does not enable the unpublished policy candidate. Live
readback confirms the original `~/.pi/agent` config/session directories and that
the loaded Agent/Engine/resources/Command/Conversation BEAM hashes match this
snapshot. The first explicit session reload preserved the exact 898,376 journal
bytes, 104 Provider request starts and 91 settled tool results. Its historical
recovery gate remains, with an independent fork available through the UI.

The snapshot's initially copied static bundle lacked the current chat hooks.
Installing its committed npm lock and running `SIGMA_RELEASE=true mix assets.build`
generated the matching `/assets/js/app-54dfe067.js` bundle. The served file matches
SHA-256 `1a48df3481cc0b86ccecea49709b978965178cdaed0001f431c1f6db69825b0d`.
Final Chrome readback confirms LiveView connected, conversation/composer mounted,
no new console errors/warnings and an enabled `Fork to continue` button. A second
explicit reload still preserves the journal bytes and Provider/tool counts above.
No prompt, retry, Continue or fork action was submitted during verification.
