# Build API Session Context

This document defines how `ex_pi` builds the per-session context sent to an LLM provider.

The target shape follows the request pattern observed from Claude Code: product identity and turn-start operating context stay in the provider `system` field, while session-scoped user/project context is prepended to the first user message as separate `<system-reminder>` text blocks. Tool schemas remain provider tools and must not be duplicated in message context.

## Current Boundary

Context building is split across these boundaries:

| Layer | Module | Responsibility |
| --- | --- | --- |
| Discovery | `PiSession.ContextFiles` | Walks from filesystem root to the active cwd and reads `AGENTS.md` or `CLAUDE.md` per directory. |
| Assembly and injection | `PiAgent.SessionContext` | Normalizes context sources into ordered injections and renders separate reminder blocks. |
| Provider context builder | `PiAgent.ContextBuilder` | Builds provider system blocks, injects session reminders, and assembles provider context for a turn. |
| Session wiring | `PiWeb.SessionLive` | Collects runtime session sources and passes a `SessionContext` into `PiAgent`. |
| Turn pipeline | `PiAgent` | Builds tool schemas and passes `ContextBuilder` output to the provider. |

`PiAgent.SessionContext` is intentionally a pure data module. It does not discover files, persist context, hold process state, or call providers.

## Request Shape

A provider request should keep the real user prompt as the final user content block, with injected context before it:

```elixir
%{
  context: %{
    system: [
      %{
        type: :text,
        text: "You are Pi, an Elixir-based AI coding agent.",
        cache_control: %{type: :ephemeral, ttl: "1h"}
      },
      %{
        type: :text,
        text: turn_start_operating_context,
        cache_control: %{type: :ephemeral, ttl: "1h"}
      }
    ],
    messages: [
      %{
        role: :user,
        content: [
          %{type: :text, text: "<system-reminder>\n...\n</system-reminder>\n"},
          %{type: :text, text: "<system-reminder>\n...\n</system-reminder>\n"},
          %{type: :text, text: "the user's actual prompt"}
        ]
      }
    ],
    tools: provider_tool_schemas
  }
}
```

The persisted session log should still contain the user's original message content, not the injected reminder blocks. Injection is an LLM-facing transform only. Anthropic maps `context.system` to the request body's top-level `system` field; OpenAI-compatible providers prepend the same text as a system message.

## Source Buckets

`SessionContext.new/1` accepts these known buckets:

| Bucket | Meaning | Current source |
| --- | --- | --- |
| `:hooks` | Startup hooks, lifecycle hooks, or hook-provided context. | Reserved for hook integration. |
| `:skills` | Available-skill summaries. | `SessionContext.skills_context/1`, fed by global and repository skills. |
| `:agents_context` | User-global instructions, worktree context, repo-local instructions, and current date. | `ConfigManager.get_config()["system_prompt"]`, `SessionLive` session metadata, `PiSession.ContextFiles.assemble(nil, effective_cwd)`, and `Date.utc_today/0`. |

The current ordering is:

```elixir
[:hooks, :skills, :agents_context]
```

This order mirrors the Claude Code request shape: lifecycle and skill context appear before a single user/project instruction context block, and the real user message remains last.

## Rendering Rules

Each injection renders as its own text block:

```text
<system-reminder>
As you answer the user's questions, you can use the following context:
# Hooks

...
</system-reminder>
```

Do not concatenate hooks, skills, and `agents_context` into one reminder block. Separate top-level blocks keep provenance clear.

`AGENTS.md`-derived sources are the exception: global instructions, worktree context, and repo-local instruction files are concatenated into one `:agents_context` reminder block. That block ends with:

```text
# currentDate
Today's date is 2026-05-25.
```

The `:skills` bucket is special. It does not use the generic context preamble. It starts exactly like this and renders each skill as a markdown list item:

```text
<system-reminder>
The following skills are available for use with the Skill tool:

- repo-skill: Repository scoped skill
- global-skill: Global skill description
</system-reminder>
```

The skills block is only a discovery summary. The full skill content should be loaded by the Skill tool when a skill is invoked.

Blank sources are dropped. A source can be passed as:

```elixir
"plain content"
{"Custom Title", "plain content"}
%{title: "Custom Title", content: "plain content", source: "/path"}
%{"title" => "Custom Title", "content" => "plain content", "source" => "/path"}
```

## Tools

Tool schemas are sent only through the provider `tools` array:

```elixir
%{
  name: tool_mod.name(),
  description: tool_mod.description(),
  parameters: tool_mod.schema()
}
```

Do not inject a `# Tools` reminder block into messages. The model already receives tool names, descriptions, and schemas through `tools`.

For Anthropic prompt caching, cache-control belongs in provider tool transformation, not in `SessionContext`.

## System Prompt

Captured Claude Code requests build `system` as an ordered array of text blocks:

```elixir
[
  %{type: "text", text: "x-anthropic-billing-header: ..."},
  %{
    type: "text",
    text: "You are Claude Code, Anthropic's official CLI for Claude.",
    cache_control: %{type: "ephemeral", ttl: "1h"}
  },
  %{
    type: "text",
    text: stable_operating_policy,
    cache_control: %{type: "ephemeral", ttl: "1h"}
  }
]
```

The important split is:

| System block | Purpose | Cache |
| --- | --- | --- |
| Header/metadata | Provider or product telemetry metadata. | No cache marker in the sample. |
| Product identity | Stable identity for the agent product. | Ephemeral, `ttl: "1h"`. |
| Operating context | Laws, memory build/recall rules, environment, MCP server instructions, git status, and recent commits. | Ephemeral, `ttl: "1h"`. |

`PiAgent.ContextBuilder` emits Pi's stable product identity and operating context as provider system blocks when no explicit `system_prompt` is passed. Explicit binary system prompts are still accepted for backwards-compatible tests and direct callers.

The default operating context includes these sections:

- `# Laws`: core behavior, safety, tool-result handling, and task execution rules.
- `# Memory`: memory build rules and recall rules.
- `# Environment`: cwd, git-repo flag, platform, shell, OS version, and model when known.
- `# MCP Server Instructions`: server-provided instructions when configured; otherwise a no-MCP placeholder.
- `gitStatus`: current branch, inferred main branch, status snapshot, and recent commits from the agent cwd.

Provider system blocks are reserved for stable product-level instructions. Session-specific instructions, repo files, hooks, and skills should use `SessionContext` user-message reminders. Tools remain provider `tools`.

## Adding A New Context Source

Use this checklist:

1. Decide whether the source is discovery, assembly, or provider-specific.
2. Put discovery in the owning app, not in `PiAgent.SessionContext`.
3. Add the source to `SessionContext.new/1` only when it is a first-class bucket.
4. Otherwise pass it through `:injections`.
5. Add a focused test for `SessionContext.to_blocks/1` or `inject_messages/2`.
6. Add a provider payload test when the source changes the request shape.

Example:

```elixir
session_context =
  SessionContext.new(
    hooks: "SessionStart:startup hook success: Success",
    skills: available_skills,
    agents_context: [
      global_agents,
      {"Worktree Context", worktree_context},
      PiSession.ContextFiles.assemble(nil, effective_cwd)
    ],
    current_date: Date.utc_today()
  )
```

## Non-Goals

`SessionContext` should not:

- become a `GenServer`;
- read files directly;
- mutate persisted messages;
- branch on provider names;
- implement token budgeting or compaction;
- own hook or skill discovery.

Future token budgeting should be a separate pure transform that can drop, summarize, or rank injections before `to_blocks/1`.

## Validation

Relevant tests:

```sh
mix test apps/ex_pi_agent/test/ex_pi_agent/session_context_test.exs
mix test apps/ex_pi_agent/test/ex_pi_agent/context_builder_test.exs
mix test apps/ex_pi_agent/test/ex_pi_agent_test.exs
mix test apps/ex_pi_session/test/ex_pi_session/context_files_test.exs
```

Full validation:

```sh
mix test
mix compile --warnings-as-errors
git diff --check
```
