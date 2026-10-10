# sigma_tools

Elixir implementation layer for sigma's first-party, oh-my-pi-style tools.

`sigma_coding` owns the runtime contract: tool behaviour, dispatcher,
permissions, hooks, and MCP. `sigma_tools` owns the built-in tool modules exposed
to the model.

## Exposed Tools

- `ask`
- `read`
- `write`
- `bash`
- `edit`
- `search`
- `find`
- `todo`

`edit` accepts an `input` string in the `apply_patch` format and uses
`Backplane.AgentRuntime.Codex.ApplyPatch`. It supports file additions, updates,
deletions, and moves within the working directory. Update hunks match file
context; there are no content tags or session snapshots.

```text
*** Begin Patch
*** Update File: lib/example.ex
@@
-old content
+new content
*** End Patch
```

`read` and `search` return numbered lines under `[path]` headers. `write` creates
new files and rejects overwrites. Editing does not require a preceding read.

Patch operations execute in order. On a later failure, earlier changes remain;
the error message and details identify applied and uncertain files. Paths outside
the working directory, including symlink escapes, are rejected.

`todo` is session-scoped and Store-backed (agent-owned ETS). It supports
`add` / `update` / `complete` / `remove` / `list` / `clear` and is not
persisted to JSONL.
