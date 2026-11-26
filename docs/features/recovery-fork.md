# Forking an interrupted session

`Fork to continue` creates an independent session when the source retains
unconfirmed subagent cleanup. It does not confirm the source's cleanup or
resume its unfinished tools.

The 2026-11-26 failure in `session_CSKN3z3E8LxeS6Z4` crossed two boundaries:

1. The journal contained an assistant `exec_command` call without a result.
   Ordinary fork validation rejected it as `invalid_fork_boundary` with an
   `unpaired_tool_call` cause.
2. Once history copying succeeded, ordinary Goal preparation rejected the
   source Runtime's missing tool result before copying its Goal state.

Both errors appeared as `Unable to fork session`. Earlier browser checks had
verified the recovery button, without confirming creation of the fork.

## Recovery behavior

The current session's full-history fork selects `recovery: true` while its
subagent recovery gate is active. The source revision/leaf checks, serialized
operation boundary and inactive-source guard still apply. Recovery and ordinary
forks have distinct operation fingerprints; existing ordinary fingerprints
remain compatible.

Recovery copies the selected raw history, including the unfinished call. The
existing journal projection excludes unpaired tool frames from Provider
context, without fabricating results or changing settled history. Ordinary
forks and explicit message cuts retain their completed-exchange checks.

Goal recovery forks use public `Goal.fork_snapshot` and the existing target
store import. They copy committed Goal state into the new thread's independent
store without preparing a source admission or reconciling its uncertain runs.
A cold source opens the Goal context for this copy without running recovery.
Source Runtime records, lifetime evidence and recovery status remain factual;
the target inherits neither Runtime work nor child admission/lifetime ledgers.

Creating and opening the fork do not call a Provider. A subsequent prompt is
new work in the target; files, Git state and external side effects remain shared
with the original working directory.

## Verification

The regression first failed on the unfinished tool call. After history copying
was corrected, an isolated copy of the real session exposed the independent
Goal `missing_tool_result` failure. With both fixes, that copy forks and opens
an idle target with an empty, healthy subagent host and no Provider call.

Eighteen selected local checks pass: journal branching, operation idempotency,
ordinary and recovery Goal forks, live recovery and UI confirmation. The live
case also completes a new target prompt through a controlled Provider while
preserving the source Runtime and lifetime records. Forced warnings-as-errors
compilation passes for all 269 umbrella source files. Online model execution
is outside these checks.

## Live verification, 2026-11-26

Port 4580 runs Sigma `f32319870145cbbe2a57dd9ad113feb612fa22c1` with public
Runtime 1.10.102 from `/private/tmp/sigma-recovery-fork-brpacf51` (PID 89378).
The previous process exited; all 16 sampled loaded modules match the new
snapshot. Code reloading/watchers remain disabled and the original agent and
session directories remain selected.

Chrome completed the original recovery button and confirmation flow, creating
`fork_72dc44e0f3ff729f`. Its LiveView is connected, runtime is idle/Ready,
`canSubmit` is true, and no recovery banner or console errors/warnings remain.
The new conversation and Provider context equal the source's selected history;
target child admissions are empty. No online prompt was submitted.

The original 900,284 journal bytes remain an exact prefix. Only the two successful
fork operation facts were appended, bringing the source to 901,053 bytes. All
26 existing sidecar files retain their hashes, and the source still has 104
Provider request starts and 91 tool results. Evidence is in
`/tmp/sigma-fork-live-integrity.json` and the snapshot's sibling
`sigma-recovery-fork-brpacf51-run/verified.json`.
