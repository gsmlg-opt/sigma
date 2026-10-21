# Codex hook contract

Sigma's hook names and command protocol follow `openai/codex` commit
`7a152fbcf9ecd32d9fb4b45edf80127ee4c8499e`. The reference was retrieved from
upstream `main` on 2026-10-21. This is a versioned compatibility target, not a claim
that future Codex versions will have the same contract.

`Sigma.Coding.Hooks.Catalog` owns the event list and timeout defaults. Both the
global and project configuration pages use that catalog, including events with
no configured handlers. Opening either page does not create a configuration file.

| Event | Matcher input | Default / maximum seconds |
| --- | --- | --- |
| PreModelRequest | Ignored | 600 / none |
| PostModelRequest | Ignored | 600 / none |
| PreToolUse | Canonical tool name and compatibility aliases | 600 / none |
| PermissionRequest | Canonical tool name and compatibility aliases | 600 / none |
| PostToolUse | Canonical tool name and compatibility aliases | 600 / none |
| PreCompact | `manual`, `auto` | 600 / none |
| PostCompact | `manual`, `auto` | 600 / none |
| SessionStart | `startup`, `resume`, `clear`, `compact`, `fork` | 600 / none |
| SessionEnd | `other` | 1 / 3 |
| UserPromptSubmit | Ignored | 600 / none |
| SubagentStart | Agent type | 600 / none |
| SubagentStop | Agent type | 600 / none |
| Stop | Ignored | 600 / none |
| Interrupt | Ignored | 1 / 3 |

Names in configuration and command `hook_event_name` are case-sensitive PascalCase.
Snake case is used internally for event atoms. Empty matchers and `*` match all;
alphanumeric/underscore alternatives separated by `|` match exactly; other
patterns are regular expressions. An invalid expression must not become a
match-all rule.

Tool names in stdin retain the canonical hook identity. Shell tools use `Bash`,
`apply_patch` keeps its name and accepts `Write`/`Edit` matcher aliases, and
`spawn_agent` accepts the `Agent` matcher alias. MCP names retain
`mcp__<server>__<tool>`. Sigma's existing host tools keep their actual names; this
change does not rename the host tool catalog.

## Configuration and handlers

```json
{
  "hooks": {
    "PreToolUse": [{
      "matcher": "Bash|apply_patch",
      "hooks": [{
        "type": "command",
        "command": "./scripts/check-tool",
        "timeout": 20,
        "statusMessage": "Checking tool"
      }]
    }]
  }
}
```

The guided editor writes Codex field names (`command`, `timeout`, `statusMessage`,
`async`). Advanced JSON preserves fields and handlers outside the guided form,
including MCP templates and existing legacy aliases. `mcp_tool` handlers use
`server`, `tool`, `input`, and optional `timeout`/`statusMessage`; `${field.nested}`
templates resolve against the event input. A whole-value placeholder retains its
JSON type, while an embedded placeholder becomes text. A missing path fails the
handler.

Command input is JSON on stdin with EOF; stdout and stderr are separate. Timeout
uses an absolute deadline. Async commands do not block their caller and their
output cannot deny a tool, rewrite its input, or continue a stopped turn.
`SessionEnd` always runs synchronously. MCP hooks use already connected, configured
session clients directly, without recursively dispatching tool hooks.

Session-owned async work queues behind the same eight-command concurrency limit
as Codex, and session shutdown cancels unfinished work. A command that completes
normally may leave an intentionally detached helper running; timeout, failure to
collect a result, and cancellation clean up the command's process group.
Model-request observers share the session shutdown boundary and are joined before
`SessionEnd`, including observers running synchronous post-request hooks.

Codex declares `prompt` and `agent` handler types but does not execute them at this
reference. They remain visible in Advanced JSON. HTTP handlers are a legacy
Sigma/Claude extension, not part of the Codex handler contract.

## Lifecycle and output

`SessionStart` is consumed once before the first admitted prompt. Subagent start
hooks run at the child's actual conversation boundary after durable creation
admission. Subagent stop hooks run before the child finishes, where a blocking
result can continue the child. They are not reconstructed by replaying roster
events. `stop_hook_active` reports a previous stop-hook continuation; the runtime
does not impose a one-continuation limit.

Pre/post compaction hooks surround actual compaction; post runs after a successful
commit. Model request hooks surround individual requests, including failed and
cancelled requests. Model and interrupt hook output is diagnostic and cannot
control execution. Session end is tied to shutdown, rather than ordinary turn
completion.

An empty new session defaults to the `startup` source; restored history defaults
to `resume`. Explicit `resume_source` values are supported. Sigma's fork operation
currently creates a journal and its compaction keeps the same running agent;
neither creates another session-start boundary. Automatic `fork`, `clear`, and
`compact` session-start sources require a corresponding host lifecycle operation.

For Codex/native hooks, exit status takes precedence over stdout. Exit 2 is
interpreted according to the event; a failed hook's JSON cannot grant permission.
Structured output is validated for the event and supported fields. A genuine
`PermissionRequest` allow bypasses the approval callback. `PreToolUse` runs before
permission evaluation; input changes and additional context can both survive.
`PostToolUse` blocking feedback replaces the result delivered to the model.
Codex `updatedInput` replaces the entire tool input, with the last completed
rewrite winning. Sigma's tool boundary requires a JSON object; other JSON input
types are diagnosed rather than widening the tool argument contract.

## Sigma host boundaries

Sigma retains its configuration locations: `~/.pi/agent/hooks.json` and
`<repository>/.pi/hooks.json`, while discovery also reads existing Codex and Claude
files. This change does not migrate user configuration, introduce Codex's TOML
configuration stack, install plugins, or replace Sigma's repository trust policy.
The former eight-event design documents are historical; this contract describes
the current compatibility target.

Command hooks require Unix `setsid` and `kill` executables on `PATH`, including
when using the macOS packages. A missing executable produces a diagnostic and
the command is not started. These programs own subprocess groups so cancellation
and timeout can also stop background descendants.

Additional context uses Sigma's bounded in-memory representation rather than
Codex's on-disk spill/recovery mechanism. Diagnostics use Sigma's logger and
telemetry rather than Codex's app-server hook lifecycle protocol. These host
differences are not evidence of complete Codex application compatibility.

Hook context is mapped to Sigma's existing user/system provider roles, including
the child agent's initial context, rather than adding a new provider message role.

## Source evidence

- [Event names and matcher events](https://github.com/openai/codex/blob/7a152fbcf9ecd32d9fb4b45edf80127ee4c8499e/codex-rs/hooks/src/lib.rs)
- [Configuration field names and handler types](https://github.com/openai/codex/blob/7a152fbcf9ecd32d9fb4b45edf80127ee4c8499e/codex-rs/config/src/hook_config.rs)
- [Discovery and timeout normalization](https://github.com/openai/codex/blob/7a152fbcf9ecd32d9fb4b45edf80127ee4c8499e/codex-rs/hooks/src/engine/discovery.rs)
- [Command input/output schemas](https://github.com/openai/codex/blob/7a152fbcf9ecd32d9fb4b45edf80127ee4c8499e/codex-rs/hooks/src/schema.rs)
- [Event-specific result validation](https://github.com/openai/codex/blob/7a152fbcf9ecd32d9fb4b45edf80127ee4c8499e/codex-rs/hooks/src/engine/output_parser.rs)
- [Model request observation](https://github.com/openai/codex/blob/7a152fbcf9ecd32d9fb4b45edf80127ee4c8499e/codex-rs/hooks/src/events/model_request.rs)
- [Host lifecycle integration](https://github.com/openai/codex/blob/7a152fbcf9ecd32d9fb4b45edf80127ee4c8499e/codex-rs/core/src/hook_runtime.rs)
