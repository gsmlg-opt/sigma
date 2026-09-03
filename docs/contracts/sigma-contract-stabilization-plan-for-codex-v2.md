# Sigma Contract Stabilization and Pi-Parity Improvement Plan

- Status: **Historical / Complete** (execution finished; see [contract-stabilization-v2-execution-report.md](contract-stabilization-v2-execution-report.md))
- Kept for: work-order mapping and acceptance criteria reference

> Execution document for Codex
>
> Repository: `https://github.com/gsmlg-opt/sigma`
>
> Reviewed baseline: `03a8ca0e8e320b1ef1a608027505a81ca25ab664`
>
> Review date: 2026-09-01
>
> Permission baseline: Sigma intentionally runs with `allow-all` permissions by default, equivalent to a Codex-style YOLO mode. `ask` and `deny` are explicit opt-in policies.

## 1. Mission

Stabilize Sigma as an OTP-native, web-first coding-agent runtime that preserves the durable behavioral contracts users expect from Pi-style agents.

The immediate goal is **not** to add more tools or reproduce the entire Pi/oh-my-pi feature surface. The immediate goal is to make the existing runtime reliable, deterministic, safe, and callable outside LiveView.

The target architecture is:

```text
LiveView / JSONL CLI / RPC / SDK
                 │
          Sigma.Protocol
                 │
      Session command boundary
                 │
   ┌─────────────┼──────────────┐
   │             │              │
Turn control  Journal writer  Tool scheduler
   │             │              │
Provider      JSONL journal   Tools / MCP
normalizer                   permissions/hooks
```

Sigma should remain:

- Elixir/OTP native.
- An umbrella application.
- Append-only JSONL based for session persistence.
- Phoenix LiveView based for its primary UI.
- Compatible with existing v3 session files and current release layouts.

## 2. Non-goals

Do not include the following in the stabilization milestone:

- Replacing JSONL with PostgreSQL, SQLite, or another database.
- Porting the upstream TypeScript package graph.
- Replacing LiveView with a terminal UI.
- Adding dozens of providers before provider normalization is complete.
- Adding LSP, AST editing, subagents, advisor, collaboration, memory consolidation, DAP, GitHub tools, or web search before the core contracts are stable.
- Redesigning DuskMoon UI components.
- Introducing a remote authentication system. Sigma may continue to rely on local binding or an external reverse proxy for deployment security.
- Combining all work into one large PR.

## 3. Current implementation status

### 3.1 Keep and build upon

The following foundations are already present and should not be rewritten from scratch:

- Eight umbrella applications with meaningful boundaries: `sigma_ai`, `sigma_protocol`, `sigma_agent`, `sigma_session`, `sigma_coding`, `sigma_tools`, `sigma_logs`, and `sigma_web`.
- Repository- and session-scoped OTP processes.
- Streaming Anthropic and OpenAI-compatible providers.
- Multi-round model/tool execution.
- MCP integration, sampling, elicitation, and tool discovery.
- Hook discovery and execution.
- A permission interceptor and permission-policy process.
- Append-only JSONL files.
- Pure journal indexing/replay through `Sigma.Session.Journal`, `Journal.Index`, and `Snapshot`.
- Branch-aware replay and restoration of model, reasoning, service-tier, MCP, mode, compaction, and branch-summary state.
- Session create, rename, delete, and fork scaffolding with no-overwrite file publication.
- Built-in `ask`, `read`, `write`, `bash`, `edit`, `search`, and `find` tools.
- Hashline edit support through a Rust NIF.
- LiveView session/repository management and installable releases.

### 3.2 Verified blockers in the reviewed baseline

| Area | Current behavior | Required correction |
| --- | --- | --- |
| Build | `main` CI and Test fail after dependency patching | Restore a green, reproducible clean build |
| Dependency management | `Mix.Tasks.Deps.Patch` mutates code under `deps/` with `String.replace/3` | Use a fixed dependency revision/release; do not mutate installed dependencies |
| Active turn | A prompt submitted while a turn is running is silently ignored | Explicitly accept, queue, steer, or reject every prompt |
| Cancellation | Turn cancellation uses `Task.shutdown(..., :brutal_kill)` | Add cooperative provider/tool cancellation with an explicit terminal state |
| Permissions | The runtime starts in `default: :allow, rules: %{}`, which is the intended default, but optional configured overrides are not fully wired | Preserve allow-all as the product default; load explicit `ask`/`deny` overrides and wire approval only when requested |
| Permission UI | `PermissionInterceptor` supports `permission_request_fn`, but the runtime does not supply one | Reuse the existing LiveView approval UI through a real callback boundary |
| Persistence | `SessionProcess.record_event/3` invokes persistence and ignores the return value | Durable state must advance only after journal append acknowledgement |
| Append cost | `Sigma.Session.Log` rereads the entire JSONL file to find the active leaf for normal messages and compaction | Maintain active-leaf state in a single session writer |
| Fork format | Current fork copies the old header and appends a new header after copied entries | New forks must contain one fresh header followed by the selected branch |
| Fork lookup | An unknown message ID can fall through to an incorrect prefix count | Return a typed `message_not_found` error |
| Session operations | Switch, dump, export, bounded listing, and relocation/adoption are incomplete | Finish the existing Session Operations V2 contract |
| Tool scheduling | Batch execution is globally parallel or sequential; parallel mode waits forever | Add metadata, bounded concurrency, deadlines, resource exclusion, and cancellation |
| Tool results | Unknown result shapes can be converted to text and treated as successful | Strictly normalize all results and fail closed |
| Provider contract | `Sigma.Ai.Provider` exposes only `stream/1` | Add normalized events, capabilities, errors, usage, stop reasons, and cancellation |
| External control | LiveView is effectively the only product client | Add a versioned command/event protocol and headless runtime |

[`docs/archive/PLAN.md`](../archive/PLAN.md) is historical documentation, not the implementation source of truth. When it conflicts with current code or tests, follow current code and repair the missing behavior.

## 4. Architectural decisions

### 4.1 Separate durable events from transient events

Transient events may be published immediately and do not enter the journal:

- Provider text/thinking deltas.
- Partial tool output.
- UI loading state.
- Debug-log events.

Durable events require successful journal append before canonical runtime state advances:

- Final user messages.
- Final assistant messages.
- Tool-result messages.
- Model/provider changes.
- Reasoning-level changes.
- Service-tier changes.
- MCP selection changes.
- Mode changes.
- Compaction entries.
- Branch summaries.

A failed durable append must stop the affected transition and return a typed error. It must not be silently logged while in-memory state continues.

### 4.2 Keep the pure/effect boundary

Use pure functions for:

- Provider-event normalization.
- Journal replay.
- Tool-result normalization.
- Prompt-admission decisions.
- Turn state transitions.
- Permission configuration parsing.

Use supervised processes only for:

- Provider transport.
- Session writer serialization.
- Tool execution.
- Turn lifecycle and cancellation.
- Runtime subscriptions.

### 4.3 Permission model: allow-all by default

Sigma uses a Codex-style YOLO permission baseline:

- A fresh installation defaults to `allow` for all built-in and MCP tools.
- Missing or legacy permission configuration resolves to `default: :allow, rules: %{}`.
- Unknown or newly discovered tools are allowed unless the user explicitly adds an `ask` or `deny` override.
- `ask` and `deny` remain supported as opt-in policy controls for users who want a guarded mode.
- An explicitly configured `ask` decision requires an interactive or headless approval resolver. If no resolver exists, that specific tool call returns `approval_required` and does not execute.
- Do not silently migrate existing users from allow-all to ask-by-default.
- Do not describe the allow-all default as a defect or incomplete safety policy. It is an intentional product contract.

### 4.4 Reserve integration hot spots

The following files are high-conflict integration points and must not be edited concurrently by multiple parallel Codex workers:

- `apps/sigma_agent/lib/sigma_agent.ex`
- `apps/sigma_agent/lib/sigma_agent/session_supervisor.ex`
- `apps/sigma_agent/lib/sigma_agent/session_process.ex`
- `apps/sigma_web/lib/sigma_web/live/session_live.ex`

Parallel workers should implement isolated contracts in their owning applications first. One integration worker should then connect those contracts through the files above.

## 5. Execution waves and dependency graph

```text
S0  Restore green baseline
 │
 ├────────────┬────────────┬────────────┬────────────┐
 │            │            │            │            │
S1 core     S3 config    S4 core      S5 core      S7 schema
Session     Permission   Tool runtime Provider      Protocol
writer                  contracts    contracts     contracts
 │            │            │            │            │
 └──────┬─────┴─────┬──────┴─────┬──────┴────────────┘
        │           │            │
       S2          S6           S7 integration
 Session ops   Active-turn       Headless/RPC
 completion     control
        └───────────┴────────────┘
                    │
                   S8
          Context/rule discovery
                    │
                   S9
        Extension SDK and new tools
```

### Parallel work after S0

The following tasks can run in separate worktrees after the baseline is green:

- Provider normalization core in `sigma_ai`.
- Tool metadata/result/scheduler core in `sigma_coding` and `sigma_tools`.
- Permission configuration parsing and settings persistence in `sigma_session`.
- Protocol command/event schemas in `sigma_protocol`.
- Session writer core in new `sigma_session` modules.

Do not run two independent workers that both modify `Sigma.Agent`, `SessionSupervisor`, or `SessionLive`.

## 6. Work orders

---

## S0 — Restore a trusted green baseline

**Priority:** P0
**Blocks:** all other work

### Goal

Make a clean checkout reproducibly compile, test, build assets, and produce a release without mutating installed dependency source code.

### Required work

1. Reproduce the current failure from a clean checkout without relying on restored `_build`, `deps`, or `node_modules` caches.
2. Remove `Mix.Tasks.Deps.Patch` from normal setup/build/release aliases.
3. Replace dependency source mutation with one of the following, in priority order:
   - A released DuskMoon version containing the required fixes.
   - A Git dependency pinned to a reviewed commit containing the fixes.
   - A maintained fork pinned to a reviewed commit.
4. Do not add another unguarded `String.replace/3` patch to `deps/`.
5. If an emergency compatibility patch is temporarily unavoidable:
   - Restrict it to one exact dependency version and source hash.
   - Verify every expected match count.
   - Fail before writing if any match is missing or duplicated.
   - Compile and test the patched fixture in isolation.
   - Open a follow-up issue to remove it.
6. Split CI into independently observable checks:
   - Elixir/Rust formatting and compilation.
   - Core ExUnit tests.
   - Web asset setup/build.
   - Release smoke test.
7. Ensure the core ExUnit job does not become invisible merely because the asset installer fails.
8. Add a release verification job that runs against the exact release SHA before the build matrix publishes artifacts.
9. Run at least one installed-release smoke scenario that exercises the agent/session seam with a fake provider, not only `GET /`.
10. Update cache keys so incompatible dependency or toolchain state is not restored across lockfile revisions.

### Acceptance criteria

- `mix deps.get` succeeds from a clean checkout.
- `mix compile --warnings-as-errors` succeeds.
- `mix test` succeeds without real provider credentials.
- `mix assets.setup` succeeds.
- `mix assets.build` succeeds.
- Rust formatting, Clippy, and tests succeed.
- No setup/build/release command modifies files under `deps/`.
- CI and Test are green on the same commit.
- The release workflow verifies the same commit before publishing.
- A release archive starts and completes a fake-provider agent smoke test.

### Out of scope

- General dependency modernization unrelated to the failing path.
- UI redesign.
- Agent behavior changes.

---

## S1 — Add a durable session writer and commit boundary

**Priority:** P0
**Depends on:** S0

### Goal

Make the JSONL journal the actual commit boundary for durable session state and eliminate full-journal reads on every append.

### Required design

Add a per-session writer under the existing session supervision subtree. Suggested ownership:

```text
Sigma.Session.EntryEncoder
Sigma.Session.Writer
```

The writer should own:

- Storage target.
- Storage module/test double.
- Whether a valid session header exists.
- Current active leaf ID.
- Accepted journal length or sequence.
- Last append result.

### Required work

1. Move event-to-entry conversion out of private helpers in `Sigma.Session.Log` into a pure encoder.
2. Make parent assignment explicit: the writer supplies the current active leaf to the encoder.
3. Initialize writer state once from `Sigma.Session.Log.snapshot/3`.
4. Serialize all durable appends through the writer.
5. Update `active_leaf_id` only after storage returns success.
6. Return typed results such as:
   - `{:ok, entry_id}`
   - `:ignored`
   - `{:error, {:storage_append_failed, reason}}`
   - `{:error, {:invalid_journal, diagnostics}}`
7. Separate durable event persistence from transient event broadcast.
8. Remove the current path where `SessionProcess` invokes a persistence callback, ignores its result, and then updates canonical state.
9. Ensure the Agent stops or rolls back the affected transition after a durable append failure.
10. Preserve streaming deltas in the UI without journaling every delta.
11. Keep compatibility facades where existing callers still use `Sigma.Session.Log`.
12. Add telemetry for append duration, success/failure, entry type, and session ID; do not log message contents.

### Required tests

Use a storage test double to cover:

- Successful header and message append.
- Append failure before state update.
- Writer restart and active-leaf reconstruction.
- Two concurrent append requests serialized in mailbox order.
- Compaction parent assignment.
- Behavioral-state append parent assignment.
- Transient events causing no writes.
- No full `read/1` call after writer initialization during ordinary appends.

### Acceptance criteria

- In-memory canonical messages never include a durable message whose append failed.
- A subsequent replay observes every acknowledged append.
- Ordinary message/tool-result/compaction appends do not reread the entire journal.
- A writer restart reconstructs the same active leaf deterministically.
- Existing linear v3 sessions continue to replay.

### Out of scope

- Remote replication.
- `fsync`-level power-loss guarantees.
- Multi-writer collaboration.

---

## S2 — Complete Session Journal and Session Operations V2

**Priority:** P0/P1
**Depends on:** S0 and S1 core

Implement this as three PRs rather than one large change.

### S2A — Correct fork and journal mutation semantics

1. Create a new fork with exactly one fresh session header at the beginning.
2. Copy only the selected valid root-to-leaf branch, excluding all source session headers.
3. Preserve unknown logical entries on the selected branch.
4. Preserve branch entry IDs and parent relationships unless a documented migration requires rewriting them.
5. Resolve a requested message ID to its containing journal entry.
6. Return `{:error, :message_not_found}` for unknown message IDs.
7. Refuse mutation when the selected active branch is ambiguous or mutation-blocking diagnostics exist.
8. Keep source JSONL and sidecar bytes unchanged.
9. Leave no target JSONL, sidecar, or temporary file after failure.
10. Append new compaction entries through the session writer using `firstKeptEntryId`; continue accepting legacy `firstKeptId` during replay.

### S2B — Runtime-owned switch and fork operations

1. Add an explicit operation boundary in `sigma_agent`; do not implement lifecycle rules directly in LiveView handlers.
2. Serialize operations for a running session.
3. Reject switch and fork with `session_busy` while any of these are active:
   - Provider stream.
   - Tool execution.
   - Permission request.
   - MCP elicitation.
   - Session hook that must complete before transition.
4. Flush accepted durable events before an idle switch or fork.
5. Validate the target snapshot before replacing the current persistence target.
6. Roll back completely after a failed switch.
7. Preserve restored model/provider/reasoning/service-tier/MCP/mode state.
8. Return tagged domain errors suitable for LiveView and RPC clients.

### S2C — Dump, export, bounded listing, and relocation

1. Add a read-only JSON dump operation containing:
   - Header.
   - Valid logical entries.
   - Selected active leaf.
   - Diagnostics.
   - Unknown entries.
2. Add a read-only Markdown export of the active branch.
3. Capture an accepted journal length at operation start so dump/export ignore later concurrent appends.
4. Publish output atomically and do not overwrite unless replacement is explicit.
5. Implement session summaries using bounded prefix/tail reads; do not call full replay for listing.
6. Include session ID, title/fallback, recorded cwd, update time, model, latest user preview when available, and diagnostic state.
7. Keep sessions listable when their recorded cwd is missing.
8. Add explicit adoption/relocation into a validated replacement cwd.
9. Move JSONL and structural sidecar metadata transactionally with rollback.

### Acceptance criteria

- All acceptance criteria in `docs/contracts/session-journal-and-operations-v2-prd.md` pass.
- New forks no longer use the legacy double-header layout.
- Busy operations return visible errors and mutate nothing.
- Dump/export are byte-for-byte non-mutating to source files.
- Listing enforces its configured read budget in tests.

---

## S3 — Wire optional permission policy overrides end-to-end

**Priority:** P1
**Depends on:** S0
**Core config work may run in parallel with S1, S4, and S5.**

### Goal

Preserve Sigma's intentional Codex-style YOLO default while making explicit `ask` and `deny` overrides work correctly through configuration, hooks, LiveView, headless clients, and session supervision.

### Required work

1. Define a documented permission configuration in `settings.json`. The default configuration is allow-all:

```json
{
  "permissions": {
    "default": "allow",
    "rules": {}
  }
}
```

A user may explicitly opt into guarded behavior with overrides such as:

```json
{
  "permissions": {
    "default": "allow",
    "rules": {
      "write": "ask",
      "edit": "ask",
      "bash": "ask",
      "dangerous_mcp_tool": "deny"
    }
  }
}
```

2. Parse only the closed set `allow | ask | deny`; never create atoms from arbitrary input.
3. Add `ConfigManager` read/update APIs with backward-compatible allow-all defaults. Missing or malformed optional configuration must not silently change the default to `ask`.
4. Replace the hardcoded policy construction in `SessionSupervisor` with loaded/passed policy values while preserving the effective fallback `default: :allow, rules: %{}`.
5. Use `default: :allow` for unknown tools, including newly discovered MCP tools, unless explicitly overridden.
6. Supply `permission_request_fn` in the real interactive dispatcher path so explicitly configured `ask` rules can be resolved.
7. Reuse the current LiveView approval interaction rather than creating a second modal system.
8. Define first-stage responses for an explicit `ask` decision:
   - Allow once.
   - Deny once.
   - Optionally allow for the current session if the existing UI already supports it cleanly.
9. Enforce one explicit hook/approval order:
   - Policy decision.
   - `PermissionRequest` hooks for the explicit `ask` branch.
   - Interactive approval for any still-unresolved `ask` decision.
   - `PreToolUse` hooks on the final approved and possibly patched arguments.
   - Tool execution.
   The `ask` path must not bypass `PreToolUse` after approval.
10. In headless mode, an explicitly configured `ask` decision without an approval handler must return a typed `approval_required` error and must not execute the tool. This rule applies only to `ask`; it must not turn the default allow-all mode into guarded mode.
11. Surface permission state in debug logs and telemetry without leaking sensitive tool parameters.
12. Document the two supported operating styles:
   - **YOLO/default:** `default: allow`, no approval prompts.
   - **Guarded/opt-in:** selected rules use `ask` or `deny`.

### Required tests

- Missing permission configuration resolves to `default: :allow, rules: %{}`.
- Valid and invalid permission values are parsed without dynamic atom creation.
- Built-in read/write/edit/bash tools execute without approval under the default policy.
- Unknown MCP tools execute under the default policy.
- Explicit `ask` rules request approval.
- Explicit `deny` rules never execute.
- An explicit `ask` rule without a request handler returns `approval_required`.
- `PermissionRequest` and `PreToolUse` hooks retain their order for explicit `ask` decisions.
- Session-specific policy processes do not leak overrides across sessions.
- LiveView allow/deny resolves exactly one waiting tool call.

### Acceptance criteria

- A fresh installation and legacy settings without a permission section are allow-all.
- Unknown tools and newly discovered MCP tools are allowed by default.
- The configured policy and overrides are visible in the process started for each session.
- The default path produces no approval prompt.
- Explicit `ask` and `deny` overrides work through the production path.
- No tool executes after an explicit deny or unresolved explicit approval request.

---

## S4 — Tool Runtime V2

**Priority:** P1
**Depends on:** S0
**May run in parallel with S1, S3 config work, and S5.**

### Goal

Replace the current global parallel/sequential switch with a bounded, cancellable, metadata-driven execution contract.

### Required contract

Introduce explicit domain types or equivalent maps/structs for:

```text
ToolMetadata
ToolExecution
ToolResult
ToolError
ToolUpdate
```

Each tool must declare or derive:

- Effect class: `read | write | process | network | destructive`.
- Concurrency mode: `shared | sequential | exclusive`.
- Interruptibility.
- Default deadline.
- Approval tier.
- Discoverability.
- User-facing render hint.
- Optional resource keys derived from normalized arguments.

`approval tier` is descriptive metadata only. It must not override the default allow-all policy unless an explicit guarded policy maps that tool or tier to `ask` or `deny`.

### Required scheduling behavior

1. Read-only tools may run concurrently within a configurable `max_parallel` limit.
2. Write/edit operations targeting the same canonical path must not overlap.
3. Process and stateful tools should be sequential or exclusive by default.
4. Unknown MCP tools should default to conservative metadata.
5. Replace `Task.yield_many(:infinity)` with explicit per-tool and batch deadlines.
6. Use non-linking supervised tasks where a tool crash should become a result rather than kill the turn runner.
7. Propagate a cooperative cancellation token or control reference to interruptible tools.
8. Allow non-interruptible cleanup to finish within a bounded shutdown budget.
9. Preserve stable result ordering corresponding to the assistant tool-call order.
10. Emit partial updates through a normalized callback/event contract.
11. Canonicalize file resource keys using the same symlink-safe path logic as tool access checks.

### Strict result normalization

Only accepted success/error structures may reenter the agent loop.

- Empty, malformed, thrown, exited, or unknown results become explicit `ToolError` values.
- Do not convert an unknown result to `inspect(value)` and mark it successful.
- Tool error content sent to the model must be bounded and sanitized.
- Full raw command output may be kept in debug logs only within configured size limits.

### Required tests

- Parallel read-only execution respects `max_parallel`.
- Two edits of one file are serialized.
- Independent reads and writes follow declared resource constraints.
- Tool deadline returns a timeout result and terminates interruptible work.
- Cancellation during Bash terminates the process/port and returns cancelled.
- A crashing tool does not crash the Agent process.
- Malformed results fail closed.
- Partial output reaches subscribers in order.
- Permission denial occurs before scheduler execution.
- Hooks still receive normalized pre/post payloads.

### Acceptance criteria

- No tool can wait forever without an explicit infinite deadline configured by the caller.
- Side-effecting tools do not run concurrently unless their metadata explicitly permits it.
- All tool results entering the agent loop satisfy one stable contract.
- Cancellation has one observable terminal outcome.

### Out of scope

- Adding the planned `job`, `todo`, `task`, LSP, AST, web-search, or GitHub tools.

---

## S5 — Provider Normalization V1

**Priority:** P1
**Depends on:** S0
**May run in parallel with S1, S3 config work, and S4.**

### Goal

Make Anthropic and OpenAI-compatible transports produce the same agent-facing event and error contract.

### Required domain contract

Add explicit types or equivalent structs for:

```text
ProviderRequest
ProviderCapabilities
ProviderModel
ProviderEvent
ProviderUsage
ProviderStopReason
ProviderError
ProviderAuth
```

The normalized event lifecycle must cover:

```text
response.started
content.text.delta
content.thinking.delta
tool_call.started
tool_call.arguments.delta
tool_call.completed
usage.updated
response.completed
response.failed
```

### Required work

1. Keep endpoint-specific parsing inside provider adapters.
2. Remove provider-specific tuple assumptions from the eventual turn core.
3. Normalize stop reasons into a closed domain set while retaining the raw provider reason for diagnostics.
4. Normalize token usage and cache usage without inventing unavailable values.
5. Classify errors at least as:
   - Authentication.
   - Rate limit.
   - Invalid request.
   - Context limit.
   - Timeout.
   - Transport unavailable.
   - Provider server failure.
   - Malformed stream.
   - Cancelled.
6. Include retryability and optional retry-after metadata.
7. Validate finalized tool-call arguments before emitting `tool_call.completed`.
8. Partial argument deltas may update the UI but must never be executed.
9. Describe model capabilities such as tools, thinking, image input, context window, and supported options.
10. Add cooperative stream cancellation support.
11. Retain a small compatibility adapter for existing `stream/1` callers during migration, then remove it after all callers use the normalized protocol.
12. Do not add more providers in this work order.

### Conformance tests

Use deterministic recorded fixtures and fake transports. Equivalent Anthropic and OpenAI-compatible responses must produce equivalent normalized event sequences for:

- Text-only completion.
- Thinking plus text.
- One tool call.
- Multiple tool calls.
- Incremental JSON arguments.
- Usage and cache usage.
- Context-limit failure.
- Rate limit with retry metadata.
- Transport timeout.
- Cancellation.
- Malformed/truncated stream.
- Image-capable request serialization.

### Acceptance criteria

- The Agent consumes one provider-neutral event contract.
- Equivalent provider behavior generates equivalent normalized events.
- UI and RPC clients receive structured terminal errors rather than raw exceptions.
- No partial tool arguments can execute.

---

## S6 — Active Turn Control: steering, follow-up, and cancellation

**Priority:** P0/P1
**Depends on:** S1 durable boundary, S4 cancellation contract, and S5 normalized provider events

### Goal

Ensure every submitted user message receives an explicit admission result and no message disappears while a turn is active.

### Required state model

Use an explicit state machine such as:

```text
idle
streaming_provider
running_tools
waiting_permission
waiting_elicitation
cancelling
completed
failed
cancelled
```

Maintain two queues:

- `steering_queue`: consumed at the next safe agent-loop boundary.
- `follow_up_queue`: starts a new turn after the active turn completes.

### Required command results

Replace fire-and-forget semantics for prompt admission with explicit results:

```text
accepted
queued_as_steering
queued_as_follow_up
rejected
```

Every result should include a stable message/turn identifier where applicable.

### Safe-boundary semantics

1. Steering does not splice arbitrary text into the middle of a provider SSE frame.
2. Steering is consumed after the current provider response or current tool batch reaches a consistent boundary.
3. A steering message becomes a durable user message before it is added to model context.
4. Follow-up starts only after the active turn reaches a terminal state.
5. Queue order is FIFO within each queue.
6. The runtime records when a queued message is accepted, consumed, cancelled, or rejected.
7. On cancellation:
   - Stop provider transport cooperatively.
   - Cancel interruptible tools.
   - Wait only for bounded non-interruptible cleanup.
   - Record one terminal `cancelled` outcome.
   - Preserve unconsumed queued messages unless the user explicitly clears them.
8. Repeated cancel calls are idempotent.
9. Session switch/fork remains rejected until the turn reaches a terminal state.
10. LiveView must show queued state instead of disabling input with no alternative.

### Implementation guidance

Avoid increasing the responsibility of the current monolithic `Sigma.Agent` module. Extract pure/control modules first, for example:

```text
Sigma.Agent.TurnState
Sigma.Agent.PromptQueue
Sigma.Agent.TurnRunner
Sigma.Agent.StreamReducer
```

`Sigma.Agent` should remain the supervised lifecycle shell and command mailbox.

### Required tests

Use a fake provider and fake tools to cover:

- Initial prompt accepted.
- Steering during provider streaming.
- Steering during tool execution.
- Multiple steering messages preserve order.
- Follow-up starts after completion.
- Prompt admission never silently returns nothing.
- Cancellation during stream.
- Cancellation during Bash.
- Cancellation while waiting for permission.
- Unconsumed follow-up survives cancellation.
- Journal append failure rejects consumption of a queued message.
- Agent remains usable after failure/cancellation.

### Acceptance criteria

- The old “turn in flight — ignore” branch no longer exists.
- Every prompt has an observable admission and terminal lifecycle.
- Cancellation reaches provider and tools without killing the Agent process.
- No duplicate terminal events are emitted.

---

## S7 — Sigma Protocol and headless runtime

**Priority:** P1
**Depends on:** stable contracts from S1, S3, S4, S5, and S6

Implement this in two stages.

### S7A — Protocol schema

In `sigma_protocol`, define a versioned, transport-neutral envelope with:

- Protocol version.
- Request/event ID.
- Session ID.
- Optional turn ID.
- Timestamp.
- Command/event type.
- Typed payload.
- Structured error.

Initial commands:

```text
session.create
session.resume
session.status
session.switch
session.fork
session.dump
session.export
prompt.submit
prompt.steer
prompt.follow_up
turn.cancel
permission.resolve
mcp.elicitation.resolve
model.select
subscription.attach
subscription.detach
```

Initial events:

```text
session.snapshot
prompt.admitted
turn.started
message.started
message.delta
message.completed
tool.started
tool.update
tool.completed
permission.required
turn.completed
turn.failed
turn.cancelled
session.error
```

The protocol must not expose PIDs, Task references, raw exceptions, or internal OTP names.

### S7B — Runtime adapters

Add at least:

1. JSON Lines over stdio for automation.
2. A WebSocket endpoint for remote UI/client control.
3. A direct Elixir API for Synapsis/Samgita integration.

Requirements:

- All adapters call the same session command boundary.
- LiveView should gradually use that boundary too, even if it does not serialize through JSON internally.
- Client disconnect must not cancel a running turn unless explicitly requested.
- A reconnecting client can request the current session snapshot and resume event consumption.
- Slow subscribers must not block the Agent or journal writer.
- Event payloads must be bounded.
- Headless approval requests return `approval_required` when no resolver is attached.

### Required tests

- Protocol encoding/decoding round trips.
- Unknown protocol version rejected cleanly.
- Stdio session with fake provider and safe tool.
- WebSocket attach, prompt, stream, cancel, reconnect.
- Two subscribers receive the same ordered terminal events.
- Disconnect does not stop the turn.
- Permission response resolves the correct request only.
- No internal process terms are serialized.

### Acceptance criteria

- A complete coding-agent turn can be driven without LiveView.
- LiveView and headless clients observe the same domain events.
- Synapsis or Samgita can integrate through a stable public API instead of calling internal GenServers.

---

## S8 — Context and Rule Discovery V2

**Priority:** P2
**Depends on:** S0; may be developed after the P0/P1 stabilization gate

### Goal

Extend the existing root-to-workdir `AGENTS.md`/`CLAUDE.md` walk without changing its current precedence unexpectedly.

### Required work

- Add import expansion with cycle detection and maximum depth.
- Preserve source provenance for every context section.
- Add sticky rules and path-scoped rules.
- Define deterministic composition order for global prompt, project files, imported files, skills, and runtime context.
- Report missing, disabled, unreadable, or cyclic imports as diagnostics.
- Avoid arbitrary atom creation and unbounded file reads.
- Add an explicit reload operation; do not silently change the active turn context midway through a provider request.
- Expose a context preview/trace for debugging.

### Acceptance criteria

- Existing repositories without new syntax receive the same context ordering as before.
- Imports and path scopes are deterministic and testable.
- Context diagnostics are visible without blocking unrelated valid rules.

---

## S9 — Deferred extension and feature expansion

**Priority:** P3
**Depends on:** S7

Only begin after the stabilization definition of done is met.

Potential follow-up work:

- BEAM-native extension behavior for tools, commands, providers, context sources, event handlers, and render hints.
- Additional providers through the normalized provider contract.
- Planned `job`, `todo`, `task`, LSP, AST, web-search, and GitHub tools through Tool Runtime V2.
- Worktree agent pools.
- Background sessions and multi-client control.
- Samgita orchestration integration.
- Synapsis agent-runtime integration.
- Backplane provider/MCP integration.
- Distributed BEAM execution.

Do not use these features to delay or widen S0–S7.

## 7. Recommended PR sequence

Use small, independently reviewable PRs. A recommended sequence is:

1. `fix/build-green-baseline`
2. `feat/session-writer`
3. `fix/session-fork-v2`
4. `feat/provider-normalization-v1`
5. `feat/tool-runtime-v2`
6. `feat/permission-policy-config`
7. `feat/permission-runtime-integration`
8. `feat/active-turn-control`
9. `feat/session-runtime-operations`
10. `feat/session-export-listing-relocation`
11. `feat/sigma-protocol-v1`
12. `feat/headless-runtime`
13. `feat/context-rules-v2`

Provider, tool-runtime, permission-config, and protocol-schema core PRs may be prepared in parallel after PR 1. Integration PRs must be rebased on the latest accepted contracts and handled by one owner for the hot files.

## 8. Test strategy

### 8.1 Test doubles

Create reusable deterministic test components:

- Fake provider with scripted normalized events.
- Blocking provider for steering/cancellation tests.
- Fake tools for success, partial update, crash, timeout, cancellation, and malformed output.
- Failing/recording session storage.
- Permission resolver test process.
- Slow/disconnecting event subscriber.

No core behavior test should require a paid API or network connection.

### 8.2 Required validation for every PR

Run the smallest relevant tests first, followed by the full gate:

```bash
mix format --check-formatted
mix compile --warnings-as-errors
mix test <affected app test paths>
mix test
cargo fmt --manifest-path apps/sigma_tools/native/sigma_tools_hashline/Cargo.toml -- --check
cargo clippy --manifest-path apps/sigma_tools/native/sigma_tools_hashline/Cargo.toml --all-targets -- -D warnings
cargo test --manifest-path apps/sigma_tools/native/sigma_tools_hashline/Cargo.toml
mix assets.setup
mix assets.build
```

Release-affecting changes must also run the installed-release smoke test.

### 8.3 Behavioral regression matrix

Before declaring S7 complete, the suite must cover:

- Text-only turn.
- Thinking stream.
- Single and multiple tool calls.
- Provider failure and retry metadata.
- Tool timeout and crash.
- Permission allow-all default plus explicit ask/deny overrides.
- MCP tool approval under an explicit `ask` override.
- Steering and follow-up.
- Cancellation in every active state.
- Journal append failure.
- Resume after process restart.
- Fork at a message.
- Busy switch/fork rejection.
- Dump/export non-mutation.
- Missing cwd listing and adoption.
- Stdio and WebSocket clients.
- LiveView reconnect.

## 9. Observability requirements

Use structured telemetry around:

- Turn admission and queue depth.
- Provider request duration, terminal reason, and classified error.
- Tool queue wait, execution duration, timeout, cancellation, and result class.
- Permission decision and approval latency.
- Journal append duration/failure and active-leaf changes.
- Session operation duration and rollback.
- Subscriber lag/drop count.

Never include API credentials, authorization headers, full prompts, full tool arguments, or unrestricted command output in telemetry metadata.

The debug drawer may show richer local detail, but it must still redact credentials and enforce size limits.

## 10. Migration and compatibility requirements

- Existing v3 JSONL files remain readable without eager rewriting.
- Legacy double-header forks remain readable, but no new fork may write that format.
- Existing `.meta.json` behavioral fields remain fallback inputs until a journal entry supersedes them.
- Structural worktree metadata may remain in sidecars.
- Existing settings without a `permissions` section load the intentional allow-all default.
- Existing provider settings continue to work through compatibility adapters during Provider V1 migration.
- Protocol V1 must be explicitly versioned from its first release.
- Do not rewrite user session files merely because they are read.

## 11. Definition of done for the stabilization milestone

The stabilization milestone is complete only when all statements below are true:

1. `main` is green from a clean, uncached build.
2. Setup/build/release no longer mutates installed dependency source.
3. Release artifacts are built only after the same SHA passes verification.
4. A prompt submitted during an active turn is never silently dropped.
5. Steering and follow-up behavior are explicit and tested.
6. Cancellation propagates to provider streams and interruptible tools.
7. A durable journal append failure prevents canonical state from advancing.
8. Ordinary appends do not reread the full session journal.
9. New forks use one fresh header and one selected branch.
10. Busy switch/fork operations fail without mutation.
11. Default tool permissions are allow-all, including unknown and newly discovered MCP tools.
12. Interactive and headless approval paths block execution only when an explicit `ask` rule remains unresolved.
13. Tools have bounded scheduling, cancellation, and strict result normalization.
14. Anthropic and OpenAI-compatible adapters produce one normalized event contract.
15. A complete turn can be driven through a headless public protocol.
16. LiveView remains a client of the same domain command/event boundaries.
17. Existing v3 sessions and released installation layouts remain compatible.
18. The regression matrix passes without real external provider credentials.

## 12. Codex execution rules

For each work order:

1. Inspect current `main` before modifying code; skip or adjust tasks already implemented after the reviewed baseline.
2. Preserve `default: :allow, rules: %{}` as the permission fallback. Do not change Sigma to ask-by-default; guarded permissions are opt-in only.
3. Add failing behavioral tests before or with the implementation.
4. Keep the diff limited to the stated contract.
5. Do not solve unrelated lint, dependency, or UI issues unless they block the scoped test.
6. Do not edit generated files or installed dependencies.
7. Do not weaken tests to accommodate current behavior.
8. Prefer tagged domain errors over raw strings or exceptions across application boundaries.
9. Preserve pure reducers and isolate side effects in supervised runtime modules.
10. Update README, PRD status, and decision logs only after implementation behavior is verified.
11. End every task with a concise execution report containing:
    - Files changed.
    - Contract implemented.
    - Tests added.
    - Commands run and results.
    - Compatibility notes.
    - Known remaining work.

Stop and report rather than broadening scope when an unrelated failure is encountered. Do not claim a work order is complete without its acceptance criteria and tests.
