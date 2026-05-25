# ex_pi

`ex_pi` is an Elixir umbrella implementation of a `pi`-style AI coding agent. It combines a Phoenix LiveView chat UI, per-session BEAM processes, streaming LLM providers, JSONL session persistence, and a small coding-tool runtime.

The original TypeScript `pi` source is vendored at `./source` for behavior checks while porting.

## Applications

| App | Module prefix | Role |
| --- | --- | --- |
| `ex_pi_ai` | `PiAi` | Provider abstraction and Anthropic/OpenAI streaming parsers |
| `ex_pi_agent` | `PiAgent` | GenServer session loop, message transforms, compaction, tool calls |
| `ex_pi_session` | `PiSession` | Config, repository list, context-file assembly, JSONL replay/persistence |
| `ex_pi_coding` | `PiCoding` | Tool behaviour, dispatcher, permissions, read/write/edit/bash/search tools |
| `ex_pi_web` | `PiWeb` | Phoenix LiveView UI, routes, session process management |

## Features

- Phoenix LiveView UI for repositories, sessions, settings, and interactive permission prompts.
- Streaming Anthropic and OpenAI-compatible chat providers.
- Append-only JSONL session logs with replay, compaction entries, and session forking.
- Context-file assembly from `AGENTS.md`/`CLAUDE.md`, ordered from filesystem root to the active workdir.
- Coding tools for file reads, writes, edits, shell commands, glob/grep/ls, and URL fetches.
- DuskMoon UI components via `phoenix_duskmoon`.

## Requirements

- Elixir `~> 1.18`
- Erlang/OTP 27 or compatible with the configured Elixir version
- API credentials for Anthropic or an OpenAI-compatible provider

## Setup

```bash
mix deps.get
mix assets.setup
mix phx.server
```

Open <http://localhost:4580>.

Provider settings are managed in the UI under `/settings/providers` and are saved in pi-compatible files under `~/.pi/agent/`:

- `settings.json`
- `auth.json`
- `models.json`
- `mcp.json`
- `AGENTS.md`

Global MCP servers are configured under `/settings/mcp`. Project settings select the default MCP servers for that repository, and new sessions can override that selection.

Direct provider calls can also read environment fallbacks, but the LiveView flow resolves credentials from the saved settings above:

- Anthropic: `ANTHROPIC_AUTH_TOKEN`, optional `ANTHROPIC_BASE_URL`
- OpenAI-compatible: `OPENAI_API_KEY` or `OPENROUTER_API_KEY`, optional `OPENAI_BASE_URL`

## Usage

1. Add a repository from the home page or visit `/repository/new`.
2. Open the repository session list.
3. Create or open a session.
4. Prompt the agent; tool calls stream back through LiveView and may request approval depending on policy.
5. Fork a session when you want a new branch of the same conversation history.

Repository routes use a Base64 URL-encoded absolute path without padding:

```text
/repository/:repository
/repository/:repository/settings
/repository/:repository/sessions/:id
```

In development, repository and session state is stored locally:

- Repository list: `apps/ex_pi_session/priv/repos.jsonl`
- Session logs: `apps/ex_pi_web/priv/sessions/<base64-url-workdir>/<session-id>.jsonl`

## Development

```bash
mix test
mix test apps/ex_pi_agent/test/ex_pi_agent_test.exs
mix test apps/ex_pi_agent/test/ex_pi_agent_test.exs:42
mix format --check-formatted
mix compile --warnings-as-errors
mix assets.build
```

The web app uses DuskMoon UI. Keep UI work on `phoenix_duskmoon` components and the configured Tailwind/DuskMoon pipeline; do not add DaisyUI or Phoenix `core_components.ex`.

## License

This project follows the licensing terms of the upstream `pi` project unless stated otherwise.
