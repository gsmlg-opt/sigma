# Session terminal operations

Session terminals use the repository-built `sigma-terminal-helper`; there is no
`script` or pipe-only fallback. The helper is packaged at
`lib/sigma_agent-*/priv/native/sigma-terminal-helper` in a release.

## Deployment gate

The feature is enabled by default. Set `SIGMA_SESSION_TERMINALS_ENABLED=false`
before application start to stage a deployment without terminal access. A disabled
feature, missing executable, or unsupported platform is shown explicitly in the
session UI and does not prevent ordinary agent sessions from loading.

Before enabling terminals in a release:

1. Run the locked native helper tests on every declared target platform.
2. Confirm the release archive contains an executable packaged helper.
3. Confirm create, resize, close, worker-loss, and control-channel EOF checks pass.
4. Inspect recorded terminal resources from the prior deployment. Do not kill
   processes by executable name, PPID, or another broad selector.
5. Restart the application as a controlled cutover. Existing legacy `script`
   processes are not adopted.

NixOS execution remains unverified until its native job runs. See
[`backend-adr.md`](backend-adr.md) for the current platform evidence and the
managed Unix-session boundary.

## Restart and recovery

Terminal catalogs, screen checkpoints, attachments, and controller leases are
volatile. An application restart loses that state and never replays terminal
commands. Browser state is presentation-only; a stale incarnation, generation,
attachment, catalog revision, or control epoch is rejected by the server.

If the terminal subsystem is unavailable, retain unresolved resource accounting
and investigate the scoped repository/session identity. Never infer that an empty
UI means that OS processes were cleaned up.

## Diagnostics

Terminal telemetry uses the `[:sigma, :terminal, ...]` prefix. Events cover catalog
counts, create/attach/detach, control, input byte counts, resize, resync, and cleanup
duration/outcome. Metadata includes scoped repository, session, incarnation,
terminal, and generation identifiers where applicable. It never includes PTY
content, input content, screen snapshots, or command text.

Terminal bytes travel between the browser and LiveView as base64 and go only to
the bounded attachment stream. They are not agent messages and are not persisted
to session JSONL.
