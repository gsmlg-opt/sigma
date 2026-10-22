# Tool availability

Sigma has retired its legacy built-in tools as the first phase of a Codex-aligned
redevelopment. The old tool app, implementations and unused extension registry
have been removed. This phase intentionally does not introduce their replacements.

## Current model tools

Web and protocol sessions start with an empty built-in tool list. A normal
session can still chat, and adds only capabilities that are actually configured:

- Native Backplane V2 collaboration: `spawn_agent`, `send_message`,
  `followup_task`, `interrupt_agent`, `list_agents`, `wait_agent`. These require
  an enabled collaboration host and the session transcript writer.
- External MCP tools: discovered from selected servers, executed through the
  existing shared dispatcher, and refreshed when the server catalog changes.

There are no built-in file, shell, patch, image, todo or model-question tools in
this intermediate phase. Old tool calls in stored sessions remain readable;
loading history does not make their former implementations available.

## Retained host capabilities

Manual skill invocation, catalog/configuration, prepared resources, hooks,
permissions, path authorization, JSONL persistence and the UI terminal remain.
The skills API reports `manualInvocation: true` and `modelActivation: false`.
The UI terminal is a human-facing host capability, not a model command tool.

MCP still uses `Sigma.Coding.Tool`, Dispatcher, scheduling metadata and result
types. Their task supervision also serves hooks. Keeping this shared host layer
does not register any retired built-in tool.

## Next phase

Codex tool contracts and profiles will come from Backplane. Initial integration
must validate Provider custom inputs/namespaces, structured results and images,
session persistence, resource ownership, permissions and hooks before exposing
new tools. No tool is considered implemented merely because its dependency
contains a matching name.

- [Retirement design](../superpowers/specs/2026-10-23-legacy-tools-retirement-design.md)
- [Retirement implementation plan](../superpowers/plans/2026-10-23-legacy-tools-retirement.md)
- [Historical replacement plan](../superpowers/plans/2026-10-07-codex-tools-replacement.md)
- [Archived oh-my-pi tool PRD](../archive/legacy-oh-my-pi-tools-prd.md)
