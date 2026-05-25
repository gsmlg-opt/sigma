# Repository Instructions

## Project Shape

- `ex_pi` is an Elixir umbrella project: a Phoenix LiveView AI coding agent inspired by `earendil-works/pi`.
- The upstream TypeScript implementation is checked out at `./source`; cross-reference it when porting behavior.
- The dev server runs on port `4580`.
- OTP app names use `ex_pi_*`; runtime modules use `Pi*` prefixes.

| App | Module prefix | Responsibility |
| --- | --- | --- |
| `ex_pi_ai` | `PiAi` | Provider behaviour, Anthropic/OpenAI SSE streaming, event reducers |
| `ex_pi_agent` | `PiAgent` | Per-session GenServer turn loop, message transforms, tool execution flow |
| `ex_pi_session` | `PiSession` | JSONL replay/persistence, config, repo list, context files |
| `ex_pi_coding` | `PiCoding` | Tool behaviour, dispatcher, permissions, read/write/edit/bash/search tools |
| `ex_pi_web` | `PiWeb` | Phoenix LiveView UI, routing, session process lifecycle |

## Commands

```bash
mix deps.get
mix assets.setup
mix phx.server
mix assets.build
mix test
mix test apps/ex_pi_agent/test/ex_pi_agent_test.exs
mix test apps/ex_pi_agent/test/ex_pi_agent_test.exs:42
mix format --check-formatted
mix compile --warnings-as-errors
```

## Collaboration Defaults

- Keep responses concise and assume Elixir/BEAM, Phoenix, LiveView, and OTP familiarity.
- Prefer architecture, protocol, process, and technical-principle explanations over beginner walkthroughs.
- Default code examples to Elixir when examples are explicitly requested.
- Prefer functional and OTP-native designs; do not introduce OOP framing when data transforms, processes, behaviours, or supervision fit better.

## Architecture Notes

- User prompts enter through `PiWeb.SessionLive`, call `PiAgent.prompt/2`, stream through a `PiAi.Provider`, then persist/broadcast `PiAgent` events.
- Providers implement `PiAi.Provider.stream/1` and return lazy streams of tagged events such as `{:start, msg}`, `{:text_delta, idx, text, msg}`, `{:toolcall_*, ...}`, and `{:done, reason, msg}`.
- Tool calls are dispatched by `PiCoding.Dispatcher`; batch execution uses `Task.Supervisor` when one is supplied.
- Permission checks go through `PiCoding.PermissionInterceptor` and `PiCoding.PermissionPolicy`; LiveView approval waits must stay aligned with the interceptor timeout.
- Session JSONL files are stored per repository/workdir. In dev, sessions live under `apps/ex_pi_web/priv/sessions/<base64-url-workdir>/`.
- Known repositories are stored in dev at `apps/ex_pi_session/priv/repos.jsonl`.
- Agent/provider/MCP config is pi-compatible and stored at `~/.pi/agent/`: `settings.json`, `auth.json`, `models.json`, `mcp.json`, and `AGENTS.md`.
- Context assembly prefers `AGENTS.md` over `CLAUDE.md` in each ancestor directory, ordered root-to-workdir so deeper project instructions have later precedence.

## Routes

```text
/                                      -> PiWeb.HomeLive
/repository/new                       -> PiWeb.HomeLive, add mode
/repository/:repository               -> PiWeb.RepositoryLive
/repository/:repository/settings      -> PiWeb.ProjectSettingsLive
/repository/:repository/sessions/:id  -> PiWeb.SessionLive
/settings                             -> redirects to providers settings
/settings/providers                   -> PiWeb.SettingsLive
/settings/credentials                 -> PiWeb.SettingsLive
/settings/mcp                         -> PiWeb.SettingsLive
/settings/skills                      -> PiWeb.SettingsLive
/settings/system_prompt               -> PiWeb.SettingsLive
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

<!-- gitnexus:start -->
# GitNexus — Code Intelligence

This project is indexed by GitNexus as **ex_pi** (504 symbols, 506 relationships, 2 execution flows). Use the GitNexus MCP tools to understand code, assess impact, and navigate safely.

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
