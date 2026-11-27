# Operation incident records

Sigma records selected live failure and recovery observations as immutable JSON
files. The records preserve a useful diagnosis when a later retirement or
continuation failure would otherwise obscure the first operation failure. They
are auxiliary diagnostics: they do not establish tool settlement, successful
cleanup, or permission to repeat an uncertain operation. Runtime Store facts,
original tool results and independently acknowledged host receipts retain those
responsibilities.

This document describes the implementation introduced on 2026-11-27. The
implementation is `Sigma.Agent.Incidents`; root and child callers live in
`Sigma.Agent`, `Backplane.Engine`, `Backplane.ChildIO`, `Subagents` and
`Backplane.RootContinuation`.

## Ownership and location

The owning root supplies its absolute transcript path and immutable JSONL session
header ID. For a transcript at `<repository-session-dir>/<name>.jsonl`, records
live at:

```text
<repository-session-dir>/.incidents/<root-header-id>/<event-id>.json
```

`<root-header-id>` is the journal header ID, not its filename, runtime session
lookup ID, child session ID, or current run ID. The header component must be
1–160 bytes of ASCII letters, digits, underscore, dot or hyphen, excluding `.`
and `..`.

`Subagents` supplies the same trusted root transcript/header when starting a
ChildIO. Its subject identifies the actual child session and agent path. A
grandchild's own or immediate parent's transcript must not become the repository
incident root. Incident context is an explicit host option; it is not inherited
from model-supplied arguments or ordinary child configuration.

## API

```elixir
context =
  Sigma.Agent.Incidents.context(root_transcript_path, root_header_id, %{
    session_id: root_session_id,
    agent_path: "/root"
  })

Sigma.Agent.Incidents.record(context, %{
  kind: :recovery_admitted,
  stage: :root_continuation,
  run_id: source_run_id,
  source_run_id: source_run_id,
  target_run_id: target_run_id,
  continuation_id: continuation_id
})
```

`context/3` returns an `Incidents` struct, or `nil` when the path/header is
unavailable or invalid. It does not create a directory or inspect the transcript.
The default subject is `%{kind: "root", id: root_header_id}`. Optional subject
fields are `id`, `session_id` and `agent_path`; `kind: :child` selects the child
subject. Other subject attributes are discarded.

`record/2` returns `:ok` or `{:error, bounded_atom}`. `record(nil, attrs)` is a
successful no-op. Consequently, `:ok` alone does not demonstrate that a record
exists: it can mean disabled context or an already-published observation. The
collector logs a static diagnostic and bounded reason on failure. Callers retain
their original operation outcome; they do not retry effects or recursively
record a collector failure.

`record_tool/3` and `record_provider/4` centralize the safe projections used by
Engine and ChildIO. They are internal host helpers, not model tools or a new Web
API.

## Version 1 schema

Each final file contains one JSON object, not JSONL. Fields with no valid value
are omitted except `error`, `evidence_refs` and `versions`, which may be empty.

| Field | Meaning |
| --- | --- |
| `format`, `schema_version` | Always `"sigma.incident"` and `1` |
| `event_id` | SHA-256 identity of this particular observation; also the filename stem |
| `incident_id` | SHA-256 correlation identity for a subject's source run |
| `root_header_id`, `subject` | Trusted journal ownership and actual root/child attribution |
| `kind`, `stage`, `summary` | Observation category, caller stage, centrally generated static summary |
| `observed_at` | UTC ISO 8601 collection time; not the original operation timestamp |
| `run_id`, `source_run_id`, `target_run_id` | Actual run identity and an explicit old-run/new-run recovery link |
| `continuation_id` | Public continuation decision identity, when available |
| `tool_call_id`, `tool_name`, `invocation_id` | Original tool identities, when available |
| `provider_request_id`, `provider_attempt_id` | Original Provider identities, when available |
| `incarnation`, `exit_code` | Integer observations, when supplied |
| `recovery_state`, `blocked_component` | Bounded recovery labels, when supplied |
| `error` | Selected known `class`/`code` and HTTP `status`; never raw error text |
| `evidence_refs` | At most eight selected identity maps |
| `versions` | Loaded `sigma_agent`, `backplane_agent_runtime`, `backplane_ai_protocol` and `backplane_skill_protocol` application versions, plus optional `sigma_commit` |

The accepted kinds and exact summaries are:

| Kind | Static summary |
| --- | --- |
| `tool_failure` | Tool reported failure |
| `provider_failure` | Provider attempt failed |
| `runtime_failure` | Runtime reported failure |
| `run_failed` | Run failed |
| `retirement_failed` | Host retirement was not confirmed |
| `recovery_started` | Recovery started |
| `recovery_admitted` | Recovery admitted a new run |
| `recovery_blocked` | Recovery was blocked |
| `recovery_cancelled` | Recovery was cancelled |

Accepting a kind does not mean every possible producer emits it. The live call
sites define coverage. Callers cannot replace a summary with supplied text.

## Live capture boundaries

Root Engine collects a tool result after its `message_end` persistence callback
succeeds. A tool incident is recorded when the canonical message has
`is_error: true`, or a bounded structured result contains `is_error: true`,
`status: failed`, or a nonzero integer `exit_code`. Thus a shell command exiting
nonzero can be collected even when the outer Code Mode tool itself completed
successfully. An arbitrary nested field named `error` alone is insufficient.
Successful tool results do not otherwise generate incidents.

Root Provider collection uses the typed failed-attempt snapshot before generic
error conversion. The live retry boundary and final Engine completion share that
projection. A newly persisted failed assistant message is collected only after
its persistence succeeds; a failed attempt without assistant output still has a
typed observation and can be recorded. The actual attempt ID distinguishes
retries.

ChildStore passes typed Provider failure snapshots to the currently fenced
ChildIO while projecting a live acknowledged runtime commit. ChildIO records
new tool messages only after `Writer.append/2` acknowledges their journal
append, and records Provider snapshots at the matching live boundary. Stale
child keys are rejected. Already persisted messages do not create fresh records.

ChildIO initialization, transcript reload, ordinary history reads and cold
recovery do not collect or backfill incidents. The record writer itself reads no
transcript, Store, Provider, or tool state. Engine also collects typed `turn_failed` and `storage_failed` Runtime errors
before generic error conversion. Root lifecycle callers add run/recovery
observations from their actual live outcomes. A recovery record
does not replace the original failure record or invent missing historical tool
results.

## Correlation, deduplication and publication

`incident_id` hashes the root header, complete subject and
`source_run_id || run_id`. Tool failure, terminal failure and recovery records
for the same subject/source therefore share a correlation ID. Child subjects
have their own correlation identities; `root_header_id` groups the complete
root/child incident family. `target_run_id` and `continuation_id` provide the
explicit link to a replacement run. Timestamps alone do not prove causal order.

`event_id` hashes the root header, complete subject, kind and selected identity
fields, plus stage and incarnation. The selected identity fields are the schema's
run, continuation, tool and Provider identity fields. Error text, selected error
classification, exit code, recovery state, evidence references, versions and
collection timestamp do not change this identity. The first published bytes for
an event win; observing a different classification later cannot overwrite them.

Publication creates an exclusive random temporary file beside the final file,
writes and syncs its contents, then atomically hard-links it to the final path.
An existing final path is treated as deduplication. Normal completion removes
the temporary link. Concurrent writers cannot replace an existing observation.
A process crash can leave a temporary file; only final `*.json` files are
published records.

File contents are synced before publication. The containing directory is not
synced, so this does not provide an additional power-loss durability guarantee.
Collector failures remain auxiliary and never constitute runtime-effect proof.

## Bounds and excluded content

The encoded object must fit within 16 KiB before it is written. Selected identity
strings are valid UTF-8 of 1–256 bytes, excluding newline, carriage return and
NUL. Invalid fields are omitted. Stage, recovery state and blocked-component
labels use the same 1–160-byte component syntax as the root header; atom labels
are converted to strings. Incarnation and exit code accept integer values.

Error projection takes `class` or `kind` only from the explicit Runtime/Provider
classification allowlist in `Incidents`. It takes `code` or `provider_code` only
from the explicit known-code allowlist. `status` or `http_status` is retained
only for integers from 100 through 599. Unknown classifications/codes are
omitted; no diagnostic text substitutes for them.

Each evidence reference permits only `run_id`, `tool_call_id`,
`provider_request_id`, `provider_attempt_id`, `transcript_entry_id` and
`invocation_id`, using the same string bounds. Arbitrary paths and payloads are
discarded. Structured tool inspection visits at most 128 nodes, at most 32
members per container, through depth six. Deeper or wider nested failures can
remain unclassified; the collector does not traverse an unbounded result.

No raw causes, details, error messages, Provider options, credentials, prompts,
tool arguments, tool output, model responses or arbitrary caller attributes are
serialized. The bounded result walk selects only the failure classification and
exit code, not its surrounding content.

`versions.sigma_commit` is taken only from the known `git_sha` field of the
`:sigma_web, :build_info` application map, and only when it is 7–64 hexadecimal
characters. The collector does not read environment variables, execute Git or
serialize other build metadata. Unloaded application versions and unavailable or
invalid commit values are omitted.

## Retention and session file operations

There is no retention scheduler, garbage collection, aggregate index, upload
service or collector UI in this implementation. The size bound applies to each
record, not the total number of files.

The directory is independent of the transcript-named `.runtime` and `.subagents`
sidecars managed by `Sigma.Session.SessionFiles`:

| Operation | Current incident behavior |
| --- | --- |
| Rename within a session directory | Existing records remain at the same header directory; transcript filename changes do not change their location |
| Adopt in place | Existing records remain unchanged |
| Adopt across session directories | Existing records remain in the source directory; future live records use the destination directory and unchanged root header |
| Delete session | Existing incident records remain; session deletion does not remove `.incidents` |
| Fork session | Existing records are not copied; the fork's fresh journal header gives future observations an independent incident root |

These are current storage semantics, not a completed incident-lifecycle migration
policy. Cross-directory adoption can split a header's records across repository
session directories. A future retention or migration operation needs explicit
ownership and independent verification; it must not rewrite historical records
or silently infer retention from transcript presence.

## Discovery by a future collector

A read-only collector can enumerate the configured repository session directories
and scan `.incidents/*/*.json`, including directories whose transcript has been
deleted or adopted elsewhere. It should ignore temporary files, bound reads to
16 KiB, validate the format/version, identifier shapes and filename/event-ID
agreement, and retain root header, subject, event and incident IDs. Deduplicate
exported copies by `event_id`; group
failure/recovery observations by `incident_id` and use explicit source/target
links for replacement runs. Unknown schema versions require separate handling.

Reading or exporting these files must not start an Agent, dispatch a Provider
request, rerun a tool, retry collection, or turn diagnostics into settlement or
cleanup receipts. The present implementation provides the on-disk contract;
discovery, transport and retention remain future work.

## Verification

The serialized Runtime 1.10.106 candidate consumer passed the complete 24-case
selection (seed `527211`): nine collector cases, five live root/child and session
file lifecycle cases, six real uncertain-operation continuation cases, two
terminal ownership cases and two production continuation/history cases. The
collector checks include typed Runtime and Provider errors, actual Writer
acknowledgement, nested child attribution, no-output Provider failure, concurrent
deduplication, payload exclusion, loaded version metadata and unavailable storage.
The public SessionFiles check verifies rename, cross-directory adoption, fresh
fork headers and delete retention using actual files.

Four LiveView recovery/status/Stop cases passed separately (seed `527210`). The
broader lifecycle/command selection passed 51 of 56 cases (seed `527207`); five
existing root-retirement cases stopped at Linux-only `/proc/<pid>` assertions on
macOS. That selection is not reported as fully passing. Strict compilation, asset builds and repository formatting checks
passed in the isolated consumer. Package publication, locked dependency adoption
and deployment remain separate gates; these results do not establish that the
running dev service contains the new collector.

Evidence and deployment status are recorded in
[Architecture and acceptance history](architecture-notes.md). No Provider prompt
or Continue was submitted to the real incident session during this validation.
