# ex_pi Hook System — Implementation Plan

> Sequenced, code-anchored, PR-sized. Targets the current umbrella.
> Trust lands **before** tool wiring so project hooks can never execute untrusted.
> Default profile: `portable_codex_first`.

## Placement

```
apps/ex_pi_coding/lib/ex_pi_coding/hooks/
  hooks.ex            # facade: dispatch/3
  spec.ex             # %HookSpec{}, %Command{}, %Http{}, outcome type
  discovery.ex        # parse/2 (pure) + load/1 (impure, trust-aware)
  matcher.ex          # eval rules + external tool-name map + event targets   (pure)
  payload.ex          # build stdin JSON per event                            (pure)
  outcome.ex          # decode + fold lattice                                 (pure)
  trust.ex            # normalized hash + trust store
  runner.ex           # Task.async_stream → Port (+ Req in M5)                (impure)
```

Lifecycle wiring touches `apps/ex_pi_agent`. Discovery reuses `ex_pi_session/config_manager.ex` path helpers and `repo_manager.ex` trust state. Specs ride the existing `PiAgent.dispatcher_opts` channel into the dispatcher.

---

## PR 1 — Compatibility discovery & parser  (M1)

Implement discovery for `hooks.json` and Claude/Codex inline `hooks`. **JSON only. No execution.** Normalize to internal specs with source metadata, trust hash input, event, matcher, handler type, command, timeout, statusMessage, async flag, `unsupported_reason`.

- `Discovery.parse/2` (pure): bytes + dialect → `[HookSpec]`. Event-name normalization; field rules (`timeout` sec → `timeout_ms`, `timeoutSec` alias, default 600_000, **UserPromptSubmit command → 30_000**).
- Mark `http`/`mcp_tool`/`prompt`/`agent`/`async` as parsed-but-unsupported.

**Acceptance:** loads `~/.codex/hooks.json`, `<repo>/.codex/hooks.json`, `~/.claude/settings.json` inline `hooks`, `<repo>/.claude/settings.json`, `<repo>/.claude/settings.local.json`, `<repo>/.pi/hooks.json`; multiple sources merge additively (FR-D5); unsupported handlers parse but skip; `async:true` parses but skips.

---

## PR 2 — Matcher & event payloads  (M1)

Claude/Codex-compatible matcher + v1 payload builders, with golden tests.

- `Matcher`: eval rules (`*`/exact/`|`-list/regex); **external tool-name map** (FR-M4); **event-specific targets** (FR-M2) — tool events on `tool_name`, SessionStart on `source`, PreCompact on trigger, UserPromptSubmit/Stop ignore.
- `Payload.build/2`: common fields (`session_id, transcript_path, cwd, hook_event_name, permission_mode`; `model` on SessionStart) + event-specifics; JSON-encodable map only.

**Acceptance:** `Bash`, `Edit|Write`, `mcp__.*`, `*`, empty all behave; SessionStart filters by source; UserPromptSubmit/Stop ignore matcher; payloads carry shared + event-specific fields. (AC-1 matching half, AC-4, AC-5)

---

## PR 3 — Decoder & outcome folder  (M1)

stdout/stderr/exit decoding + folded outcomes for all six steering events. **Pure.**

- `Outcome.decode(event, %{exit, stdout, stderr}) :: outcome` — exit-0 empty → proceed; exit-2 event-specific; new + legacy schemas; `continue:false` → halt; **dialect divergences** (PostToolUse block: Codex-substitute vs Claude-alongside; PreToolUse `defer`; `model` scope).
- `Outcome.join/2` semilattice: `deny/halt > block > defer > ask > modify/context > proceed`; `:halt` absorbing; `{:modify,_}` patch-merge, conflict → `:ask`; `{:context,_}` concat ≤10k.
- `fold/1 = reduce(_, :proceed, &join/2)`.

**Acceptance:** property tests for join commutativity/associativity + `:halt` idempotence; table tests for decode across both schemas/exit codes; deny beats allow (AC-8); `continue:false` wins for Stop; PostToolUse dialect behaviors (AC-3); plain stdout is context only for SessionStart/UserPromptSubmit.

> End of M1: `parse`, `Matcher`, `Payload`, `Outcome` pass property + golden suites with zero I/O.

---

## PR 4 — Trust gate  (M2, before any execution)

Codex-style trust for command specs.

- `Trust`: hash the **normalized hook definition + source path** (FR-D6). User/project hooks skipped until trusted unless a dev/test bypass flag is set. Managed hooks not required yet.
- `Discovery.load/1` (impure): resolve all layer paths (reuse `ConfigManager` + add `~/.codex`, `~/.claude`, repo `.codex`/`.claude`/`.pi`), read → `parse` → accumulate → tag `{origin, dialect, trusted?}`; query repo trust from `repo_manager.ex`.

**Acceptance:** new repo hook listed but skipped; trusting allows execution; changing command/timeout/source invalidates trust; untrusted-repo project hooks don't run. (AC-10)

---

## PR 5 — Command runner  (M2)

Command execution with JSON stdin, `cwd`=session cwd, timeout-seconds, stdout/stderr capture, output caps, observer events.

- `Runner.run/3` via `Task.async_stream` (reuse `Dispatcher.TaskSupervisor` pattern), `on_timeout: :kill_task`, per-spec timeout; dedup identical command+args.
- `Port` spawn; write JSON stdin; capture exit/stdout/stderr. Crash/timeout → `{:error, …}` → non-blocking.
- `Hooks.dispatch/3` facade = filter by matcher → `Runner.run` → map `Outcome.decode` → `Outcome.fold`.
- Telemetry spans `[:ex_pi, :hook, :run, :start|:stop]`.

**Acceptance:** multiple matching hooks run concurrently; default timeout 600s, UserPromptSubmit 30s, explicit `timeout` overrides; raw results only, no loop steering yet. (AC-9)

---

## PR 6 — Wire PreToolUse, PermissionRequest, PostToolUse  (M3)

Into `PiCoding.Dispatcher` + `PiCoding.PermissionInterceptor`, no change to no-hook behavior.

- **PreToolUse** in `do_check` after policy `:allow`: collapse `{:block|:halt} → {:deny,r}`; `{:ask,r} → request_fn`; `{:defer,r} → :ask` unless headless; `{:modify,patch} → {:allow, patched_args}`; else `:allow`. Thread patched args into `Tool.execute` (extend `check/2` return or add `check_with_hooks/3`).
- **PermissionRequest** at the `:ask` branch: `deny → {:deny,msg}`; `allow → :allow` (apply `updatedInput`/`updatedPermissions`); none → existing approval flow. Deny dominates.
- **PostToolUse** after `Tool.execute`: Codex-block / `updatedToolOutput` → replace `result.content`; Claude-block → append feedback; `additionalContext` → attach; `:halt` → continue:false flag.

**Acceptance:** block/rewrite Bash; PermissionRequest auto-allow/deny; PostToolUse dialect behaviors; existing dispatcher flow + telemetry intact. (AC-1, AC-2, AC-3, AC-6, AC-8) **First useful shipping slice.**

---

## PR 7 — Wire UserPromptSubmit & SessionStart  (M4)

Into `PiAgent`. `on_event` stays observational; add a **separate synchronous** `Hooks.dispatch` whose folded result the loop branches on. Specs resolved once at agent init, stored in state.

- **SessionStart** (~ag:295, `{:agent_start, cwd}`): `{:context,t}` → prepend developer message before first turn; no control branch.
- **UserPromptSubmit** (~ag:301): `{:block,r}` → skip turn, emit notice; `{:context,t}` → append to user message.

**Acceptance:** blocking prompt prevents the provider call; context reaches the model as a system-reminder; SessionStart context precedes the first prompt; SessionStart block is diagnostic only. (AC-4, AC-5)

---

## PR 8 — Wire Stop continuation  (M4)

Stop dispatch before `agent_end` (~ag:261/344). Add `stop_hook_active` to `PiAgent` state + payload.

- `{:halt,_}` → force `agent_end` (wins).
- `{:block,r}` with `stop_hook_active==false` → enqueue `r` as synthetic user message, set flag, re-enter loop.
- else → `agent_end`, reset flag. Bounded continuation guard.

**Acceptance:** Stop block → one more turn; next payload `stop_hook_active:true`; `continue:false` forces stop; guard prevents infinite continuation; `agent_end` emits once. (AC-7)

---

## M5 — Compatibility hardening

Corpus golden tests (real Codex + Claude configs); inline `[hooks]` TOML; optional HTTP runner (`Req`: same JSON body, response→decision, non-2xx non-blocking, trust-gated, FR-X3a–e); plugin hooks once plugin roots exist; PreCompact observe-only dispatch. (AC-11, NFR-1)

---

## Test matrix → acceptance

| Layer | Modules | ACs |
|---|---|---|
| property/pure | Outcome, Matcher | AC-8 |
| golden/pure | Discovery.parse, Payload | AC-1(½), AC-4, AC-5, NFR-1 |
| unit/impure | Runner, Trust | AC-9, AC-10 |
| integration | Dispatcher, PermissionInterceptor | AC-1, AC-2, AC-3, AC-6 |
| integration | PiAgent lifecycle | AC-4, AC-5, AC-7 |
| diagnostic | Discovery | AC-11 |

## Sequencing & risk

- PR 1–3 (M1) are pure; PR 4–6 ship the high-value slice (policy gates, formatters, auto-approve) with **zero agent-loop risk**.
- PR 7–8 (M4) are the only loop-invasive work; gate behind `hooks.lifecycle_steering` to ship dark.
- Trust (PR 4) precedes execution so project hooks never run untrusted on a long-lived server.

## Open items to confirm against `main`

- The exact `PiAgent.Message` constructor at the `UserPromptSubmit` site, to splice `additionalContext`.
- Whether `PermissionInterceptor.check/2` can carry patched args without breaking callers (else `check_with_hooks/3`).
- `transcript_path` source — map to `ex_pi_session` JSONL storage for the active session.
- `permission_mode` value source in `ex_pi`'s permission model, for the stdin payload.
