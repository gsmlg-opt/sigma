# Repository Instructions

## Project Shape

- `sigma` is an Elixir umbrella project: a Phoenix LiveView AI coding agent inspired by `earendil-works/pi`.
- The upstream TypeScript implementation is checked out at `./source`; cross-reference it when porting behavior.
- The dev server runs on port `4580`.
- OTP app names use `sigma_*`; runtime modules use `Sigma*` prefixes.

| App | Module prefix | Responsibility |
| --- | --- | --- |
| `sigma_ai` | `Sigma.Ai` | Provider behaviour, Anthropic/OpenAI SSE streaming, event reducers |
| `sigma_agent` | `Sigma.Agent` | Per-session GenServer turn loop, message transforms, tool execution flow |
| `sigma_session` | `Sigma.Session` | JSONL replay/persistence, config, repo list, context files |
| `sigma_coding` | `Sigma.Coding` | Tool behaviour, dispatcher, permissions, read/write/edit/bash/search tools |
| `sigma_web` | `Sigma.Web` | Phoenix LiveView UI, routing, session process lifecycle |

## Commands

```bash
mix deps.get
mix assets.setup
mix phx.server
mix assets.build
mix test
mix test apps/sigma_agent/test/sigma_agent_test.exs
mix test apps/sigma_agent/test/sigma_agent_test.exs:42
mix format --check-formatted
mix compile --warnings-as-errors
```

## Collaboration Defaults

- Never add `Co-authored-by: Cursor <cursoragent@cursor.com>` (or similar Cursor attribution) to commits. Run `./scripts/install-git-hooks.sh` once per clone so `.githooks` strips it; see `docs/agents/cursor-commit-attribution.md`.
- Keep responses concise and assume Elixir/BEAM, Phoenix, LiveView, and OTP familiarity.
- Prefer architecture, protocol, process, and technical-principle explanations over beginner walkthroughs.
- Default code examples to Elixir when examples are explicitly requested.
- Prefer functional and OTP-native designs; do not introduce OOP framing when data transforms, processes, behaviours, or supervision fit better.

## Architecture Notes

- User prompts enter through `Sigma.Web.SessionLive`, call `Sigma.Agent.prompt/2`, stream through a `Sigma.Ai.Provider`, then persist/broadcast `Sigma.Agent` events.
- Providers implement `Sigma.Ai.Provider.stream/1` and return lazy streams of tagged events such as `{:start, msg}`, `{:text_delta, idx, text, msg}`, `{:toolcall_*, ...}`, and `{:done, reason, msg}`.
- Tool calls are dispatched by `Sigma.Coding.Dispatcher`; batch execution uses `Task.Supervisor` when one is supplied.
- Permission checks go through `Sigma.Coding.PermissionInterceptor` and `Sigma.Coding.PermissionPolicy`; LiveView approval waits must stay aligned with the interceptor timeout.
- Session JSONL files are stored per repository/workdir. In dev, sessions live under `apps/sigma_web/priv/sessions/<base64-url-workdir>/`.
- Known repositories are stored in dev at `apps/sigma_session/priv/repos.jsonl`.
- Agent/provider/MCP config is pi-compatible and stored at `~/.pi/agent/`: `settings.json`, `auth.json`, `models.json`, `mcp.json`, and `AGENTS.md`.
- Context assembly prefers `AGENTS.md` over `CLAUDE.md` in each ancestor directory, ordered root-to-workdir so deeper project instructions have later precedence.

## Routes

```text
/                                      -> Sigma.Web.HomeLive
/repository/new                       -> Sigma.Web.HomeLive, add mode
/repository/:repository               -> Sigma.Web.RepositoryLive
/repository/:repository/settings      -> Sigma.Web.ProjectSettingsLive
/repository/:repository/sessions/:id  -> Sigma.Web.SessionLive
/settings                             -> redirects to providers settings
/settings/providers                   -> Sigma.Web.SettingsLive
/settings/credentials                 -> Sigma.Web.SettingsLive
/settings/mcp                         -> Sigma.Web.SettingsLive
/settings/skills                      -> Sigma.Web.SettingsLive
/settings/system_prompt               -> Sigma.Web.SettingsLive
```

The `:repository` param is a Base64 URL-encoded absolute path with no padding.

## UI Conventions

- Use Phoenix LiveView and `phoenix_duskmoon` components for UI work.
- Do not introduce DaisyUI or other component libraries.
- Do not use Phoenix `core_components.ex`; prefer DuskMoon components and existing local patterns.
- Keep Tailwind configured through `@duskmoon-dev/core/plugin`.
- If a required DuskMoon capability is missing, open an `internal request` issue in the relevant DuskMoon repository rather than adding a competing local component system.
- DuskMoon issue targets: `phoenix_duskmoon` -> `https://github.com/gsmlg-dev/phoenix_duskmoon/issues`; JS/CSS packages -> `https://github.com/gsmlg-dev/duskmoon-dev/issues`.

## Code Style

- Prefer functional, data-first Elixir. Keep protocol parsing and message transforms pure where practical.
- Put side effects at clear boundaries: LiveView events, provider HTTP streams, JSONL storage, shell/tool execution.
- Use OTP primitives (`GenServer`, supervisors, monitored tasks) for process lifecycle and concurrency.
- Preserve pi-compatible file formats unless the change explicitly migrates them.
- Avoid broad rewrites while porting; first match upstream behavior, then simplify with Elixir-native structure.

## Agent note

After we add new feature, change architecture or fix issues we write agent note.
When save note to agent-note, should add label:
- `project: sigma`

