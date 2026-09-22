# Sigma Skills V1 Contract

Status: frozen S0 compatibility contract. `:backplane_skill_protocol ~> 1.7.8`
is authoritative for new Skill protocol terms.

This document records the first implementation boundary for
`docs/features/skills/sigma-skills-prd.md`. It is intentionally narrower than
the complete release gate: local parsing, catalog resolution, activation,
resource grants, remote reads, publication, and public transports remain
separate work orders.

New protocol work uses `Backplane.SkillProtocol` v1 for document parsing and
validation, descriptors and references, resolution, bundle verification, and
prepared-resource reads. Sigma exposes only its own plain maps at service and
public boundaries; package structs do not leave `sigma_session`. Sigma retains
thin Session facades for host policy and stable cross-application maps.

## Baseline

- Sigma checkout: `e59e49a298e66a7c571cec2e7878ae85b082f8b0`
- PRD observed Sigma baseline: `22d39dfa05f3a718fb506d348f537c35279a9b0f`
- Runtime: Elixir umbrella (`sigma_session`, `sigma_agent`, `sigma_coding`,
  `sigma_protocol`, `sigma_web`)
- Supported verification: `mix format --check-formatted`,
  `mix compile --warnings-as-errors`, `mix test`

The legacy implementation pins `yaml_elixir ~> 2.12` (resolved as 2.12.2, with
`yamerl 0.10.0`) behind `Sigma.Session.Skills.Parser`. It discovers `SKILL.md` below
`~/.agents/skills` and `<workdir>/.agents/skills`. It exposes absolute paths
internally and uses name-based global disable settings. These are compatibility
inputs to the migration, not the V1 public identity.

The package standard validation profile requires an explicit lowercase
kebab-case `name` and nonempty `description`. Directory-name fallback is not a
valid new-document interpretation.

`Sigma.Agent.PublicRuntime` and `Sigma.Protocol.Envelope` are the shared
headless boundary. Protocol V1 currently has no skill command or event types;
S2 owns the additive `skills.v1` extension and must preserve all existing
commands/events for legacy clients. `sigma_session` must not gain a production
dependency on `sigma_agent`.

## Domain records

These shapes are plain maps or structs at service boundaries. Internal cache
paths never cross a public boundary.

### Skill source

```text
%{
  source_id: binary(),
  kind: :repository | :global,
  alias: binary(),
  location: binary(),
  credential_ref: binary() | nil,
  enabled?: boolean(),
  scope: binary() | nil
}
```

### Descriptor and binding

```text
descriptor = %{
  skill_id: binary(),
  source_id: binary(),
  source_key: binary(),
  name: binary(),
  description: binary(),
  metadata: map(),
  diagnostics: [map()],
  disable_model_invocation?: boolean(),
  argument_hint: binary() | nil
}

binding = %{
  skill_id: binary(),
  source_id: binary(),
  enabled?: boolean(),
  content_pin: %{scheme: binary(), value: binary()} | nil,
  provenance: binary()
}
```

`skill_id` is a stable logical identity within a source. It is not a display
name, absolute path, archive digest, or latest-content pointer. Unqualified
resolution is explicit binding, repository, then global;
multiple matches in the winning scope return `ambiguous_skill`. A disabled
winner does not fall through to a lower-priority source.

### Snapshot

```text
snapshot = %{
  skill_id: binary(),
  source_id: binary(),
  ref: %{
    source_id: binary(),
    skill_id: binary(),
    revision: binary() | nil,
    artifact_digest: "sha256:" <> lowercase_hex()
  },
  digest: "sha256:" <> lowercase_hex(),
  root: internal_path(),
  manifest: map(),
  entry_body: binary(),
  provenance: map(),
  ownership: %{operation_root: internal_path(), token: binary()}
}
```

New snapshots use the package `BundleManifest.artifact_digest`: the exact
compressed archive bytes represented as `sha256:<lowercase-hex>`, with the
package bundle manifest as the resource inventory. Snapshot roots are trusted
internal values and are not accepted from model or public request payloads.

The operation ownership fields are internal lifecycle data and are never accepted
from model or public request payloads. `sha256-tree-v1` is historical Sigma
persistence only. Existing records remain readable for history, but are never
replayed or silently resolved to new content, and no new snapshot may use that
scheme.

## Invocation contract

An invocation request contains `request_id`, `request_key`, `principal`,
`repository_id`, `session_id`, exactly one `skill_id` or qualified `reference`,
`arguments`, optional `expected_digest`, and `mode: "next_turn"`.

The request fingerprint is computed from the normalized request fields and is
stored separately from the resolved snapshot. A repeated key with the same
fingerprint returns the existing operation; the same key with different fields
returns `idempotency_conflict`.

State transitions are:

```text
preparing -> queued -> running -> completed | failed | cancelled | interrupted
preparing -> completed | failed | cancelled | interrupted
queued     -> cancelled | interrupted
```

Preparation is outside the session process. Policy and binding are rechecked
before queued work starts. A cancelled preparation cannot admit a late prompt.
Restart marks unrecoverable in-flight work `interrupted`; it never silently
replays a provider turn. Active and queued work retain their prepared snapshot.

`$ARGUMENTS` is replaced once as a literal token. No shell, environment,
recursive, or command substitution is allowed. If absent, arguments are
appended in a separate labeled data block. Empty arguments are valid.

## Errors and limits

Service errors use a stable code, safe message, retryability, and correlation
ID. The initial closed set is:

```text
skill_not_found, ambiguous_skill, skill_disabled,
manual_invocation_required, unsupported_skill_kind, invalid_skill_metadata,
source_changed, remote_unavailable, remote_changed, digest_mismatch,
unsafe_archive, resource_denied, artifact_unavailable,
context_budget_exceeded, queue_full, idempotency_conflict,
publish_precondition_unsupported, publish_conflict
```

Initial guardrails are depth 32, 2,000 candidates per local root, 500 regular
archive files, 10 MiB compressed, 20 MiB expanded, 5 MiB per resource, 256 KiB
entry file, 16 KiB arguments, four preparation workers, two transfers per
source, 32 pending invocations per session, and eight distinct model
activations/16 attempts per turn. Eligible remote reads have at most three
attempts within a 30-second deadline.

## Public extension

The existing Protocol V1 envelope remains unchanged for legacy clients. S2
will negotiate `skills.v1` before emitting new commands/events:

```text
skill.invoke
skill.invocation.status
skill.invocation.cancel
```

Public payloads use camelCase, bounded strings/collections, opaque IDs, and
digests. They contain no process terms, secrets, absolute filesystem paths,
cache roots, or package bodies. HTTP adapters use the same service and
repository/session boundary; they do not parse packages or create Agent
loops.

## Test fixtures frozen for S1/S2

Fixtures must cover automatic and manual-only skills, duplicate names across
repository/global sources, comments and quoted/block/nested metadata,
`$ARGUMENTS`, references/assets/scripts, invalid policy types, malformed and
cyclic paths, archive traversal and limits, generated records, and changed or
missing digests. Provider call-count tests must prove disabled/invalid
requests do not reach the provider.

## S0 gaps carried forward

- Extend parser diagnostics and bounded discovery in S1-A; the YAML dependency
  is now selected and pinned as `yaml_elixir 2.12.2`/`yamerl 0.10.0`.
- Unify web and headless skill-context construction under S1-B.
- Add the additive Protocol schema in S2; do not widen legacy closed enums.
- Implement trusted snapshot-root grants before removing the current
  filename-based `SKILL.md` read exception.
- Remote distribution/publication is explicitly deferred to a separate job
  under the new design; this Sigma job does not implement that integration.

## Verified implementation slices

- Historical S1-A parser: `Sigma.Session.Skills.Parser` handles YAML comments, quoted and
  folded values, nested metadata, CRLF, duplicate keys, and supported policy
  type validation. `Sigma.Session.Skills` preserves metadata and argument hints.
- S1-B local catalog: `Sigma.Session.Skills.Catalog` supplies one revisioned
  repository/global catalog to the current web and headless context builders,
  with repository precedence and qualified `repo:`/`global:` resolution.
- SP-03 immutable preparation: `Sigma.Session.Skills.Snapshot` is a thin facade
  over package `Bundle.pack/3` and `Bundle.prepare/3`. It returns the exact package
  ref/digest/manifest and `Document.body_raw` as plain Sigma maps, retries package
  `source_changed` once, and retains a marker-owned prepared root until release.
  Historical `sha256-tree-v1` snapshots remain non-replayable records.
- S2 local entry path: `Sigma.Session.SlashCommands` supports explicit
  `/skill <reference> <arguments>` and unqualified local skill commands with
  one-pass `$ARGUMENTS` expansion. The existing LiveView admission path passes
  the effective workdir, and the existing composer menu lists enabled local
  catalog skills.
- S2 model activation slice: `Sigma.Tools.ActivateSkill` is registered in the
  existing dispatcher, resolves the same local catalog, rejects manual-only
  skills for model-origin calls, and returns a prepared snapshot/instruction
  result without starting a nested Agent turn. Successful activation is
  deduplicated per Agent turn through the existing tool-state ETS. Durable
  activation records are still pending; the existing read tools now receive
  turn-scoped activated roots and PathUtils authorizes package resources under
  those roots.
- Remote distribution, archive consumption, offline binding, and publication
  are deferred to a separate job and intentionally absent here.
- S2 Protocol slice: `Sigma.Agent.SkillInvocation` freezes request validation,
  deterministic fingerprints, and invocation state transitions; Protocol V1
  now accepts additive `skill.invoke`, `skill.invocation.status`,
  `skill.invocation.cancel`, and `skill.invocation.updated` types. PublicRuntime
  exposes callback seams for the shared invocation service, but durable
  reservation/admission and transport adapters are still pending.
- The existing session journal now accepts `skill_invocation` entries through
  `EntryEncoder`/`Writer`, providing the durable encoding boundary for the
  eventual request-key reservation and restart recovery service.
- S5-B read adapter slice: Sigma now exposes `GET /api/v1/skills` and
  `GET /api/v1/skills/:id` through a thin controller using registered
  repository IDs and the shared catalog revision. Invocation/publication write
  routes and trusted remote caller delegation remain pending.
- S5-B capability slice: `GET /api/v1/capabilities` reports local catalog,
  manual/model activation, and local-only operation. Remote distribution and
  publication are not advertised in this job.
- S5-B local invocation slice: `POST /api/v1/sessions/:sessionId/skill-invocations`
  requires `Idempotency-Key`, persists the validated request in the
  session-scoped invocation store, and admits it through the existing Agent
  follow-up path; the matching GET endpoint reads the persisted record. Full
  crash-safe reservation/queue replay semantics still require integration with
  the serialized session operation boundary.
- Stdio and WebSocket adapters now inject the same Agent-side invocation
  callback seam; WebSocket supplies the Session store/expander callbacks, while
  headless callers can provide the same trusted callbacks without an Agent-to-
  Session production dependency.
- Session resume recovery marks persisted `preparing`, `queued`, and `running`
  invocation records as `interrupted` before runtime reconstruction, preventing
  a restart from silently replaying a skill request.

These slices do not satisfy the original full V1 contract because the new
design explicitly moves remote distribution/publication to another job.
Within Sigma, durable activation/invocation admission, remote-free UI polish,
and release smoke evidence remain outstanding.
