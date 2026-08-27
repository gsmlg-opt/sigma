# sigma

`sigma` is an Elixir umbrella implementation of a `pi`-style AI coding agent. It combines a Phoenix LiveView chat UI, per-repository BEAM processes, streaming LLM providers, pi-compatible JSONL persistence, MCP and hook support, and an oh-my-pi-style coding-tool runtime.

The original TypeScript `pi` project is [earendil-works/pi](https://github.com/earendil-works/pi). A local checkout at `./source` is optional and gitignored; it is a porting reference, not part of the published tree.

## Applications

| App | Module prefix | Role |
| --- | --- | --- |
| `sigma_ai` | `Sigma.Ai` | Provider behaviour plus Anthropic and OpenAI-compatible streaming parsers |
| `sigma_protocol` | `Sigma.Agent.Message` | Shared message structs and protocol types used across apps |
| `sigma_agent` | `Sigma.Agent` | Repository/session supervisors, turn loop, context building, compaction, and tool-call orchestration |
| `sigma_session` | `Sigma.Session` | pi-compatible config, repository list, context files, skills, slash commands, and JSONL replay/persistence |
| `sigma_coding` | `Sigma.Coding` | Tool behaviour, dispatcher, permissions, MCP, and hooks |
| `sigma_tools` | `Sigma.Tools` | First-party tools (`ask`, `read`, `write`, `bash`, `edit`, `search`, `find`) and the hashline edit NIF |
| `sigma_logs` | `Sigma.Logs` | Per-session in-memory debug log buffers for LLM, tool, and permission events |
| `sigma_web` | `Sigma.Web` | Phoenix LiveView UI, routes, settings, and repository/session lifecycle |

## Features

- Phoenix LiveView UI for repositories, sessions, global settings, project settings, skills, hooks, MCP servers, interactive permission prompts, and a session debug-log drawer.
- Per-repository and per-session OTP processes for agent runtime lifecycle.
- Streaming Anthropic and OpenAI-compatible chat providers.
- Append-only JSONL session journals with replay, compaction entries, and session forking.
- New sessions can run in the project directory, an existing git worktree, or a newly created worktree.
- Context-file assembly from `AGENTS.md`/`CLAUDE.md`, ordered from filesystem root to the active workdir. `AGENTS.md` wins when both files exist in the same directory.
- Built-in tools: `ask`, `read`, `write`, `bash`, `search`, `find`, and hashline-only `edit` (`[path#TAG]` sections).
- Global and project MCP server selection, plus hook discovery for Pi, Codex, and Claude-style hook files.
- Skills from `~/.agents/skills` and `<repo>/.agents/skills`.
- DuskMoon UI components via `phoenix_duskmoon` and the DuskMoon web component packages.

## Requirements

- Elixir `~> 1.18` (CI uses 1.18.4)
- Erlang/OTP 28 (CI uses 28.5)
- Rust (`rustc` / `cargo`) for the hashline NIF in `apps/sigma_tools/native/sigma_tools_hashline`
- Node.js or Bun for web assets (`mix assets.setup`)
- API credentials for Anthropic or an OpenAI-compatible provider

## Setup

```bash
mix setup
mix phx.server
```

`mix setup` runs `deps.get`, `deps.patch`, `assets.setup`, and `assets.build`. `mix sigma.run` is an alias for `mix phx.server`.

`mix sigma.rel-run` overwrites the `sigma` release for the current Mix environment and runs it in the foreground. It uses the currently built static assets; run `mix assets.build` first when frontend assets have changed.

Open <http://localhost:4580>.

## Installing a release

GitHub Release archives include user-level service definitions for Linux and
macOS under `sigma/service/`. Install Sigma under `~/.local/share/sigma`, then
follow the [user service installation guide](rel/service/README.md) to run it as
a systemd user service or macOS LaunchAgent. No root-level service is required.

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
3. Create or open a session. New sessions can target the project directory or a git worktree.
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
- Session logs: `~/.pi/agent/sessions/<base64url-workdir>/<session-id>.jsonl`
- Session metadata: `~/.pi/agent/sessions/<base64url-workdir>/<session-id>.meta.json`

`Sigma.Session.ConfigManager.sessions_dir/1` uses a Base64-URL encoding of the absolute workdir (no padding). Older `--<pi-safe-path>--` directories are migrated on first use.

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

MIT. See [LICENSE](LICENSE).
