# Backplane execution engine

Sigma uses `backplane_agent_runtime` as its only execution engine. The original Sigma turn loop and engine selector have been removed.

## Activation

All session entry points execute through Backplane. Supply provider, model, and tool options without selecting an engine:

```elixir
context = %{
  repo_path: repo_path,
  sessions_dir: sessions_dir,
  session_opts: [
    provider: provider_module,
    model: model,
    tools: tools
  ]
}
```

The previous `SIGMA_AGENT_ENGINE` environment variable and `execution_engine` application/session settings no longer select an execution path. Stale settings cannot reactivate the removed loop.

Sigma continues to own the session, prompt and follow-up admission, provider configuration, context assembly, journal, permission resolution, hooks, and Protocol V1 subscriptions. A Backplane `Conversation` owns every turn's provider/tool loop.

## Runtime records and recovery

Runtime records live in a sidecar directory next to the transcript: `<session>.jsonl.runtime`. They do not alter the existing JSONL format. A standalone agent without a transcript must supply an absolute `backplane_runtime_path` explicitly. A second agent cannot open an already-owned sidecar path. A caller that intentionally shares a store must supervise it externally and inject its PID via `backplane_store`; agents do not stop injected stores.

The store serializes writes in one local BEAM process per directory. It commits the run, transition, effect records, and outbox together as a snapshot, with revision and incarnation checks. Its acknowledgement follows file-data sync and atomic same-filesystem rename. It does not provide a distributed writer lock or guarantee persistence of directory entries through every sudden power loss.

Store APIs can reopen runtime evidence. Sigma does not yet load/fence an interrupted run or resume it automatically, and does not automatically re-execute interrupted tools. Keep sidecars together with their transcripts when backing up or diagnosing sessions. An uncertain external mutation requires reconciliation before retrying that operation. Sigma's ordinary retry/fork commands retain their existing meaning and do not roll back external effects.

## Compatibility limits

- Tools execute sequentially on the Backplane path.
- Typed enum constraints used by the Todo action/status fields are validated before dispatch.
- Exact tool schemas are retained. Unsupported MCP schema keywords fail explicitly; constraints are never stripped to force acceptance.
- Sigma's coding dispatcher remains the tool boundary for permissions and pre/post hooks.
- The existing Bash tool stops its BEAM task on cancellation or timeout, but external shell descendants can continue. Reconcile shell effects before retrying a cancelled command.
- Each turn has a work quota of 100 provider/tool invocations and a five-minute effect timeout. The root run has no wall-clock timeout. The quota does not measure billed tokens and bounds repeated failed tool attempts.
- Writer-backed sessions expose the session-owned subagent collaboration tools; writerless sessions retain their ordinary tools without collaboration admission.
- Real-provider and browser acceptance are separate from deterministic local integration tests.

Failed or interrupted turns are never replayed through a second engine. Review interrupted tool effects before retrying.

## Verified locally

Regression tests run a scripted provider through the actual public runtime and coding dispatcher: a real file is written, the provider continues with the tool result, Protocol V1 events encode, JSONL history persists, and runtime records reopen after the session stops. Approval denial/cancellation prevents the write. Separate tests cover steering at response completion, follow-ups, killed provider metrics, prompt/stop hooks, strict schema rejection, valid Todo enum execution and invalid enum rejection before dispatch, and store conformance/failure cases.

These tests use no live model service. Browser and live-provider checks remain prerequisites for a broader rollout.

The test environment uses the same engine as production. Standalone fixtures supply isolated runtime stores. Negative regressions retain obsolete engine settings as inputs and prove that they still execute through Backplane and create runtime records.
