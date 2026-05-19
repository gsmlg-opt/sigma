# ex_pi — Port Review

**Date:** 2026-05-19
**Reviewer's lens:** state-of-the-port snapshot, comparing `apps/` against `source/packages/` to identify the next porting increments. Continues the Phase A–H workflow already established in `PLAN.md`.

---

## TL;DR

| Layer                       | Upstream surface (TS) | Ported surface (Elixir) | Status |
|-----------------------------|-----------------------|--------------------------|--------|
| LLM provider abstraction    | 9 providers, OAuth on 3 | 2 providers, no OAuth   | **partial** |
| Tool system                 | read/write/edit/bash/grep/find/ls | + url_fetch          | **complete (matches pi default set)** |
| Agent loop                  | turn loop + steering + follow-up + abort + hooks | turn loop + abort | **partial — queues missing** |
| Session persistence         | single-file tree (`id`/`parentId`) | one-file-per-fork copy | **divergent design** |
| Compaction                  | auto + manual + custom-prompt | auto only          | **mostly complete** |
| Web/TUI surface             | TUI (canonical) + web-ui (lib) | LiveView app           | **redesigned, not transliterated** |
| Slash commands / editor UX  | full `/login`, `/tree`, `/fork`, `/model`, … + `@file` + paste | none (button-driven) | **missing** |
| Customization (skills, templates, extensions, themes, packages) | full | none | **out of scope (study port)** |
| CLI modes (print / JSON / RPC / export) | full | none — web only | **missing for headless workflows** |
| Multimodal input (images)   | full | type-defined, not wired | **stub only** |
| Permission gating           | extension-driven (no built-in popups) | code-only default, UI removed in `673bd7b` | **simplified intentionally** |

Phases A–H landed cleanly and the daily-use loop is solid: streaming, caching, thinking, compaction, fork, URL-fetch, and the seven-tool set all work end-to-end on Anthropic. The interesting open work is now **above the loop**, not inside it.

---

## What's been ported well

These do not need rework — listed only so the next phases can lean on them.

- **`ExPiAi.Stream`** is genuinely pure. SSE → `StreamEvent` separation is the right place to grow more providers without touching the agent.
- **`ExPiAgent` turn loop** uses `Task.Supervisor.async_nolink` with a clean abort path and a `restart: :temporary` child spec. Provider crashes don't kill the GenServer, and `SessionManager` evicts dead agents on `:DOWN`.
- **`ExPiCoding.PermissionInterceptor`** correctly blocks per-tool via `receive`, so the agent stays responsive while one tool waits — same shape as pi's preflight hook.
- **Symlink-safe `PathUtils.safe_resolve/2`** (Phase A.5a) closes the `tmp → /private/tmp` style escape; this is stronger than pi's plain `path.resolve`.
- **JSONL log replay** with compaction handling round-trips correctly, and `Log.fork_at_message/5` counts message entries (not raw rows), so compaction markers don't shift the cut point.
- **Anthropic prompt caching + extended thinking** (Phases F/G) are wired through the same provider without leaking model-specific branches into the agent.

---

## Gaps vs upstream pi

Organized by impact, not by upstream package layout.

### 1. Agent-loop ergonomics — the biggest UX hole

Pi's editor is built around the message queue, and most users notice it immediately:

| Behavior | Pi | ex_pi |
|---|---|---|
| Submit while tool running | `Enter` → steering, delivered after current turn | input disabled until turn ends |
| Submit while idle but queued | `Alt+Enter` → follow-up, delivered after agent stops | n/a |
| Abort | `Esc` (also brings queue back to editor) | red cancel button — full kill, no queue restore |
| `beforeToolCall` / `afterToolCall` hooks | yes, configurable | not implemented |

The steering/follow-up split lives on `Agent` in `source/packages/agent/src/agent.ts` and is read at each `agentLoop` iteration boundary. Porting it cleanly means adding a queue to `ExPiAgent` state and draining it inside `run_turn_loop/1` between iterations — not a heavy lift, but it changes the LiveView submit handler shape.

### 2. Session format — a design decision is still open

Pi uses **one JSONL file per session** with entries linked by `id`/`parentId`. Forking, cloning, and tree navigation are all reads against the same file. ex_pi uses **one file per fork** and copies the prefix on branch (`Log.fork/4` at `apps/ex_pi_session/lib/ex_pi_session/log.ex`).

Trade-offs:

- **ex_pi's copy-on-fork** is simpler to reason about: each session is self-contained, no parent-link integrity, no entry-id assignment. Replay is linear.
- **Pi's tree-in-file** gives `/tree` an in-place navigator that scales to dozens of branches without filesystem clutter, and `/clone` is essentially free.

Until a clear `/tree` requirement lands, the copy-on-fork shape is defensible. The decision worth recording is *not which is better* but *under what trigger we'd migrate*. Suggested trigger: when a single project's session directory exceeds ~50 files and the user starts using fork as a "save point" rather than a branch.

### 3. Provider coverage

Only Anthropic and OpenAI completions are implemented. Upstream registers nine:

```
anthropic (✓)              google-generative-ai
openai-completions (✓)     google-vertex
openai-responses           amazon-bedrock
openai-codex               mistral
azure-openai
```

Each shares the `ExPiAi.Stream` reducer, so additions are tractable. Priority depends on which provider the user actually uses; for a study port, **OpenAI-Responses next** (it's the new default OpenAI API and tests the "responses-style" branch of the StreamEvent contract).

### 4. OAuth

Pi supports three OAuth flows:
- **Anthropic** — Pro/Max subscription auth (`packages/ai/src/utils/oauth/anthropic.ts`)
- **OpenAI Codex** — ChatGPT Plus subscription auth
- **GitHub Copilot** — uses Anthropic-compatible API under Copilot subscription

For Anthropic, OAuth uses PKCE and a redirect to a local callback. In a LiveView world, the callback can be a regular Phoenix route (`/oauth/anthropic/callback`) that completes the exchange and writes to `auth.json`. This is the *only* OAuth flow most users will actually want, and it removes the "you need an API key" friction.

### 5. Image input

`ExPiAi.Message` defines `image_content` but nothing produces or transmits it:

- Providers don't pack image blocks into the wire format.
- LiveView has no upload affordance.
- No tool returns image results (pi's `read` on `*.png` returns base64).

Smallest end-to-end slice: paste/upload in LiveView → store as part of message content → Anthropic provider emits `{"type":"image", ...}` block. ~80 LoC across three files.

### 6. Slash commands and editor UX

The LiveView has buttons for "New Session", "Fork", and "Cancel" — that is the *entire* command surface. Pi's `/`-menu (full list in `source/packages/coding-agent/src/core/slash-commands.ts`) is the primary UI for everything except prompting. The minimum useful set for ex_pi is:

| Command | Justification |
|---|---|
| `/model` | switch provider/model without leaving the chat |
| `/compact [prompt]` | manual compaction with optional steering for the summarizer |
| `/new` | start a fresh session without going back to the workdir page |
| `/clear` | reset messages within the same session id |
| `/name <name>` | session display name (currently sessions show only IDs) |

`@file` references and `Ctrl+V` image paste also fall under "editor UX" and would land together.

### 7. CLI / headless modes

Phoenix is the only entrypoint. Pi exposes:
- `pi -p "prompt"` — print-and-exit
- `pi --mode json` — JSON-line event stream
- `pi --mode rpc` — JSONL framing on stdin/stdout, used by external integrations
- `pi --export session.jsonl session.html` — offline HTML render

A Mix task `mix ex_pi.run -p "prompt"` plus `mix ex_pi.export <session> <out>` would cover the realistic study-port slice. RPC mode is overkill for a study port unless the goal is to drive ex_pi from an external supervisor.

### 8. Context-file walking

`ConfigManager` reads exactly one file: `~/.pi/agent/AGENTS.md`. Pi walks **from `cwd` up to `/`** *and* `~/.pi/agent/`, concatenating every `AGENTS.md` / `CLAUDE.md` it finds. For a coding agent that's the difference between "knows about the current repo's conventions" and "doesn't."

This is the single highest-leverage missing feature for actual coding tasks. ~30 LoC in `ExPiSession.ConfigManager`. No design questions.

### 9. Customization layer (skills / prompts / extensions / themes / packages)

Pi's extensibility surface is enormous: TS extensions, agent skills, prompt templates, themes, npm/git packages. For a study port the explicit guidance in `docs/port_plan.md` is *do not port these*. The recommendation is to leave this gap intact unless the goal of `ex_pi` changes.

The narrow exception is **prompt templates** (just Markdown files with `$ARGUMENTS` substitution). That's ~50 LoC and gives users a way to keep frequently-used prompts without an extensions framework. Worth its place.

### 10. Permissions

`673bd7b` removed the permissions/thinking UI. The remaining defaults live in `settings.json` and the `PermissionPolicy` GenServer. This matches pi's "no built-in popups" philosophy (`source/README.md` Philosophy section), so **no work is recommended here** — leave the simplification in place.

---

## Recommended next phases

Each phase is a single commit-worthy increment, framed as a question the way Phases A–H were. Pick whichever matters most for your usage; they are independent unless noted.

### Phase I — Steering and follow-up queues

**Question:** what does it cost to mirror pi's `Enter` (steering) vs `Alt+Enter` (follow-up) semantics inside a single `GenServer`-per-session?

**Tasks:**
1. Add `:steering_queue` and `:followup_queue` to `ExPiAgent` state.
2. Add `steer/2` and `follow_up/2` public API.
3. In `run_turn_loop/1`, drain the steering queue between turn iterations (after `message_end`, before `convert_to_llm`); drain the follow-up queue once a turn finishes with no tool calls.
4. LiveView: `Enter` submits steering when `turn_in_flight`; otherwise submits a normal prompt.
5. Settings keys: `steeringMode`, `followUpMode` (`"one-at-a-time"` | `"all"`).

**Open question:** when a steering message arrives during a tool batch, do tools complete first (pi's behavior) or abort? Pi's answer is "complete first" — the steering is delivered *between* turns, not mid-turn. Match that unless there's a reason not to.

**Estimated size:** ~150 LoC + tests. No new modules.

### Phase J — Context-file walking (AGENTS.md / CLAUDE.md hierarchy)

**Question:** does the system prompt come from one file or every file the user has placed between `/` and `cwd`?

**Tasks:**
1. `ExPiSession.ConfigManager.context_files_for_cwd/1` — walk from cwd up; collect every `AGENTS.md` and `CLAUDE.md`; also include `~/.pi/agent/AGENTS.md` if present.
2. Concatenate with file-path delimiters.
3. Wire the concatenated string into `ExPiAgent.init/1` as the system prompt (replacing the current single-file read).
4. Add `--no-context-files` semantics later if needed.

**Estimated size:** ~30 LoC + one test fixture (nested `AGENTS.md` files).

### Phase K — Image input end-to-end

**Question:** what's the minimum that makes `paste image → assistant describes it` work?

**Tasks:**
1. LiveView file-upload component (Phoenix has this built-in).
2. Encode upload as `{:image, %{data: base64, mime_type: "image/png"}}` content block on the user message.
3. Anthropic provider: emit `{"type":"image", "source":{"type":"base64", ...}}` in the request body.
4. Test fixture: small base64 PNG → assistant emits text response.

**Estimated size:** ~80 LoC. OpenAI image support can land in a follow-up.

### Phase L — Slash commands

**Question:** which command surface earns its place in a *web* agent vs. the TUI?

**Tasks:**
1. Editor parser: detect leading `/` and produce a command menu.
2. Implement `/model`, `/new`, `/clear`, `/compact [prompt]`, `/name <name>`.
3. Implement `@file` token expansion (file picker, inserts file content into the prompt).
4. `/help` listing whatever is wired in.

**Open question:** should the LiveView also reserve `/skill:name` and `/<template-name>` for Phase Q, or are those out of scope? Recommend reserving the syntax so they don't need an editor rewrite later.

**Estimated size:** ~250 LoC (editor logic, command handlers, file picker hook).

### Phase M — Additional providers

**Question:** does adding a third provider require changing `StreamEvent`, or did Stage 1 actually flatten everything?

**Tasks (order = recommended):**
1. **OpenAI Responses** — tests the new API style and image input on OpenAI.
2. **Google Generative AI (Gemini)** — different SSE shape, different tool-call schema.
3. **Bedrock** — AWS SigV4 signing, exposes any hidden assumption about HTTP headers.

Each adds a `providers/<name>.ex` and a fixture-based decode test. No agent changes if Stage 1 held up.

**Estimated size:** ~200 LoC per provider, +/- depending on the SSE quirks.

### Phase N — Anthropic OAuth

**Question:** where does the OAuth callback live in a LiveView app, and how does the policy GenServer pick up a token that may have been written by a different request?

**Tasks:**
1. Phoenix route: `GET /oauth/anthropic/start` (PKCE init → redirect) and `/oauth/anthropic/callback` (token exchange).
2. Persist to `auth.json` in the existing format.
3. Add a token-refresh probe inside `ExPiAi.Providers.Anthropic` before each request.

**Estimated size:** ~150 LoC. Token refresh is the subtle part — pi handles it inside the provider request path.

### Phase O — Headless modes (print, JSON, export)

**Question:** how much of `ExPiAgent` can be reused for a Mix task without dragging in `Phoenix.PubSub`?

**Tasks:**
1. `mix ex_pi.run -p "prompt" [--session id]` — runs an agent, prints text, exits.
2. `mix ex_pi.json -p "prompt"` — emits each `Event` as a JSON line on stdout.
3. `mix ex_pi.export <session-file> [out.html]` — pure offline conversion.

**Open question:** session persistence in `--print` mode — pi defaults to ephemeral but flags exist (`--no-session`). Decide once before implementing.

**Estimated size:** ~200 LoC + a templated HTML for export.

### Phase P — Prompt templates (only)

**Question:** is there a minimal customization layer that earns its place in a study port?

**Tasks:**
1. Load `~/.pi/agent/prompts/*.md` and `.pi/prompts/*.md` at session start.
2. `/templatename arg1 arg2` expands to the template body with `$1`, `$@`, `$ARGUMENTS` substitution.
3. Skip: skills, extensions, themes, packages.

**Estimated size:** ~50 LoC. Worth doing only if the user actually wants templated prompts; otherwise skip the whole customization layer per `port_plan.md`.

---

## Phases NOT recommended

For each, reason given. Pulled out so future-you doesn't have to re-derive these.

- **Session tree in single file** (pi-style `id`/`parentId`) — the current copy-on-fork is simpler and the only thing it's missing is in-place `/tree` navigation. Revisit when a user actually asks for that.
- **Permissions UI re-introduction** — explicitly removed in `673bd7b`. Code-level defaults plus interceptor blocking is sufficient and matches pi's stated philosophy.
- **Extensions framework** — would require either NIFs (forbidden per `port_plan.md`) or Lua/Elixir-script execution. Heavy infrastructure for low study value.
- **Skills, themes, packages** — same justification. Each lives behind a manifest format and a discovery layer that pi maintains as part of its product surface, not its study surface.
- **`/share` (GitHub Gist upload)** — networked output, no study value, security surface.
- **MCP support** — pi explicitly skips it; ex_pi should too.

---

## Architectural notes worth recording

These are decisions that the next phase will need to confirm or reject. Capture the answer in `PLAN.md`'s decision log per phase, same shape as Phases A–H.

1. **Steering semantics during tool batches.** If a steering message arrives while three parallel tools are running, do they complete (pi) or abort (faster delivery)? Phase I lives or dies on this answer.

2. **Session file plurality.** Copy-on-fork or single-file tree. The cost of changing later is a one-time migration of existing JSONL files — manageable, but worth deciding before users accumulate sessions.

3. **System prompt composition order.** When `AGENTS.md` walks the directory tree (Phase J), is global-first or cwd-first? Pi is global-first (so cwd overrides via being later); record the choice in code as a comment so it's not lost.

4. **Multimodal in the agent type.** Image content blocks are already in `ExPiAi.Message` but not anywhere else. When wiring Phase K, decide whether `ExPiAgent.Message` mirrors the wire shape or adds a richer "attachment" abstraction. Pi just mirrors.

5. **OAuth token storage.** `auth.json` currently holds plaintext API keys. Adding refresh tokens means deciding whether storage at rest needs to change (e.g., file mode 0600, or OS keychain). Pi uses 0600 plaintext.

6. **CLI ergonomics.** If Phase O lands, the project gains a second entry point with no shared CLI argument parser. Decide whether to standardize on `Optimus` or hand-roll once and live with it; the hand-rolled choice is appropriate for ≤3 Mix tasks.

---

## Suggested order

If "make ex_pi useful for everyday coding tasks on Anthropic" is the goal, the optimal cadence is:

1. **Phase J** (context files) — biggest UX win per LoC; nothing depends on it.
2. **Phase I** (steering/follow-up) — second biggest UX win; touches `ExPiAgent` core.
3. **Phase L** (slash commands) — multiplies the value of Phases I and J.
4. **Phase N** (Anthropic OAuth) — removes the API-key onboarding cliff.
5. **Phase K** (image input) — enables debugging from screenshots.
6. **Phase M** (more providers) — only when Anthropic stops being enough.
7. **Phase O** (headless modes) — for scripting/CI use cases.
8. **Phase P** (prompt templates) — small, do whenever.

If instead the goal is "complete the port surface for study purposes", swap the order so M lands earlier (it answers the Stage 1 "did Compat actually flatten everything?" question on real data).

---

## Closing

Phases A–H are a complete daily-use loop on Anthropic, and the architectural decisions made along the way are documented well enough that this review could be assembled in an afternoon. The remaining work is mostly **above the agent loop** — editor UX, multi-file context, multi-provider, CLI modes — rather than inside it. None of the recommended phases requires touching `ExPiAi.Stream`, `ExPiAgent.run_turn_loop/1`, or the JSONL schema, which is a healthy sign that the lower stages of the port are stable.
