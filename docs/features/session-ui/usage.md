# Session UI Observability V2 Usage

The session page exposes request, turn, session, context, and compaction state
without changing the journal or provider accounting model.

## Chat Composer

The transcript and composer use DuskMoon React Chat through the Phoenix chat
bridge. Send with **Ctrl/Cmd+Enter** or **Send**; Enter adds a new line. Slash
commands and `/skill ` offer keyboard completion with arrows, Enter/Tab, and
Escape. Images can be attached, pasted, or dropped (PNG, JPEG, GIF, or WebP;
four files, 5 MiB per file, 10 MiB total). Images cannot accompany slash commands.

Text drafts survive refresh in sessionStorage for each session. Pending image
files survive in-app navigation but must be reattached after a full reload.
An admitted submission clears only its unchanged draft. Rejections and
disconnections preserve it. Prompts sent during a turn retain the runtime's
steering/follow-up admission semantics, and **Stop** cancels the active turn.

Scrolling up pauses automatic following; **Jump to latest** resumes it. Message
updates carry per-message sequences, and reconnect requests a canonical
snapshot. Request-detail expansion stays open when late metrics update.

## Reading Session Metrics

Each completed assistant response has a compact footer with provider input and
output tokens, observed LLM throughput, elapsed time, and terminal state. Expand
**Request details** for provider/model, TTFT, cache and reasoning subsets,
purpose, and usage quality. Cache and reasoning values are subsets of the
canonical input/output totals and are not additional spend.

When a user turn caused multiple provider requests or tools, **Turn total**
shows the complete turn rather than treating the final assistant message as the
whole execution. LLM throughput is weighted as total output tokens divided by
total provider-request elapsed time. Tool time contributes to turn wall time,
not LLM throughput.

The desktop session rail shows runtime phase, own-session usage, coverage,
timing, current context, compaction history, and fork lineage. At widths below
the desktop breakpoint, open the same information with the chart button in the
session toolbar; it appears as a drawer.

The three usage scopes are intentionally distinct:

- **Own usage** is the default and includes every observable request started by
  this session, including old branches and compaction requests.
- **Inherited usage** came from a fork source and is not counted again as child
  own usage.
- **Active-lineage usage** filters to the selected branch and does not replace
  the session total.

`unknown`, `partial`, or a coverage fraction means the journal or provider did
not supply enough information. These states are not zero usage.

## Context and Compaction

The context card separates the next-request estimate from the last provider
measurement. Window, threshold, remaining budget, estimate source, and stale
state come from the runtime policy; the browser does not calculate a fallback.
An unknown model window remains unknown.

Use the toolbar's **Compact context** button only while the session is idle.
Successful compaction replaces older model context with a summary, so the
current estimate can decrease while historical session usage remains. Only a
committed context entry increments the successful count. Failed attempts retain
known provider usage but do not increment that count.

## Retry, Resend, and Fork

- **Retry** starts one replacement turn from the persisted checkpoint before
  the selected user turn. The original answer and later messages are excluded
  from the replacement context but remain available as an alternative branch.
- **Resend** appends the selected prompt as a new turn at the current active
  leaf. It is not checkpoint Retry.
- **Fork** creates a separate session at the selected safe boundary and does not
  automatically call the model. The child starts with zero own usage and shows
  its inherited source.

Retry and Fork require confirmation and are rejected when the session is busy,
the source revision changed, history or attachments are unavailable, or a
required model replacement was not selected. Repeated submission of the same
operation ID returns the durable result instead of executing again.

These operations change conversation/session history only. They never roll back
workspace files, Git state, commands already run, or external requests. A fork
shares the source working directory unless the host explicitly provides an
isolated directory.

## Refresh and Recovery

Completed metrics and operation results are replayed from the JSONL journal.
Refreshing the page or restarting the runtime restores durable usage,
compaction counts, branches, and operation outcomes. An in-flight request is a
runtime overlay and is finalized as interrupted/unknown if recovery proves it
did not reach a durable terminal fact.

Protocol clients must opt in to `metrics.v1`. They should attach first, keep the
returned cursor/watermark, and replace their projection with `session.status`
after `resync_required`. Legacy clients that omit `metrics.v1` keep the original
Protocol V1 event set. See [Protocol V1](../../contracts/protocol-v1.md) and the
[PublicRuntime integration guide](../../contracts/public-runtime-integration.md).

SUI-10 request Inspector, detailed paginated history, and compaction-turn
prediction remain deferred optional enhancements.
