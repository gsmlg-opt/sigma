# Sigma Contract Stabilization V2 Execution Report

- Status: Complete
- Date: 2026-09-01
- Integration: locally fast-forwarded into `main` at `48d9ecc`
- Base: `03a8ca0e8e320b1ef1a608027505a81ca25ab664`
- Plan: `docs/contracts/sigma-contract-stabilization-plan-for-codex-v2.md`

## Work orders

### S0 — Trusted build and release baseline

- Removed the dependency-patching Mix task and every setup/build/release alias
  that called it.
- Split CI into independent Elixir, Rust, assets, test, and installed-release
  smoke jobs with lock-exact caches.
- The release workflow creates the version commit first, verifies and builds its
  immutable SHA, then publishes and tags that exact SHA.
- Added `scripts/verify-release-agent-smoke.exs` and workflow contract tests.

### S1 — Durable session writer

- Added `Sigma.Session.EntryEncoder` and the mailbox-serialized
  `Sigma.Session.Writer`.
- Durable appends advance the active leaf only after storage acknowledgement;
  every acknowledged message also advances Agent and SessionProcess canonical
  state even if a later append fails.
- Writer startup/restart, failure rollback, legacy header repair, torn tails,
  transient events, and no-full-reread appends have behavioral coverage.

### S2 — Journal and session operations V2

- Forks now contain one fresh header and one selected valid branch, preserving
  entry IDs, parents, and unknown logical entries.
- Runtime operations acquire an Agent mailbox lock that atomically excludes
  prompts and durable model changes, flush the Writer, and serialize switch,
  fork, rename, delete, and adoption.
- Added stable-length JSON dump and Markdown export, bounded prefix/tail session
  summaries, orphan visibility, and ownership-aware transactional adoption.
- Rollback failures are returned as composite domain errors; runtime recovery
  rediscovers live sessions through Registry after RepositoryProcess restart.
- ADR 0001 records the OTP-native per-session switch/handoff design.

### S3 — Optional permission overrides

- `settings.json` supports only the closed `allow`, `ask`, and `deny` actions.
- Missing and legacy configuration retains `default: :allow, rules: %{}`.
- Explicit `ask` rules use permission hooks, correlated interactive resolution,
  and typed headless `approval_required`; explicit deny never executes.

### S4 — Tool Runtime V2

- Added typed metadata, execution, result, error, and update contracts.
- Permission checks run before bounded scheduling; sequential writes never
  overlap, canonical resource keys resolve every symlink component, deadlines
  and cancellation are typed, and outputs/partial updates are normalized.
- Non-interruptible work is never force-killed. If cleanup exceeds its bound it
  returns `indeterminate` and retains its resource lock in
  `PendingToolRegistry` until the task exits.

### S5 — Provider Normalization V1

- Added provider request/model/capability/event/usage/stop/error contracts.
- Anthropic and OpenAI-compatible adapters pass through one normalized event
  lifecycle with classified HTTP and retry metadata.
- The supervised bridge is demand-driven, consumer-owned, and terminal-aware:
  it emits exactly one terminal event, synthesizes failure for terminal-less
  EOF, stops terminal-then-hang producers, and suppresses post-terminal errors.
- Malformed/truncated tool arguments never become executable tool calls.

### S6 — Active turn control

- Prompt admission returns explicit accepted, steering, follow-up, or rejected
  results with stable message/turn IDs.
- FIFO steering is durably consumed at provider/tool safe boundaries.
- Follow-ups start after every terminal outcome, including cooperative and
  forced cancellation.
- Cancellation reaches provider transports, interruptible tools, permission
  waits, and MCP elicitations without killing the Agent; terminal events are
  idempotent and singular.
- LiveView keeps the input enabled and displays queued admission.

### S7 — Protocol V1 and headless runtime

- Added versioned, closed command/event envelopes, structured errors, and a
  bounded JSON codec that rejects process terms and unknown versions/types.
- `Sigma.Agent.PublicRuntime` is the shared direct Elixir command boundary.
- Added JSON Lines stdio and authenticated Phoenix WebSocket adapters.
- Per-client relays isolate slow/disconnected subscribers, retain ordered
  terminal events, and publish queue/drop telemetry.
- Reconnect snapshots bound every field, verify their encoded size, and expose
  truncation metadata; stopped WebSocket sessions resume from saved provider
  configuration.
- LiveView prompt/cancel and session operations use the same domain boundaries.

### S8 — Context and rule discovery V2

- Preserved legacy root-to-workdir `AGENTS.md`/`CLAUDE.md` order.
- Added deterministic relative imports, cycles/depth limits, path scopes,
  sticky/disabled rules, provenance, diagnostics, and preview trace.
- Imports are opened once, checked for canonical containment and matching inode,
  then read from that same descriptor with a strict `limit + 1` allocation.
- Agent context reload is explicit, idle-only, and cannot alter an active
  provider request.

## Stabilization definition of done

| # | Requirement | Authoritative evidence |
|---|---|---|
| 1 | Green clean build | Fresh `MIX_BUILD_PATH=/tmp/sigma-final-build.xwRJ1D/_build` compile completed with warnings as errors. |
| 2 | No dependency-source mutation | Dependency tree SHA-256 remained `a7a0f2d6d53ec55390cb4fa4e78a40a402ed5a1af6d822da8e2281cbada6e60d` across `mix assets.setup` and `mix assets.build`; patch task is absent. |
| 3 | Same verified release SHA | Release workflow creates `source_sha` after the version commit; verify/build check out that SHA and Publish advances/tags exactly `${SOURCE_SHA}`. Workflow contract tests pass. |
| 4 | Active prompt never dropped | `PromptQueue` and LiveView active-turn/retry queue tests assert explicit admission. |
| 5 | Explicit steering/follow-up | Provider/tool-boundary FIFO tests and cooperative/forced cancellation follow-up tests pass. |
| 6 | Cancellation propagation | Real Anthropic/OpenAI transport cancellation plus provider/tool/permission tests pass. |
| 7 | Failed append cannot advance state | Writer rollback and later-append-failure canonical-state regressions pass. |
| 8 | Ordinary append does not reread journal | Recording storage tests prove writer initialization is the only replay read. |
| 9 | One-header selected-branch forks | Branch fixtures verify one header, selected ancestry, unknown entry retention, and source non-mutation. |
| 10 | Busy operations are non-mutating | Runtime provider/tool/permission operation-lock and restart-recovery tests pass. |
| 11 | Default allow-all permissions | Config/permission tests cover built-ins, unknown tools, and MCP tools. |
| 12 | Ask-only approval blocking | Interactive correlation, wrong-request rejection, deny, and no-resolver `approval_required` tests pass. |
| 13 | Bounded strict tool runtime | Parallel limit, sequential writes, canonical conflicts, timeout/crash/cancel, indeterminate cleanup, and malformed result tests pass. |
| 14 | One provider-neutral contract | Adapter/fixture normalization, usage/cache, stop reason, HTTP errors, malformed/truncated, demand, and single-terminal tests pass. |
| 15 | Complete headless turn | Direct API, stdio fake-provider, and WebSocket attach/stream/cancel/reconnect tests pass. |
| 16 | LiveView uses shared boundaries | Prompt/cancel call `PublicRuntime`; switch/fork/rename/delete/adopt call `Sigma.Agent.Runtime`; Web and headless subscribers observe the same Agent events. |
| 17 | V3/release compatibility | Legacy V3, double-header, sidecar fallback, release layout, NIF presence, and installed-release Agent smoke tests pass. |
| 18 | Credential-free regression matrix | Full umbrella suite uses deterministic providers/tools and passed 700 tests with no external credentials. |

## Final verification

- `mix format --check-formatted`: passed.
- `mix compile --warnings-as-errors`: passed.
- `mix test`: 700 tests, 0 failures:
  - `sigma_logs`: 14
  - `sigma_ai`: 37
  - `sigma_coding`: 216
  - `sigma_tools`: 19
  - `sigma_protocol`: 3
  - `sigma_agent`: 83
  - `sigma_session`: 166
  - `sigma_web`: 162
- `cargo fmt -- --check`: passed.
- `cargo clippy --all-targets -- -D warnings`: passed.
- `cargo test`: passed.
- `mix assets.setup` and `mix assets.build`: passed with stable dependency digest.
- Fresh build-path compilation: passed.
- `MIX_ENV=prod mix sigma.rel-build`: passed.
- Installed release eval smoke: `release agent smoke ok`.
- `git diff --check`: passed.
- Independent final review: no remaining Critical or Important findings; ready
  to merge.

## Compatibility and remaining work

- Existing V3 journals, legacy double-header forks, behavioral sidecar
  fallbacks, provider settings, and installed release layouts remain supported
  without eager read-time rewrites.
- S9 feature expansion remains intentionally deferred and is not part of this
  stabilization milestone.
- During production dependency resolution, Hex reported existing Cowlib 2.19.0
  advisories. They are not introduced by this work and are outside the approved
  stabilization scope, but should be handled in a separate dependency-security
  update.
- No in-scope implementation work remains. The verified eight-commit branch was
  locally fast-forwarded into `main` with user authorization; no push or remote
  mutation was performed.
