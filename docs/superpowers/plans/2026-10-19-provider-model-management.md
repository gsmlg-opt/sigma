# Shared Providers and Configured Models Implementation Plan

> **For agentic workers:** Use subagent-driven-development with scoped ownership and test-first behavior checks. User approved this design on 2026-10-19. Do not ask for another design approval.

**Goal:** Separate shared provider connections from configured models, fix session model authority and defaults, and allow MCP and Backplane Skills to reference providers.

**Architecture:** Preserve pi storage as an adapter. Sigma.Session.Models owns configured model membership; Providers resolves service-specific connection data; existing MCP and Skill Protocol clients remain the execution paths. Web settings and all session selection paths consume these same APIs.

**Tech Stack:** Elixir/OTP, Phoenix LiveView, Phoenix DuskMoon, Req, Backplane Skill Protocol.

**Workspace:** `/home/gao/Workspace/gsmlg-opt/sigma/.trees/pm`, branch `codex/provider-models`. The approved spec is `docs/superpowers/specs/2026-10-19-provider-model-management-design.md`.

**Delivery boundary:** Implement all three approved stages and run scoped checks/browser proof. Leave changes reviewable; do not commit, push, merge, restart the existing service, or edit user configuration.

## Coordination and API contracts

- Data worker owns `apps/sigma_session/lib/sigma_session/config_manager.ex`, new `models.ex`, `providers.ex`, `config_events.ex`, related Session tests, and provider-backed Skill source binding. It may add a narrow invalid-provider guard to `sigma_coding/mcp.ex`.
- UI worker owns SettingsLive, new settings components/LiveComponents, settings routing and settings tests.
- Coordinator owns ModelDiscovery, SessionLive/NewSessionLive/ProtocolSessionOptions, ContextPolicy, Web application config subscription startup, associated tests, docs, integration and browser proof.
- Nobody reverts another contributor's changes. Serialize all Mix/devenv build and test commands with `flock /tmp/sigma-pm-mix.lock`; never run Mix concurrently.
- `Sigma.Session.Models.list(config \\ ConfigManager.get_config())` returns maps containing `provider_id`, `model_id`, `name`, `provider_name`, `default_context_limit` (nil allowed), and `metadata` (original descriptor). It contains no resolved secrets.
- `Models.resolve(provider_id, model_id)` returns `{:ok, provider_config}` with selected `"model"` and resolved credentials only when the pair belongs to the latest configured collection, otherwise `{:error, :model_unavailable}`.
- `Models.add(provider_id, descriptors)`, `update(provider_id, model_id, updates)`, `remove(provider_id, model_id)`, and `set_default(provider_id, model_id)` return `{:ok, config}` or a tagged error. add takes a descriptor list and merges without overwriting existing metadata.
- `Sigma.Session.Providers.resolve_service(provider_id, :mcp | :skills)` returns a service descriptor or a tagged error; MCP has a full URL, Skills has an origin. Normalized provider fields use `"kind"` (`"custom"` or `"backplane"`) and `"service_origin"`; disk retains `serviceOrigin`.
- `ConfigManager.put_skill_source(id, attrs)` and `delete_skill_source(id)` expose existing settings.json skillSources as CRUD. Canonical new reference field is `providerId`.
- `Sigma.Session.ConfigEvents.subscribe()` joins a built-in :pg scope `Sigma.Session.ConfigEvents` for the current agent directory. `broadcast()` sends `{:models_changed, agent_dir}` to members. Web Application starts the scope with an explicit child spec calling `:pg.start_link/1`; broadcasts outside Web safely do nothing if the scope is absent.
- `Sigma.Ai.ModelDiscovery.discover(provider_config, opts \\ [])` returns `{:ok, [descriptor]}` or `{:error, code}`. Req options in `opts` permit fake HTTP testing; UI uses safe fixed text for each error. No credential-bearing errors or response bodies.
- Existing standalone MCP and Skill sources remain readable. Provider-backed configurations store only provider references and explicit overrides.

## Task 1: Model authority and shared provider data

Files: modify ConfigManager and its tests; create Models/Providers/ConfigEvents modules and scoped models/provider tests.

- [x] Add regression tests proving a stale current/default model does not become configured and connection updates preserve descriptors.

```elixir
test "stale selection cannot resurrect a removed model" do
  File.write!(Path.join(agent_dir, "settings.json"),
    Jason.encode!(%{"defaultProvider" => "p", "defaultModel" => "removed"}))
  File.write!(Path.join(agent_dir, "models.json"),
    Jason.encode!(%{"providers" => %{"p" => %{"models" => [%{"id" => "kept"}]}}}))
  assert {:error, :model_unavailable} = Models.resolve("p", "removed")
  assert [%{model_id: "kept"}] = Models.list()
end
```

- [x] Run scoped tests before implementation; confirm failures concern authority/missing domain APIs.
- [x] Implement contracts above. Model writes are explicit, default pair cannot synthesize membership, IDs are trimmed/nonempty, budget accepts positive integers or blank nil. Preserve unknown descriptor/provider metadata and legacy strings.
- [x] Default removal clears settings default pair; selection events cannot change defaults. Provider deletion rejects references from Models/MCP/Skills.
- [x] Run Session config/model tests and confirm collection merge, duplicate handling, metadata, stale defaults, reference deletion and no secret copying.

Run: `flock /tmp/sigma-pm-mix.lock devenv shell --no-tui -- env MIX_ENV=test mix test apps/sigma_session/test/sigma_session/config_manager_test.exs apps/sigma_session/test/sigma_session/models_test.exs apps/sigma_session/test/sigma_session/providers_test.exs`.

## Task 2: Model discovery

Files: create `apps/sigma_ai/lib/sigma_ai/model_discovery.ex` and `apps/sigma_ai/test/sigma_ai/model_discovery_test.exs`.

- [x] Test OpenAI /models and Anthropic /v1/models with saved auth modes, keyless requests, trailing slash handling, pagination, duplicate IDs, empty/invalid payloads, 401/403/404/timeout redaction.
- [x] Observe red, then implement a stateless Req module; do not add a process or new dependency.
- [x] Normalize descriptor IDs/names and valid explicitly supplied metadata, without inventing defaults or model capabilities.
- [x] Follow Anthropic pagination under a finite request bound and reject repeated cursors; do not return partial pages as successful complete discovery.
- [x] Run the discovery file and existing provider auth tests.

Core URL assertion:

```elixir
assert {:ok, [%{"id" => "model-a"}]} =
  ModelDiscovery.discover(%{"api_type" => "openai", "base_url" => endpoint,
    "resolved_key" => "test-key"}, request_options)
```

## Task 3: Independent provider and Models settings

Files: SettingsLive, new settings components as needed, router, settings tests.

- [x] Test /settings/models navigation and model CRUD, zero-model connection save, separate global defaults and per-model defaultContextLimit.
- [x] Replace the oversized provider table with responsive connection cards/details; remove Current Model and active-provider controls.
- [x] Add Backplane kind/service origin fields while preserving existing LLM API/base URL/auth configuration.
- [x] Add configured model list, provider selector, add/edit/remove, global default action and blank/custom positive context budget.
- [x] Add asynchronous discovery search/multiselect confirmation; stale provider/connection results never mutate another collection.
- [x] Keep errors local to discovery/model configuration and preserve existing credentials/context/hooks settings.
- [x] Run settings tests; update old modal assertions only where behavior deliberately changed.

## Task 4: Session selectors and context budgets

Files: SessionLive, NewSessionLive, ProtocolSessionOptions, ContextPolicy, Web Application and associated scoped tests.

- [x] Reproduce synthetic dropdown options, forged/removed selections, global default mutation, stale creation and custom context parser failures.
- [x] Consume Models.list/resolve in every selection/start path. Remove ensure_model_option, stop updating ConfigManager defaults on session changes, retain existing journal ownership/persistence ordering.
- [x] Subscribe Web views to ConfigEvents and refresh configured choices. Recheck latest membership before creating worktrees/sessions, selecting a model, or starting a subsequent prompt.
- [x] Historical unavailable models are shown as unavailable, never selectable or silently replaced. Running turns are not terminated by settings changes.
- [x] Accept arbitrary positive integer budgets; keep zero valid for token measurements elsewhere. Persist new-session model budget into metadata and preserve existing session budgets on changes.
- [x] Protocol startup consumes the same authority/default-budget rules and cannot fall through to unconfigured history.
- [x] Test all meaningful transitions and journal-failure no-side-effect behavior.

Budget parser behavior:

```elixir
assert {:ok, 128_000} = ContextPolicy.parse_context_limit("128000")
assert {:error, :invalid_context_limit} = ContextPolicy.parse_context_limit("0")
assert {:error, :invalid_context_limit} = ContextPolicy.parse_context_limit("128000x")
```

## Task 5: Provider-backed MCP

Files: ConfigManager service resolution, Settings MCP form/tests, narrow Coding MCP invalid-reference guard if needed.

- [x] Test provider-derived /mcp and inherited credential, explicit URL override precedence, no copied secrets, stale/missing provider rejection and standalone HTTP/stdio compatibility.
- [x] Add providerId/urlOverride persistence and read-time service resolution; do not persist derived URL/key copies.
- [x] Add provider/standalone selection, inherited preview and optional URL override UI.
- [x] Keep existing server IDs and repository/session MCP selection unchanged. Do not add client hot reload or replace transport.
- [x] Run ConfigManager and relevant MCP settings/client cases.

## Task 6: Provider-backed remote Skills

Files: ConfigManager source CRUD, RemoteAdapter/RemoteSource binding glue, source tests, Settings Skills/source browser.

- [x] Test provider reference resolution, origin-only endpoint, legacy standalone sources, stable display-name edits, changed origin/access binding invalidation, explicit catalog and exact offline reuse.
- [x] Implement provider-backed source CRUD without copying credentials. Preserve source identity and prevent changed access scopes reusing old cached bindings.
- [x] Add Backplane provider selector and source controls; use existing Facade.remote_catalog for explicit search/pagination.
- [x] Continue existing source_id:skill_id invocation/preparation path; do not auto merge the remote catalog into local automatic skills.
- [x] Run scoped remote adapter/source/controller and Settings Skills tests. Preserve existing digest/redirect/read-only package checks.

## Task 7: Integration, review and browser proof

- [x] Run scoped config/model/discovery/context/Session/NewSession/Protocol/settings/remote tests under the Mix lock; report any out-of-scope baseline failures without repairing them.
- [x] Run formatter on modified Elixir files, compile with warnings as errors and diff whitespace checks.
- [x] Complete a spec compliance review, then a code quality review; resolve concrete findings before final checks.
- [x] Build assets for changed LiveView classes and start an isolated local service with fixture agent_dir, sessions and repositories; leave 4580 and user files alone.
- [x] Exercise connection setup, discovery/add/manual context/default, session removal/refresh, MCP reference/override and remote Skills source browsing/preparation at desktop/mobile in both themes. Inspect actual loaded asset/version and console.
- [x] Update provider documentation and this checklist with exact checks and limits, then present the final worktree/diff and results.

## Final verification (2026-10-19)

- Combined scoped suite: 116 tests, 0 failures (seed 615427): sigma_ai 8, sigma_coding 6, sigma_agent 10, sigma_session 44, sigma_web 48. The Web set includes Settings/Models/services, NewSession, ProtocolSessionOptions, SessionChannel and Skills controller.
- SessionLive model/context/prompt/retry/manual-compaction checks: 19 selected tests, 0 failures, 72 excluded (seed 861970). Both checkpoint Retry entrypoints and manual compaction reject a removed actual agent model before journal/runtime effects; automatic completion of an existing turn is unchanged.
- Formatting: all 35 changed Elixir files pass `mix format --check-formatted`. `MIX_ENV=test mix compile --warnings-as-errors` and `git diff --check` pass. Mix commands run serially under the documented lock.
- Independent spec/quality review findings resolved: serialized model/config mutations, actual-model checks for channel prompts/retry and Web checkpoint retry/manual compaction, actionable provider reference deletion errors, stale remote-source catalog display. Final review reports no remaining findings in these repairs.
- A stale line selector earlier selected an out-of-scope terminal-bytes test, which timed out waiting for the terminal running state. This terminal behavior was not repaired or included in the scoped pass count. No whole-suite claim is made.
- Old remote skill bindings without access-scope metadata require one online refresh before exact offline reuse. Provider changes affect subsequent service resolution; no MCP hot-reconnect framework is added.
- Changes remain uncommitted on `codex/provider-models` in `.trees/pm`. The existing 4580 service and real user configuration were not changed.

Browser acceptance completed against local HTTP fixtures at 4585/4691, including actual remote-skill preparation and a streamed provider turn, both themes and desktop/mobile layouts, latest loaded modules, matching served asset hashes and clean fresh console checks. See [acceptance record](../specs/provider-model-management-acceptance.md). The isolated services were stopped after capture.
