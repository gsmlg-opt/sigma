# Sigma Skills Local Acceptance

Date: 2026-09-10

This is historical local-only evidence from before the Backplane Skill Protocol
cutover. It records the former Sigma implementation and does not claim current
V1 acceptance.

## Verified

| Area | Evidence |
| --- | --- |
| YAML parser and policy validation | Historical `Sigma.Session.Skills.Parser`; comments, quoted/folded values, nested metadata, CRLF, duplicate keys, invalid policy types; `apps/sigma_session/test/sigma_session/skills_test.exs` |
| Local catalog | Repository/global source IDs, precedence, qualified references, disabled/manual filtering, catalog revision; `Sigma.Session.Skills.Catalog` tests |
| Local snapshots | Historical bounded tree manifest and `sha256-tree-v1` digest, entry/resource capture, symlink rejection; `Sigma.Session.Skills.Snapshot` tests |
| Manual invocation | `/skill <reference> <arguments>`, shorthand commands, one-pass `$ARGUMENTS`, existing LiveView admission path; slash-command tests |
| Model activation | `activate_skill` built-in, manual-only denial, snapshot preparation, per-turn deduplication; `apps/sigma_tools/test` |
| Resource grants | Agent turn ID/root propagation and read-path authorization under activated roots; `PathUtils` tests |
| Protocol | `skills.v1` command/event envelope compatibility and pure invocation state/fingerprint validation |
| Persistence | Atomic invocation sidecar reserve/update/recovery, concurrent idempotency, durable journal entry encoding |
| Public reads | Repository-scoped `GET /api/v1/skills`, detail, and capabilities endpoints |
| Transport parity | Shared Agent invocation callback seam for HTTP, WebSocket, and stdio adapters |
| Management handoff | Project Skills cards link to New Session with an explicit skill reference; New Session displays the selection without auto-sending |

## Commands

The current checkout passes:

```text
mix format --check-formatted
mix compile --warnings-as-errors
mix test
git diff --check
mix run --no-start scripts/verify-skills-local-smoke.exs
MIX_ENV=prod mix assets.deploy
MIX_ENV=prod mix sigma.rel-build
```

Latest full-suite result: 14 + 42 + 224 + 4 + 87 + 178 + 32 + 165 tests
passed, one excluded. The existing PTY-size shell test has intermittent
environment-dependent failures and is unrelated to skills behavior.

The local smoke script completed with `skills local smoke: passed`, covering
catalog resolution, snapshot digest creation, slash expansion, model activation,
invocation persistence, and restart interruption recovery.

The production release build completed successfully after `assets.deploy`.
An isolated release boot reached the HTTP listener on port 4593, and the
fake-provider Agent smoke was evaluated inside the running release node with
`release agent smoke ok`. The isolated node was stopped cleanly afterward.

## Deferred

- Remote distribution, archive publication, and all Backplane integration.
- Remote/offline catalog bindings and package cache policy beyond local snapshots.
- Management-page invocation UI and richer picker states beyond the existing
  composer catalog.
- Crash-injection testing around the serialized session-operation boundary;
  current sidecar recovery marks nonterminal records `interrupted` on resume.
- Deployment rollback evidence in an external production/staging runtime.

These limitations are intentional scope boundaries, not passing claims. The
local implementation should not advertise remote publication or full V1
acceptance until the separate design/job supplies those dependencies.
