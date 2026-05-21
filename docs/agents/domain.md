# Domain Docs

This is a single-context repository. Engineering skills should use one root `CONTEXT.md` and root `docs/adr/` for domain language and architectural decisions.

## Before exploring, read these

- `CONTEXT.md` at the repo root, if present.
- `docs/adr/` ADRs that touch the area about to be changed, if present.

If any of these files do not exist, proceed silently. Do not flag their absence or suggest creating them upfront. The producer skill (`/grill-with-docs`) creates them lazily when terms or decisions get resolved.

## File structure

```text
/
├── CONTEXT.md
├── docs/adr/
│   ├── 0001-example-decision.md
│   └── 0002-example-follow-up.md
└── apps/
```

## Use the glossary's vocabulary

When output names a domain concept in an issue title, refactor proposal, hypothesis, or test name, use the term as defined in `CONTEXT.md`. Do not drift to synonyms the glossary explicitly avoids.

If the concept is not in the glossary yet, either reconsider the terminology or note the gap for `/grill-with-docs`.

## Flag ADR conflicts

If output contradicts an existing ADR, surface it explicitly rather than silently overriding it.
