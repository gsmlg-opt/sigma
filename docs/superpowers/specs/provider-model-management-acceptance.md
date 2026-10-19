# Provider and model management acceptance

Validated on 2026-10-19 in `.trees/pm`, branch `codex/provider-models`, baseline
`898ce173950d555da9e31a73c2dba3ef6917385e`, with the uncommitted implementation.
The baseline commit alone does not contain the feature.

## Isolated browser environment

- Sigma: `http://127.0.0.1:4585`; local HTTP fixture: `http://127.0.0.1:4691`.
- Temporary configuration, repository, skill cache, logs and screenshots:
  `/tmp/sigma-pm-browser-dxaPLJ`.
- Chrome isolated context: `sigma-pm-browser-20261019`, pages 45–47 only.
- Configuration and sessions used the temporary `agent/` directory. Existing user
  configuration and the existing port 4580 server were left unchanged.
- The fixture served model discovery, OpenAI Responses SSE, MCP JSON-RPC and the
  Backplane Skill Protocol. Its skill artifact was produced with the installed
  `Backplane.SkillProtocol.Bundle.pack/3`, downloaded and digest verified by Sigma.
  This is local integration evidence, not an external production Backplane test.

## Browser results

| Workflow | Result |
| --- | --- |
| Create provider | Created `Browser Backplane` (`prov_130`) through the UI with an explicit service origin and saved credential reference. Immediately verified `models: []` on disk. Provider UI has no current-model control. |
| Discover models | Explicit discovery showed loading, fetched authenticated `/v1/models`, and did not add candidates automatically. Selected Alpha, searched Beta, then added both; hidden selection survived search. Duplicate marker and empty search state rendered. |
| Manual model | Added `manual-browser` with budget 65536 through the form. |
| Budget and default | Edited Alpha budget to 131072 while preserving its 262144 context window; set its provider/model pair as global default. Submitted the edit with Tab then Enter. |
| New session | Default Alpha was selected and the form showed 131072. Created `session_48NLqabs06opmiG2` without a custom budget; session inherited exactly 131072. |
| Session adjustment | Apply changed the budget to 196608 and persisted it. After refreshing compiled source, Apply changed it to 180000, and final runtime smoke changed it to 175000; metadata and UI agreed. |
| Live membership | Removed Beta through confirmation while Session and New Session pages were already open. Both selectors updated without reload and contained only Alpha and Manual Browser. Neither removed Beta nor the unadded candidate appeared. |
| MCP reference | Selected the same provider. The form showed inherited `/mcp` and the credential name. Saved a server-local URL override, verified only `providerId`, `type`, `urlOverride` were stored, then restored inheritance. Provider endpoint was unchanged. |
| Remote source | Created `browser-skills` using the same provider; service origin, credential name and protocol preview were read-only. Loading and saving settings made no catalog request. Explicit Browse and Search fetched the catalog and showed `browser-skills:review`. |
| Actual remote skill use | Sent `/skill browser-skills:review inspect README` from the browser. Authorized catalog → resolve → artifact calls preceded the provider request. Provider input contained `BROWSER_REMOTE_SKILL_MARKER: Review inspect README…`; persisted message metadata included the verified digest, binding/cache files existed, and the browser displayed the streamed assistant reply. |
| Final runtime smoke | Restarted only the isolated service after final compilation, reloaded the session, changed its budget and completed another provider turn. Previous skill messages replayed correctly. |
| Credentials | Settings showed credential names. The Models document did not contain the synthetic fixture token. MCP/source configuration stored references rather than copied secrets. |

The actual skill turn is recorded in `requests.jsonl`,
`agent/skill-bindings.json`, `agent/skill-cache/`, and
`agent/sessions/L3RtcC9zaWdtYS1wbS1icm93c2VyLWR4YVBMSi9yZXBv/session_48NLqabs06opmiG2.jsonl`.
The request log records an authorization boolean, not authorization values.

## Layout, themes and diagnostics

Providers, Models, MCP and Skills were checked in Sunshine and Moonlight at both
1440×1000 desktop and 390×844 mobile viewports. For every page/theme combination,
`document.documentElement.scrollWidth === innerWidth` (1440 or 390). The existing
mobile settings navigation stacks above the content; content remains reachable
by vertical scrolling. Representative mobile content and desktop captures were
visually inspected. Theme changes used the Appearance control; model editing was
also exercised with the keyboard.

Screenshots under the temporary directory:

- `{providers,models,mcp,skills}-desktop-{sunshine,moonlight}.png`
- `{providers,models,mcp,skills}-mobile-{sunshine,moonlight}.png`
- `{providers,models,mcp,skills}-mobile-moonlight-content.png`
- `skills-mobile-moonlight-browse.png`, `new-session-default-budget.png`,
  `skill-use-session.png`

Fresh Settings and Session navigations after the final restart had no console
warnings or errors. Preserved console history contained only expected WebSocket
connection-refused messages during the deliberate isolated-server restart.
A screenshot automation stall was recovered by selecting page 45 explicitly and
using viewport emulation; it did not require browser reset or product changes.

## Served code and assets

The final service used `MIX_ENV=test mix run --no-start --no-compile --no-halt`
after the final scoped test compilation. `server.log` contains `BROWSER_MODULE`
records confirming loaded module MD5 equals the current on-disk BEAM MD5 for
ConfigManager, Models, Providers, SessionLive, ProtocolSessionOptions,
ModelsSettingsComponent and RemoteSkillSourcesComponent. In particular:

- SessionLive: `9f77e25bd579ae5215e6592388fd6172`
- ModelsSettingsComponent: `16323635a175b33ef9d38bc87c91b25b`
- RemoteSkillSourcesComponent: `5d3ba4a0692b2e2f68850142918781d7`

The version display reported 0.4.0, test, branch and baseline above, with build
time `2026-10-19T07:57:56Z`. Browser fetches returned HTTP 200 and SHA-256 values
matching the worktree static files:

| Asset | SHA-256 |
| --- | --- |
| `/assets/css/app-3e1ecb9c.css` | `3e1ecb9c9f01c10b672ff54349a4e5e4d55fcf96816353ab2aa8dd50b4a7a80b` |
| `/assets/js/app-e45723a5.js` | `4a8ea4ab87cdd2b452e36a8efa7410b8e4aea36c2be641576bffa9d9c91ecdb3` |
| `/assets/js/duskmoon_rich_elements.js` | `2fb1f18a5fee313b59012a2e1678e8600a091ab44d1371e37efc8e11dfee2322` |

## Automated checks and limits

The fresh combined scoped suite passed 116 tests (seed 615427), then 19 focused
SessionLive tests passed after the final admission guards (seed 861970): 135 tests
across the two scoped runs, with no failures. The 35-file scoped format check,
`MIX_ENV=test mix compile --warnings-as-errors`, and `git diff --check` passed.
The separate 18-test Settings/Models/Services run also passed; those cases are
already included in the combined suite.

An earlier stale line selector selected an out-of-scope terminal-bytes test. It
timed out waiting for the terminal running state and was not repaired. It is not
included in the scoped pass count; the complete repository suite was not run.

Browser testing used a fresh binding. Existing binding records without the new
identity metadata require an online refresh before offline reuse; that migration
case was not exercised through this fresh browser fixture. Authentication failure,
stale discovery, malformed results, service errors and admission refusals are
covered by scoped automated regressions rather than induced in this browser run.

## Shutdown

The isolated Sigma and fixture service are stopped after capture. Logs,
configuration and screenshots remain in the temporary directory for inspection.
The pre-existing port 4580 server and shared Chrome session remain running.
