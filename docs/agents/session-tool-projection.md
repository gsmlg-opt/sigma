# Session tool projection and deletion diagnostics

## Malformed native tool input (2026-11-27)

The persisted `fork_ad237257be91cb4e` transcript contains native `write_stdin`
function calls with `"chars": {}` and numeric `session_id: 4902`. The first
observed LiveView failure was `String.trim(%{})` in `SessionLive.tool_summary/2`.
The same record then crashed the asynchronous session load on each reconnect.
This explains the inaccessible session UI; it does not explain the independent
terminal Runtime failure or establish a successful tool effect.

Tool summaries now trim only binary input and display only scalar detail fields.
Structured invalid fields leave the one-line detail empty or retain the session
identifier. The expandable input keeps the original arguments. Rendering neither
validates execution nor repairs, replays or overwrites the persisted call.

Both real malformed calls received normal native validation errors, including
`at /chars: Expected type string, got object`. The regression persists the exact
malformed shape through the actual Writer, projects its live event and paired
validation result, reopens the session and checks unchanged input, error result
and transcript bytes plus repository operation availability. Additional summary
cases cover structured values in command arguments, image paths, cell IDs, tool
search and clock fields.

## Deletion diagnostics

Two RepositoryLive deletion confirmations were observed at 16:24:17 and 16:24:24
CST. The server log records only handled event completion. A later user screenshot
confirms the active-turn rejection message from `:session_busy`. No deletion of
the original user session was performed during investigation.

SessionLive uses the same operation-error projection as RepositoryLive instead
of replacing every failure with a generic deletion message. The user requires
deletion to cancel and retire an active session before removing its files;
manual Stop is not an acceptance condition. Deletion reserves the Agent,
rejects new prompts, releases queued work, cancels the active turn and joins its
preparation tasks before the existing host, Goal, Store and terminal retirement
gates permit file removal. Caller loss waits for in-flight retirement and uses
the normal reopen path; incomplete cleanup retains its original error rather
than asserting shutdown.

Typed Runtime errors identify unconfirmed native tools, async hooks and SessionEnd
through fixed component labels. Arbitrary error messages and nested causes are
not inserted into the flash. Persistence and release wrappers preserve an
already-applied result: a successful deletion followed by failed result storage
must say that deletion occurred. Generic errors no longer assert that no files
changed when that has not been established.

A later read of `session_qdne9q8K0KXFAJfs` found two host lifetimes with confirmed
native receipts and absent async-hook/SessionEnd receipts. These durable records
do not preserve the actual deletion return, so they cannot establish its exact
failure cause. Its incident records separately contain two root-continuation
failures with class `not_found`; these explain a recovery failure, not the
deletion return. All six older `session_ZRx8Ss-v_ol1fNT3` host lifetimes have
confirmed async-hook/SessionEnd receipts, with native receipts for every binding.
No user session was deleted or prompted during these reads.

## Verification boundary

The isolated consumer reproduced both malformed-input regressions against the
original display code. After the fix, all 13 projection cases and the four
automatic-recovery UI cases pass. The persisted malformed-call fixture contains
the real settled validation error exchange; incomplete-exchange filtering keeps
its separate history contract.

The integrated deletion checks pass five Agent cases and one LiveView case,
including active Provider cancellation, queued-resource release, preparation
fencing and caller-loss handling. The earlier active-delete regression was red
against the original busy guard. These checks do not establish deployment, a
successful deletion of the original session or resolution of its independent
Runtime failure. All three focused operation-error tests pass, covering cleanup
components and already-applied operations followed by acknowledgement failure.
Evidence:
`/Volumes/Data/tmp/sigma-deps-upgrade-zwchi4ni/malformed-red.log` and
`/Volumes/Data/tmp/sigma-deps-upgrade-zwchi4ni/delete-repair1.log`,
`projection-full.log`, and `web-final.log` in the same directory.
