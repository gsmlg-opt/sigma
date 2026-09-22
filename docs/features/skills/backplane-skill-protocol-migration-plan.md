# Backplane Skill Protocol Migration Plan

| Item | Value |
| --- | --- |
| Status | Implementation complete; E2E deferred and baseline unused-lock check still fails |
| Date | 2026-09-22 |
| Sigma baseline | `cecc5063d4f6281e4a6bf9e54f3897056071ac83` (`main`) |
| Package | `:backplane_skill_protocol`, Hex `~> 1.7.8` |
| Package contract | `Backplane.SkillProtocol` v1 |
| Product contract | [Sigma Skills PRD](sigma-skills-prd.md) |
| Existing implementation evidence | [Sigma Skills Local Acceptance](sigma-skills-local-acceptance.md) |

## 1. Objective

Replace Sigma-owned Skill protocol machinery with the released
`:backplane_skill_protocol` package wherever the package provides the required
contract. Preserve Sigma's current local invocation, persistence, transport, and
UI behavior while removing duplicate parsing, validation, resolution, bundle,
and resource-integrity logic.

This is a migration of ownership, not a second skills implementation. After the
cutover:

- `Backplane.SkillProtocol` owns Skill document parsing and validation, protocol
  identity, eligibility rules, descriptor/reference resolution, bundle packing
  and verification, prepared-resource reads, and the Backplane read client.
- `Sigma.Session` owns configured roots and sources, enablement, repository/global
  precedence, diagnostics presentation, prepared-root lifetime, remote bindings,
  and conversion into Sigma's stable service maps.
- `Sigma.Agent` owns invocation admission, turn lifetime, cancellation,
  deduplication, and persistence.
- `Sigma.Coding` owns tool authorization and accepts only trusted prepared roots.
- `Sigma.Web` remains a thin catalog, invocation, settings, and status adapter.

The actual OTP application name is `:backplane_skill_protocol`. Do not introduce
the misspelled `:bakcplane_skill_protocol` in manifests, configuration, or docs.

## 2. Accepted Decisions

1. Add `{:backplane_skill_protocol, "~> 1.7.8"}` only to
   `apps/sigma_session/mix.exs`. Other umbrella applications consume plain Sigma
   maps and callbacks rather than taking a direct package dependency.
2. Use the package's standard document validation profile. New discovery requires
   an explicit lowercase kebab-case `name` and nonempty `description`; remove the
   directory-name fallback.
3. Treat package errors and diagnostics as authoritative. Sigma may map them to
   existing public error codes/messages, but must not reinterpret invalid input as
   valid or add a second YAML validation path.
4. Keep repository-over-global precedence and disabled-winner behavior as Sigma
   host policy. Represent candidates as package `Descriptor`/`SkillRef` values and
   use `Backplane.SkillProtocol.Resolver` for the actual selection.
5. Replace source-directory grants with package-prepared immutable roots. A source
   `SKILL.md` path is discovery input, not runtime authority.
6. Remove the arbitrary external `SKILL.md` read exception after every activation
   path supplies a trusted prepared root.
7. Use `Bundle.pack/3`, `Bundle.prepare/3`, `PreparedSkill`, and `Resource.read/3`
   for local packages. Use `Client` and `Source.Backplane` for remote reads.
8. New snapshots use the package's `sha256:<hex>` exact archive digest and bundle
   manifest. Existing persisted `sha256-tree-v1` records remain readable history
   but are never replayed or silently resolved to new content.
9. The package intentionally does not own persistent cache, offline fallback,
   cleanup, enablement, or publication. Those remain explicit Sigma services.
10. Remote publication remains outside this migration because package v1 exposes a
    read client only. Do not fall back to the legacy unauthenticated `/skills`
    upload path.

## 3. Capability and Ownership Map

| Current Sigma capability | Target owner | Migration action |
| --- | --- | --- |
| `Skills.Parser` YAML/frontmatter parsing | Package `Parser` and `Validator` | Delete Sigma parser and direct YAML use |
| Recursive root scanning | Package `Source.Local` plus Sigma host adapter | Use package diagnostic-preserving discovery with Sigma-selected limits |
| `Skills.Skill` identity fields | Package `Descriptor` and `SkillRef` | Keep a thin Sigma view map only at app/public boundaries |
| `Skills.Catalog.resolve/2` | Package `Resolver` | Preserve Sigma precedence/enablement as policy around resolver |
| Manual/model eligibility | Package `Eligibility` | Map package denials to Sigma errors before provider admission |
| `Skills.Snapshot` tree walk/digest | Package `Bundle` and `PreparedSkill` | Replace implementation; retain module only as a temporary facade |
| Turn resource reads | Package `Resource` plus Sigma path grants | Grant prepared roots; keep dispatcher authorization in Sigma |
| Slash/body extraction | Package `Document.body_raw` | Stop reparsing or reading source files after preparation |
| Backplane catalog/resolve/artifact | Package `Client` and `Source.Backplane` | Add source adapter without copying wire codecs |
| Enablement, precedence, config | Sigma | Preserve as host policy |
| Invocation store and events | Sigma | Preserve schemas and lifecycle |
| UI/API/WebSocket/stdio | Sigma | Rewire to the same Session facade |
| Persistent cache/offline bindings | Sigma | Implement around exact package refs/manifests |
| Publication | Separate reviewed contract | Deferred; package v1 cannot perform it |

## 4. Known Package Gaps and Upstream Route

Two package gaps affect the migration. They are independent and require separate
upstream issues.

### 4.1 Diagnostic-preserving discovery

`Backplane.SkillProtocol.Source.Local.discover/2` originally stopped the entire
root on the first invalid or unreadable Skill. Sigma's accepted behavior keeps
valid skills and returns bounded per-package diagnostics. A silent local fork of
package discovery is not acceptable.

Before SP-02 implementation, file this upstream feature request:

```text
Repository: gsmlg-opt/backplane
Type: Feature
Label: internal request
Title: [internal] Add diagnostic-preserving local Skill discovery
Requesting repository: gsmlg-opt/sigma on branch main
Severity: needed

Add a public Source.Local discovery API or option that returns deterministic
descriptors plus bounded path-scoped diagnostics, continues after an invalid
Skill document, and still fails the operation for root escape, global scan-budget
exhaustion, or invalid root configuration. Error context must identify the
affected path without exposing file contents.
```

Resolved by [gsmlg-opt/backplane#37](https://github.com/gsmlg-opt/backplane/issues/37)
and released in package v1.7.2. Sigma now uses
`Source.Local.discover_with_diagnostics/2`; the temporary filesystem traversal and
issue-linked workaround have been removed.

### 4.2 Stable local bundle capture

`Backplane.SkillProtocol.Bundle.pack/3` validates the archive it creates, but the
current implementation reads source files sequentially without a pre/post source
inventory check. A concurrently changing source can therefore produce a valid
archive containing bytes from different source states. Sigma's accepted contract
requires a change to be detected or safely rejected rather than admitted silently.

Before SP-03 implementation, file this upstream bug request:

```text
Repository: gsmlg-opt/backplane
Type: Bug
Label: internal request
Title: [internal] Detect concurrent source changes during Skill bundle packing
Requesting repository: gsmlg-opt/sigma on branch main
Severity: blocker

Bundle.pack/3 must detect a source tree that changes while it is being collected.
Return a stable typed error without publishing the archive. Cover file replacement,
content/size change, add/remove/rename, and cancellation. A bounded caller retry may
then repack; the package must not combine multiple source states silently.
```

Resolved by [gsmlg-opt/backplane#38](https://github.com/gsmlg-opt/backplane/issues/38)
and released in package v1.7.2. Do not implement a second Sigma directory
fingerprint or copy-and-recheck algorithm. SP-03 must use the package's stable
capture behavior; archive verification alone is not evidence that the source stayed
stable while packing.

## 5. Migration Sequence

Work serially by default. SP-03 and SP-04 are security-sensitive and must be
reviewed together before the legacy read exception is removed. Remote work starts
only after local preparation and grants pass their acceptance gates.

| Task | Status | Initial/current worker | Escalation state | Depends on |
| --- | --- | --- | --- | --- |
| SP-00 Contract and dependency | DONE | `terra_worker` / `sol_worker` | `sol_escalated=true`, `sol_repair_rounds=1` | none |
| SP-01 Upstream package requests | DONE | `luna_worker` / `luna_worker` | `sol_escalated=false`, `sol_repair_rounds=0` | SP-00 |
| SP-02 Local discovery and catalog | DONE | `terra_worker` / `sol_worker` | `sol_escalated=true`, `sol_repair_rounds=2`, `reopened_by_user=2026-09-22` | SP-00, SP-01 |
| SP-03 Immutable preparation | DONE | `sol_worker` / `sol_worker` | `sol_escalated=false`, `sol_repair_rounds=1` | SP-00, SP-01, package v1.7.2 |
| SP-04 Activation and grant cutover | DONE | `sol_worker` / `sol_worker` | `sol_escalated=false`, `sol_repair_rounds=1` | SP-02, SP-03 |
| SP-05 Backplane read source | DONE | `sol_worker` / `sol_worker` | `sol_escalated=false`, `sol_repair_rounds=1` | SP-03, SP-04 |
| SP-06 Adapters and UI parity | IMPLEMENTATION_COMPLETE_E2E_DEFERRED | `terra_worker` / `root` | `sol_escalated=true`, `sol_repair_rounds=3`, `reopened_by_user=2026-09-22` | SP-04, SP-05 |
| SP-07 Remove legacy machinery | IMPLEMENTATION_COMPLETE_BASELINE_FAILURE | `terra_worker` / `sol_worker` | `sol_escalated=true`, `sol_repair_rounds=1` | SP-06 |
| SP-08 Release acceptance | NON_E2E_GATES_DONE | `terra_worker` / `terra_worker` | `sol_escalated=false`, `sol_repair_rounds=0` | SP-07 |
| SP-09 Remote argument hints | DONE | `sol_worker` / `sol_worker` | `sol_escalated=false`, `sol_repair_rounds=0` | SP-05, SP-08 |
| SP-10 Publish protocol package | DONE | `sol_worker` / `sol_worker` | `sol_escalated=false`, `sol_repair_rounds=0` | SP-09 |
| SP-11 Activate package v1.7.7 | DONE | `terra_worker` / `sol_worker` | `sol_escalated=true`, `sol_repair_rounds=2`, `reopened_by_user=2026-09-22` | SP-10, SP-12, SP-13 |
| SP-12 Publish deterministic package | DONE | `sol_worker` / `sol_worker` | `sol_escalated=false`, `sol_repair_rounds=0` | SP-11 diagnosis |
| SP-13 Activate package v1.7.8 | DONE | `terra_worker` / `terra_worker` | `sol_escalated=false`, `sol_repair_rounds=0` | SP-12 |

ROUTE task=SP-00 agent=terra_worker reason=bounded dependency and contract adapter work

ROUTE task=SP-01 agent=luna_worker reason=fully specified upstream issues and no code design

ROUTE task=SP-02 agent=terra_worker reason=routine domain adapter and focused catalog migration

ROUTE task=SP-02 agent=sol_worker reason=focused regressions and cross-caller eligibility semantics

ROUTE task=SP-03 agent=sol_worker reason=filesystem integrity and immutable artifact lifecycle

ROUTE task=SP-04 agent=sol_worker reason=coupled cross-app authorization and turn-lifetime change

ROUTE task=SP-05 agent=sol_worker reason=authenticated remote protocol, integrity, and cache boundaries

ROUTE task=SP-06 agent=terra_worker reason=bounded existing API and LiveView integration

ROUTE task=SP-06 agent=sol_worker reason=Terra compile failure and coupled adapter/UI repair

ROUTE task=SP-07 agent=terra_worker reason=cross-module cleanup after verified cutover

ROUTE task=SP-08 agent=terra_worker reason=repository-wide acceptance and release evidence

ROUTE task=SP-08A agent=luna_worker reason=fully specified stale retry metadata assertion

ROUTE task=SP-09 agent=sol_worker reason=cross-repository protocol compatibility and strict wire decoding

ROUTE task=SP-10 agent=sol_worker reason=unified release writes main, GitHub Release, Hex packages, and image

ROUTE task=SP-11 agent=terra_worker reason=bounded published dependency and lock update

ROUTE task=SP-11 agent=sol_worker reason=Terra dependency artifact and lock mismatch before focused tests

ROUTE task=SP-12 agent=sol_worker reason=unified release carries a protocol integrity fix across GitHub, Hex, and image artifacts

ROUTE task=SP-13 agent=terra_worker reason=bounded published dependency and lock update with established regressions

### SP-00 - Freeze the Consumer Contract and Add the Dependency

**Objective:** establish one package-backed Session facade before behavior changes.

**Required reading:** this plan, `docs/contracts/skills-v1.md`, package v1 contract,
`apps/sigma_session/mix.exs`, current `Skills`, `Catalog`, and `Snapshot` modules.

**Allowed edits:** Session manifest/lockfile, Skill contract docs, new Session adapter
types/tests. Do not edit Agent, Coding, Tools, or Web behavior.

**Work:**

- Add the Hex dependency and record the resolved package version/checksum.
- Amend `docs/contracts/skills-v1.md` so package terms are authoritative and mark
  the old `sha256-tree-v1` snapshot as historical.
- Define a single `Sigma.Session.Skills` facade returning Sigma-owned maps. Keep
  package structs inside `sigma_session`.
- Define exhaustive error mapping from package `Error.code/phase/retryable` and
  validation diagnostics to existing Sigma public errors.
- Add package fixture tests for CRLF, BOM, nested metadata, duplicate keys,
  invocation booleans, capabilities, and standard-name validation.

**TDD red checks:** missing `name` and non-kebab names are rejected; a package error
never leaks an absolute path or raw document through public JSON.

**Acceptance:** dependency resolves from Hex, `sigma_session` compiles alone, and
the adapter tests prove package-standard parsing without changing callers.

**Validation:**

```bash
mix deps.get
mix deps.tree
mix test apps/sigma_session/test/sigma_session/skills_protocol_test.exs
mix compile --warnings-as-errors
```

### SP-01 - Route Package Gaps Upstream

**Objective:** create both internal requests described in section 4, bind the
temporary discovery adapter to its issue number, and record the stable-pack release
dependency for SP-03.

**Allowed edits:** upstream issue only at first. The SP-02 implementer adds the
workaround comment at the actual callsite. Do not modify Backplane from Sigma.

**Acceptance:** each issue has the correct type, label, requester/branch, expected
behavior, minimal reproduction, and severity; SP-02 has the discovery issue number;
SP-03 is marked blocked until the stable-pack fix is released and pinned.

**Validation:** read the created issue back with `gh issue view` and include its URL
in the SP-02 handoff. External mutation requires explicit execution authorization.

### SP-02 - Replace Parsing, Eligibility, and Resolution

**Objective:** make the package authoritative for local Skill documents and
selection while preserving Sigma host policy and diagnostic isolation.

**Required reading:** current `skills.ex`, `skills/parser.ex`, `skills/catalog.ex`,
package `Parser`, `Validator`, `Eligibility`, `Descriptor`, `SkillRef`, `Resolver`,
and the SP-01 issue.

**Allowed edits:** Session skills modules/tests and direct Session callers needed
to consume the facade. Exclude snapshots, Agent turn state, Coding grants, and UI.

**Work:**

- Convert each configured repository/global source into stable source IDs and
  precedence values.
- Use package standard parsing/validation. Preserve exact `Document` data long
  enough for eligibility and preparation; expose only bounded Sigma view fields.
- Remove directory-name fallback and add a diagnostic migration message.
- Use `Eligibility.evaluate/3` for automatic and explicit selection.
- Use `Resolver.resolve/2` for name and qualified reference resolution; check the
  winning candidate's Sigma enablement after resolution so a disabled winner does
  not fall through.
- Use the package discovery API when the upstream release supports diagnostics;
  otherwise keep the issue-linked candidate enumerator only.

**TDD red checks:** one invalid package does not hide a valid sibling; missing name
is diagnosed; repository wins over global; equal-rank duplicates are ambiguous;
disabled winner does not fall through; manual-only is automatic-denied but
explicit-allowed; source-qualified lookup never switches source.

**Acceptance:** all catalog consumers receive the same revision and selection,
and `Sigma.Session.Skills.Parser` no longer exists.

**Validation:**

```bash
mix test apps/sigma_session/test/sigma_session/skills_test.exs
mix test apps/sigma_session/test/sigma_session/slash_commands_test.exs
mix compile --warnings-as-errors
```

**Completed after explicit reopen (2026-09-22):** package v1.7.2 now owns bounded
diagnostic-preserving traversal and containment. Catalog resolution accepts an
explicit or automatic trigger, model activation and context use automatic
eligibility, slash invocation and suggestions use explicit eligibility, and the
Agent context renderer trusts the already-eligible Session view. The original
escalation record and repair count remain historical task metadata.

### SP-03 - Replace Snapshot Logic with Verified Preparation

**Objective:** replace source-root snapshots with immutable package-prepared roots.

**Required reading:** current `Snapshot`, package `Bundle`, `BundleManifest`,
`PreparedSkill`, `Resource`, and current invocation persistence contract.

**Allowed edits:** Session preparation/cache modules and focused tests. Coordinate
interfaces with SP-04; do not change read authorization yet.

**Work:**

- Using the pinned v1.7.2 stable-pack fix, implement local preparation as
  `Bundle.pack/3` followed by `Bundle.prepare/3` in operation-owned storage. Pass
  explicit package limits and cancellation checks.
- Require logical bundle root/name agreement. Do not set
  `validate_directory_name: false` as a compatibility escape hatch.
- Return a Sigma snapshot view containing exact `SkillRef`, artifact digest,
  manifest, prepared root, `Document.body_raw`, and provenance.
- Define ownership: an invocation owns its archive/staging/prepared destination;
  terminal completion/cancellation removes it, while active turn grants retain it.
  Startup cleanup removes only proven stale operation-owned paths.
- Map the package's stable-capture failure to Sigma `source_changed`; allow at most
  one bounded retry before failing. Never reread the source tree after the package
  returns a verified bundle.
- Keep historical `sha256-tree-v1` records displayable but non-replayable.

**TDD red checks:** mutation after preparation cannot alter instructions/resources;
links and special files fail; add/remove/replace during packing returns
`source_changed`; oversize/cancelled preparation exposes no destination; same content
produces the expected package manifest; stale cleanup cannot remove an active root;
old digest requests never resolve to current content.

**Acceptance:** `Skills.Snapshot` is either removed or is a thin facade over package
preparation, with no custom filesystem manifest or digest implementation.

**Validation:**

```bash
mix test apps/sigma_session/test/sigma_session/skills_preparer_test.exs
mix test apps/sigma_session/test/sigma_session/skills_test.exs
mix compile --warnings-as-errors
```

### SP-04 - Cut Activation and Resource Grants to Prepared Roots

**Objective:** make every explicit/model activation consume one verified prepared
Skill and remove source-path authority.

**Required reading:** `SlashCommands`, `ActivateSkill`, Agent skill invocation and
turn-state code, both read adapters, `PathUtils`, and SP-03 interfaces.

**Allowed edits:** Session slash expansion, Agent, Tools, Coding, and their focused
tests. Exclude Web presentation and remote sources.

**Work:**

- Make slash/API/model activation resolve and prepare before admission.
- Expand arguments against package `Document.body_raw` exactly once; never reread
  `skill.path` after preparation.
- Store exact ref/digest in invocation records and use the prepared root for the
  owning turn's read grants.
- Propagate cancellation through package `cancelled?` checks and discard late
  preparation results.
- Release prepared storage only after the owning turn and its tool tasks finish.
- Remove `allow_skill_files?: true` and authorize external reads only under trusted
  prepared roots. A package cannot grant write, shell, or network authority.

**TDD red checks:** arbitrary external `SKILL.md` is denied; prepared nested resource
is readable; sibling/escaping paths are denied; slash/API/model paths inject identical
bytes and digest; manual-only and disabled requests cause zero provider calls; late
cancelled preparation cannot admit a prompt; cleanup waits for tool completion.

**Acceptance:** no runtime path grants a mutable source directory, and all current
local activation entry points pass through the same prepared snapshot.

**Validation:**

```bash
mix test apps/sigma_agent/test/sigma_agent/skill_invocation_test.exs
mix test apps/sigma_tools/test/sigma_tools_test.exs
mix test apps/sigma_coding/test/sigma_coding/utils/path_utils_test.exs
mix test apps/sigma_session/test/sigma_session/slash_commands_test.exs
mix run --no-start scripts/verify-skills-local-smoke.exs
```

### SP-05 - Adopt the Package Backplane Read Source

**Objective:** add remote catalog/resolve/prepare without copying HTTP or wire logic.

**Required reading:** package `Client` and `Source.Backplane`, Sigma credential/source
configuration, binding contract, and Backplane Skill Protocol auth requirements.

**Allowed edits:** Session remote source/config/cache modules and tests. Exclude
publication and provider serialization.

**Work:**

- Construct one instance-scoped package client from configured origin, source ID,
  non-secret access-context ID, and credential supplier.
- Use package catalog pagination, exact resolve, and one-shot prepare APIs.
- Persist explicit bindings and exact refs/manifests in Sigma. A remote catalog row
  is metadata only and cannot enter automatic context before verified preparation.
- Build offline reuse as a Sigma-owned verified cache keyed by source ID, skill ID,
  revision, and artifact digest. Package one-shot failures never silently fall back;
  offline selection must be an explicit host policy decision using a previously
  verified prepared artifact.
- Keep network I/O outside provider serialization and the Agent GenServer.

**TDD red checks:** redirects are refused; credentials do not appear in errors;
resolve happens once per online preparation; digest mismatch publishes no cache;
requested historical revision never falls forward; explicit offline binding works;
uncached offline selection fails; concurrent prepares cannot expose partial roots.

**Acceptance:** all remote protocol traffic is performed by the package, and Sigma
owns only configuration, binding, cache lifetime, and error presentation.

**Validation:** focused Session tests with a fake package transport, followed by a
real Backplane test-instance smoke for catalog, exact resolve, artifact verification,
and prepared resource read. Record server and consumer SHAs.

**SP-05 evidence (2026-09-22):**

- Consumer: Sigma `cecc5063d4f6281e4a6bf9e54f3897056071ac83` plus the uncommitted
  migration diff. Server: Backplane `13cd225fab4f1f1740c0e4ba6dba37f938b363cd`.
  The resolved Hex package was `backplane_skill_protocol` 1.7.2 with package
  checksum `302ff7f9e34dce8b3d9fc16ba6e50855771dc3360b084144443f0f602685ad75`
  and registry checksum `06a49c9d382ae8d335158a8df90b4bc3f424370d56e19464e3761d57c058547d`.
- `mix run --no-start /tmp/sigma_sp05_publish.exs` in Backplane exited 0 and
  published `skill/sigma-local-smoke-1790063077658234` through
  `Backplane.Skills.Ingest.ingest/2` at exact revision
  `r-015417f67cc22bad8c96e885a0b706a83668c794ca8a43dbe141c0b1e3a4a69b`.
- `mix run --no-start /tmp/sigma_sp05_consume.exs` in Sigma exited 0 using
  `http://localhost:4220`, source `sigma-local-smoke`, access context
  `client:sigma-local-smoke`, and the process-supplied `LOCAL_BACKPLANE_TOKEN`.
  Authenticated catalog returned one row; exact resolve and artifact digest matched;
  online preparation read `SKILL.md` and the 39-byte nested resource; explicit
  offline reuse returned the same exact prepared root with a fail-on-call transport.
- `mix run --no-start /tmp/sigma_sp05_cleanup.exs` exited 0 after deleting the
  fixture through `Backplane.Skills.delete/2`. The exact skill and revision counts
  were zero and the unreferenced blob was absent. A final authenticated Sigma
  catalog request returned zero rows and no cursor. All disposable local fixture,
  consumer-cache, metadata, and script files were removed.
- Local automated validation passed: focused SP-05 tests 6/6, complete
  `sigma_session` tests 255/255, format check, warnings-as-errors compile, and
  `git diff --check`. The host had no `unbuffer`, so the recorded `mix` commands ran
  directly. Live validation exposed no implementation defect and consumed no
  additional repair round.

### SP-06 - Rewire Public and UI Adapters

**Objective:** preserve user-visible behavior while exposing package-backed identity
and status consistently.

**Allowed edits:** skills controller, Protocol/WebSocket/stdio composition, Skills
LiveViews/composer data, and focused tests. Do not parse or prepare packages in Web.

**Work:**

- Rewire all adapters to the Session facade and catalog revision.
- Expose opaque source/skill/revision/digest values without package structs,
  credentials, absolute paths, or package bodies.
- Show strict-validation diagnostics and unsupported historical digest status.
- Add remote source/offline state only after SP-05 passes; selection never downloads
  or invokes until explicitly submitted.
- Keep legacy clients from receiving unnegotiated event types.

**Acceptance:** UI, HTTP, WebSocket, stdio, and direct runtime resolve the same Skill
and exact digest; selection alone causes zero provider calls and zero downloads.

**Validation:** existing controller, LiveView, Protocol, and invocation tests plus a
desktop browser smoke for catalog, selection, invocation, diagnostics, and remote
offline state. Mobile/responsive validation is not part of this task.

**Blocked evidence (2026-09-22):** automated Web, Session, Agent, Protocol, and
composer checks passed, but desktop Chrome acceptance failed after the second and
final Sol repair round. The remote metadata request returned `200` with the exact
candidate while the connected LiveView contained no `.slash-command-menu`: an
async LiveView patch removed the hook-created node, and `updated()` did not rebuild
it. Candidate selection, keyboard behavior, and explicit submission therefore
remain unaccepted. SP-07 and SP-08 must not start until this task is explicitly
reopened with a new repair decision.

The user explicitly reopened SP-06 for a third and final Sol repair round. That
round added idempotent menu reattachment and passed its focused Bun checks, assets
build, format check, and `git diff --check`. Desktop Chrome then confirmed one menu
node after the async LiveView patch, and Enter/Tab selection rewrote the composer to
the exact remote reference without sending a message or requesting resolve/artifact.
However, the menu is painted behind `.sigma-session-transcript`: a viewport capture
does not show the candidate, `document.elementFromPoint/2` at the candidate center
returns the transcript, and two real candidate clicks timed out. SP-06 remains
blocked after `sol_repair_rounds=3`; mouse/visible selection, explicit submission,
stale-query protection, and offline-state acceptance are not complete. SP-07 and
SP-08 must not start without an explicit new repair decision.

The user then explicitly reopened progress and directed that E2E not run during
development. A scoped CSS repair now lets an open menu escape the composer's normal
scroll clipping and raises the footer above the transcript; the closed state retains
the existing scroll behavior. Bun composer tests passed 4/4, `mix assets.build`,
`mix format --check-formatted`, and `git diff --check` passed, and the compiled CSS
contains the conditional override. Browser click, IME, submission, stale-query, and
offline checks were intentionally not run. SP-06 is therefore not accepted as DONE;
its remaining E2E evidence is deferred to SP-08. By this user-approved sequencing
change, SP-07 may proceed from the completed non-E2E implementation checks.

### SP-07 - Remove Legacy Protocol Machinery

**Objective:** leave one protocol implementation after the cutover.

**Allowed edits:** obsolete modules/tests/dependencies and affected documentation.

**Work:**

- Delete `Sigma.Session.Skills.Parser` and custom snapshot traversal/digest code.
- Remove direct `yaml_elixir`/`yamerl` dependencies when `rg` confirms no remaining
  Sigma use; transitive package dependencies may remain in `mix.lock`.
- Remove manual body splitting and any duplicated resolver/eligibility branches.
- Remove the temporary discovery adapter only after the upstream package release is
  pinned and its diagnostic behavior is covered in Sigma tests.
- Update the old local acceptance document as historical evidence; do not rewrite
  its prior test claims as current package evidence.

**Acceptance:** repository search finds no duplicate YAML parser, archive validator,
tree digest, package resolver, or unrestricted external `SKILL.md` exception.

**Validation:**

```bash
rg -n "YamlElixir|yamerl_constr|sha256-tree-v1|allow_skill_files" apps
mix deps.unlock --check-unused
mix format --check-formatted
mix compile --warnings-as-errors
mix test
git diff --check
```

**SP-07 evidence (2026-09-22):** the Sigma parser was deleted, the direct
`yaml_elixir` dependency and unrestricted external `SKILL.md` exception were
removed, local and remote argument expansion share one implementation, and the
legacy identifier scan under `apps` returns no matches. Focused Coding and Session
tests, warnings-as-errors compilation, format, and `git diff --check` passed. A
stale retry metadata assertion found by the first full suite was repaired as the
independent SP-08A task; the subsequent full suite passed. The required
`mix deps.unlock --check-unused` still exits nonzero for pre-existing unrelated
`ex_doc`, `makeup`, `zigler`, and associated lock entries, so SP-07 is not recorded
as DONE even though its implementation checks pass.

### SP-08 - Release Acceptance and Rollback Evidence

**Objective:** prove the package-backed system is behaviorally complete before the
old path is considered removed.

**Required evidence:**

- Focused and full test commands with exit codes.
- Exact resolved `backplane_skill_protocol` version/checksum.
- Local manual and model activation through a real dispatcher/read path.
- API/WebSocket/stdio parity and session restart behavior.
- Real Backplane catalog/resolve/artifact smoke when remote read is enabled.
- Production compile, assets, release build, isolated release boot, and local Skill
  smoke using the built release.
- Package-source mutation, cancellation, stale cleanup, and missing historical
  artifact cases.

**Release gates:**

```bash
mix format --check-formatted
mix compile --warnings-as-errors
mix test
mix run --no-start scripts/verify-skills-local-smoke.exs
MIX_ENV=prod mix assets.deploy
MIX_ENV=prod mix sigma.rel-build
git diff --check
```

Do not mark SP-08 complete if a required check is unrun. Report environment-blocked
checks separately. The current host lacks `unbuffer`; use a PTY or install the
documented helper before claiming the exact `unbuffer mix ...` command passed.

**SP-08 non-E2E evidence (2026-09-22):** `mix format --check-formatted`,
`mix compile --warnings-as-errors`, the full umbrella `mix test`,
`MIX_ENV=prod mix assets.deploy`, `MIX_ENV=prod mix sigma.rel-build`, and
`git diff --check` all exited 0. The release executable reports `sigma 0.3.0`.
The resolved package is `backplane_skill_protocol` 1.7.2 with package checksum
`302ff7f9e34dce8b3d9fc16ba6e50855771dc3360b084144443f0f602685ad75`
and registry checksum
`06a49c9d382ae8d335158a8df90b4bc3f424370d56e19464e3761d57c058547d`.
Per the user's instruction not to run E2E during development, browser interaction,
live Backplane reads, local Skill smoke, provider invocation, isolated release
boot, and the remaining SP-06 interaction/offline scenarios were not run. SP-08
therefore remains `NON_E2E_GATES_DONE`, not DONE.

### SP-09 - Preserve Remote Argument Hints

**Objective:** expose committed `argument-hint` metadata in remote catalog rows
without downloading an artifact during selection or breaking strict v1 clients.

Backplane now keeps the legacy catalog descriptor shape by default and exposes the
nullable `argument_hint` field only when the client requests
`fields=argument_hint`. The field comes only from the committed revision manifest;
the selected fields are cursor-bound. The package decoder accepts string, null, and
legacy omission while continuing to reject wrong types and unknown descriptor
fields. Sigma requests the field and maps it through its bounded public view.

**SP-09 evidence (2026-09-22):** Backplane package client tests passed 20/20,
Publication tests 10/10, router tests 9/9, the full protocol package 67/67, and the
full Skills app 196/196. Package-isolated warnings-as-errors compilation, formatting,
and diff checks passed. Sigma warnings-as-errors compilation, focused remote adapter
tests 3/3, formatting, and diff checks passed. Backplane umbrella compilation remains
blocked by the pre-existing clause-grouping warning at
`apps/backplane_system/lib/backplane/settings/oauth_refresher.ex:160`, outside this
task's diff. No E2E was run.

Backplane commit `d485764cc31b74b109eb167aa3f7831931f61b5a` was pushed to
`main`. Release workflow `35730016430` completed successfully and published GitHub
Release/tag `v1.7.7`, all four unified-version Hex packages, and the Docker image
from that exact SHA. Hex exposes `backplane_skill_protocol` 1.7.7 with package
checksum `6eb55601e9244aab244486d78d4b49976ad23cac0808a05084c1b8e474fd7969`
and registry checksum
`45c4262ef8dfd4798ddd6e985146832310b3a2410a858b6a917348e4001149b0`.

Sigma now requires and locks `backplane_skill_protocol ~> 1.7.7`. The first scoped
dependency update also selected `mint` 1.10.1; preserving the existing 1.10.0 lock
then left the local artifact mismatched, so SP-11 escalated once. A lock-constrained
`mix deps.get` restored the 1.10.0 artifact without lock drift. The focused remote
adapter tests then passed 3/3 and proved `fields=argument_hint` plus the mapped hint;
warnings-as-errors compilation, formatting, and diff checks passed.

Final review found that two same-content preparations can produce different archive
digests because package 1.7.7 lets `:erl_tar` write changing entry metadata. The
package-boundary regression failed 12/13 before the fix and passed 13/13 after
setting fixed tar metadata. Injecting the identical uncommitted fix into Sigma's
ignored dependency artifact made the deterministic regression pass 1/1 and the full
Session suite pass 261/261. The artifact was then restored to published 1.7.7 and
force-compiled, so Sigma had no hidden patched dependency. Both Sol repair rounds
were exhausted and SP-11 stopped until the user explicitly reopened the release.

The reopened work published the two-file deterministic archive repair as Backplane
commit `ed17fb7f32f29d125019f8e1be70c95449674c58`. Release workflow `35736723510`
completed successfully and published GitHub Release/tag `v1.7.8`, all four unified
Hex packages, and the Docker image from that exact SHA. Sigma now requires and locks
`backplane_skill_protocol ~> 1.7.8` with package checksum
`055f30addc50cb0f9b83c27782504d2c189218e19799ee508073356affd25e7f`
and registry checksum
`59ec001c42d9f19be320d80b9ee9c23df3475d2e83ab739ba52cf02da92dc432`;
`mint` remains at the existing 1.10.0 lock.

Against the published 1.7.8 package, the deterministic regression passed 1/1, the
full Session suite passed 261/261, the remote adapter suite passed 3/3, and
warnings-as-errors compilation, formatting, and diff checks passed. The first full
umbrella run had one unrelated timing assertion land exactly at its 350 ms boundary;
the same-seed focused rerun passed without changing the assertion, and a second full
umbrella run passed 1,039 tests with one exclusion.

No local E2E, browser, live Backplane, provider, smoke, or release-boot check was run.
The standard release workflow's own qualification, including its browser
qualification, passed in CI. No GitHub issue was created because the first fix was
implemented and released directly.

## 6. Compatibility and Rollout

Use a short-lived runtime feature flag only during integration:

| Stage | Behavior | Stop condition |
| --- | --- | --- |
| A | Package parse/validate behind existing catalog facade | catalog or diagnostic mismatch |
| B | Package resolver/eligibility | wrong winner, fallback, or policy bypass |
| C | Package local preparation with old grants still disabled | mutable result or cleanup race |
| D | Prepared-root grants for local activation | path escape or provider duplication |
| E | Package Backplane read source | auth leak, digest mismatch, or revision fallback |
| F | Remove old code and flag | any adapter still depends on legacy shapes |

Rollback may select the previous application release, but must not reinterpret new
package refs as old tree digests. Preserve invocation records and prepared artifacts
needed by active work until those turns finish. Never delete user Skill source trees,
remote artifacts, or historical records during rollback.

## 7. Baseline Evidence

At plan creation:

- Sigma `main` was clean at `cecc5063d4f6281e4a6bf9e54f3897056071ac83`.
- Backplane `main` was observed at `3bed201b668685cdc6c9e01397be4de93ea0529f`.
- Hex reported `backplane_skill_protocol` 1.7.0 as the current release.
- The focused existing regression suite passed in a PTY: `sigma_coding` 10 tests,
  `sigma_session` 17 tests, and `sigma_tools` 7 tests.
- The requested `unbuffer` wrapper was unavailable (`command not found`, exit 127);
  the PTY run, not the blocked wrapper command, is the passing evidence.
- No project-scoped Agent Note matched this migration. Live source and package v1
  contract evidence therefore control this plan.

## 8. Completion Definition

The migration is complete only when:

1. Package 1.7 or a reviewed compatible later release is the sole Skill protocol
   implementation in Sigma.
2. All local entry paths prepare one immutable package before provider admission.
3. Runtime reads are restricted to the workdir or trusted prepared roots.
4. Current local user workflows and public adapters pass equivalent behavior tests.
5. Remote reads, if enabled, use the package client with exact revision/digest proof.
6. Legacy code and temporary workarounds are removed or have a live upstream issue,
   bounded scope, and explicit removal condition.
7. Every release gate has passing evidence, or the feature remains incomplete.
