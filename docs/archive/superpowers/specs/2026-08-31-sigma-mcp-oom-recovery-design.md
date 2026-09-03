# Sigma MCP OOM Recovery Design

## Problem

Sigma pins `backplane_mcp_protocol` 0.6.0. When the affected session connects to the legacy Agent Note MCP server, the client synchronously compiles a self-referencing output schema through Peri. The release BEAM grows to roughly 29 GiB RSS, is killed by the kernel, and eventually leaves port 4580 unavailable after the process manager exhausts its restart budget.

## Decision

Require `backplane_mcp_protocol ~> 0.6.2` and update `mix.lock` to 0.6.2. That upstream release moves tool-validator compilation into a supervised task, bounds it to 500 ms, and disables only schema validation when compilation times out. Tool discovery, MCP calls, and Agent Note remain enabled.

This dependency floor prevents resolution back to the affected 0.6.0 implementation. No local schema parser, MCP-specific exception, or user configuration change is introduced.

## Alternatives

1. Disable Agent Note or remove its MCP configuration. This restores availability but removes requested functionality and only masks the dependency defect.
2. Patch Sigma to skip output validation for Agent Note. This creates deployment-specific policy in the wrong repository and violates the upstream dependency boundary.
3. Upgrade to the released upstream fix and constrain the minimum compatible patch. This is selected because it preserves functionality and uses the package-owned fix.

## Verification

- Preserve the observed RED evidence: HTTP connection refused, `gave_up`, status 137, and kernel OOM kills near 29 GiB RSS on 0.6.0.
- Run the focused Sigma MCP tests and warnings-as-errors compilation against 0.6.2.
- Start the repo-managed Sigma service, open the affected session, and confirm Agent Note reports `schema_validation_disabled` with `:compile_timeout` rather than growing unbounded.
- Confirm localhost, LAN root, exact session route, and LiveView WebSocket access while RSS remains below 2 GiB during the observation window.

## Scope

Only the `sigma_coding` dependency floor and `mix.lock` change. Theme behavior, release-runner lifecycle, MCP configuration, credentials, and session data are outside this repair.
