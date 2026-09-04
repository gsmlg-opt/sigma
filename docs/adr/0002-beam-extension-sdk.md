# ADR 0002: BEAM-native Extension SDK boundary

- Status: Accepted
- Date: 2026-09-04
- Scope: extension registration boundary across `sigma_coding` / `sigma_tools` / future OTP apps
- Related: [S9 Phase 1 plan](../contracts/s9-phase1-plan.md) WO-3, [tools.md](../features/tools.md), [hooks design](../features/hooks/01-hooks-design.md), [protocol-v1.md](../contracts/protocol-v1.md), Tool Runtime V2 (`Sigma.Coding.Tool` / Dispatcher / metadata)

## Context

S0–S8 delivered a stable tool runtime, provider normalization, and Protocol V1.
Further product surface (extra tools, context sources, providers, UI hints) needs a
**BEAM-native** extension path. Upstream pi has a TypeScript extension API; Sigma
must not copy that runtime model.

Today:

- First-party tools live in `sigma_tools` and implement `Sigma.Coding.Tool`.
- Sessions load builtins via `Sigma.Tools.default_tools/0` into the dispatcher.
- Hooks are external `command` / `http` handlers — explicitly **not** an Elixir
  plugin framework ([hooks N1](../features/hooks/02-hooks-prd.md)).
- There is no independent extension behaviour, registry, or loader.

Without a written boundary, follow-up PRs risk inventing hot-load, remote
plugins, or bypassing Tool Runtime V2 / Protocol contracts.

## Decision

### 1. Extension model

Extensions are **compiled OTP modules** in the BEAM release (umbrella apps or
optional dependency apps). Registration happens at **compile time or application
start** (e.g. `Application.start/2`, supervised init). Runtime arbitrary code
loading, remote download, or eval-as-extension are forbidden.

### 2. Extension points (phased)

| Point | Phase 1 | Phase 2 MVP | Later |
| --- | --- | --- | --- |
| Tools (`Sigma.Coding.Tool`) | boundary + thin registry façade | external OTP app `register_tool` | — |
| Context sources | listed only | register + assemble hook | — |
| Providers (`Sigma.Ai.Provider`) | [playbook](../features/providers.md) (WO-4) | thin adapters | more vendors |
| Commands / slash | out of scope | TBD ADR | — |
| Events / render hints | out of scope | TBD | UI-facing hints |
| Hooks | orthogonal; unchanged | still not Elixir plugins | — |

Phase 1 ships this ADR and an optional in-memory tool registry façade only.

### 3. Thin registry façade (Phase 1)

`Sigma.Coding.ExtensionRegistry` may expose:

- `register_tool/1` — accept a module implementing `Sigma.Coding.Tool`
- `list_tools/0` — return registered modules

Defaults **remain** `Sigma.Tools.default_tools/0`. Session / Protocol wiring does
not switch to the registry until Phase 2 MVP. The registry must not bypass
`Dispatcher`, permissions, hooks, or Tool Runtime V2 metadata.

### 4. Relation to existing contracts

- **Tool Runtime V2:** every extension tool implements `Sigma.Coding.Tool`,
  returns normalized results, and carries metadata (`effect`, `concurrency`, …).
  No side channel into the agent turn loop.
- **Protocol V1 / PublicRuntime:** extensions do not invent new wire commands.
  Headless clients keep using existing envelopes; tool lists are session options.
- **Permissions:** extension tools use the same `PermissionInterceptor` /
  `PermissionPolicy` path as first-party tools.
- **Hooks:** remain process-boundary handlers. Do not merge hooks discovery into
  the Extension SDK.

### 5. Errors and permissions

- Invalid modules (missing callbacks / bad name) are rejected at registration.
- Duplicate tool names: last successful register wins for that name (Phase 1);
  Phase 2 may tighten to hard conflict.
- Execution failures stay tagged tool errors; registry failures must not crash
  the agent GenServer.

## Non-goals (explicit)

- Hot plug / unload of extensions without release restart
- Remote or untrusted code download as plugins
- JS/TS pi extension compatibility layer
- Full SDK surface in one PR (commands, providers, context, events, render)
- Replacing hooks with an Elixir plugin framework
- New umbrella app solely for the registry

## Consequences

- Contributors have a single Accepted boundary for S9 extension work.
- Phase 2 MVP can add tool + context registration for external OTP apps without
  reopening S0–S8 contracts.
- `sigma_coding` stays the runtime kernel; `sigma_tools` stays first-party
  implementations; third-party apps register through the façade.
- Reviewers can reject PRs that introduce runtime code loading or dispatcher
  bypasses by citing this ADR.

## Open questions (non-blocking)

1. Should Phase 2 merge `default_tools/0` with `ExtensionRegistry.list_tools/0`
   inside session option builders, or keep an explicit `Sigma.Tools.all_tools/0`?
2. Namespace policy for third-party tool names (`vendor.tool` vs flat names).
3. Whether provider registration shares the same registry process or a sibling
   module under `Sigma.Ai`.
