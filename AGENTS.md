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
| `sigma_coding` | `Sigma.Coding` | MCP tool hosting, shared dispatch, permissions, hooks, terminal primitives |
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
- Sigma is a web product: no standalone CLI/TUI. Non-browser clients (including any future CLI) use the Web API (Protocol V1). Sandboxing and approval workflows are out of scope by decision.
- Default tool approvals use YOLO mode: `permissions.default = "allow"` with empty `rules`, inherited by root and managed-child sessions.
- Do not develop security or permission features, or add/run related tests. Keep the existing YOLO defaults and adapters; continue only tool functionality, results, history and lifecycle work, with functional checks, compilation, formatting and diff inspection.
- The user deferred `web::run`, `image_gen::imagegen`, selecting an actual plugin registry, remote encrypted History and `notes.thread_hint` on 2026-10-27. Keep all five as TODOs outside the current completion gates; do not choose services or endpoints. Existing local History/Notes tools, configured plugin hosts and their remaining functional/lifecycle work retain their scope.

## Architecture Notes

Full design boundaries and historical, version-scoped acceptance evidence live in [docs/agents/architecture-notes.md](docs/agents/architecture-notes.md). Read the relevant entry before changing that area; dependency versions there are historical, `mix.lock` is authoritative.

- Request flow: `Sigma.Web.SessionLive` → `Sigma.Agent.prompt/2` → `Sigma.Ai.Provider` stream → persisted/broadcast `Sigma.Agent` events. Providers implement `Sigma.Ai.Provider.stream/1` and return lazy streams of tagged events (`{:start, msg}`, `{:text_delta, idx, text, msg}`, `{:toolcall_*, ...}`, `{:done, reason, msg}`).
- Tools: legacy built-in tools and their registry are retired; do not restore them. Web and Protocol sessions select `native_tools: true` with an empty legacy `tools: []`. Engine composes public Backplane Codex profiles with MCP and collaboration contracts through explicit host adapters. Writer-backed roots expose 42 native tools; writerless roots 19; two plugin tools are added only when `plugins.registryUrl` is configured.
- Configured MCP tools use `Sigma.Coding.Dispatcher`; connected MCP functions start as deferred `tool_search` candidates. Managed children borrow root MCP connections through a trusted owner lookup and never own them.
- Use public Backplane APIs and records (Runtime, Store, ToolEffects, Goal, MultiAgent, PluginProtocol). Do not add local proofs, cancellation bypasses, receipts, dependency patches or private-state resets to work around upstream behavior; route upstream gaps through `upstream-issue-routing`.
- Recovery invariants: history reads, reloads and cold recovery never replay Provider calls or tool effects, never invent tool results/receipts, and never rewrite settled journal facts. Uncertain outcomes stay uncertain. Display history and Provider context are separate projections of the Writer-selected branch.
- Lifecycle: retirement (native bindings, async hooks, SessionEnd, Provider DOWN facts, child archives) is confirmed only from actual acknowledgements; never infer shutdown from an empty effects list or a Goal ACK.
- Commands: `PlainCommand` delegates non-PTY jobs to Backplane LocalCommand; PTY jobs each own a `sigma-terminal-helper` (built by `scripts/build-terminal-helper.sh`; Native builds must precede Elixir compilation). Keep the PTY writer alive through slave cleanup and output draining. LocalCommand currently requires Linux `/proc`, so `CodexResources` rejects native turns on macOS until gsmlg-opt/backplane#159 ships; do not work around it locally. Hooks are portable: Linux uses util-linux `setsid` and `/proc`, macOS uses the packaged `sigma-setsid` helper and `ps`.
- Native tools require the OpenAI Responses transport; Anthropic and Chat Completions providers reject native custom/namespace tools before HTTP (`Sigma.Ai.Providers.ToolTransport`) until gsmlg-opt/backplane#160 ships.
- Provider credentials must not reach logs: `Sigma.Agent.CrashRedaction` redacts GenServer status and crash reports (including stack-frame arguments) for credential keys. Processes holding provider options implement `format_status/1` through it.
- Durable sidecars live under `<root_transcript>.subagents/` (notes, message board, lifetime recovery) and `.runtime`; rename/adopt/delete/fork must move, retire or independently copy them as described in the history doc.
- Protocol V1 (`sigma_protocol`) is the Web API surface for non-LiveView clients; capabilities are a closed, versioned set in `Sigma.Protocol.Envelope`.
- Local `mix assets.build` may fail on hosts with glibc older than DuskMoon's NIF baseline (duskmoon-bundler#9, closed as not planned); do not add a local workaround.
- Permission checks go through `Sigma.Coding.PermissionInterceptor` / `PermissionPolicy`; LiveView approval waits stay aligned with the interceptor timeout.
- Session JSONL files are stored per repository/workdir; in dev under `apps/sigma_web/priv/sessions/<base64-url-workdir>/`. Known repositories (dev): `apps/sigma_session/priv/repos.jsonl`.
- Agent/provider/MCP config is pi-compatible under `~/.pi/agent/`: `settings.json`, `auth.json`, `models.json`, `mcp.json`, `AGENTS.md`.
- Context assembly prefers `AGENTS.md` over `CLAUDE.md` per ancestor directory, ordered root-to-workdir so deeper instructions take precedence.

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
/settings/plugins                     -> Sigma.Web.SettingsLive
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

## Agent Note

Agent Note project: sigma

Use the shared `agent-note` skill for reviewer-first project engineering knowledge.
Before substantial design or debugging, recall relevant project notes.
At accepted decisions, significant implementation boundaries, or reproducible
blocker handoffs, evaluate durable findings and create/update notes only when the
skill's quality gate passes. For meaningful implementations, maintain a coherent
human-reviewable explanation of architecture, design rationale, actual behavior,
verification and limits; do not save a separate task-status note after each fix. This authorizes scoped capture, not whole-project curation or deletion.
No note is required for an ordinary completed task.
Contributors return candidates; the coordinating agent writes shared notes.
Apply recalled guidance only after checking its sources and target-version scope.
If the skill or MCP is unavailable, report the limitation without claiming a write.

