# Sigma Skills Implementation Plan

> Protocol ownership update (2026-09-22): use
> [`backplane-skill-protocol-migration-plan.md`](backplane-skill-protocol-migration-plan.md)
> for parser, validation, discovery, resolution, bundle preparation, resource reads,
> and Backplane read-client work. It supersedes the hand-written protocol portions
> of S1-A, S1-B, S1-C, and S4; the remaining product/UI/invocation requirements in
> this document continue to apply unless the migration plan explicitly amends them.

| Item | Value |
| --- | --- |
| Status | Ready for implementation planning; all implementation tasks below are not started |
| Date | 2026-09-09 |
| Product contract | [Sigma Skills PRD](sigma-skills-prd.md) |
| Primary repository | `gsmlg-opt/sigma` |
| Separate integration change | `gsmlg-opt/backplane` — task BP-1 only |
| Review/branch baselines | Sigma review `4d4a108`, observed branch `22d39df`; Backplane `bd5bc830` |
| Suggested placement | `docs/features/skills/sigma-skills-prd.md` and `docs/features/skills/sigma-skills-plan.md` |

## 1. Delivery objective

Implement the activation/distribution loop specified in the PRD, not a standalone completion widget or a second Agent runtime. Deliver local invocation first, then complete Backplane consumption, safe sharing, and thin API adapters.

The source register and baseline evidence are in PRD sections 1 and 14. File paths below are navigation/ownership boundaries, not evidence that every proposed module already exists. New modules and tests must be named consistently with the actual checkout.

No tests were executed for this handoff. Every work order must report its actual validation results; existing failures must be distinguished from changes introduced by the work order.

## 2. Execution constraints

Preserve the existing umbrella and functional boundaries. Use one parser, catalog, resolver, preparation service, and activation contract. Do not add Session-to-Agent production coupling or another event store, database service, marketplace, scheduler, or plugin abstraction.

Use one worktree/branch per work order. Workers edit only their assigned boundary. Shared contract amendments go through the integration owner before code is duplicated or adapted independently. Do not modify Backplane from a Sigma work order; BP-1 is a separate repository change and merge/release dependency.

Do not weaken filesystem checks to make references work, fall back to unsafe legacy publishing, turn errors into LLM prompts, or mark a feature complete from mocked tests alone. Keep source credentials, real private skills, and user session data out of fixtures.

### 2.1 Files to inspect before implementation

| Boundary | Current navigation anchors |
| --- | --- |
| Skills and configuration | `apps/sigma_session/lib/sigma_session/skills.ex`, `slash_commands.ex`, `config_manager.ex`; existing skills and slash-command tests |
| Composition | `apps/sigma_web/lib/sigma_web/protocol_session_options.ex`; `live/session_live.ex` skill-context and prompt handling; current headless bootstrap |
| Runtime/persistence | `apps/sigma_agent/lib/sigma_agent/public_runtime.ex`, `runtime.ex`, `session_context.ex`, `context_builder.ex`, `prompt_queue.ex`, `protocol_event_mapper.ex`, `protocol_subscription.ex`, `stdio.ex`; actual session journal/writer and snapshot implementations |
| Protocol | Actual files under `apps/sigma_protocol/lib/sigma_protocol/` and their codec/envelope compatibility tests |
| Tool access | `apps/sigma_tools/lib/sigma_tools/read.ex`, existing tool registration/dispatcher, `apps/sigma_coding/lib/sigma_coding/tools/read.ex`, `utils/path_utils.ex` |
| Web | `apps/sigma_web/assets/js/app.js`, `live/project_skills_live.ex`, `live/settings_live.ex`, `live/session_live.ex`, `router.ex`, `endpoint.ex`; actual Agent channel/socket modules |
| Dependencies | Root and app `mix.exs`, `mix.lock`, existing HTTP/JSON/YAML dependencies and frontend/browser test runner |
| Backplane | `apps/backplane_skills/lib/backplane/skills/api_router.ex`, `ingest.ex`, `archive.ex`, `skill.ex`, blob implementations and tests; `apps/backplane_api/lib/backplane/api/router.ex` |

Source-supported integration facts: the current resource exception is filename-based; runtime composition already has separate Session and Agent boundaries; Backplane content hashes are compressed-byte hashes and current ingest is an upsert. These constrain the work orders below. See PRD [S6, S9, S10, B3].

## 3. Milestones and parallel execution

| Milestone | Exit condition |
| --- | --- |
| M0 — Contract frozen | S0 accepted, existing baseline recorded, schemas/fixtures available to all workers |
| M1 — Local skill loop | S1-A/B/C, S2 and local S3 behavior integrated; manual-only selection, deterministic activation and resource reads work |
| M2 — Remote consumption | S4 and remote UI integrated; Backplane archives are verified, pinned and usable offline |
| M3 — Sharing and remote clients | BP-1 deployed to the test target; S5-A/B integrated; safe publication and API/Protocol parity work |
| M4 — Release acceptance | S6 passes all PRD acceptance gates; deployment smoke report and rollback instructions are committed |

| Wave | Parallel work | Integration rule |
| --- | --- | --- |
| 0 | S0 | Contracts precede parallel implementation |
| 1 | S1-A parser; S1-B catalog; S1-C artifacts/access; BP-1 Backplane conditional upload | Pure fixtures allow independent development; integrate S1-A into S1-B before accepting catalog behavior |
| 2 | S2 runtime; S3 composer; S4 remote source; S5-B transport scaffolding | UI/transports may use contract fakes, but cannot be accepted before real S2 integration |
| 3 | S5-A publishing; final S3/S5-B wiring | Publication completion requires both S4 and BP-1, not just a successful legacy upload |
| 4 | S6 release matrix | Tests run throughout development; this is the final cross-boundary acceptance gate |

Direct completion dependencies: S1-B requires S1-A; S2 requires S1-A/B/C; S3 requires S1-B and S2, plus S4 for remote views; S4 requires S1-B/C; S5-A requires S1-C, S4 and BP-1; S5-B requires S2, S4 and S5-A; S6 requires every task. BP-1 needs only the frozen publication contract to begin.

### 3.1 Shared-file ownership

The integration owner controls dependency manifests/lockfile merges and the frozen contract. S2 owns Protocol schema changes and public runtime dispatch. S3 owns `app.js`, composer rendering, skills management UI, and settings-page changes. S5-B owns HTTP routes/controllers and transport wiring. S1-C owns shared path checks. Other workers provide service interfaces and test requirements rather than editing those files concurrently.

## 4. Work orders

### S0 — Reconcile checkout and freeze contracts

**Priority:** blocking foundation. **Repository:** Sigma, with read-only Backplane inspection. **Dependencies:** none. **Owner:** integration lead.

Record actual commit SHAs and compare relevant paths against the review. Inventory built-in slash commands, session ID/repository scoping, queue/admission behavior, persistence crash boundaries, tool registration, and all web/headless composition sites. Do not assume an old file layout or a generic slash-command module contains every command.

Create `docs/contracts/skills-v1.md` containing the descriptor/source/binding/snapshot records, plain callback return contracts, request fingerprints, invocation state transitions, typed errors, digest schemes, bounded defaults, API field names, and the negotiated Protocol extension. Define exact durable record encoding and how compaction/restart preserve invocation IDs and active references. Freeze the local manifest hash canonicalization with byte-level fixtures.

Select a YAML dependency after checking the checkout and its maintained safe/bounded parsing options. Assign any new HTTP dependency to the Session adapter boundary. Confirm which bootstrap constructs the shared Session callbacks for stdio as well as web; do not move source ownership into `sigma_web` or introduce a production cycle.

Build shared synthetic fixtures: automatic and manual-only skills, duplicate names in different sources, quoted/block/nested YAML, `$ARGUMENTS`, references/assets/scripts, invalid types, malformed/cyclic paths, archive-backed Backplane records, generated records, and changed/missing digests. Specify the exact capability/precondition fixtures used by BP-1 and Sigma.

**Acceptance:** all workers can implement against frozen inputs/outputs; the test runner and pre-existing failures are recorded; baseline Protocol fixtures are captured; no unfinished behavior is advertised as an implemented capability.

**Out of scope:** feature implementation or unrelated refactoring during preflight.

### S1-A — Parser and bounded local discovery

**Priority:** P0. **Repository:** Sigma. **Dependencies:** S0. **Primary boundary:** Session skills parser/discovery and tests. **PRD:** FR-01, AC-01, AC-07.

Replace the hand-written frontmatter reader with the contract's YAML adapter. Preserve current roots, name fallback, source tagging, disabled-global compatibility, and existing list-function adapters until callers migrate. Preserve unknown metadata without interpreting unsupported runtime behavior. Validate policy types and reject duplicate YAML keys.

Bound file reads, candidate count, traversal depth, and diagnostic count. Resolve canonical roots, retain supported root symlinks, track visited directories, and report unreadable/cyclic inputs. Make one invalid package a local diagnostic rather than an exception that loses the whole catalog.

Suggested new modules under `Sigma.Session.Skills` are `Parser` and `Discovery`; their names are proposals, not current modules. Keep parsing pure and filesystem traversal separately testable.

**Required tests:** inline comments on booleans; quoted values and escaped strings; LF/CRLF; folded/literal descriptions; nested metadata; absent/invalid frontmatter; duplicate keys; missing description; directory-name fallback; scan limits; unreadable directories; symlink-root compatibility and loops; no accidental atom creation from untrusted keys.

**Acceptance:** AC-01 passes and existing discovery tests retain valid behavior. Return deterministic metadata/diagnostics without crashing unrelated discovery.

### S1-B — Effective catalog, identity, bindings, and shared context

**Priority:** P0. **Repository:** Sigma. **Dependencies:** S0 to start, S1-A to complete. **Primary boundary:** Session catalog/resolver/policy/config and shared context builder. **PRD:** FR-02/03, AC-02/03.

Implement stable logical identities separate from content digests. Merge source descriptors using explicit bindings and repository/global/Backplane precedence. Keep qualified lookup, built-in collisions, same-scope ambiguity, disabled winners, and policy filtering as pure functions.

Implement versioned catalog snapshots and source-scoped settings. Migrate legacy global disabled names conservatively. Serialize configuration read-modify-write operations, and apply changes atomically; two sessions toggling skills must not lose each other's settings. Preserve existing configuration keys.

Provide one shared skill-context builder that constructs catalog/prepare callbacks for every client. SessionContext rendering consumes the effective automatic view, while UI/API obtain their manual/management views from the same revision. Callback declarations belong here; runtime consumers are S2's responsibility.

Provide explicit refresh/change notifications with bounded rescanning, and apply changed catalogs to future admissions without changing active snapshots. S3 owns their UI presentation.

**Required tests:** stable IDs across refresh and content changes; identical names in all scopes; explicit source binding; same-scope ambiguity; disabled binding/high-priority entry with a lower candidate; legacy migration; worktree isolation; concurrent configuration writes; automatic/manual view consistency; catalog revision refresh.

**Acceptance:** one resolver explains every effective selection, and no client needs to rescan/merge skills independently.

### S1-C — Snapshots, archive validation, and resource grants

**Priority:** P0. **Repository:** Sigma. **Dependencies:** S0. **Primary boundary:** artifact/cache modules, shared path enforcement, both read implementations. **PRD:** FR-07, AC-06/07/09.

Implement immutable local snapshots and the `sha256-tree-v1` manifest. Implement staged, bounded archive preparation using `sha256-archive`, preserving the Backplane enclosing directory convention. Canonicalize every entry, reject duplicate normalized paths and unsafe types, and enforce total expanded bytes across all resources.

Add private snapshot storage with atomic publication, source/digest identity, concurrent preparation deduplication, waiter-aware cancellation, retention references, and stale-staging cleanup. A trusted snapshot contains read grants; public requests cannot construct them.

Replace the external filename-only exception with trusted grant validation. Coordinate activation wiring with S2 before removing legacy behavior. Inspect every dispatcher/read validation stage: adding support to one `read.ex` while an earlier scheduler rejects the same path is not complete. Package root reads remain read-only and do not change shell working directory or grant tool execution.

**Required tests:** external unregistered `SKILL.md` denied; activated global references allowed; project siblings and external symlink targets denied; root symlinks handled intentionally; archive traversal, absolute paths, duplicate/case-colliding paths on supported filesystems, hardlinks/symlinks, decompression limits, oversized headers and truncated streams rejected; local mutation detected; concurrent requests/cancellation cannot expose partial snapshots; failed extraction leaves no active entry.

**Acceptance:** package access works through the real dispatcher/read path and every failed validation leaves the cache unusable for that package.

### S2 — Unified activation, durable admission, and model tool

**Priority:** P0. **Repository:** Sigma. **Dependencies:** S1-A/B/C; contract-based development may begin earlier. **Primary boundary:** Agent activation/context/queue/persistence integration, Protocol schema and activation tool wiring. **PRD:** FR-04/05/10/11, AC-03/04/12–16.

Implement a small runtime activation module consuming trusted callbacks and plain snapshots. Manual invocation reserves an ID/key, prepares asynchronously, then enters existing admission as a new/follow-up turn. Preserve receipt ordering while preparation runs outside the session process. Check binding policy again before queued work starts.

Move skill-specific slash resolution into the shared entry path. Preserve `/init` and inventory-derived built-ins. Expand arguments once without shell/environment interpolation, and inject the verified body only into the owning turn. Do not mutate the historical first message or persist an unintended permanent skill mode.

Add `activate_skill` to the existing tool registration/dispatcher. A model activation stays in its current turn, obtains scoped resource grants, and produces a structured activation record. Enforce trusted origin, manual-only restrictions, deduplication, context limits, failure suppression, and total attempt budgets. Reuse permissions and tool execution; do not create a nested Agent or secondary prompt loop.

Implement durable request reservation and invocation-to-admission correlation using existing writer/log conventions. Store a request fingerprint separately from the resolved snapshot. Deduplicate concurrent requests, keep keys across compaction/restart, ignore late cancelled-task results, and mark unrecoverable in-flight work interrupted rather than automatically replaying it.

Own the `skills.v1` command/error/update schemas, closed-enum tests, and legacy subscription behavior. Expose the same service to S3 and S5-B. Make the direct/headless context builder work without web UI modules.

**Required tests:** provider call count remains zero for disabled/invalid requests; same expansion through all explicit entry paths; model activation never starts a second turn; duplicate successful activation does not duplicate body; bounded repeated failures; context overflow; delayed preparation FIFO; cancel before/after preparation and during a turn; disable while queued; two concurrent identical keys; key/body conflict; crash before/after durable admission; resume/compaction; an unavailable old artifact never resolves to a new slug version.

**Acceptance:** one durable request admits at most one prompt, task cancellation cannot leak a late admission, and local activation passes through real Agent context/dispatcher code with a mock provider.

### S3 — Composer completion, picker, and management UI

**Priority:** P1. **Repository:** Sigma. **Dependencies:** S0/S1-B interface to start; S2 for local completion; S4 for remote views. **Primary boundary:** `app.js`, session composer and skills/settings LiveViews. **PRD:** FR-06/12, AC-02/04/05.

Extend the existing menu with built-in/skill groups and source-aware candidates. Use the effective catalog revision, not a second local scan or hard-coded list. Implement `/skill ` selection, unambiguous aliases, argument hints, manual-only badges, source labels, and management diagnostics.

Handle candidate selection separately from send. Preserve IME composition, focus, argument text, keyboard behavior, current image/attachment restrictions, and cleanup on LiveView updates/remounts. Update command data when the catalog changes; do not read it only on initial mount.

Add an explicit in-session picker and remote search/install/update affordances. Source configuration uses the common settings service and credential references; S4 provides backend behavior. Show preparation, queue, active snapshot, offline cache, unsupported generated skills, and errors. A management-page invocation must select the target session.

**Required tests:** keyboard/IME interaction in the actual custom-element/shadow-DOM composition; stale LiveView/async responses; large-catalog filtering; source/name collision; disable/refresh while menu open; selecting a candidate causes zero sends/provider calls; explicit send invokes S2 once; existing composer/attachment behavior does not regress.

**Acceptance:** local manual-only skills can be selected and executed end-to-end; complete remote views only after integrating S4, not from static mock rows.

### S4 — Backplane search, verified consumption, and offline bindings

**Priority:** P1. **Repository:** Sigma. **Dependencies:** S1-B/C. **Primary boundary:** Session Backplane source/HTTP adapter and binding/cache integration. **PRD:** FR-08, AC-08/09.

Consume existing `/skills` metadata/detail/archive routes. Translate remote snake_case fields into the frozen domain contract. Treat advertised `content_hash` as the exact compressed-byte hash, not the entry-file or local tree hash. Validate policy from the downloaded package before enabling automatic use.

Use configured source aliases/base URLs and credential references. Restrict request construction and redirects to the approved source boundary. Implement deadline-aware, bounded retries for eligible reads and sanitized errors. Remote metadata lookup, artifact download, and automatic context construction are separate phases; provider serialization must perform no network I/O.

Store explicit enabled bindings and pins, cached metadata, last successful refresh, and update availability. Offline verified bindings continue working. A missing old digest, digest-changing slug, disabled source, unavailable credential, or unsupported generated entry returns the contract's specific outcome. No automatic update of active or queued content is permitted.

Expose remote search as a partial search window against the current server; do not implement fake full-registry pagination or infer completeness from a short result list. Provide service functions to S3 for source settings/search/enable/update, and to S5-B for API views.

**Required tests:** source listing/detail/download fixtures; header credential redaction; source isolation; partial response at 20/100 limits; generated entry; absent/malformed digest; metadata-download race; hash mismatch; permanent vs transient HTTP failures; Retry-After beyond deadline; offline hit/miss; source disabling; shared concurrent download; update while a snapshot is running; old digest no longer available.

**Acceptance:** a real archive-backed fixture obtained from a Backplane test service runs in Sigma, including a reference file; disconnecting that service preserves only already verified enabled use.

### BP-1 — Conditional archive publication in Backplane

**Priority:** P1, blocking safe sharing but not local execution or remote reads. **Repository:** Backplane only. **Dependencies:** S0 publication contract. **Primary boundary:** Skills API router, ingest, blob lifecycle, tests, narrowly necessary constraints. **PRD:** FR-09, AC-10/11.

Add reserved `_capabilities` discovery and conditional `PUT /skills/:slug/archive` exactly as specified in PRD section 8. Keep legacy route behavior for its clients. Verify the target route slug matches the archive-resolved slug; reject generated/non-archive replacement. Advertise the capability only when its full enforcement is deployed.

Refactor existing ingest into reusable validation/storage and atomic publication decision boundaries. The condition must be evaluated inside the create/update transaction. Test simultaneous creates using the actual unique constraint and simultaneous replacements using the old digest; a plain `Repo.get_by` followed by unconditional upsert is insufficient. The unchanged-content fast path must still honor a failing precondition.

Enforce bounded raw/multipart parsing where applicable. Return archive ETags derived from compressed bytes, without presenting an archive hash as an ETag for independently mutable JSON metadata. Preserve error/status distinctions: 428 missing condition, 412 false condition, 409 unsupported target, 422 invalid package, 201 create, 200 replace.

Stage blobs and finalize references safely. A losing/conflicting transaction must not delete a blob referenced by a winning or still-active publication. Use staging holds/deferred cleanup as needed. This work does not add historical version retention; document that old unreferenced blobs may still be removed.

**Required tests:** route ordering; capability response; create-only success/conflict; exact-digest replacement; stale digest; missing target; missing precondition; same-content wrong-precondition; target/archive slug mismatch; generated target; concurrent create/replace; database failure after blob staging; cleanup cannot remove another writer's blob; legacy API regressions; bounded invalid upload.

**Acceptance:** concurrency tests run against the real persistence path, and Sigma cannot silently overwrite a changed slug through the new endpoint.

### S5-A — Full-package export and explicit sharing

**Priority:** P1. **Repository:** Sigma. **Dependencies:** S1-C, S4 and BP-1 for acceptance. **Primary boundary:** Session export/publication modules, local publication records and tests. **PRD:** FR-09/11, AC-10/11.

Create deterministic full-package archives with one enclosing directory, metadata/resources, normalized entry metadata and compressed-byte digest. Present the publication manifest and exclusions through a service interface. Keep local source files untouched. Refuse unsafe/incomplete packages and require explicit destination/create-or-replace intent.

Discover Backplane's publication capability. Legacy servers remain usable for reads/export but fail network publication with the typed unsupported-capability result. Never fall back to legacy POST, even when a preliminary GET says the slug is absent.

Reserve a publication ID/key and immutable upload bytes, then send the appropriate conditional PUT. Persist successful IDs/digests and conflicts. A timeout or lost response is `outcome_unknown`; use bounded read reconciliation without dispatching a fresh mutation. A failed/stale replace requires a new explicit decision, not a new current-digest fetch followed by automatic retry.

Expose service operations for S3's UI and S5-B's transport; those workers own actual UI/routes. Retain unresolved operation metadata across restart and clean staging only when no unresolved publication needs it.

**Required tests:** identical input produces identical archive bytes; upload/download roundtrip retains resources; preview/exclusion policy; generated conflict; create vs approved replace; legacy capability rejection; concurrent local requests with one request key; uncertain upload outcome; digest reconciliation; stale precondition; no blind second upload; restart retains unresolved outcome.

**Acceptance:** a selected local skill can be shared to a conditional-write Backplane instance and downloaded/activated in a second fresh Sigma cache. Default behavior never overwrites another publication without a valid precondition.

### S5-B — HTTP, stdio, WebSocket and LiveView parity

**Priority:** P1. **Repository:** Sigma. **Dependencies:** S0/S2 contracts for scaffolding; S2/S4/S5-A for acceptance. **Primary boundary:** HTTP controllers/router, existing channel/stdio adapters, caller resolution and transport tests. **PRD:** FR-10, AC-04/12/15.

Expose PRD section 9's proposed routes as thin adapters. Resolve registered repositories and effective session workdirs on the server. Use S2's invocation service for HTTP, direct, stdio, WebSocket and LiveView calls; transports never parse files, build skill prompts, extract archives, or start their own loops.

Map idempotency keys, reference/expected-digest fields, 202 operation reservation, polling, cancellation and typed errors consistently. Catalog/detail reads use S1-B/S4 without requiring a provider run. Publication routes use S5-A and enforce separate delegation.

Integrate a trusted caller resolver at the deployment boundary. Remote requests with no configured trust context are denied. Do not trust a body field saying `manual`, accept arbitrary workdirs or fetch URLs, expose absolute cache paths, or add an unrelated login system.

Wire S2's negotiated Protocol extension and correlation fields. Preserve strict unknown-version/type handling, size bounds, process-term exclusion, legacy subscription event sets, and existing Agent endpoint behavior. Respect transport payload limits; do not send complete archives or cache paths through the protocol.

**Required tests:** equivalent invocation results through each adapter; repository/session ID collision isolation; unauthorized/manual-only/publish capability denial; forged origin and path injection; missing/mismatched idempotency keys; operation polling and queued cancellation; oversized arguments; ordinary prompts remain unchanged; old clients receive no unexpected enum types; no secrets/internal paths/process terms in serialized results.

**Acceptance:** transport choice cannot change selection, permissions, snapshot pinning, request deduplication, or cancellation semantics.

### S6 — Integration, release evidence and rollback

**Priority:** release gate. **Repository:** Sigma; Backplane test target is an integration dependency. **Dependencies:** all work orders. **Primary boundary:** cross-app tests, browser tests, smoke fixtures, feature documentation and operational validation.

Run the complete acceptance matrix against the integrated checkout. Reproduce the local path with a mock provider counting actual calls and checking received instructions. Run API/Protocol integration against real persistence, and exercise conditional publication against a Backplane instance running BP-1.

Inject failures at network, artifact, prompt admission, persistence, compaction, and restart boundaries. Validate that preparation runs outside the session process, one slow source does not block cancellation, and feature rollback preserves local operation and historical references.

Update README/setup instructions, `/init` skill guidance, source configuration help, API/Protocol documentation, diagnostics, and package author guidance. Remove promises that are still unsupported. Explain scope precedence, manual-only policy, cache pins, generated-skill limitations, partial remote search, conditional publication, unknown upload outcomes, and historical-artifact limitations.

**Acceptance:** every PRD AC has an actual test/smoke result and owner; both repositories' integrated SHAs are recorded; the release report lists remaining limitations rather than claiming mock coverage proves production compatibility.

## 5. Acceptance ownership matrix

| PRD criterion | Primary owner | Required verification layer |
| --- | --- | --- |
| AC-01 — parsing/discovery | S1-A | Pure parser and temporary-directory tests |
| AC-02 — one catalog/resolution | S1-B | Resolver/config tests plus S3/S5-B parity |
| AC-03 — manual-only/disabled | S1-B, S2 | Agent/tool tests with provider call counts |
| AC-04 — explicit entry parity | S2, S3, S5-B | Direct/UI/API integration |
| AC-05 — composer behavior | S3 | Real browser/custom-element/IME tests |
| AC-06 — resource access | S1-C, S2 | Real dispatcher/read tests, not path helper alone |
| AC-07 — unsafe packages | S1-A, S1-C, S4 | Malformed/hostile fixture and interrupted-I/O tests |
| AC-08 — Backplane contracts | S4 | HTTP contract fixtures and actual server smoke |
| AC-09 — pins/offline | S4, S2 | Cache/source mutation and network-disconnect tests |
| AC-10 — safe sharing | BP-1, S5-A | Real conditional writes and fresh-cache roundtrip |
| AC-11 — ambiguous publication | BP-1, S5-A | Lost-response/concurrent-write and blob-lifetime tests |
| AC-12 — durable idempotency | S2, S5-B | Concurrent requests, crash injection and restart |
| AC-13 — queue/cancel | S2 | Deterministic delayed preparation/execution tests |
| AC-14 — model activation bounds | S2 | Current-turn tool tests and permanent-failure loops |
| AC-15 — clients/security | S2, S5-B | Closed-protocol compatibility and caller-scope tests |
| AC-16 — resume/rollback | S2, S4, S6 | Compaction/recovery and feature-disable tests |

## 6. End-to-end smoke journeys

### Journey A — Manual local skill

Install a synthetic manual-only skill containing `$ARGUMENTS` and a reference file. Open the correct repository/worktree session. Type its prefix, select it without sending, enter arguments, and explicitly submit. Verify that the provider receives the expanded instructions once and can read the reference; automatic activation of the same skill fails. Repeat after toggling it disabled and confirm zero provider calls.

### Journey B — Backplane consumption and offline use

Publish a test archive to the Backplane fixture service. Search from Sigma, inspect/enable the specific digest, and activate it. Disconnect Backplane and repeat from the verified binding. An uncached skill must fail, and changing the remote slug must not alter an active invocation. A requested old digest removed from the server must report unavailable when absent locally.

### Journey C — Sharing and conflict

Export a local multi-file skill, verify the manifest, and create it through the conditional endpoint. Download it into a clean second cache and compare resources. Attempt a second create and a replacement with a stale digest: both must preserve the current artifact. Lose the upload response deliberately and verify no automatic second mutation occurs.

### Journey D — Remote invocation and restart

Submit one explicit API invocation twice concurrently with the same key. Verify one admission and one provider run. Kill the runtime around the documented persistence boundaries and retry the same request. It must return the same result or interrupted state, not repeat the task. Repeat with conflicting bodies, queued cancellation, and a legacy WebSocket subscriber attached.

## 7. Validation and evidence requirements

Each work order first runs its targeted tests, then the repository's supported compile/format/static checks for its changed boundary. S0 determines actual commands from the checkout; do not invent CI commands that the repository does not support. Integration runs the relevant Session, Agent, Tools/Coding, Protocol and Web suites, browser tests, and Backplane API/storage tests.

A worker completion report must include task ID, base/final SHA, changed files, implemented contracts, tests actually executed with pass/fail results, unexecuted validations and reasons, remaining gaps, dependency changes, and migration/rollback effects. A reviewer checks runtime behavior against the ACs, not only whether planned module names exist.

Required release evidence includes the integrated Sigma and Backplane SHAs, deployed feature capabilities, the four smoke-journey results, performance measurements on a named runner, cancellation/retry counts, and restart/compaction outcomes. Never paste real tokens or private skill contents into the report.

## 8. Rollout and rollback

| Rollout stage | Enabled behavior | Stop condition |
| --- | --- | --- |
| Local canary | Local catalog, picker, manual/model activation with bounds | Wrong source resolution, leaked grants, or duplicate admission |
| Remote read canary | One configured Backplane source, approved digest bindings | Hash disagreement, silent content switch, or retry/deadline violation |
| Publishing canary | BP-1 capability confirmed, explicit create/replace only | Lost precondition enforcement, unsafe fallback, or uncertain outcome retried blindly |
| Public-client canary | Trusted caller resolver and negotiated skills extension | Repository-scope bypass, forged trigger authority, or legacy-client regression |

Disable the failing feature flag without deleting local packages, binding history, request mappings, or active/historical snapshots. Keep already admitted work on its original artifact unless explicitly cancelled. Rollback cannot undo an already successful external publication or tool side effect; inspect the recorded outcome before taking corrective action.

Backplane's conditional endpoint is additive, so rolling Sigma back should not require deleting published skills or reverting legacy API semantics. Preserve the ability to export packages and use existing local skills while remote features are disabled.

## 9. Codex handoff directive

Read the PRD and this plan, then execute S0 before feature changes. Record the actual checkout baselines and freeze `skills-v1` contracts. Dispatch the independent Wave 1 work orders with bounded file ownership. Use fakes only to unblock development, not to claim integration completion.

Implement Sigma tasks in the Sigma repository. Submit BP-1 as a separate Backplane change and make its deployed capability an explicit prerequisite for network sharing. Preserve the existing Agent executor, permissions, session lifecycle, and Protocol compatibility.

Complete work orders one at a time per branch, report actual validation, and integrate according to the dependency table. Where current code differs from the review, document the concrete difference and adjust the bounded task; do not silently change product semantics or broaden the project.
