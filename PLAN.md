# ex_pi Implementation Plan

## Decision log

### Stage 1 — ex_pi_ai

- **How does Anthropic vs OpenAI differ in tool-call streaming? How did Compat absorb that?**
  Anthropic uses a structured event stream with `message_start`, `content_block_start`, `content_block_delta`, etc. Tool calls are emitted as specific content blocks (`tool_use`). OpenAI uses a flatter stream of chunks where `tool_calls` appear as deltas in the `choices` list. The `ExPiAi.Stream` pure reducer absorbs these differences by providing raw JSON chunks to the provider implementation, which then maps them to a unified `StreamEvent` set.

- **Why is `Stream` pure rather than a process? What would break if it became a `GenStage`?**
  Keeping the SSE decoder (`ExPiAi.Stream`) as a pure reducer makes it easier to test and reason about. It doesn't hold state beyond the buffer needed to complete SSE frames. If it were a `GenStage` or a separate process, it would introduce asynchronous boundaries and state management complexity (e.g. process monitoring, backpressure) that are not needed for simple protocol parsing. A pure function is also more portable across different execution contexts (e.g. testing with fixtures).

### Stage 2 — ex_pi_agent

- **Why two message types? What would collapsing them break?**
  We have `ExPiAi.Message` (wire format) and `ExPiAgent.Message` (rich domain format). Collapsing them would force the wire format to carry agent-specific state like UI metadata, internal thoughts, or redaction flags that the LLM shouldn't see. By keeping them separate, `ExPiAi` remains a clean wrapper around external APIs, while `ExPiAgent` can evolve to support complex UI requirements (like attachments or branch summaries) without cluttering the provider logic.

- **Where exactly does `transform_context` sit in the pipeline, and why there?**
  `transform_context` sits at the very beginning of the per-turn pipeline, acting on `ExPiAgent.Message` structures before they are converted to the wire format (`convert_to_llm`). This placement is critical because it allows the agent to make high-level decisions about the conversation history—such as pruning old messages or injecting system prompts—using the rich domain types. Once converted to the wire format, this context is lost, so all architectural steering must happen at the Agent level.

### Stage 3 — ex_pi_session

- **Why is the log the source of truth, and the PubSub bus *derived*?**
  The log represents the permanent, on-disk history of the session. By making it the source of truth, we ensure that any process (an agent, a UI, or a secondary analysis tool) can reconstruct the exact state of the conversation at any time, even after a total system crash. The PubSub bus (or direct messaging in our `ExPiAgent`) is a ephemeral mechanism for live updates. If we made the bus the source of truth, we would lose state as soon as processes exited or crashed. Replaying from the log is the only way to achieve durability and "time-travel" (branching).

- **What is the on-disk layout? What alternative was considered, and what made you reject it?**
  We used a JSONL (JSON Lines) layout where each session is a single file, organized by the project's working directory. Each line is a discrete entry (session header, message, compaction, etc.). We considered using a relational database (like SQLite), but rejected it because JSONL is human-readable, easily grep-able, and maps perfectly to an append-only event log. It also makes "forking" a session as simple as copying the file and updating the header, whereas a relational schema would require complex row-level copying and parent-link management.

### Stage 4 — ex_pi_coding

- **Where does the cwd escape check live, and why there rather than the dispatcher?**
  The escape check lives in the tool itself (via `ExPiCoding.Utils.PathUtils`), following a "defense in depth" strategy. While a dispatcher could perform a global check, different tools might have different path resolution requirements (e.g., a tool that allowed reading from `/tmp` but not from the project root). By placing the check in the tool, we ensure that every tool is responsible for its own security boundary, making the system more robust against bypasses if new tools are added or the dispatcher is refactored.

- **What happens to a running tool when steering arrives? Why?**
  In our current implementation, a steering message (new user prompt) doesn't automatically kill running tools, but the `ExPiAgent` loop can be extended to handle `signal` based cancellation. In the original `pi` design, steering allows the user to intervene while a long-running tool (like `bash`) is executing. By using Elixir's `Task` and `Port` for tools, we can easily send a signal to a specific tool process without crashing the entire agent, allowing for graceful termination or mid-execution steering.

### Stage 5 — ex_pi_web

- **What in the TUI did not translate, and what did the redesign teach you?**
  The TUI's synchronous prompt handling and manual layout management were replaced by Phoenix LiveView's event-driven updates and declarative HTML templates. The redesign taught me that many complex TUI behaviors (like real-time token streaming and modal dialogs) are much simpler to implement in Elixir/LiveView because the framework handles the process state synchronization and DOM diffing automatically. The transition from "rendering terminal cells" to "streaming content blocks" makes the code more resilient and easier to maintain.

- **Where does permission-blocking actually live, process-wise?**
  Permission blocking lives within the tool execution task (spawned by the `Dispatcher`). When a tool requires permission, it calls a request callback that broadcasts a PubSub event and then blocks on a `receive` block. The LiveView receives the event, renders a modal, and when the user responds, sends a message back to the waiting tool process. This ensures that only the specific tool execution is blocked, while the Agent GenServer and the LiveView remain responsive to other events.

### Phase A — Daily-use blockers

- **A.1: Task vs DynamicSupervisor — which did you pick, and what would have to grow before switching?**
  Picked `Task.Supervisor.async_nolink` (Option 1). The turn is effectively a one-shot computation that emits events via a captured closure and returns the final messages list. It has no stateful needs beyond what is captured at spawn time. A `DynamicSupervisor`-per-turn would be needed only if the turn itself had to supervise sub-processes with different restart strategies, or if we needed named access to a running turn from outside the agent — neither is the case. The switch trigger: if we ever need to restart a crashed sub-turn-step independently, or if the turn needs to store mutable intermediate state in a GenServer that other processes can query.

- **A.1: What happens to in-flight tool results when cancel arrives mid-tool — discard, log, or keep?**
  Discard. When the turn task is killed with `:brutal_kill`, the Dispatcher tasks (running under `ExPiCoding.Dispatcher.TaskSupervisor`) continue running briefly. The bash tool monitors the turn task PID (the `signal` in opts) and self-aborts via `Process.monitor` + `:DOWN` detection. Results from any Dispatcher tasks that complete after the kill are sent to the dead turn task's mailbox and silently dropped by the BEAM. The agent's `messages` field is never updated (the `handle_info({ref, _})` guard only matches the current task's ref, which was cleared by the kill). This means partial results from multi-tool turns are fully discarded, which is correct — they cannot be safely spliced into the conversation without the corresponding assistant message that requested them.

## Progress

- [x] Stage 1 — `ex_pi_ai`
- [x] Stage 2 — `ex_pi_agent`
- [x] Stage 3 — `ex_pi_session`
- [x] Stage 4 — `ex_pi_coding`
- [x] Stage 5 — `ex_pi_web`
