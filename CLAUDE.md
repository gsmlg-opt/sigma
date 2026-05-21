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
| `ex_pi_ai` | `ExPiAi` | LLM provider abstraction — streaming SSE parsing |
| `ex_pi_agent` | `ExPiAgent` | GenServer per session — manages the turn loop |
| `ex_pi_session` | `ExPiSession` | JSONL append-only persistence + config management |
| `ex_pi_coding` | `ExPiCoding` | Tool system (read/edit/bash) + permission interceptor |
| `ex_pi_web` | `ExPiWeb` | Phoenix LiveView UI + session lifecycle management |

### Key Data Flow

1. User submits prompt → `SessionLive` → `ExPiAgent.prompt/2` (cast)
2. `ExPiAgent` runs `run_turn_loop/1`: transforms messages → calls `Provider.stream/1` → reduces SSE events
3. On tool calls: `ExPiCoding.Dispatcher.dispatch_batch/3` executes tools in parallel via `Task.Supervisor`
4. Every `{:message_end, msg}` event is persisted to a `.jsonl` file AND broadcast over PubSub to the LiveView
5. LiveView receives events via `handle_info` and updates the message stream

### Provider Behaviour

`ExPiAi.Provider` defines a single callback: `stream(params) :: Enumerable.t()`. Providers must return a lazy stream of tagged tuples:
- `{:start, ai_msg}`, `{:text_delta, idx, text, ai_msg}`, `{:thinking_delta, ...}`, `{:toolcall_start/delta/end, ...}`, `{:done, stop_reason, ai_msg}`

Current implementations: `Anthropic`, `OpenAI`, `ReqLLM` (generic OpenAI-compat). A `MockProvider` exists inline in `session_live.ex` for testing.

### Session Persistence

Sessions are stored as JSONL files at `~/.pi/sessions/<base64-encoded-workdir>/<session-id>.jsonl`. Each line is a JSON object with a `"type"` field (`"session"` header, `"message"`, `"compaction"`). `ExPiSession.Log.replay/1` reconstructs `ExPiAgent.Message` structs from these entries, handling compaction summaries.

Session **forking** copies the JSONL prefix up to a given message index into a new file — it never mutates the original.

### Permission System

`ExPiCoding.PermissionInterceptor.check/2` gates all tool execution. It delegates to an `ExPiCoding.PermissionPolicy` GenServer (default: `:allow`). When a tool requires human approval, the interceptor calls `permission_request_fn` which blocks via `receive` — the LiveView answers through PubSub. The 60-second timeout in `SessionLive` matches the interceptor's expected response window.

### Configuration

Agent config is stored in `~/.pi/agent/` (pi-compatible format):
- `settings.json` — active provider, default model
- `auth.json` — API keys by provider ID
- `models.json` — provider/model definitions
- `AGENTS.md` — system prompt (plain text)

`ExPiSession.ConfigManager` reads/writes these files and translates the pi format into the internal representation used by the UI.

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
