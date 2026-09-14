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

Terminal catalogs, retained screen checkpoints, attachments, and controller
leases are volatile. After confirmed OS cleanup, an exited or failed tab keeps
its bounded screen in a read-only session-owned state holder until explicit
close or restart. An application restart loses that state and never replays
terminal commands. Browser state is presentation-only; a stale incarnation,
generation, attachment, recovery, catalog revision, or control epoch is
rejected by the server.

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

## Panel layout

The session terminal is bottom-docked in the central workspace, below the chat
composer. Opening it uses transcript height without changing chat width; collapse
returns that space to the transcript. Dock height is bounded by workspace space. Long composers scroll internally
to keep the input and send controls accessible on short viewports.
Maximize is an explicit viewport mode, and restore returns to the bottom dock.
Opening an empty catalog retains the existing first-terminal creation behavior;
height changes, tab selection, and maximize/restore do not create or restart runs.
Only the visible, synchronized controller measures its host with FitAddon and
proposes a fenced PTY resize. The confirmed resize event is canonical: every
renderer applies those columns and rows in stream order. Observers never refit
their character grid to their own viewport; their host clips or scrolls the
canonical grid without changing the PTY size.
