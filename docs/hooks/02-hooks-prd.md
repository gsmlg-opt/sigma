# ex_pi Hook System — PRD

> Product requirements for Claude Code + Codex–compatible hooks in `ex_pi`.
> `hooks.json` is a **first-class config file**, not an internal format.
> Revised after compatibility review against the Claude Code and Codex hook references.

## 0. Canonical requirement

`ex_pi` must load and execute lifecycle hooks using the same three-level shape Claude Code and Codex share — `hooks → event → matcher group → handler list` — with `hooks.json` as a first-class discovery location. The system is a **compatibility adapter** around the Claude/Codex hook contract, not an `ex_pi`-invented DSL. Runtime default profile: **`portable_codex_first`** — accept both config shapes, normalize to one internal spec, execute the safe shared command-handler subset.

## 1. Problem & motivation

Teams already run workflows steered by `hooks.json` (Codex) and `settings.json` (Claude Code): policy gates on `Bash`, formatters on `PostToolUse`, context injection on `SessionStart`, continuation enforcement on `Stop`. `ex_pi` ignores these today, so migrating silently drops the guardrails users depend on. This makes those files run unchanged.

## 2. Goals

- **G1 — Drop-in compatibility.** Unmodified `.codex/hooks.json` or `.claude/settings.json` executes with faithful stdin payloads, exit-code semantics, and decision schemas.
- **G2 — Full v1 event coverage (dispatched):** `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PermissionRequest`, `PostToolUse`, `Stop`. `PreCompact` is dispatched but observe/context-only and does not steer compaction.
- **G3 — Real steering, Claude Code parity.** Deny/modify/ask/defer tool calls, block/inject prompts, substitute or annotate tool results, force continuation on Stop.
- **G4 — Superset matching with tool aliasing.** Matchers apply to all real tools via external names (`Bash`, `Edit|Write`, `mcp__.*`), not just `Bash`.
- **G5 — Safe by default.** Trust-gated, hash-pinned project hooks; no hook can wedge or crash a turn.

## 3. Non-goals

- N1 — Native Elixir plugin/extension API.
- N2 — Integration with external services or other repos.
- N3 — Hook authoring GUI (config is hand-written JSON).
- N4 — Sandboxing beyond trust gate + timeouts (deferred).
- N5 — `SessionEnd`, `PostToolUseFailure`, `PostToolBatch`, `SubagentStart/Stop`, `FileChanged`, `CwdChanged`, `PostCompact` (deferred; require seams not yet present).

## 4. Compatibility profile

Canonical config inputs: Codex `hooks.json`; Claude `settings.json` `hooks` key; `ex_pi` `.pi/hooks.json` convenience files.

**v1 executes:** `command` handlers only.
**v1 dispatches steering for:** SessionStart, UserPromptSubmit, PreToolUse, PermissionRequest, PostToolUse, Stop.
**v1 observes only:** PreCompact.
**v1 parses but skips (with diagnostic):** `http` (until M5), `mcp_tool`, `prompt`, `agent` handler types; `async`/`asyncRewake` command hooks; plugin hooks without explicit enabled plugin roots; inline `[hooks]` TOML (until M5).

Compatibility is defined by: (1) discovery + additive merge, (2) matcher behavior, (3) stdin payload shape, (4) stdout/stderr/exit decoding, (5) outcome folding, (6) trust gating.

## 5. Functional requirements

### 5.1 Discovery
- **FR-D1** v1 loads and **accumulates** from: `~/.pi/agent/hooks.json`, `~/.codex/hooks.json`, `~/.claude/settings.json`, `<repo>/.codex/hooks.json`, `<repo>/.claude/settings.json`, `<repo>/.claude/settings.local.json`, `<repo>/.pi/hooks.json`.
- **FR-D1b** Phase-2: plugin-bundled `hooks/hooks.json` only from explicitly enabled plugin roots; inline `[hooks]` TOML.
- **FR-D2** Parse Codex JSON, Claude `settings.json` (`hooks` key) into one canonical `HookSpec`; merge-and-warn on duplicate sources in a layer.
- **FR-D3** Tag every spec with `{origin, dialect, trusted?, unsupported_reason?}`.
- **FR-D4** Project-layer specs load only when the repo is trusted; otherwise loaded-but-skipped with a surfaced notice.
- **FR-D5 (additive merge — hard requirement)** Higher-precedence layers may override scalar config but do **not** replace lower-precedence hooks. If multiple sources define matching hooks, **all** matching hooks run.
- **FR-D6 (trust hash)** Trust is recorded against the normalized hook-definition hash **plus source path**. Changing command, URL, timeout, handler type, matcher, event, or origin invalidates trust until re-approved.

### 5.2 Matching
- **FR-M1** Matcher evaluation per Claude rule: `*`/`""`/absent → match-all; only letters/digits/`_`/`|` → exact or `|`-list; any other char → regex.
- **FR-M2 (event-specific targets)**
  - PreToolUse / PostToolUse / PermissionRequest: matcher filters **external `tool_name`**.
  - SessionStart: matcher filters `source` (`startup|resume|clear|compact`).
  - PreCompact: matcher filters trigger (`manual|auto`); else match-all.
  - UserPromptSubmit, Stop: **matcher ignored**; run on every occurrence.
- **FR-M3** All real `ex_pi` tools are matchable; MCP tools keep `mcp__<server>__<tool>`.
- **FR-M4 (tool-name aliasing — hard requirement)** Matcher and stdin `tool_name` use the external name; dispatcher executes by internal name. Mapping: `bash→Bash`, `read→Read`, `write→Write`, `edit→Edit`, `grep→Grep`, `glob→Glob`, `ls→LS`, `ask_user_question→AskUserQuestion`, `url_fetch→WebFetch` (canonical; `UrlFetch` accepted alias, documented and never changed).

### 5.3 Execution
- **FR-X1** All matching hooks for an event run **concurrently**; identical command handlers (by command+args) deduplicated.
- **FR-X2** Each `command` hook receives canonical JSON on **stdin**; `cwd` = session cwd; parent env inherited.
- **FR-X3 (Option A — command-only v1)** Execute only `command` handlers. `http`, `mcp_tool`, `prompt`, `agent`, and `async` parse but skip with diagnostics. HTTP support targets M5.
- **FR-X4** Per-hook timeout: `timeout` (sec), `timeoutSec` alias. Default **600s**, **except UserPromptSubmit command default 30s**. Timeout → non-blocking error.
- **FR-X5** A crashing/timing-out hook never aborts the turn; degrades to proceed + user-visible warning.
- **FR-X6** Output strings (`additionalContext`, `systemMessage`, plain stdout) capped at 10,000 chars (overflow → file + preview), matching Claude.

### 5.4 Decision (per event)
- **FR-O1** Decode `hookSpecificOutput` (new) and `decision`/`reason` (legacy, with `approve→allow`/`block→deny` for PreToolUse), plus exit-2. Universal `continue:false` is absorbing.
- **FR-O2** Fold N outcomes order-independently; precedence `deny > defer > ask > allow` for PreToolUse; restrictive dominates generally.
- **FR-O3 PreToolUse**: `permissionDecision` allow/deny/ask/defer; `updatedInput` rewrites args; `additionalContext` injects. `defer` honored only in headless `-p` mode, else degrades to `ask`.
- **FR-O4 PostToolUse**: Codex `decision:"block"` → substitute result with feedback; Claude `decision:"block"` → feedback **alongside** original; `updatedToolOutput` (either dialect) → substitute. Cannot undo side effects.
- **FR-O5 UserPromptSubmit**: plain stdout / `additionalContext` → context; `decision:"block"` or exit-2 → block + erase prompt.
- **FR-O6 Stop**: `decision:"block"` or exit-2 → continuation as synthetic user turn, guarded by `stop_hook_active`; `continue:false` → force stop, wins.
- **FR-O7 SessionStart**: stdout / `additionalContext` → prepend developer context. No blocking.
- **FR-O8 PermissionRequest**: `decision.behavior` deny → deny request; allow (+optional `updatedInput`/`updatedPermissions`) → bypass interactive approval; no decision → normal flow. Folds with **deny dominating allow**. Sits between policy `:ask` and approval UI.
- **FR-O9 PreCompact**: dispatch before compaction; expose compaction metadata; errors non-blocking; decisions ignored in v1 except diagnostics/`statusMessage`.

### 5.5 stdin payload
- **FR-P1 common**: `session_id`, `transcript_path`, `cwd`, `hook_event_name`, `permission_mode`; `model` on SessionStart (Claude scope) and broadly tolerated.
- **FR-P2 event-specific**: SessionStart `source`; UserPromptSubmit `turn_id`,`prompt`; PreToolUse `turn_id`,`tool_name`,`tool_use_id`,`tool_input`; PermissionRequest `turn_id`,`tool_name`,`tool_input`; PostToolUse adds `tool_response`; Stop `turn_id`,`stop_hook_active`,`last_assistant_message`.

### 5.6 Observability
- **FR-T1** `:telemetry` spans per hook dispatch `{event, origin, dialect, decision}`, mirroring existing tool/permission telemetry.
- **FR-T2** Surface `statusMessage` while running and non-blocking errors to the user.

## 6. Non-functional requirements

- **NFR-1 Compatibility** — verified against a corpus of real Codex + Claude configs.
- **NFR-2 Safety** — no hook crashes/hangs/deadlocks a session; trust gate + hash enforced.
- **NFR-3 Performance** — dispatch overhead negligible vs surrounding tool/LLM latency; concurrent fan-out, handler dedup.
- **NFR-4 Purity** — Discovery (parse), Matcher, Payload, Outcome are pure and unit-tested without I/O.
- **NFR-5 Additivity** — tool-event support adds zero agent-loop changes; only lifecycle steering touches `agent.ex` (~3 sites).

## 7. Acceptance criteria

- **AC-1** `Bash` matcher hits internal `bash`; `Edit|Write` hits internal `edit`/`write`; a deny on `rm -rf` blocks the call with the hook reason — identical for `.codex/hooks.json` and `.claude/settings.json`.
- **AC-2** PreToolUse `updatedInput` rewrites a Bash command before execution.
- **AC-3** PostToolUse: Codex-block substitutes the result; Claude-block annotates alongside; `updatedToolOutput` substitutes.
- **AC-4** SessionStart matcher filters `startup|resume|clear|compact`; its context appears in the first model turn.
- **AC-5** UserPromptSubmit and Stop ignore matchers; a UserPromptSubmit block aborts the turn.
- **AC-6** PermissionRequest is normalized; deny beats allow; allow bypasses the approval prompt.
- **AC-7** Stop continuation = exactly one extra turn; second invocation with `stop_hook_active=true` terminates; `continue:false` forces stop.
- **AC-8** Two concurrent PreToolUse hooks (allow + deny) → deny, regardless of finish order.
- **AC-9** A hook exceeding its timeout (600s default; 30s for UserPromptSubmit) yields a warning and the turn proceeds.
- **AC-10** New/changed project hook is listed but skipped until trusted; changing command/timeout/source invalidates trust; untrusted-repo project hooks do not execute.
- **AC-11** `http`/`mcp_tool`/`prompt`/`agent`/`async` handlers parse but skip with a diagnostic.

## 8. Out of scope / future (M5+)

Claude/Codex corpus hardening; inline `[hooks]` TOML; HTTP handler support; plugin hooks after plugin roots exist; PreCompact/PostCompact steering; PostToolUseFailure / PostToolBatch / Subagent / SessionEnd events; per-hook sandboxing.

## 9. Milestones

1. **M1 — Pure compatibility core**: HookSpec, JSON Discovery parse, Matcher (incl. external tool-name map + event-specific targets), Payload builders, Outcome decode+fold. No runner, no I/O.
2. **M2 — Command runner + trust**: command execution, stdin JSON, timeouts, output caps, trust hash, skip-untrusted, telemetry. (Trust lands **before** tool wiring.)
3. **M3 — Tool & permission hooks**: PreToolUse, PermissionRequest, PostToolUse wired into dispatcher/interceptor. First useful shipping slice.
4. **M4 — Lifecycle steering**: SessionStart, UserPromptSubmit, Stop, `stop_hook_active`, continuation guard.
5. **M5 — Compatibility hardening**: corpus tests, inline TOML, optional HTTP, plugin hooks, PreCompact observe.
