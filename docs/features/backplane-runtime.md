# Backplane execution engine

Sigma uses `backplane_agent_runtime` 1.6.0 by default for newly started sessions. The existing Sigma engine remains available as an explicit fallback while Backplane is validated in use.

## Activation

No engine option is required for Backplane. To select the Sigma fallback for a session, set `execution_engine: :sigma` in the trusted options supplied to `Sigma.Agent.Runtime.get_session/3` or `Sigma.Agent.PublicRuntime.execute/2`. Direct callers can pass it to `Sigma.Agent.start_link/1`.

```elixir
context = %{
  repo_path: repo_path,
  sessions_dir: sessions_dir,
  session_opts: [
    execution_engine: :sigma,
    provider: provider_module,
    model: model,
    tools: tools
  ]
}
```

To select the fallback across the application, set `SIGMA_AGENT_ENGINE=sigma` before starting Sigma. Unset it or set `SIGMA_AGENT_ENGINE=backplane` to use Backplane. An explicit session option takes precedence, and a running session keeps its selected engine. No engine selector is accepted from untrusted Protocol V1 payloads.

Sigma continues to own the session, prompt and follow-up admission, provider configuration, context assembly, journal, permission resolution, hooks, and Protocol V1 subscriptions. A Backplane `Conversation` owns the default turn's provider/tool loop. The original Sigma loop is not invoked on that path.

## Runtime records and recovery

Runtime records live in a sidecar directory next to the transcript: `<session>.jsonl.runtime`. They do not alter the existing JSONL format. A standalone agent without a transcript must supply an absolute `backplane_runtime_path` explicitly. A second agent cannot open an already-owned sidecar path. A caller that intentionally shares a store must supervise it externally and inject its PID via `backplane_store`; agents do not stop injected stores.

The store serializes writes in one local BEAM process per directory. It commits the run, transition, effect records, and outbox together as a snapshot, with revision and incarnation checks. Its acknowledgement follows file-data sync and atomic same-filesystem rename. It does not provide a distributed writer lock or guarantee persistence of directory entries through every sudden power loss.

Store APIs can reopen runtime evidence. Sigma does not yet load/fence an interrupted run or resume it automatically, and does not automatically re-execute interrupted tools. Keep sidecars together with their transcripts when backing up or diagnosing sessions. An uncertain external mutation requires reconciliation before retrying that operation. Sigma's ordinary retry/fork commands retain their existing meaning and do not roll back external effects.

## Compatibility limits

- Tools execute sequentially on the Backplane path.
- Exact tool schemas are retained. Unsupported MCP schema keywords fail explicitly; constraints are never stripped to force acceptance.
- Sigma's coding dispatcher remains the tool boundary for permissions and pre/post hooks.
- Each turn has a work quota of 100 provider/tool invocations and five-minute run/effect timeouts. The quota does not measure billed tokens.
- Sigma's repeated-tool-failure nudge is not wired into this engine; the runtime quota bounds repeated attempts.
- Collaboration spawn/delegate/send/wait operations remain outside this integration.
- Real-provider and browser acceptance are separate from deterministic local integration tests.

Fallback is explicit: a failed Backplane turn is not replayed automatically through Sigma because a tool may already have produced external effects. Changing the application setting affects newly started sessions; stop/reopen an existing session to change its engine, retaining its JSONL history. Review interrupted tool effects before retrying.

Keep the Sigma engine until Backplane has passed representative live-provider/browser usage, configured MCP schemas, cancellation and approval flows, history operations, and recovery checks. Removing it is a later change after that evidence is available.

## Verified locally

The scoped agent and protocol suites passed (236 tests, including 25 Backplane tests). Tests run a scripted provider through the actual public runtime and coding dispatcher: a real file is written, the provider continues with the tool result, Protocol V1 events encode, JSONL history persists, and runtime records reopen after the session stops. Approval denial/cancellation prevents the write. Separate tests cover steering at response completion, follow-ups, killed provider metrics, prompt/stop hooks, strict schema rejection, and store conformance/failure cases.

These tests use no live model service. Browser and live-provider checks remain prerequisites for a broader rollout.

The test environment explicitly selects Sigma for the legacy regression fixtures. The synchronous public-runtime suite clears that override and proves that omitted engine options execute Backplane, that the explicit Sigma fallback still performs a real tool write, and that session options override the application selection.
