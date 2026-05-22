# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

`ex_pi` is an Elixir umbrella project — an AI coding agent (port of [earendil-works/pi](https://github.com/earendil-works/pi)) that runs a Phoenix LiveView web UI for interactive sessions. The web server runs on port **4580** (not the default 4000).

The original `pi` TypeScript source is checked out at `./source` — use it to cross-reference the original implementation when porting logic.

## Commands

```bash
# Install dependencies
mix deps.get

# Start dev server (with hot reload)
mix phx.server

# Build assets
mix assets.build

# Run all tests
mix test

# Run a single test file
mix test apps/ex_pi_agent/test/ex_pi_agent_test.exs

# Run a single test by line number
mix test apps/ex_pi_agent/test/ex_pi_agent_test.exs:42

# Format check
mix format --check-formatted

# Compile (warnings as errors)
mix compile --warnings-as-errors
```

## Architecture

This is an **umbrella project** with five apps under `apps/`:

| App | Module prefix | Role |
|-----|--------------|------|
| `ex_pi_ai` | `PiAi` | LLM provider abstraction — streaming SSE parsing |
| `ex_pi_agent` | `PiAgent` | GenServer per session — manages the turn loop |
| `ex_pi_session` | `PiSession` | JSONL append-only persistence + config management |
| `ex_pi_coding` | `PiCoding` | Tool system (read/edit/bash) + permission interceptor |
| `ex_pi_web` | `PiWeb` | Phoenix LiveView UI + session lifecycle management |

### Key Data Flow

1. User submits prompt → `SessionLive` → `PiAgent.prompt/2` (cast)
2. `PiAgent` runs `run_turn_loop/1`: transforms messages → calls `Provider.stream/1` → reduces SSE events
3. On tool calls: `PiCoding.Dispatcher.dispatch_batch/3` executes tools in parallel via `Task.Supervisor`
4. Every `{:message_end, msg}` event is persisted to a `.jsonl` file AND broadcast over PubSub to the LiveView
5. LiveView receives events via `handle_info` and updates the message stream

### Provider Behaviour

`PiAi.Provider` defines a single callback: `stream(params) :: Enumerable.t()`. Providers must return a lazy stream of tagged tuples:
- `{:start, ai_msg}`, `{:text_delta, idx, text, ai_msg}`, `{:thinking_delta, ...}`, `{:toolcall_start/delta/end, ...}`, `{:done, stop_reason, ai_msg}`

Current implementations: `Anthropic`, `OpenAI`, `ReqLLM` (generic OpenAI-compat). A `MockProvider` exists inline in `session_live.ex` for testing.

### Session Persistence

Sessions are stored as JSONL files at `~/.pi/sessions/<base64-encoded-workdir>/<session-id>.jsonl`. Each line is a JSON object with a `"type"` field (`"session"` header, `"message"`, `"compaction"`). `PiSession.Log.replay/1` reconstructs `PiAgent.Message` structs from these entries, handling compaction summaries.

Session **forking** copies the JSONL prefix up to a given message index into a new file — it never mutates the original.

### Permission System

`PiCoding.PermissionInterceptor.check/2` gates all tool execution. It delegates to an `PiCoding.PermissionPolicy` GenServer (default: `:allow`). When a tool requires human approval, the interceptor calls `permission_request_fn` which blocks via `receive` — the LiveView answers through PubSub. The 60-second timeout in `SessionLive` matches the interceptor's expected response window.

### Configuration

Agent config is stored in `~/.pi/agent/` (pi-compatible format):
- `settings.json` — active provider, default model
- `auth.json` — API keys by provider ID
- `models.json` — provider/model definitions
- `AGENTS.md` — system prompt (plain text)

`PiSession.ConfigManager` reads/writes these files and translates the pi format into the internal representation used by the UI.

### Routes

```
/                           → HomeLive (project selector)
/workdir/:workdir           → WorkdirLive (session list for a directory)
/workdir/:workdir/sessions/:id → SessionLive (chat UI)
/settings                   → SettingsLive (credentials, providers, system prompt)
```

The `:workdir` route param is a Base64-URL-encoded absolute path (no padding).

## UI Library

This project uses the DuskMoon UI system:

- **`phoenix_duskmoon`** — Phoenix LiveView UI component library (primary web UI)
- **`@duskmoon-dev/core`** — Core Tailwind CSS plugin and utilities
- **`@duskmoon-dev/css-art`** — CSS art utilities
- **`@duskmoon-dev/elements`** — Base web components
- **`@duskmoon-dev/art-elements`** — Art/decorative web components

Do NOT use DaisyUI or other CSS component libraries. Do NOT use `core_components.ex` — use `phoenix_duskmoon` components instead.
Use `@duskmoon-dev/core/plugin` as the Tailwind CSS plugin.

### Reporting issues or feature requests

If you encounter missing features, bugs, or need functionality not yet available in any DuskMoon package, open a GitHub issue in the appropriate repository with the label `internal request`:

- **`phoenix_duskmoon`** — https://github.com/gsmlg-dev/phoenix_duskmoon/issues
- **`@duskmoon-dev/core`** — https://github.com/gsmlg-dev/duskmoon-dev/issues
- **`@duskmoon-dev/css-art`** — https://github.com/gsmlg-dev/duskmoon-dev/issues
- **`@duskmoon-dev/elements`** — https://github.com/gsmlg-dev/duskmoon-dev/issues
- **`@duskmoon-dev/art-elements`** — https://github.com/gsmlg-dev/duskmoon-dev/issues

## Agent skills

### Issue tracker

Issues are tracked in GitHub Issues for `gsmlg-dev/ex_pi` using the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

Use the default triage label vocabulary. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context repo: root `CONTEXT.md` plus `docs/adr/`. See `docs/agents/domain.md`.

<!-- gitnexus:start -->
# GitNexus — Code Intelligence

This project is indexed by GitNexus as **ex_pi** (484 symbols, 486 relationships, 2 execution flows). Use the GitNexus MCP tools to understand code, assess impact, and navigate safely.

> If any GitNexus tool warns the index is stale, run `npx gitnexus analyze` in terminal first.

## Always Do

- **MUST run impact analysis before editing any symbol.** Before modifying a function, class, or method, run `gitnexus_impact({target: "symbolName", direction: "upstream"})` and report the blast radius (direct callers, affected processes, risk level) to the user.
- **MUST run `gitnexus_detect_changes()` before committing** to verify your changes only affect expected symbols and execution flows.
- **MUST warn the user** if impact analysis returns HIGH or CRITICAL risk before proceeding with edits.
- When exploring unfamiliar code, use `gitnexus_query({query: "concept"})` to find execution flows instead of grepping. It returns process-grouped results ranked by relevance.
- When you need full context on a specific symbol — callers, callees, which execution flows it participates in — use `gitnexus_context({name: "symbolName"})`.

## Never Do

- NEVER edit a function, class, or method without first running `gitnexus_impact` on it.
- NEVER ignore HIGH or CRITICAL risk warnings from impact analysis.
- NEVER rename symbols with find-and-replace — use `gitnexus_rename` which understands the call graph.
- NEVER commit changes without running `gitnexus_detect_changes()` to check affected scope.

## Resources

| Resource | Use for |
|----------|---------|
| `gitnexus://repo/ex_pi/context` | Codebase overview, check index freshness |
| `gitnexus://repo/ex_pi/clusters` | All functional areas |
| `gitnexus://repo/ex_pi/processes` | All execution flows |
| `gitnexus://repo/ex_pi/process/{name}` | Step-by-step execution trace |

## CLI

| Task | Read this skill file |
|------|---------------------|
| Understand architecture / "How does X work?" | `.claude/skills/gitnexus/gitnexus-exploring/SKILL.md` |
| Blast radius / "What breaks if I change X?" | `.claude/skills/gitnexus/gitnexus-impact-analysis/SKILL.md` |
| Trace bugs / "Why is X failing?" | `.claude/skills/gitnexus/gitnexus-debugging/SKILL.md` |
| Rename / extract / split / refactor | `.claude/skills/gitnexus/gitnexus-refactoring/SKILL.md` |
| Tools, resources, schema reference | `.claude/skills/gitnexus/gitnexus-guide/SKILL.md` |
| Index, status, clean, wiki CLI commands | `.claude/skills/gitnexus/gitnexus-cli/SKILL.md` |

<!-- gitnexus:end -->

## graphify

This project has a knowledge graph at graphify-out/ with god nodes, community structure, and cross-file relationships.

Rules:
- ALWAYS read graphify-out/GRAPH_REPORT.md before reading any source files, running grep/glob searches, or answering codebase questions. The graph is your primary map of the codebase.
- IF graphify-out/wiki/index.md EXISTS, navigate it instead of reading raw files
- For cross-module "how does X relate to Y" questions, prefer `graphify query "<question>"`, `graphify path "<A>" "<B>"`, or `graphify explain "<concept>"` over grep — these traverse the graph's EXTRACTED + INFERRED edges instead of scanning files
- After modifying code, run `graphify update .` to keep the graph current (AST-only, no API cost).
