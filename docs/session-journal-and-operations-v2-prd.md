# Sigma Session Journal and Session Operations v2 - PRD

> First child PRD of `oh-my-pi-learning-roadmap-prd.md`.
> Defines durable session semantics before provider, tool-runtime, or context-rule expansion.

## Problem Statement

Sigma persists conversation messages and compaction entries in JSONL, while other
session behavior is split across mutable sidecar metadata, LiveView assigns, and
runtime process state. The log already writes `id` and `parentId`, but replay is
linear: it does not resolve a selected root-to-leaf branch. Model selection is
restored from `.meta.json`, and session switching is currently route navigation
rather than a lifecycle operation with flush, rejection, and rollback semantics.

This fragmentation creates several user-visible risks:

- Resuming a session can restore messages without restoring the behavior that
  produced them.
- A future branch inside one journal could replay entries from sibling branches.
- Switching or forking while work is active has no single place to guarantee that
  pending state is settled.
- Richer session listings could become slow if they replay complete transcripts.
- Dumping or exporting a session has no explicit read-only contract.
- Existing sessions remain tied to a working-directory-derived storage path even
  when their recorded history is otherwise valid.

Sigma needs one session contract that can be replayed deterministically and one
operations boundary that owns all session transitions. The design must preserve
existing v3 JSONL sessions and current repository/worktree metadata without
wholesale rewrites.

## Solution

Sigma will treat each session JSONL file as an append-only journal. Journal
entries form a tree through `id` and `parentId`; replay selects one active leaf,
walks its ancestry to the root, and reduces that path into one session snapshot.
The snapshot contains both model-facing messages and restored behavioral state.

The session application will own journal parsing, indexing, replay, summary
reads, and atomic file operations. The agent runtime will own transitions for
running sessions. Phoenix LiveView will request operations and render their
results; it will not implement persistence or lifecycle rules itself.

Existing `.meta.json` fields remain a compatibility fallback during migration.
New behavioral changes are appended to the journal. Structural workspace fields
such as worktree path and branch may remain in sidecar metadata until a later,
explicit migration.

## Domain Terms

- **Journal**: One session header followed by append-only session entries.
- **Entry**: A typed record with `id`, `parentId`, and `timestamp`.
- **Branch**: The ordered ancestry from a root entry to a leaf entry.
- **Active leaf**: The entry whose ancestry defines restored session state and
  the parent of the next normal append.
- **Snapshot**: The pure replay result for one active leaf, including messages,
  settings, summaries, and diagnostics.
- **Fork**: A new independent session file created from a selected branch of an
  existing session. Fork never mutates the source session.
- **Switch**: Replacing the running session snapshot and persistence target with
  another existing session.
- **Dump**: A machine-readable, read-only representation of the journal.
- **Export**: A human-readable, read-only rendering of the active branch.

## User Stories

1. As a Sigma user, I want a resumed session to restore its active conversation
   branch, so that sibling experiments do not leak into the model context.
2. As a Sigma user, I want the model and provider selection to survive resume, so
   that the session continues with the behavior I selected.
3. As a Sigma user, I want reasoning level, service tier, MCP selection, and mode
   state to survive resume, so that restored behavior matches the prior session.
4. As a Sigma user, I want compaction summaries to replay only on the selected
   branch, so that an unrelated branch cannot replace my history.
5. As a Sigma user, I want to fork at a specific message or the current leaf, so
   that I can explore an alternative without changing the source session.
6. As a Sigma user, I want a fork to preserve relevant restored settings, so that
   it starts from the same operational context as its source branch.
7. As a Sigma user, I want a failed fork to leave no partial target, so that the
   session list never contains a half-created conversation.
8. As a Sigma user, I want switching from an idle session to flush persisted
   state first, so that reopening the previous session loses nothing.
9. As a Sigma user, I want switching or forking to be rejected while a turn is
   active, so that Sigma never silently abandons provider or tool work.
10. As a Sigma user, I want a failed switch to keep the current session usable,
    so that one corrupt target cannot destroy my active state.
11. As a Sigma user, I want recent sessions to load quickly even when transcripts
    are large, so that repository and session navigation stays responsive.
12. As a Sigma user, I want sessions with missing working directories to remain
    visible, so that moving a checkout does not hide valid history.
13. As a Sigma user, I want to adopt a session into a replacement working
    directory, so that an externally moved repository can continue safely.
14. As a Sigma user, I want a JSON dump of a session without changing it, so that
    I can inspect or process the journal externally.
15. As a Sigma user, I want a Markdown export of the active branch without
    changing it, so that I can share a readable transcript.
16. As a Sigma user, I want a trailing torn JSONL write to be ignored with a
    diagnostic, so that a crash does not make the whole session unusable.
17. As a Sigma user, I want interior corrupt entries to be reported and isolated,
    so that recoverable branches remain available.
18. As a Sigma developer, I want replay to be a pure transformation, so that the
    same journal and leaf always produce the same snapshot.
19. As a Sigma developer, I want unknown entry types preserved, so that older
    Sigma versions do not destroy state written by newer versions.
20. As a Sigma developer, I want session transitions serialized by the runtime,
    so that two clients cannot switch, fork, or append the same session at once.
21. As a Sigma developer, I want listing tests to enforce bounded reads, so that
    adding summary fields cannot accidentally introduce full transcript replay.
22. As a Sigma developer, I want existing v3 logs and sidecars to remain
    readable, so that rollout does not require an eager migration.

## Implementation Decisions

### Journal ownership and public boundaries

- `sigma_session` is the source of truth for persisted session state.
- A pure journal reducer will index valid entries by ID, resolve the selected
  root-to-leaf path, and return a snapshot. It performs no file or process I/O.
- `Sigma.Session.Log` remains the compatibility facade for current callers while
  delegating replay and new state restoration to the journal reducer.
- `Sigma.Session.SessionFiles` remains responsible for validated paths and
  atomic file lifecycle operations such as fork, rename, delete, and relocation.
- `sigma_agent` owns running-session status and serializes switch and fork
  requests through the repository/session runtime.
- `sigma_web` calls the runtime operation boundary. LiveViews do not write JSONL
  or behavioral sidecar fields directly after their journal-backed replacement
  is available.

### Journal entry contract

- A journal starts with one session header. New files must not copy an old header
  and append a second header; a fork writes one new header followed by copied
  branch entries with a fresh session identity.
- Every non-header entry has a non-empty unique `id`, a `parentId` that is either
  `null` or references an earlier valid entry, and an ISO-8601 `timestamp`.
- The initial supported behavioral entry types are:
  - `message`
  - `model_change`
  - `thinking_level_change`, exposed as `reasoning_level` in the Sigma snapshot
  - `service_tier_change`
  - `mcp_server_selection_change`
  - `mode_change`
  - `compaction`
  - `branch_summary`
- `model_change` stores the selected model as `provider/model_id`. The snapshot
  splits the value into `provider_id` and `model_id` for existing Sigma callers.
- `thinking_level_change` stores the effective reasoning level and may also store
  the configured selector when auto-selection and effective level differ.
- `service_tier_change` stores the selected tier or `null` to clear it.
- `mcp_server_selection_change` stores the complete selected server-ID list. It
  replaces the prior list rather than merging with it.
- `mode_change` stores the mode name and optional mode-specific data.
- New `compaction` entries reference a journal entry ID through
  `firstKeptEntryId`. Readers also accept the current `firstKeptId` field and may
  resolve its value through a nested message ID for existing sessions.
- `branch_summary` stores the summarized branch origin as `fromId` and its text
  as `summary`.
- Entry payloads use string keys on disk. The reducer converts only known keys
  into internal atoms and never creates atoms from arbitrary journal input.
- Unknown entry types are retained in raw dump and fork operations but ignored
  when constructing model-facing context.
- A duplicate entry ID is corrupt. The first valid entry wins; later duplicates
  are excluded and reported in snapshot diagnostics.
- An entry with a missing, self-referential, or forward parent is excluded from
  branch replay and reported. Other valid branches remain recoverable.
- The latest valid entry is the default active leaf on ordinary resume. A caller
  may request another valid leaf for branch inspection or forking.
- Selecting a historical leaf for read-only inspection does not mutate the
  journal. The next content or state entry appended to that leaf makes the new
  branch durable and becomes the latest active leaf.

### Snapshot contract

- Replay returns one snapshot containing at least:
  - session identity and recorded working directory
  - active leaf ID and ordered branch entry IDs
  - model-facing messages
  - provider and model selection
  - reasoning level
  - service tier
  - selected MCP server/tool identifiers supported by Sigma
  - active mode and mode data
  - latest applicable compaction and branch summary
  - recoverable diagnostics
- Behavioral state is reduced only from entries on the active branch. A newer
  state entry on a sibling branch has no effect.
- The latest state entry of each supported type on the active branch wins.
- Compaction applies only when its entry is on the active branch. Replay emits
  its summary followed by the kept active-branch tail.
- The display transcript and model context may render compaction differently,
  but both are derived from the same snapshot and active branch.
- Replay of the same bytes and leaf is deterministic and does not mutate the
  journal, sidecar, configuration files, or runtime.

### Compatibility and migration

- Current v3 JSONL files remain readable without an eager full-file rewrite.
- Existing message and compaction entries are interpreted as today when their
  journal is linear.
- Legacy fork files containing a copied source header followed by a second fork
  header remain readable. The last valid session header supplies the fork's
  identity and `parentSession`; earlier headers are compatibility metadata and
  are not members of the branch entry tree. New forks write exactly one header.
- Existing `.meta.json` behavioral fields are read only when the active branch
  has no corresponding journal entry. Journal state always takes precedence.
- Existing `provider_id` and `model_id` sidecar values are the migration fallback
  for model restoration.
- Existing `mcp_server_ids` and any future recognized behavioral sidecar values
  follow the same journal-first fallback rule.
- Once journal-backed behavioral writers ship, new changes append journal
  entries. They do not continue dual-writing the same behavioral field to the
  sidecar.
- Worktree path, branch, and worktree ownership fields remain structural sidecar
  metadata in this stage. This PRD does not eliminate `.meta.json` entirely.
- Migration is lazy. Reading an old session does not modify it. The first future
  state change appends the new entry format.
- Replaying session state never rewrites global provider settings. A direct user
  model selection retains Sigma's existing separate global-default update
  behavior, but journal restoration itself is session-local and read-only.

### Append and durability rules

- Normal entry writes append exactly one complete JSON object and newline.
- Appends are serialized per running session. There is one logical writer for a
  session file at a time.
- A successful append must be visible to a subsequent replay before the caller
  receives success. Power-loss durability through `fsync` is not required in v2.
- Full-file operations use a temporary file and no-overwrite atomic publication.
- A trailing incomplete line remains recoverable and produces diagnostics.
- Operations never silently discard interior corruption. They expose diagnostics
  and refuse mutations that cannot identify an unambiguous active branch.

### Session operation contract

| Operation | Source mutation | Target mutation | Running-session rule |
| --- | --- | --- | --- |
| Resume | None | None | Loads a snapshot into an absent or idle runtime |
| Switch | Flush only | None | Reject while current session is busy |
| Fork | Flush only | Atomically creates one new session | Reject while source session is busy |
| Compact | Appends one compaction entry | None | Runs only through the owning session runtime |
| Dump | None | Writes only the requested output | Reads a stable accepted snapshot |
| Export | None | Writes only the requested output | Reads a stable accepted snapshot |
| Relocate | Moves the session file set transactionally | Updates structural location metadata | Reject while source session is busy |

- `resume` reads and reduces journal state without changing source bytes.
- `switch` first verifies that the current session is idle or hibernating, flushes
  accepted events, loads and validates the target snapshot, then swaps the
  runtime persistence target and restored state.
- A busy session returns an explicit `session_busy` result. V2 does not
  implicitly cancel an active provider stream, tool execution, permission
  request, or hook.
- A failed switch restores the previous runtime snapshot and persistence target.
  The caller receives a visible error; the current session remains usable.
- `fork` may target the current active leaf or a specified valid leaf. It writes
  one fresh header and the selected branch in parent-before-child order.
- A fork preserves restored behavioral state by copying the selected branch. It
  copies structural sidecar metadata unless the caller explicitly adopts a new
  working directory.
- Fork publication is all-or-nothing. The source bytes never change, and failure
  leaves no target JSONL, sidecar, or temporary file.
- `dump` produces a JSON document containing the header, valid logical entries,
  selected leaf, and diagnostics. Unknown entries are included.
- `export` produces Markdown for the active branch. It includes messages,
  compaction summaries, tool-call/result content, and restored session settings
  needed to understand the transcript.
- Dump and export capture the accepted journal length at operation start and do
  not read later concurrent appends. They never trigger migration, compaction,
  title generation, or metadata writes.
- Output files are published atomically and do not overwrite an existing target
  unless the caller explicitly selects replacement behavior.
- Existing hook and permission-policy checks remain in their current lifecycle
  positions. Session operations do not bypass them or invent new hook semantics.

### Session listing and repository relocation

- Session listing returns summaries rather than bare file names. A summary
  includes session ID, title or fallback name, recorded cwd, updated time, model,
  latest user-message preview when available, and diagnostics status.
- Listing reads a bounded prefix and tail from each JSONL file. The initial budget
  is at most 64 KiB from each end per session; it must not invoke full replay.
- If the bounded data cannot produce a field, listing returns a partial summary
  instead of reading the complete transcript.
- Missing recorded working directories do not hide session summaries.
- Session identity is independent of the current cwd-derived directory key.
- Explicit repository path updates continue moving the repository session
  directory atomically.
- An orphaned session can be adopted by supplying a replacement cwd. Adoption
  validates the target directory, relocates the session file set, updates
  structural metadata, and leaves conversation entries unchanged.
- V2 does not search the entire filesystem for moved repositories. Discovery is
  limited to Sigma's configured repositories and session root.

### Error and concurrency behavior

- Runtime operations for the same repository/session are serialized.
- Concurrent requests receive the result of the ordered operation or an explicit
  busy/conflict error; they never race file publication.
- Invalid session IDs and path traversal remain rejected before file access.
- Read diagnostics distinguish trailing torn writes, invalid JSON, duplicate IDs,
  missing parents, and unsupported entry payloads.
- A recoverable diagnostic does not prevent read-only replay of another valid
  branch. A mutation requiring an ambiguous or corrupt active path is rejected.
- If a recorded provider, model, MCP server, or mode is no longer available, the
  snapshot preserves the recorded value and reports a diagnostic. Runtime uses
  the configured provider/model fallback, omits unavailable MCP servers, and
  treats an unavailable mode as `none` without rewriting the journal.
- File and transition errors are returned as tagged domain errors suitable for
  LiveView messages and telemetry. Raw exceptions and file contents are not
  exposed to the browser.

## Testing Decisions

- Tests assert external behavior: snapshots, operation results, emitted runtime
  state, output artifacts, source non-mutation, and user-visible LiveView state.
  They do not assert private reducer helper structure.
- The primary pure seam is the journal reducer in `sigma_session`. Table-driven
  fixtures cover linear logs, multiple branches, state changes on sibling
  branches, multiple compactions, unknown entries, duplicates, missing parents,
  and torn writes.
- Existing log, branching, compaction, JSONL storage, and session-file tests are
  prior art and remain compatibility coverage.
- The primary lifecycle seam is `Sigma.Agent.Runtime` with a fake provider and
  fake tools. Tests cover idle switch, busy rejection, flush ordering, failed
  target rollback, fork isolation, crash rebuild, and restored settings.
- A storage test double records byte ranges so listing tests prove the prefix and
  tail budgets and fail if full replay is invoked.
- Dump/export tests hash or compare the source JSONL and sidecar before and after
  the operation and assert byte-for-byte non-mutation.
- Relocation tests cover explicit repository path changes, orphan summaries,
  successful adoption, target conflicts, rollback, and worktree metadata.
- LiveView tests cover visible busy errors, successful navigation after switch or
  fork, restored model selection, and reconnect after runtime rebuild.
- Stage verification remains scoped to `sigma_session`, `sigma_agent`, and the
  affected `sigma_web` LiveViews. Unrelated failures are recorded without widening
  this PRD.

## Acceptance Criteria

1. Replaying a branched journal with a selected leaf returns only that leaf's
   ancestry and state.
2. Model, reasoning, service tier, MCP selection, and mode changes restore from
   the active branch; sibling branch changes have no effect.
3. A linear existing v3 session replays the same user and assistant messages as
   before this work.
4. An existing model selection stored only in `.meta.json` restores until a
   journal `model_change` entry supersedes it.
5. A valid trailing torn line is skipped with diagnostics and earlier entries
   still replay.
6. Duplicate IDs and broken parent links are diagnosed deterministically without
   creating atoms from untrusted keys.
7. Forking at a message creates one independent valid session, leaves the source
   byte-for-byte unchanged, and leaves no partial target on failure.
8. Switching an idle session flushes accepted state and restores the target's
   messages and behavioral settings.
9. Switching or forking a busy session returns `session_busy` and does not change
   either session.
10. A corrupt or missing switch target leaves the previous session running with
    its prior persistence target and state.
11. Session listing reads no more than the configured prefix and tail budgets and
    returns partial summaries when fields are unavailable.
12. A session whose recorded cwd is missing remains listable and can be adopted
    into a validated replacement cwd.
13. JSON dump and Markdown export leave JSONL and sidecar bytes unchanged.
14. Existing session hooks, permission interception, compaction, and runtime crash
    recovery continue to pass their scoped behavior tests.
15. The stage ends with a decision-log entry describing the contracts adopted
    from oh-my-pi and the OTP-native choices Sigma made differently.

## Delivery Slices

1. **Journal replay core**: entry validation, index, active-path reduction,
   snapshot contract, and v3 fixtures. No UI changes.
2. **Replayable behavioral state**: journal entry writers plus sidecar fallback
   for existing model and session settings.
3. **Session operations**: serialized resume, switch, fork, compact, dump, and
   export with non-mutation and rollback tests.
4. **Bounded listing and relocation**: session summaries, orphan visibility, and
   explicit adoption into a replacement cwd.
5. **LiveView integration**: operation-driven switching/forking, visible errors,
   restored controls, and the stage decision log.

Each slice must be independently shippable. Later slices may depend on earlier
contracts but must not require provider normalization or tool-runtime hardening.

## Out of Scope

- Provider stream normalization or new provider families.
- Tool concurrency groups, cancellation metadata, or partial-result redesign.
- Context import expansion, sticky rules, or path-scoped rules.
- Advisor, subagent, collaboration, memory, LSP, DAP, and native runtime work.
- Replacing JSONL with a database or remote session service.
- Cross-device synchronization or concurrent multi-writer collaboration.
- Automatic full-filesystem discovery of moved repositories.
- Implicit cancellation of active turns during switch or fork.
- HTML, PDF, or styled web export; v2 export is Markdown only.
- A branch-tree visualization or general history editor.
- Removing all structural `.meta.json` fields.
- Eager rewriting of every existing session.

## Further Notes

- oh-my-pi is a contract reference, not a module-layout template. Sigma should use
  pure reducers, storage boundaries, GenServer serialization, supervised runtime
  processes, and LiveView events that fit the current umbrella.
- The first implementation change after this PRD is the journal replay core. It
  should not include LiveView work or behavioral-state writers.
- The existing `/settings/hooks` documentation request remains separate from this
  stage and should be delivered independently.
