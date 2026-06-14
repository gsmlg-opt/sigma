# pi_tools

Elixir implementation layer for ex_pi's first-party, oh-my-pi-style tools.

`ex_pi_coding` owns the runtime contract: tool behaviour, dispatcher,
permissions, hooks, and MCP. `pi_tools` owns the built-in tool modules exposed
to the model.

## Exposed Tools

- `ask`
- `read`
- `write`
- `bash`
- `edit`
- `search`
- `find`

`edit` is hashline-only. It accepts an `input` string with `[path#TAG]`
sections and `replace`, `delete`, or `insert` operations. Tags are produced by
`read`, `search`, `write`, and `edit` from session-scoped snapshots.
