# Sigma oh-my-pi Learning Roadmap - PRD

> Product requirements for translating durable oh-my-pi design contracts into
> Sigma's OTP/Phoenix architecture without wholesale TypeScript porting.

## Problem Statement

Sigma already implements many of the core pieces of an AI coding agent, but the
current roadmap risks learning from oh-my-pi at the wrong level. The upstream
project has many packages and product surfaces, but its most valuable lessons
are the stable contracts beneath them: session journal semantics, provider
normalization, agent-loop steering, tool execution contracts, and context/rule
discovery.

Without a PRD, future work can drift into feature copying: adding advisor,
subagents, collaboration, memory, LSP, DAP, or more providers before Sigma has
the underlying contracts that make those features predictable. That would
increase complexity without preserving the behavior users depend on when they
resume sessions, fork work, switch providers, run tools, or migrate project
instructions.

## Solution

Sigma should learn from oh-my-pi by implementing a staged contract roadmap:

1. Session journal and session operations v2
2. Provider normalization v1
3. Tool runtime hardening v1
4. Context and rule discovery v2

Each stage must translate the upstream behavior into Sigma's existing OTP,
Phoenix LiveView, and Elixir data-transform boundaries. The goal is not to
match the upstream package graph. The goal is to preserve the user-visible
contracts that make an agent reliable across long conversations, branching
sessions, provider differences, tool execution, and project-local instructions.

## User Stories

1. As a Sigma user, I want sessions to resume reliably, so that I can continue
   coding work after closing the browser or restarting the server.
2. As a Sigma user, I want recent sessions to load quickly, so that a large
   transcript does not make the session list sluggish.
3. As a Sigma user, I want Sigma to continue the right session after a repository
   directory is moved, so that ordinary workspace cleanup does not orphan work.
4. As a Sigma user, I want to fork a session at a meaningful point, so that I can
   explore an alternative without corrupting the original branch.
5. As a Sigma user, I want session switching to flush pending state and reject
   unsafe switches, so that active tool or model work does not get lost.
6. As a Sigma user, I want to dump or export a session without mutating it, so
   that sharing or inspecting history does not change the canonical log.
7. As a Sigma user, I want compacted history to remain understandable after
   replay, so that long-running sessions can keep useful context.
8. As a Sigma user, I want model, reasoning, service-tier, MCP selection, and
   mode changes to survive resume, so that a restored session behaves like the
   session I left.
9. As a provider maintainer, I want one normalized stream contract, so that the
   agent loop does not need provider-specific branches.
10. As a provider maintainer, I want endpoint-family compatibility to be explicit,
    so that OpenAI-compatible, Anthropic-compatible, gateway, and first-party
    endpoints can diverge safely.
11. As a provider maintainer, I want stop reasons and transport errors normalized,
    so that the UI and agent loop can respond consistently.
12. As a provider maintainer, I want tool-call argument streaming to be parsed
    incrementally but finalized authoritatively, so that partial UI updates do
    not corrupt execution.
13. As a tool author, I want every tool to declare its execution metadata, so that
    the runtime can schedule it safely.
14. As a tool author, I want shared, exclusive, and sequential execution modes,
    so that tools with different state requirements can run without hidden races.
15. As a tool author, I want interruptible tools to receive cancellation
    separately from non-interruptible tools, so that steering can stop safe work
    without killing critical cleanup.
16. As a tool author, I want malformed tool results to be coerced into a stable
    shape, so that one bad tool cannot break the agent loop.
17. As a Sigma user, I want live partial tool execution updates, so that long
    Bash or edit operations are visible while they run.
18. As a Sigma user, I want prompts sent during an active turn to be handled
    intentionally, so that follow-up instructions are not silently ignored.
19. As a project maintainer, I want Sigma to honor project instruction files with
    clear precedence, so that migrated repositories preserve their rules.
20. As a project maintainer, I want imported instruction files to resolve
    predictably, so that shared team guidance can be reused without duplicating
    content.
21. As a project maintainer, I want sticky and path-scoped rules, so that rules
    apply only where they are relevant.
22. As a plugin or skill author, I want context sources to compose in a stable
    order, so that adding a skill does not unexpectedly erase project rules.
23. As a Sigma developer, I want high-level tests around the agent/session seam,
    so that future changes preserve behavior instead of implementation details.
24. As a Sigma developer, I want each stage to be independently shippable, so
    that the roadmap can pause after any contract lands.

## Implementation Decisions

- Sigma will keep its existing OTP-native shape. The roadmap must not port the
  upstream TypeScript package graph, runtime classes, or UI stack.
- Session journal and session operations v2 is the first stage because provider,
  tool, advisor, subagent, memory, and collaboration features all rely on stable
  session semantics.
- Session state will be treated as an append-only journal with explicit branch
  and active-leaf semantics. Fork, resume, switch, compact, dump, and export are
  first-class operations with documented mutation rules.
- Session metadata changes will be represented as replayable state, including
  model selection, reasoning level, service tier, selected MCP servers, mode
  data, compaction summaries, and branch summaries.
- Session listing will avoid reading full transcripts. Recent-list and resume
  behavior should use bounded prefix/tail reads and tolerate missing or moved
  working directories.
- Provider normalization v1 will define one agent-facing stream contract for
  text deltas, thinking deltas, tool-call lifecycle, terminal done events, and
  terminal error events.
- Provider endpoint differences will be represented as compatibility metadata
  carried through provider requests. Provider code owns endpoint-local mechanics;
  the agent loop consumes only normalized events.
- Provider schema normalization will be fail-soft for non-critical compatibility
  shaping and fail-explicit for cases that would execute an unsafe or ambiguous
  tool call.
- Tool runtime hardening v1 will add execution metadata to tool definitions:
  approval tier, discoverability, concurrency mode, interruptibility, and
  user-facing render hints.
- Tool execution will coerce all results into a stable shape before they reenter
  the agent loop. Empty, malformed, or exception-backed results must become
  explicit tool-result messages rather than crashes.
- Tool scheduling will support at least shared and exclusive execution groups.
  Sequential execution remains available where stateful tools need it.
- Steering and follow-up prompts will be modeled explicitly. New prompts during
  an active turn should either queue, steer, or be rejected with visible state;
  they must not disappear silently.
- Context and rule discovery v2 will preserve Sigma's pi-compatible settings
  while adding richer project instruction discovery, import expansion, sticky
  rules, and path-scoped rule matching.
- Existing hooks and permission-policy behavior remain part of the tool runtime
  contract. New scheduling or steering behavior must not bypass permission
  interception.
- The primary testing seam is the agent/session boundary: a fake provider and
  fake tools drive the agent, and assertions are made against emitted events,
  replayed sessions, and restored UI state.
- Pure lower-level tests are still required for provider normalization, session
  journal replay, context/rule discovery, and tool result coercion.
- Advisor, subagents, memory, collaboration, LSP, DAP, web search, GitHub
  filesystem tools, and native runtime work are deferred until these core
  contracts are stable.

## Testing Decisions

- Tests should assert external behavior: emitted events, replayed session state,
  restored settings, normalized provider events, permission outcomes, and tool
  results. Tests should not assert private helper function structure.
- Session journal tests should cover resume, fork, switch, compact, dump/export
  non-mutation, moved-directory recovery, and corrupt or partial JSONL recovery.
- Provider tests should replay fixture streams from each supported endpoint
  family and assert the same normalized event sequence for equivalent behavior.
- Tool runtime tests should cover shared/exclusive scheduling, interruptible
  cancellation, non-interruptible completion, malformed result coercion, hook
  interaction, permission denial, and partial updates.
- Context/rule tests should cover root-to-workdir precedence, imported files,
  sticky rules, path-scoped rules, disabled or missing files, and composition
  with skills and hooks.
- LiveView tests should cover visible session switching, fork navigation,
  reconnect after resume, prompt handling during active turns, and partial tool
  update rendering.
- Stage-level verification should stay scoped to the touched apps. If unrelated
  tests fail, record them and stop rather than widening the implementation.

## Out of Scope

- Recreating the upstream TypeScript package structure.
- Importing TypeScript or JavaScript through ports, NIFs, or generated wrappers.
- Adding dozens of providers before provider normalization exists.
- Implementing advisor, subagents, memory consolidation, collaboration web,
  LSP, DAP, GitHub filesystem tooling, or native runtime support in the first
  roadmap stage.
- Replacing Phoenix LiveView with upstream TUI or web UI patterns.
- Redesigning DuskMoon, hooks, permissions, or existing hashline tools beyond
  the integration points needed by the four roadmap stages.

## Further Notes

- The first implementation PRD should be narrower than this roadmap: "Session
  journal and session operations v2" is the recommended first child PRD.
- Existing Sigma hashline tools already capture a major upstream lesson:
  line-addressed, snapshot-validated file edits. The roadmap should build on
  them rather than restarting that work.
- oh-my-pi should remain a source reference. Sigma should translate contracts
  into Elixir modules, behaviours, supervised processes, and Phoenix LiveView
  interactions that fit the current umbrella.
- Each stage should end with a decision-log entry explaining what was learned
  from upstream, what Sigma chose differently, and why.
