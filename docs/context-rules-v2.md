# Context and Rule Discovery V2

Sigma keeps the existing root-to-workdir `AGENTS.md`/`CLAUDE.md` walk. In each
directory, `AGENTS.md` still wins and deeper files remain later in the assembled
context. Repositories without V2 directives receive the same assembled text and
ordering as before.

## Directives

Context directives are Markdown comments and are removed from the model-facing
body:

```markdown
<!-- sigma:import rules/elixir.md -->
<!-- sigma:paths apps/example/**/*.ex,test/**/*.exs -->
<!-- sigma:sticky -->
<!-- sigma:disabled -->
```

- `sigma:import` loads one relative file after the importing section. Imports
  resolve relative to the source and must stay beneath its directory.
- `sigma:paths` applies the section only when the preview/reload target matches
  one of the comma-separated globs. Globs are relative to the source directory.
- `sigma:sticky` keeps a section applicable even when its path scope does not
  match.
- `sigma:disabled` omits the source and reports a diagnostic.

Import order is declaration order and recursive. Discovery detects cycles,
missing/unreadable/disabled sources, invalid scopes, and depth or size limits.
Valid unrelated rules remain usable when diagnostics exist.

Default bounds are eight import levels, 64 sources, 64 KiB per source, and
512 KiB total context-file input. Each open descriptor reads at most its
remaining limit plus one byte, so growth races cannot allocate an unbounded
file. Callers may lower these limits but cannot raise them through discovery
options. Directive values remain strings; Sigma does not create atoms from
context input.

## Composition and provenance

Provider context composition is deterministic:

1. Stable product/system instructions.
2. Runtime hook context.
3. Enabled skills.
4. Agent context: configured global prompt, worktree context, then project
   context files from root to workdir with each import immediately after its
   parent.
5. Runtime date/environment context.

`Sigma.Session.ContextFiles.discover/3` returns assembled `content`, every
section with source/import/depth/scope provenance, recoverable `diagnostics`, and
an include/skip `trace`. `preview/3` exposes the same result for settings and
debugging. SessionLive displays diagnostics and the composition trace when a
source cannot be applied.

## Explicit reload

Context files are discovered once when a session runtime starts. They are not
silently reread during a provider request. Build a replacement
`Sigma.Agent.SessionContext` and call `Sigma.Agent.Runtime.reload_context/3`.
Reload returns `session_busy` while any turn is active, so an in-flight provider
request always retains the immutable context captured at admission.

`Sigma.Agent.Runtime.context_preview/2` returns the currently active rendered
context and its source injections.
