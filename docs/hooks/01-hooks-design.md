# ex_pi Hook System — Design

> Claude Code / Codex–compatible hook execution for the `ex_pi` umbrella.
> Status: design proposal. Anchored to current `main` (`ex_pi_agent`, `ex_pi_coding`, `ex_pi_session`).

## 1. Goal & non-goals

**Goal.** Run existing `hooks.json` / `settings.json` workflows from Claude Code and Codex **unchanged** inside `ex_pi`. A `.codex/hooks.json` or `.claude/settings.json` authored for either CLI fires here with identical stdin payloads, exit-code semantics, and decision schemas.

**Non-goals.**
- Not a plugin framework. Hooks are external `command`/`http` handlers, not Elixir extensions.
- No coupling to other repos (Samgita/Synapsis/backplane). Fully self-contained in `ex_pi`.
- Not reimplementing pi's TS extension API — that is a separate concern.

## 2. Guiding principles

1. **One canonical model, N wire dialects.** A single internal `HookSpec` / `Outcome` algebra is the source of truth. Claude Code and Codex are *serialization dialects* at the edge, distinguished only by config location. Their `hooks.json` shape is the same, so one parser serves both.
2. **The interception point is the existing pipeline, not new call sites.** Tool hooks ride `PiCoding.Dispatcher.do_dispatch`; lifecycle hooks ride `PiAgent`'s `emit` sites. No parallel event bus.
3. **Outcomes form a join-semilattice.** N matching hooks run concurrently; the fold over their outcomes is commutative + associative, so the decision is order-independent by construction — which is exactly what concurrent launch requires.
4. **Impurity is quarantined.** Discovery and the Outcome fold are pure. Only the Runner touches the world (subprocess / HTTP). Pure core is unit-testable with zero I/O.
5. **Compatibility is three tables, not architecture.** stdin fields, stdout/exit decoding, and field rules (timeouts, cwd) are fixed by the two ecosystems. Get them byte-faithful and workflows continue.
6. **Trust gates execution.** Hooks are arbitrary code execution. Project-layer specs run only when the repo is trusted.

## 3. Where it binds in the current code

The repo already exposes every seam needed; no new infrastructure.

| Seam (file:loc) | Role | Hook event |
|---|---|---|
| `PiCoding.PermissionInterceptor.check/2` | gate before `Tool.execute` | `PreToolUse` |
| `PiCoding.PermissionInterceptor` `:ask` branch | when a permission dialog would show | `PermissionRequest` |
| `PiCoding.Dispatcher.do_dispatch` (post-`Tool.execute`) | result wrap before return | `PostToolUse` |
| `PiAgent` `emit({:agent_start, cwd})` (~ag:295) | session start | `SessionStart` |
| `PiAgent` user-message build (~ag:301) | prompt submitted | `UserPromptSubmit` |
| `PiAgent` `emit({:turn_end, …})` / before `{:agent_end}` (~ag:261/344) | loop wants to stop | `Stop` |
| `PiAgent` `emit({:compact, …})` (~ag:529) | compaction | `PreCompact` |
| `PiAgent.dispatcher_opts` (state field, ag:21/134) | injection channel for specs | — |

`tool_call.name` (`PiAgent.Message` tool-call struct) feeds both the matcher and stdin `tool_name` — **after aliasing to the external Claude/Codex name** (see §3.1). Because `ex_pi` has real tools, matchers like `Edit|Write` actually fire — a strict **superset** of Codex, which today only emits `Bash`. Existing `"Bash"` matchers keep working.

### 3.1 Tool-name aliasing (hard requirement)

`ex_pi` tools are lowercase internally (`bash`, `edit`, …); Claude/Codex configs match PascalCase. The matcher and stdin payload use the **external** name; the dispatcher still executes by the internal name.

| internal | external (`tool_name`) |
|---|---|
| `bash` | `Bash` |
| `read` | `Read` |
| `write` | `Write` |
| `edit` | `Edit` |
| `grep` | `Grep` |
| `glob` | `Glob` |
| `ls` | `LS` |
| `url_fetch` | `WebFetch` (Claude's canonical name; `UrlFetch` accepted as alias) |
| `ask_user_question` | `AskUserQuestion` |

MCP tools keep the `mcp__<server>__<tool>` form so `mcp__.*` matchers work unchanged.

## 4. Architecture

```
                         ┌─────────────────────────────────────────┐
   hooks.json /          │            PiCoding.Hooks (facade)        │
   settings.json   ──►   │   dispatch(event, payload, specs)         │
   (codex + claude)      │            :: Outcome.t()                 │
                         └───────┬───────────────┬──────────────────┘
                                 │               │
                ┌────────────────▼──┐   ┌────────▼─────────────┐
   pure         │ Hooks.Discovery   │   │ Hooks.Outcome (pure) │  pure
                │  → [HookSpec]     │   │  decode + fold       │
                └────────┬──────────┘   └────────▲─────────────┘
                         │ specs                  │ raw results
                ┌────────▼──────────────────────┴─────┐
   impure       │ Hooks.Runner                          │ impure
                │  Task.async_stream → Port / Req       │
                │  stdin JSON, exit/stdout capture      │
                └───────────────────────────────────────┘
```

### 4.1 Canonical types (the entire compatibility surface)

```elixir
%HookSpec{
  event:    :pre_tool_use | :permission_request | :post_tool_use
          | :user_prompt_submit | :stop | :session_start | :pre_compact,
  matcher:  Regex.t() | :any,          # "*"/""/nil → :any
  handler:  %Command{cmd, timeout_ms, status_message}
          | %Http{url, timeout_ms, headers},
  origin:   {:user | :project | :plugin, path :: String.t()},
  dialect:  :codex | :claude,
  trusted?: boolean()
}

# Outcome — join-semilattice, restrictive dominates
@type outcome ::
        :proceed                                # identity / monoid unit
      | {:modify, input_patch :: map()}         # PreToolUse updatedInput
      | {:ask, reason :: String.t()}            # escalate to permission gate
      | {:defer, reason :: String.t()}          # PreToolUse -p-mode pause (Claude)
      | {:context, text :: String.t()}          # inject into next message
      | {:block, reason :: String.t()}          # deny / feedback / continuation
      | {:halt, reason :: String.t() | nil}     # continue:false — wins absolutely
```

### 4.2 The fold (Outcome — pure)

`deny/halt > block > defer > ask > modify/context > proceed`. `join/2` is commutative and associative; `:proceed` is the unit. For PreToolUse, Claude fixes precedence as `deny > defer > ask > allow`, which this ordering preserves. `:halt` (Codex `continue:false`) is the absorbing element — once present it wins regardless of order. `{:modify, _}` patches compose; conflicting patches on the same key degrade to `:ask`. `{:context, _}` values concatenate (capped at 10,000 chars, matching Claude). This is the only place decisions are made, and it has no I/O.

### 4.3 Outcome → loop collapse

Each binding site collapses the folded outcome onto a type the existing code already understands:

| Event | Outcome | Collapses to |
|---|---|---|
| PreToolUse | block/halt / ask / modify / proceed | `{:deny, r}` / `request_fn.(tc)` / rewrite `tool_call.arguments` / `:allow` |
| PostToolUse | block/halt / proceed | substitute result `content` with feedback / pass result through |
| UserPromptSubmit | block / context / proceed | abort turn (surface reason) / append to user msg / nothing |
| Stop | block (=continue) / halt / proceed | inject synthetic user turn (guarded) / force `agent_end` / `agent_end` |
| SessionStart | context / proceed | prepend developer message / nothing |
| PreCompact | (observe) | no branch |

## 5. The three wire-contract tables

### 5.1 stdin (built from `PiAgent` state)

Common: `session_id`, `transcript_path`, `cwd`, `hook_event_name`, `model`. Turn-scoped events add `turn_id`. Event-specifics:

- **PreToolUse**: `tool_name`, `tool_use_id`, `tool_input` (e.g. `{command}` for bash, `{file_path, content}` for write).
- **PostToolUse**: above + `tool_response`.
- **UserPromptSubmit**: `prompt`.
- **Stop**: `stop_hook_active`, `last_assistant_message`.
- **SessionStart**: `source` (`startup` | `resume` | `clear`).

### 5.2 stdout / exit decoding (accept both schemas)

- `exit 0`, empty stdout → `:proceed`.
- `exit 2` → blocking; **stderr** is the reason/feedback.
- other non-zero → non-blocking error: surface to user, **not** to model; never wedges the turn.
- JSON stdout, **new schema**: `hookSpecificOutput.permissionDecision` (`allow|deny|ask`) + `permissionDecisionReason`; `hookSpecificOutput.additionalContext`.
- JSON stdout, **legacy schema**: `decision` (`block`/`approve`) + `reason`.
- Common fields: `continue:false` → `:halt`; `stopReason`; `systemMessage`; `suppressOutput` (parsed, ignored).
- **PostToolUse** block does not undo — substitutes result content with feedback; model continues from it.
- **Stop** block does not reject — `reason` becomes a continuation prompt (synthetic user turn). Any `continue:false` wins.

### 5.3 field rules

- `timeout` in **seconds**; `timeoutSec` accepted alias; **omitted → 600s**, **except `UserPromptSubmit` command/http/mcp → 30s** (Claude).
- command `cwd` = session `cwd` (`PiAgent` state).
- `statusMessage` optional, shown while running.

### 5.4 Matcher targeting (event-specific)

The matcher filters a different field per event; it is **not** universally tool-name nor universally ignored:

| Event | Matcher filters | Match values |
|---|---|---|
| PreToolUse / PermissionRequest / PostToolUse | external `tool_name` | `Bash`, `Edit\|Write`, `mcp__.*` |
| SessionStart | `source` | `startup` `resume` `clear` `compact` |
| PreCompact | trigger | `manual` `auto` |
| UserPromptSubmit / Stop | (none) | always fires; a `matcher` is silently ignored |

Matcher evaluation (Claude rule): `*`/`""`/absent → match-all; only letters/digits/`_`/`|` → exact or `|`-list; any other char → regex.

### 5.5 Dialect divergences (honor per `spec.dialect`)

Three places Claude and Codex genuinely differ; the adapter resolves them by the spec's origin:

1. **`model` field** — Claude emits it only on `SessionStart`; Codex emits it broadly. `ex_pi` emits on `SessionStart` always and elsewhere as a harmless superset.
2. **PostToolUse "block"** — Codex: `decision:"block"` *replaces* the tool result with feedback. Claude: `decision:"block"` adds feedback *alongside* the original; **`updatedToolOutput`** is what replaces it. Support both: Codex-block → substitute; Claude-block → append feedback; `updatedToolOutput` (any dialect) → substitute.
3. **PreToolUse `defer`** — Claude-only, `-p` mode. `ex_pi` parses it; if not running headless it degrades to `:ask` with a logged notice.

## 6. Discovery & layering

Accumulate (never replace) across layers, tag each spec with `{origin, dialect, trusted?}`:

1. `~/.pi/agent/hooks.json` (user — `ConfigManager.agent_dir/0` path family).
2. `~/.codex/hooks.json`, `~/.claude/settings.json` (user, cross-ecosystem).
3. `<repo>/.codex/hooks.json`, `<repo>/.claude/settings.json` (**project — trusted only**).
4. plugin/skill-bundled `hooks/hooks.json`.

Inline `[hooks]` TOML in a config file is merged with a sibling `hooks.json` (merge-and-warn). Mirrors `ConfigManager`'s existing `mcp.json` + VS Code–style merge pattern.

## 7. Concurrency, isolation, locality

- Matching specs run via `Task.async_stream` (same `Task.Supervisor` style as `Dispatcher.dispatch_batch`), each a supervised task with its per-hook timeout.
- A crashed/timed-out hook yields a non-blocking error; the fold treats it as `:proceed` for safety and surfaces a user-visible warning.
- Command hooks run on the node owning the session/workspace (process-per-session already pins this). Only `http` handlers are node-mobile.

## 8. Trust model

Project-layer specs execute only when the repo is marked trusted (home: `ex_pi_session/repo_manager.ex`). Untrusted repo → user + plugin layers still run; project layers are loaded-but-skipped with a surfaced notice. This matters more than for a local CLI because the executor is a long-lived server process.

## 9. Risks & decisions

- **Lifecycle steering requires loop edits.** `emit/2` is fire-and-forget; steering events (UserPromptSubmit/Stop) need a synchronous `Hooks.dispatch` whose result the loop branches on. Decision: **full Claude Code parity** (steering), touching `agent.ex` in ~3 places; `on_event` stays observer-only.
- **Stop infinite loops.** Mitigated by threading `stop_hook_active` and honoring `continue:false` as absorbing.
- **`updatedInput` / `allow` on PreToolUse.** Codex currently fails-open on these (WIP); `ex_pi` honors them since it owns the executor. Default behavior documented so configs are predictable.
