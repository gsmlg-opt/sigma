# sigma

`sigma` is an Elixir umbrella implementation of a `pi`-style AI coding agent. It combines a Phoenix LiveView chat UI, per-repository BEAM processes, streaming LLM providers, pi-compatible JSONL persistence, MCP and hook support, and a small coding-tool runtime.

The original TypeScript `pi` source is vendored at `./source` for behavior checks while porting.

## Applications

| App | Module prefix | Role |
| --- | --- | --- |
| `sigma_ai` | `Sigma.Ai` | Provider behaviour plus Anthropic and OpenAI-compatible streaming parsers |
| `sigma_protocol` | `Sigma.Agent.Message` | Shared message structs and protocol types used across apps |
| `sigma_agent` | `Sigma.Agent` | Repository/session supervisors, turn loop, context building, compaction, and tool-call orchestration |
| `sigma_session` | `Sigma.Session` | pi-compatible config, repository list, context files, skills, slash commands, and JSONL replay/persistence |
| `sigma_coding` | `Sigma.Coding` | Tool behaviour, dispatcher, permissions, MCP, hooks, and read/write/edit/bash/search tools |
| `sigma_logs` | `Sigma.Logs` | Per-session in-memory debug log buffers for LLM, tool, and permission events |
| `sigma_web` | `Sigma.Web` | Phoenix LiveView UI, routes, settings, and repository/session lifecycle |

## Features

- Phoenix LiveView UI for repositories, sessions, global settings, project settings, skills, hooks, MCP servers, and interactive permission prompts.
- Per-repository and per-session OTP processes for agent runtime lifecycle.
- Streaming Anthropic and OpenAI-compatible chat providers.
- Append-only JSONL session logs with replay, compaction entries, and session forking.
- Context-file assembly from `AGENTS.md`/`CLAUDE.md`, ordered from filesystem root to the active workdir. `AGENTS.md` wins when both files exist in the same directory.
- Coding tools for file reads, writes, edits, shell commands, glob, grep, ls, URL fetches, and user questions.
- Global and project MCP server selection, plus hook discovery for Pi, Codex, and Claude-style hook files.
- DuskMoon UI components via `phoenix_duskmoon` and the DuskMoon web component packages.

## Requirements

- Elixir `~> 1.18`
- Erlang/OTP 27 or compatible with the configured Elixir version
- Node/npm for the web asset setup under `apps/sigma_web/package.json`
- API credentials for Anthropic or an OpenAI-compatible provider

## Setup

```bash
mix deps.get
mix assets.setup
mix phx.server
```

The umbrella also provides a full setup alias:

```bash
mix setup
```

Open <http://localhost:4580>.

Provider settings are managed in the UI under `/settings/providers` and are saved in pi-compatible files under `~/.pi/agent/`:

- `settings.json`
- `auth.json`
- `models.json`
- `mcp.json`
- `hooks.json`
- `AGENTS.md`

Direct provider calls can also read environment fallbacks, but the LiveView flow resolves credentials from the saved settings above:

- Anthropic: `ANTHROPIC_AUTH_TOKEN`, optional `ANTHROPIC_BASE_URL`
- OpenAI-compatible: `OPENAI_API_KEY` or `OPENROUTER_API_KEY`, optional `OPENAI_BASE_URL`

## Usage

1. Add a repository from the home page or visit `/repository/new`.
2. Open the repository session list.
3. Create or open a session.
4. Prompt the agent; tool calls stream back through LiveView and may request approval depending on policy.
5. Fork a session when you want a new branch of the same conversation history.

The session input supports `/init`, which expands into the built-in setup prompt for creating or updating project/user `AGENTS.md` files and related Sigma Agent setup.

Repository routes use a Base64 URL-encoded absolute path without padding:

```text
/repository/:repository
/repository/:repository/settings
/repository/:repository/hooks
/repository/:repository/skills
/repository/:repository/sessions/new
/repository/:repository/sessions/:id
```

Global settings routes:

```text
/settings
/settings/providers
/settings/credentials
/settings/mcp
/settings/hooks
/settings/skills
/settings/system_prompt
```

Runtime state is stored locally in the pi-compatible agent directory:

- Repository list: `~/.pi/agent/repos.jsonl`
- Session logs: `~/.pi/agent/sessions/--<pi-safe-workdir>--/<session-id>.jsonl`
- Session metadata: `~/.pi/agent/sessions/--<pi-safe-workdir>--/<session-id>.meta.json`

`Sigma.Session.ConfigManager.sessions_dir/1` derives the session directory by replacing path separators in the absolute workdir with dashes and wrapping the result in double dashes.

## Development

```bash
mix test
mix test apps/sigma_agent/test/sigma_agent_test.exs
mix test apps/sigma_agent/test/sigma_agent_test.exs:42
mix format --check-formatted
mix compile --warnings-as-errors
mix assets.build
```

For focused LiveView or umbrella-app work, run the relevant app test path directly, for example:

```bash
mix test apps/sigma_web/test/sigma_web/live/session_live_test.exs
```

The web app uses DuskMoon UI. Keep UI work on `phoenix_duskmoon` components and the configured Tailwind/DuskMoon pipeline; do not add DaisyUI or Phoenix `core_components.ex`.

## License

This project follows the licensing terms of the upstream `pi` project unless stated otherwise.
