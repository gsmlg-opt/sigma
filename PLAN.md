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

- **A.2: Where does crash isolation live — agent, supervisor, or LiveView?**
  All three layers play a role, but each owns a distinct failure mode. (1) The agent turn task uses `async_nolink` so any provider exception crashes only the task, never the GenServer. `run_stream/2` rescues `RuntimeError` and `Jason.DecodeError`, emits `{:turn_error}` with a human-readable message, and returns `{:error, state}` so the turn task exits cleanly — the agent immediately accepts new prompts. (2) The `DynamicSupervisor` holds agents with `:temporary` restart — a killed agent is not restarted, so `SessionManager` evicts it on `:DOWN` and lets the next `get_agent/2` call start a fresh one. No domino effect on sibling sessions. (3) The LiveView calls `Process.monitor(agent)` after getting the PID and handles the `:DOWN` message by showing a flash error (session history on disk is untouched). The LiveView itself never crashes.

- **A.2: Why rescue inside run_stream rather than letting the task crash?**
  Letting the task crash works for isolation (the agent survives via `async_nolink`), but produces a raw exception reason in the `:DOWN` message that the agent's `handle_info` re-emits verbatim as `{:turn_error, reason}`. A rescue lets us convert the exception to a clean, user-readable string before emitting. It also allows the turn task to exit normally (`:normal` reason), which prevents the `:DOWN` handler from double-emitting `{:turn_error}`. The trade-off: we only rescue two known exception types; unexpected panics still propagate and are caught by the `:DOWN` path with their raw reason.

- **A.4: Should agent processes restart on crash — and who owns the policy lifecycle?**
  Agents use `restart: :temporary` (added via `child_spec/1` override on `ExPiAgent`). The `DynamicSupervisor` default is `:permanent`, which would restart a crashed agent with its original `init` opts — at that point the `on_event` closure points at a dead LiveView process and the `messages` list is frozen at session-start. Temporary restart means the agent stays dead, `SessionManager` evicts it on `:DOWN`, and the LiveView shows a crash banner with the history preserved on disk. The `PermissionPolicy` GenServer is started with `start_link` inside `ExPiAgent.init`, so OTP links them — the policy is automatically killed when the agent is killed and never outlives its session.

- **A.3: Where should per-tool permission defaults live — code or config?**
  Config. The hardcoded `default_permissions/0` in `ExPiAgent` was a temporary fallback that couldn't be changed without recompiling. Moving defaults to `settings.json` (via `ConfigManager.get_permissions/0`) lets non-technical users change the policy from the Settings UI without touching code. The rules map is loaded at mount time in `SessionLive` and passed as `permission_rules:` to the agent — each session gets a fresh `PermissionPolicy` GenServer initialized from the current saved defaults. The format on disk is string-valued (`"allow"`, `"ask"`, `"deny"`) to keep the JSON human-readable; conversion to atoms happens in `get_permissions/0` using `String.to_existing_atom/1`, which is safe because the allowed values are a closed set of known atoms.

- **A.5c: Does `Log.fork` count message entries or raw entry positions?**
  Message entries only. The original `Enum.take(entries, index + 1)` counted by raw position — correct only when the log contains no entries between messages (no compaction, no future entry types). The fix is `take_through_nth_message/2`, which walks the entries list accumulating all non-message entries unconditionally but stops after seeing `n` message entries. The companion `fork_at_message/5` accepts either a message ID or `:all`; it computes the count by scanning message entries before the target ID, adding 1 to include it. The per-message fork button in `SessionLive` calls `fork_at` with `phx-value-msg-id`, keeping the LiveView handler trivially thin. The "fork all" button now also routes through `fork_at_message(…, :all, …)` so both paths share the same counting logic.

- **A.5b: Should `{:agent_start}` carry the cwd so `log.ex` avoids `File.cwd!`?**
  Yes. `File.cwd!` in `event_to_entry` returned the OS process cwd, which is the umbrella root — not the session's working directory. The agent already knows the correct cwd at init time and stores it in `state.cwd`. Changing the tuple to `{:agent_start, cwd}` passes that value through without any extra I/O. `Log.fork/5` was similarly extended to take an explicit `cwd` argument so the forked session header records the correct directory without any implicit file-system calls.

- **A.5a: Does safe_resolve block symlinks that escape the cwd?**
  The original `safe_resolve/2` used `Path.expand`, which resolves `.` and `..` in the string but does NOT follow symlinks. A symlink at `<cwd>/evil -> /etc/passwd` would pass the `within_cwd?` check — the symlink file is inside cwd — but any tool that opens it would reach `/etc/passwd`. The fix: `resolve_real_path/2` walks the full path with `File.read_link/1` at each level (up to 40 hops before returning `:symlink_loop`). For paths that don't yet exist, it walks up to the nearest existing parent. Both the input path AND the cwd are resolved before the prefix check, so macOS's `/tmp → /private/tmp` indirection doesn't cause false rejections. The resolved symlink target is returned as the real path for the within-cwd comparison, but the original non-resolved path is returned to callers so they get the path they asked for.

### Phase B — UI completeness and missing tools

- **B.1: Should `{:turn_error}` show a flash or be silently swallowed?**
  Flash. Silently resetting `turn_in_flight` left the user with no indication that the turn failed — the input just reappeared as if nothing happened. The handler now calls `put_flash(:error, "Turn failed: #{msg}")` with the reason string. Also fixed `get_permissions/0` to use a closed-set map (`%{"allow" => :allow, "ask" => :ask, "deny" => :deny}`) instead of `String.to_existing_atom/1`, which was fragile to atom load order in the test environment.

- **B.2: Should tool calls and results render with context or as placeholders?**
  With context. `render_content/1` now shows `→ name(...)` for `:tool_call` content blocks instead of `[Calling tool...]`. Tool result messages get a distinct console icon, a `"tool: <name>"` role label (using `message.tool_name` from the struct, since `render_content` only sees content blocks), an ERROR badge when `is_error` is true, and error-colored text. A `render_content/1` catch-all clause was added to silence unknown content block types.

- **B.3: Should the Write tool create-only or create-or-overwrite?**
  Create-only. Failing when the file already exists gives the LLM a clear semantic distinction between write (create) and edit (modify), and prevents accidental silent overwrites. Parent directories are created automatically with `File.mkdir_p!`. The tool rejects cwd-escape attempts via `PathUtils.safe_resolve` like all other tools.

- **B.4: Should sessions list sort by recency or filesystem order?**
  Recency (mtime descending). `File.ls!` returns filesystem order, which is arbitrary and bears no relation to what the user worked on most recently. `File.stat/1` is called per file to get mtime and sort descending. The `{:ok, stat}` match pattern avoids crashing on files that disappear between the `ls` and `stat` calls.

### Phase C — Streaming UX

- **C.1: Should the message stream auto-scroll or leave the user at the current position?**
  Auto-scroll, unless the user has scrolled up to read. A `MutationObserver` on the messages container fires whenever the `phx-update="stream"` DOM changes. It checks whether the user is within 300px of the bottom before scrolling, so reading earlier messages is not interrupted. The observer is disconnected in `destroyed()` to avoid leaks after navigation.

- **C.2: Should token usage be shown or hidden from the session view?**
  Shown. `message.usage` already carries `input`, `output`, and `cost.total` from the provider response — it just needed a template row. `format_cost/1` uses 6 decimal places below `$0.001` and 4 above so sub-cent costs remain readable. The row is only rendered when `usage` is non-nil to avoid blank lines on in-progress or replayed messages that predate the usage field.

- **C.3: Should assistant messages render markdown or plain text?**
  Markdown. `marked` parses the text and `DOMPurify` sanitizes the resulting HTML before setting `innerHTML`, guarding against prompt-injection via script tags. Non-assistant messages (user input, tool results) keep `whitespace-pre-wrap` because terminal output and plain text should not be reinterpreted as markdown. The `@tailwindcss/typography` plugin was absent, so a hand-rolled `.markdown` CSS class provides the necessary styles for `<pre>/<code>`, headings, lists, blockquotes, and tables — no additional Tailwind plugin dependency required.

### Phase E — Navigation tools

- **E.1: Should glob, grep, and ls be implemented as separate tools or unified into a single search tool?**
  Separate tools, matching pi's own `find`, `grep`, and `ls` modules exactly. Each tool has a distinct affordance the LLM chooses between: `glob` returns matching file paths (no content); `grep` returns matching lines with `file:line:` prefixes (content, no directory tree); `ls` returns a flat directory listing with `[dir]`/`[file]` tags. A unified "search" tool would force the LLM to specify which operation it wants via a mode parameter, adding friction and diluting the schema descriptions. All three are read-only so they default to `:allow` under the existing permission system — no policy changes needed. `grep`'s `collect_files` uses both `glob_filter` and `"**/" <> glob_filter` patterns to correctly match files at the root level as well as subdirectories, working around Erlang's `:filelib.wildcard` treatment of `**` (which may not match zero directory components in all Elixir versions).

### Phase D — Context compaction

- **D.1: Should compaction trigger automatically on a token threshold, or only when the user clicks a button?**
  Automatically, after every successful turn. `maybe_compact/1` checks `input_tokens` from the last assistant message's `usage` field; if it exceeds 80,000 tokens (matching pi's `COMPACT_THRESHOLD_TOKENS = 100_000` rounded down to leave headroom), `run_compact/1` is called before `execute_turn` returns. `find_compact_boundary/2` splits the message list so `to_keep` always starts at a user message, which ensures the compaction summary (mapped to an assistant role in `convert_to_llm`) is followed by a user message — a valid alternating sequence for all providers. The summary is generated by a silent LLM call (no streaming events emitted) and written to the JSONL log via the existing `{:compact, msg, first_kept_id}` event path. The LiveView adds the summary to the message stream and shows a flash notification; `Log.replay` already handles compaction entries on the next load, so the forking/reload path requires no additional changes.

## Progress

- [x] Stage 1 — `ex_pi_ai`
- [x] Stage 2 — `ex_pi_agent`
- [x] Stage 3 — `ex_pi_session`
- [x] Stage 4 — `ex_pi_coding`
- [x] Stage 5 — `ex_pi_web`
- [x] Phase A — Daily-use blockers (A.1–A.5c)
- [x] Phase B — UI completeness and missing tools (B.1–B.4)
- [x] Phase C — Streaming UX (C.1–C.3)
- [x] Phase D — Context compaction (D.1)
- [x] Phase E — Navigation tools (E.1)

## Phase A Summary

Seven commits landed across all five umbrella apps. The agent's turn execution now runs in a supervised task with `async_nolink`, so provider crashes cannot kill the GenServer — `run_stream/2` rescues `RuntimeError` and `Jason.DecodeError` and converts them to a clean `{:turn_error, reason}` event, while unexpected panics are caught by the `{:DOWN}` path. The `ExPiAgent` child spec overrides `restart: :temporary` so a crashed agent stays dead rather than reviving with a stale `on_event` closure; `SessionManager` evicts the dead entry on `:DOWN` and the LiveView shows a flash banner pointing the user to the preserved on-disk history. The `PermissionPolicy` GenServer is now started with `start_link` inside `ExPiAgent.init`, linking it to the agent so it dies automatically when the agent is killed.

Permission defaults were moved out of hardcoded Elixir into `settings.json`. `ConfigManager.get_permissions/0` reads the `"permissions"` key, converts string values to atoms with `String.to_existing_atom/1` (safe because the valid values are a closed set), and returns the map for the mount-time rules. A Settings → Permissions page with radio groups lets users toggle read/edit/bash policies without touching code. Each new session gets a fresh `PermissionPolicy` initialized from those saved defaults.

The symlink escape hole in `safe_resolve/2` was closed by replacing `Path.expand` with `resolve_real_path/2`, which follows symlinks with `File.read_link/1` up to 40 hops (returning `:symlink_loop` on overflow) and resolves both the input path and the cwd before doing the prefix check — so macOS's `/tmp → /private/tmp` indirection no longer causes false rejections. The `{:agent_start}` event was changed to `{:agent_start, cwd}` so the session log writes the correct working directory without a `File.cwd!` call, and `Log.fork/5` was extended with an explicit `cwd` parameter for the same reason. Finally, `Log.fork` was fixed to count only `"message"`-typed entries when building the prefix (skipping compaction and other entry types), and a `fork_at_message/5` API plus a per-message fork button in `SessionLive` allow users to branch from any point in their session history.
