# Automatic recovery after an uncertain operation

A live native root turn that ends with `unknown_outcome` and an unrecorded tool
result prepares a fresh run automatically. The model receives the public
continuation notice and unresolved operation identities, together with an
instruction to report the issue, inspect the current state before repeating an
action, and continue the task. A queued user followup takes precedence and keeps
its original content and prepared resources.

The old run stays `unknown_outcome`. Its Store snapshot, uncertain invocation,
and missing result remain unchanged. The host never retries the old tool call or
creates a replacement result. The model decides fresh actions using the available
evidence in the new run.

## Admission and ownership

Only a terminal result or DOWN matching the Agent's actual current turn task can
initiate automatic preparation. The Agent reserves its existing pending host
prompt and `:session_operation` state in the same callback. Preparation executes
outside the GenServer, through `RootContinuation.prepare`, and requires the
existing public executor, Provider, native resource, async-hook, SessionEnd,
Registry and manager closure contracts. A source-to-target continuation decision
is durable and uses compare-and-create admission.

A synthetic probe retains the source turn identity until that decision provides
the target. This prevents an ordinary failed turn's asynchronous status refresh
from presenting a nonexistent replacement turn. If the source is ineligible, the
synthetic instruction is discarded and the original terminal state restored;
it never becomes an ordinary prompt. Ordinary model-visible tool failures remain
in the current turn and can be handled directly by the model.

The UI receives `:recovery_started` only after the source is known to have an
uncertain operation without a result. It shows recovery preparation as active,
with the existing Stop control. A successful admission starts the fresh Provider
request using the selected history plus the public continuation notice.

## Stop, missing acknowledgements and cold loading

Stop during preparation waits for the in-progress cleanup attempt, retains its
actual facts and durable decision, and starts no replacement host or Provider.
A later explicit prompt can reuse that decision. Cancellation also wins when a
turn ends with an event-persistence failure.

Missing acknowledgements or failed preparation leave a visible error and a
structured blocked incident with the known failed component. Preparation failure
never schedules another synthetic attempt. There is no timer that repeatedly
retries unchanged missing facts, and no arbitrary recovery-count ceiling for
separate, newly admitted executions.

Task identity and the durable continuation decision fence duplicate or stale
terminal callbacks. Initialization, history reads, page reloads and cold reopening
never schedule Provider calls or tool effects. If the process stops after the
decision is persisted but before admission, the next explicit prompt may use the
existing decision; merely opening the session does no work.

The root continuation contract does not restart an uncertain managed child.
Children keep their existing parent reporting and retirement contracts. Their
live failures are collected under the trusted root incident directory. See
[Operation incident records](operation-incidents.md) for the collector format,
retention behavior and diagnostic limits.

## Verification

Functional verification uses controlled Providers and real file reads, commands,
SessionEnd hooks, public native closure and durable Stores. It covers automatic
fresh work, preservation of the original unknown run, Stop before adoption,
explicit cold continuation, queued followups, stale terminal messages, and a
lost preparation acknowledgement that blocks without recursive recovery.

Exact test outcomes and the dependency/deployment boundary are recorded in
[Architecture and acceptance history](architecture-notes.md). Passing controlled
functional tests does not mean the affected user's real model was invoked; that
session is kept passive during qualification.
