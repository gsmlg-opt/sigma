# sigma — Port Instructions for Claude Code

## Context

Port [earendil-works/pi](https://github.com/earendil-works/pi) (TypeScript) to Elixir. The umbrella `sigma` is already scaffolded with five apps and stub modules.

**This is a study port, not a product.** Goal is *understanding*, measured by ability to explain pi's design choices. [Synapsis](https://github.com/gsmlg-opt/Synapsis) already covers production agent management — do not duplicate it.

"Done" with a stage means: matching code, passing tests, **and** a written explanation appended to `PLAN.md`'s decision log.

## Setup

```sh
# Clone pi separately as a reference. Do NOT vendor it into sigma.
git clone https://github.com/earendil-works/pi /tmp/pi-ref

cd sigma
nix develop                  # elixir 1.18 / otp 27 / node 22
mix compile                  # must pass against current stubs
mix format --check-formatted
mix test                     # passes vacuously for now; keep it green
```

If `mix compile` fails on the scaffolded stubs, fix that first and record what was wrong in the decision log before any stage work.

## Operating rules

1. **Read pi source before writing Elixir.** Every stage lists files in `/tmp/pi-ref` to read first. Skipping this is the primary failure mode.
2. **One question per commit.** Subject line = the question. Body = pi's answer + sigma's answer + the trade-off.
3. **Functional only.** `GenServer`s dispatch; pure modules compute. If a `handle_*` clause has more than ~10 lines of logic, extract.
4. **Behaviours mark cross-app boundaries.** `Provider`, `Storage`, `Tool` are seeded. Add more only where a real boundary exists, not for "future flexibility".
5. **No upward deps.** App DAG is strict: `ai → agent → session → coding → web`. A `mix deps.tree` violation is a design smell, not a packaging issue.
6. **Stop between stages.** Do not chain stages. At each stage exit, summarise what was learned and wait for human signal.
7. **Decision log is append-only.** After every stage, append at least two entries to `PLAN.md`'s "Decision log" section.
8. **Scope is a ceiling, not a target.** Underbuild rather than overbuild. Skipped tooling earns its place when the *next* stage hurts without it.

## Anti-patterns — never, regardless of stage

- Adding Phoenix to `sigma_web` before stage 5.
- Wrapping every module in a `GenServer`.
- Branching on provider name inside provider code (use `Compat` data carried on the request).
- Mutating any event after append to the session log.
- Running `mix phx.new` over the umbrella (Phoenix lands manually at stage 5).
- Adding tools beyond `read`, `edit`, `bash` at stage 4.
- Implementing themes, skills, slash commands, or extensions in pi's form.
- Importing JS/TS via NIFs or ports to "avoid reimplementation".
- Suggesting OOP-style design (inheritance, mutable shared state across modules).

## Pi source map

| pi package | path in `/tmp/pi-ref` | sigma app |
|---|---|---|
| `pi-ai` | `packages/ai/src/` | `sigma_ai` |
| `pi-agent-core` | `packages/agent/src/` | `sigma_agent` |
| `pi-coding-agent` | `packages/coding-agent/src/` | `sigma_session`, `sigma_coding` |
| `pi-tui` | `packages/tui/src/` | skip — `sigma_web` replaces |
| `pi-web-ui` | `packages/web-ui/src/` | reference for `sigma_web` |

## How to work a stage

1. Read the listed pi sources end-to-end. Take notes.
2. State the question in your own words before writing anything.
3. Build only what answers the question. Stop at exit criteria.
4. Run tests + format + warnings-as-errors.
5. Append decision log entries to `PLAN.md`.
6. Post a summary of what was learned. Stop.

---

## Stage 1 — `sigma_ai`

**Question:** what does an LLM call actually look like once you flatten providers?

**Read first:** all of `packages/ai/src/` in `/tmp/pi-ref`. Specifically: provider implementations, message types, the streaming layer, the compat flags carried on models. Note *where providers diverge* — that's where the Compat concept earns its keep.

**Tasks, in order:**
1. Define wire types (`Message`, `ToolCall`, `StreamEvent`) in `lib/sigma_ai/message.ex`. Match pi's variants; do not invent new ones.
2. Define the `Provider` behaviour. `stream/1` returns an `Enumerable` of `StreamEvent`.
3. Implement `Sigma.Ai.Stream` as a pure SSE reducer: takes `(state, binary)`, returns `{events, state}`. No process, no IO. This is the central architectural piece.
4. Implement one provider end-to-end. **Start with Anthropic** (simplest tool-call wire format). Use `Req` for HTTP.
5. Capture a live trace to `apps/sigma_ai/test/fixtures/sse/anthropic_hello.txt`. Write a test that replays the fixture through `Stream` and asserts the event sequence.
6. Add OpenAI as the second provider. **`StreamEvent` must not change.** If it must, stage 1 is not yet complete — investigate why.

**Exit criteria:**
- `mix test` passes including fixture replay.
- A live Anthropic call streams tokens to stdout incrementally.
- The OpenAI provider was added without modifying `Sigma.Ai.Stream` or `StreamEvent`.

**Forbidden this stage:**
- Touching anything outside `apps/sigma_ai/`.
- Adding state-holding processes (no GenServers).
- Provider code branching on anything other than `Compat` flags.

**Decision log prompts:**
- How does Anthropic vs OpenAI differ in tool-call streaming? How did Compat absorb that?
- Why is `Stream` pure rather than a process? What would break if it became a `GenStage`?

---

## Stage 2 — `sigma_agent`

**Question:** what is the actual loop?

**Read first:** `packages/agent/src/` in full. Focus on the `Agent` class, `AgentMessage` vs `Message`, `transformContext`, `convertToLlm`, the event emitter, and the steering/follow-up queue interaction with turn boundaries.

**Tasks:**
1. Define `Sigma.Agent.Message` — the rich domain type. Identify carefully what it carries that wire `Message` does not.
2. Define `Sigma.Agent.Event` — agent-level event types. Distinguish from `Sigma.Ai.StreamEvent`.
3. Implement `convert_to_llm/1` as a pure function. Test independently with edge cases (tool-call ID continuity, custom variants, redacted messages).
4. Implement `transform_context` as a single composition slot in the per-turn pipeline.
5. Build the loop as **one `GenServer` per session**. Exposes `subscribe/1`, `prompt/2`. Resist Supervisor-per-session — that is a stage-2-refactor question, not a stage-2 design question.
6. Drive a 3-turn conversation in a test. Reconstruct final UI state from emitted events alone — this is the source-of-truth check.

**Exit criteria:**
- A consumer rebuilds full state from the event log with no other input.
- `transform_context` can drop messages from mid-context without breaking tool-call ID continuity.
- Multi-turn loops without manual intervention.

**Forbidden this stage:**
- Persistence (stage 3).
- Real tool execution (stage 4).
- Per-session supervisor hierarchy. One process, one inbox.

**Decision log prompts:**
- Why two message types? What would collapsing them break?
- Where exactly does `transform_context` sit in the pipeline, and why there?

---

## Stage 3 — `sigma_session`

**Question:** how is history persisted, and how does branching actually work?

**Read first:** in `packages/coding-agent/src/`, locate session management, branching, and compaction. Pi spreads these across multiple files; find them all.

**Tasks:**
1. Define the `Storage` behaviour: `append/2`, `read/1`.
2. Implement `JsonlFile` storage — one JSONL per session, organised by cwd.
3. Implement `Log` as the public API: subscribe to agent events, persist, replay.
4. Implement branching: fork at index N → new `session_id` with `parent_id` reference. Shared prefix, separate suffix. No copying.
5. Implement compaction: summary event appended into the suffix; pre-compaction prefix retained verbatim.
6. Crash test: kill the session `GenServer` mid-conversation; restart; resume from log.
7. Branch test: fork at index 3; both branches advance independently; no cross-contamination.

**Exit criteria:**
- All three behaviours (resume, fork, compact) tested and passing.
- Compacting a branch leaves the parent log unchanged.

**Forbidden this stage:**
- Tools (stage 4).
- Snapshots — replay-only at this stage. Snapshots earn their place only when load is provably slow.
- ETS-backed default. Disk first; ETS only for test storage.

**Decision log prompts:**
- Why is the log the source of truth, and the PubSub bus *derived*?
- What is the on-disk layout? What alternative was considered, and what made you reject it?

---

## Stage 4 — `sigma_coding`

**Question:** how do tools plug in?

**Read first:** `packages/coding-agent/src/` for tool registration, dispatch, permission handling, the cwd invariant, and the path-escape check.

**Tasks:**
1. Define `Tool` behaviour with `name/0`, `description/0`, `schema/0`, `execute/2`.
2. Implement `read`, `edit`, `bash`. `bash` uses `Port` for streaming; `System.cmd` is forbidden (it buffers).
3. Path resolution: every file tool resolves via `Path.expand/2` and asserts the result is under cwd. Check lives **in the tool**, not the dispatcher (defence in depth).
4. Dispatcher: per-session `Task.Supervisor`. Default concurrent dispatch; opt-in sequential mode for tools sharing state.
5. Permission interceptor between dispatch and execute. Calls into a permission GenServer that the UI will later drive. For now, simulate via test config.
6. Stream `bash` stdout through the agent event stream live.

**Exit criteria:**
- Agent calls `read`, reasons about output, calls `edit` based on it.
- `bash` output streams into events with sub-100ms latency.
- Permission prompt blocks execution; deny path tested.

**Forbidden this stage:**
- Extensions of any kind.
- Tool framework that anticipates MCP/remote — just keep the boundary clean for later.
- UI work.

**Decision log prompts:**
- Where does the cwd escape check live, and why there rather than the dispatcher?
- What happens to a running tool when steering arrives? Why?

---

## Stage 5 — `sigma_web`

**Question:** what survives the TUI → web translation?

**Read first:** `packages/tui/src/` and `packages/web-ui/src/`. Reference only — note what the TUI exposes that should be **redesigned**, not transliterated. Branching navigation especially.

**Tasks:**
1. Manually add Phoenix to `apps/sigma_web`. Do **not** run `mix phx.new` over the umbrella. Add deps, create endpoint + router + supervision tree by hand.
2. PubSub topic per session. LiveView subscribes; agent publishes.
3. One LiveView per session. Use `Phoenix.LiveView.stream/4` for token deltas. **Do not re-render full message bodies on each chunk** — that path will not perform.
4. Permission modal: interceptor pauses execution → broadcast → LiveView renders modal → user answer flows back via PubSub. The modal blocks the *agent*, not the LiveView.
5. Branch sidebar as first-class navigation: list, switch, fork.
6. Reconnect survives mid-conversation.

**Exit criteria:**
- Two browsers attached to same session see the same live state.
- Forking from the UI creates a navigable new branch with no manual refresh.
- `bash` output streams visibly without lag.
- LiveView reconnect mid-run does not break the session.

**Forbidden this stage:**
- Themes (entirely out of scope).
- Authentication (out of scope).
- Custom WebSocket protocols beyond what LiveView provides.

**Decision log prompts:**
- What in the TUI did not translate, and what did the redesign teach you?
- Where does permission-blocking actually live, process-wise?

---

## When stuck

1. Re-read the relevant pi source. Most blockers come from skipping step 1 of a stage.
2. Write the confusion verbatim into the decision log, even if unresolved. Future-you will thank present-you.
3. Ask the human. Do not paper over confusion with abstractions.

## Done-with-stage checklist

Before declaring a stage complete:

- [ ] All listed tasks done.
- [ ] All exit criteria explicitly demonstrated (test names referenced).
- [ ] Forbidden patterns audited — none introduced.
- [ ] Two or more decision log entries appended to `PLAN.md`.
- [ ] Three-paragraph "what I learned" summary posted to the human.
- [ ] STOP. Wait for explicit signal to start the next stage.