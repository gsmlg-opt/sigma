# Codex tool protocol integration

## Scope and source versions

The legacy Sigma tools have been retired. Their replacements use public
`Backplane.AgentRuntime.Codex` contracts, strict catalog admission and resource
ownership. Web and protocol entrypoints now select the native root profile through the
actual Engine. This is source integration on `main`; the existing development
service has not been restarted as part of this change.

Comparison and executable versions remain distinct:

- Comparison checkout: `openai/codex` revision
  `9a8a85bc539325f2819dd0717f88b6ba6286495e`, tool builder
  `codex-rs/core/src/tools/spec_plan.rs` (Git blob
  `24b60f3ff2231a2e4a5e27dc7a93331a9aacd436`).
- Read-only builder refresh on 2026-10-29: `openai/codex`
  `c8bd6c1da9782bb92cf300a8768f87232b2d5631`, Git blob
  `2602fcb9bbbd9f916444d0c338a161b9fa9b5413`. Compared with the preceding
  comparison revision, this file adds no tool names/families. Its changes pass
  dynamic tools explicitly to the router, limit default namespace descriptions
  to MCP namespaces, and resolve context-management descriptions from model
  messages. This is a bounded source comparison, not whole-repository parity
  or a change to the executable inventory pin below.
- Executable contract: locked Hex packages `backplane_agent_runtime`,
  `backplane_ai_protocol`, `backplane_mcp_protocol` and
  `backplane_skill_protocol` 1.10.53, plus Runtime's required transitive
  `backplane_plugin_protocol` 1.10.53. The Runtime inventory is pinned to Codex
  `46fdd5ef39735f4159cdcf0ec5e85c10521494e5`. Passing Sigma integration tests
  establishes compatibility with these published APIs, not complete parity with
  every tool or platform in the newer Codex checkout.

The [alignment checklist](../superpowers/plans/2026-10-24-codex-tools-alignment.md)
records the authorized phase and remaining TODO/platform boundaries.

Current dependencies are the five official Backplane **1.10.53** packages,
source `012b7a750dcee5cfa48118d9c3eb87e03e411e22`. Four direct dependency minima
are updated; relative to 1.10.52 the lockfile changes only those five Backplane
entries. HTTP 0.21.17, ex_json_pointer 0.8.0 and plug_crypto 2.2.0 remain.
Locked resolution and dev/test/prod warnings-as-errors pass.
[Release 40981188107](https://github.com/gsmlg-opt/backplane/actions/runs/40981188107)
published the #147 fix; #148's earlier publication failure is resolved.

Runtime now registers clock ownership before publishing the tool/executor start.
Its public `native_clock_wait_retirement` owns registration ACK, timer retirement,
completion fencing and waiter/executor joins. Sigma preserves that authoritative
record and the existing ToolPostHooks callbacks. The original immediate-Stop
regression now passes unchanged (seed 43221, one selected/20 excluded). A new
PostToolUse case cancels on `tool_execution_start` without waiting for allocation
or ACK; it validates the original proof against Store intent and independent host
binding, then executes new work with a new Session/resources, retains old effects
and confirms full retirement. The other four root/managed-child × direct/real-Deno
cases retain their original assertions. A Deno outer start alone does not prove
that nested clock admission has occurred.

Two local recovery corrections accompany adoption. `Session.Operations.dump`
recursively projects tuple diagnostics to JSON arrays, retaining cancelled-call
repair details and complete original journal entries. `SessionLive` applies its
existing selected-branch cancelled-message restoration to active and stopped
views, so a cold-recovered cancelled tool card remains visible during a later
turn. Provider input remains repaired, and neither correction writes old journal
facts or creates a tool result. Behavioral regressions fail before each fix and
pass after it: Operations4 (seed 43230) and Web3 (seed 43234).

The nine-file tool selection passes 48 cases in source (seed 43227). The final
Linux x86_64/Nix production archive is assembled normally, moved and independently
extracted; all 565 product BEAM code identities match prod and actual loaded paths
resolve inside the package. Its unchanged eleven-file selection passes **55**
cases (tool48 + Operations4 + Web3, seed 43237), with zero failures/exclusions/skips.
A distinct packaged BEAM cold-loads seven Stores/twelve runs and seven journals;
public ToolEffects revalidates five clock and two Deno outer proofs against
original intents and independent binding ledgers. All **53** original files
retain bytes/hash/ns mtime/inode. No Agent/Provider/effect resumes. The expected
unconfirmed detached-helper case remains unconfirmed; its exact helper has exited.
Evidence: `/tmp/sigma-clock53-e742ylg6/complete/accepted/` and
`/tmp/sigma-clock53-e742ylg6/complete/package/archive.json`.

Actual extracted-package Protocol and Chrome sessions each execute five controlled
Provider requests and three successful results: raw patch, immediate clock Stop,
new clock work and real Deno/command reads. Protocol cancels directly from the
clock `tool.started` handler; Chrome uses the actual Stop button. The original
clock Store/proof, old Session DOWN, replacement resources and confirmed durable
host retirement are checked. A distinct final-package BEAM resumes both originals
twice through Protocol and explicitly reloads Chrome: complete dumps match,
including original cancelled calls and JSON diagnostics. Against the corrected
cold baseline, all **27** session/effect/log files retain bytes/hash/ns mtime/inode;
Provider11/hooks10 stay fixed. Those counts include one earlier catalog preflight
failure, retained without replay.

Chrome then starts an explicit fresh Provider turn, reloads while it is active,
retains the original cancelled clock card and all three successful cards, and
completes normally. The original unresolved clock call is absent from Provider
input; original Store/proof, journal byte prefixes, hook log and file effects stay
exact. This new work is a separate write boundary, ending at Provider13/hooks10:
one additional request failed inside the controlled Provider fixture's string/list
handling, then one fresh request passed after correcting that fixture. Both are
retained. Final host retirement is confirmed; owned services/helpers/page are
closed and 4580 remains without a listener. Packaged JS matches; favicon 404s and
intentional-shutdown connection refusals remain recorded.

Evidence limitations are explicit. The first cold harness mistakenly replayed its
already-consumed host-retire control file, adding a confirmed empty-host retirement
ledger entry; the other 26 files and all original effects remained exact. That
comparison is retained. The harness now ignores old controls, and the 27-file cold
proof above uses a new baseline after explicit fixture retirement. The original
Protocol script's dump failure is retained; the corrected final package later
exports and cold-reads those same sessions successfully. Packaged-runner missing
mock-provider configuration and a post-run inventory-helper omission are also
retained, followed by the complete passing run. No failed prompt or tool effect is
replayed. Evidence: `/tmp/sigma-clock53-e742ylg6/client/`.

The same independently extracted **1.10.53** package now also executes all 42
default native tools through the public Engine/Runtime, with actual MCP resources,
deferred discovery, six V2 collaboration tools, managed-child real Deno/followup
and independent interruption, cross-turn PTY/cells, Goal and hooks. The prior
1.10.51 fixture assertions and action sequence are unchanged apart from version
and temporary fixture identities; this run uses fresh local stores. Each of three
independent BEAMs confirms all five package versions and 19 core module paths.

The second BEAM cold-reads all 122 canonical messages, all 42 tools' results,
exact image bytes/detail and two async cards without starting an Agent. All 27
captured durable/effect files retain bytes/hash/ns mtime/inode; Provider/MCP-event/
hook counts stay 67/12/55. The third BEAM accepts an explicit new prompt, reads the
original Notes/Memory/pre-reset History/Board/completed Goal, and follows up the
same completed child through real Deno/MCP. New work raises Provider calls to 79
and ends in confirmed full retirement; original journal prefixes and patch bytes/
mtime remain unchanged. All owned BEAMs/MCP processes exit. This is controlled
Provider acceptance on Linux x86_64/Nix; online-model evidence retains its separate
1.10.51 scope. Evidence: `/tmp/sigma-full53-21bk2iaf/acceptance.json`.

Historical 1.10.52 acceptance remains separately scoped: the nine-file 47-case
package selection (seed 43225), six Stores/ten runs/six journals, four clock plus
two Deno proofs and 44 unchanged files are in `/tmp/sigma-packaged52-h_29umea/`.
Its Protocol/Chrome Events/Goal flows each have nine requests/six results;
resume/reload preserves 29 files, while final orderly closure separately writes
two empty-host ledgers and preserves the other 27. The earlier source immediate
Stop failure and publication failure explain #147/#148; both are superseded by
1.10.53 adoption and the original passing regression. Full 42-tool package
acceptance is now **1.10.53** as described above; real online acceptance remains
explicitly scoped to the **1.10.51** writerless profile.

The selected online service (`prov_3592 / gpt-6.1-sol`, 2026-10-29) first
rejected a missing `tools[7].description`. That field belongs to Sigma's local
Responses namespace projection. It now emits a nonempty namespace description;
the strengthened existing wire regression is RED before / GREEN after, retaining
custom grammar, output schemas, order, call identity and exact replay bytes.
Dev/test/prod strict compilation and the two changed Elixir files' formatting
pass. No Backplane package or production tool selection changes for this fix.

The new production archive is independently extracted and its assembly moved
away; public BEAM code identities match the current production modules. Its real
online writerless profile (native19 + connected MCP4/discovery1) completes six
turns, 19 Provider requests/responses and 13 outer tool results. Requested and
responding models are both `gpt-6.1-sol`. Clock, Plan, raw patch, Unicode file
reads, three actual Deno cells, exact original-detail image consumption and
metadata search/direct/nested MCP followups succeed. Actual MCP arguments retain
LF, CRLF and outer spaces; null/boolean results reach the model. The completed
Plan is retained across turns. After the public host retirement returns
`capture: :disabled, status: :confirmed`, the owned BEAM/stdio processes exit.
Another BEAM only opens and loads the six completed public Store records; all 12
selected files retain content, ns mtime and inode, with no Provider/MCP replay.
This writerless capture does not prove durable Writer/managed-child recovery or
online execution of all 42 default tools.

The corrected full Writer-backed profile remains rejected before model/tool
execution: HTTP 400 `invalid_request_error`, requiring `encrypted: true` on
`history.search_contents.query`. The current public local-History contract uses
plaintext queries. The remote encrypted History feature remains user-deferred;
do not falsely annotate plaintext, rename/drop production tools or silently
select another service. Preserve both original full-profile failures. This
service-compatibility limitation is separate from the now-resolved clock startup gap #147 and from the prior
controlled-Provider Writer/child/client/package acceptance. Evidence is under
`/tmp/sigma-live-provider51-nk_kvunj`; global configuration bytes/mtime/inode and
the original 4580 service remain unchanged.

Issues #90–#105, #107 and #109–#114 have published fixes; admission, real host
implementation and consumer acceptance remain separate. This batch adopts #109
terminal Goal ACK, #110 active-only notification expiry, #111 native nested-error
serialization, #112 Responses image fidelity and #114 nested backend context. The #108 release adds only Anthropic
PDF URL tool-result resources/links, preserving the original URI and link name.
Responses tool-role audio/resources/links remain unsupported; the full native
profile still requires Responses. Sigma does not claim typed-media consumption
from that limited codec release or switch transports to bypass incompatibility.

Current work keeps default YOLO auto-approval and excludes all security/permission
development and tests. Existing adapters remain; functional verification covers
execution, results, history and lifecycle. Older approval/isolation evidence below
is historical and is not a claim that those checks ran in this batch.

On 2026-10-27, the user deferred `web::run`, `image_gen::imagegen`, selecting
an actual plugin registry, remote encrypted History and `notes.thread_hint`. They remain
explicit TODOs and are excluded from this phase's completion gates. Existing
configured plugin APIs and their outstanding functional/lifecycle acceptance
retain their scope; no default registry or service endpoint is selected.

The requested one-hour check and the 1.10.44/45 results below retain their
historical version scope. The 1.10.48 integration adopted the published #126/#131/#133
fixes (1.10.46), #134/#135 (1.10.47) and sequential resource scopes #139 (1.10.48).
The original Error archive, idle-child transfer, root plugin cancellation and cold
pending-Goal recovery regressions now pass. This is uncommitted main integration;
the original port 4580 process is unchanged.

The 1.10.50 consumer acceptance adopts #141 and #142 through the public
contracts. LifetimeEvidence retains the exact `resource_scope_retirement` from
the authoritative Store alongside plugin-wait and Code Mode records; public
reconciliation validates the original identities. Code Mode registers its actual
worker before execute/resume through `register_code_mode`, which the existing
ToolPostHooks adapter already preserves. No local proof parser or cancellation
executor is added. The original six full-cancellation/retirement cases pass
(seed 43162). A seven-file functional selection then passes **88 tests**, excluding
the two archived-child inventory cases under the unchanged permission scope.
Those followups introduce `tool_search` beyond their original ceiling; their full
regressions remain, with no expanded grants. The preceding 1.10.48 selection was
80 pass/four fail; the two #141 failures are now accepted on 1.10.50. These
selections overlap and are not cumulative. The later 1.10.51 adoption below
addresses the independent #145 boundary.

Official 1.10.51, source `389b0956a2cce9a51c1782327a806b299f94c5a5`, closes #145 with
public `Goal.settle_host_admission/4`. It requires exact ordered host-effect
results, actual terminal result, executor DOWN, complete command cleanup and the
same future-start fence; it preserves ordinary hook-veto continuation policy.
[Release run 40738362785](https://github.com/gsmlg-opt/backplane/actions/runs/40738362785)
has completed, and all five official packages are locked. Sigma owns one hook
execution scope per actual automatic Goal executor, records completed command/MCP
outcomes in their observed order, seals pending starts and joins actual workers
before settlement. The Agent joins the durable acknowledgement before terminal
events. Failed writes retain the original seal, results and cause for persistence
retry; an uncertain command cleanup remains unconfirmed. Ordinary successful work
uses the existing Runtime binding and receipt recovery instead.

The original full hook-veto continuation regression now passes on 1.10.51,
including a later ordinary prompt, fresh automatic work on the same Goal, preserved
instructions and complete retirement. Its unchanged 1.10.50 failure at the fresh
automatic Provider assertion (seed 43171) remains historical evidence in
`/tmp/sigma-alignment51-o9l_8mm3/goal-hook50-baseline.log`. Current functional
coverage also includes SessionStart/async ordering, actual hook cancellation,
connected MCP hooks, eight real command workers, persistence retry and cold owner
reopening. The targeted 22-case selection passes (seed 43175); expected deliberately
unconfirmed cleanup reports remain explicit rather than becoming successful closure.

Hook ownership now extends through actual Session/Goal binding and run-index
preparation. Engine releases the Runtime handoff only after those stages succeed.
A real index I/O failure can use the host-effect settlement only after its reserved
Session is confirmed closed. Cancellation while Session preparation is pending
fences Goal binding before Runtime starts. A successful binding/index followed by
an uncertain handoff or Runtime startup retains ordinary indexed-run recovery;
an absent Store is not no-start evidence. The combined eight-file functional
selection passes **43 tests** (seed 43186), including Events, resource cancellation,
the original hook-veto continuation and both new preparation regressions. These
overlapping selections are not cumulative. Intentional detached-helper cleanup
uncertainty remains an asserted error. The same 43 cases also pass against actual
extracted 1.10.51 package BEAMs (seed 43188). The following versioned 1.10.50
client evidence retains its historical scope; current 1.10.51 package/client
acceptance is described in the next section.

Actual 1.10.50 Protocol/real-Deno and Chrome Stop flows run automatically loaded
PostToolUse hooks and cancel the original pending plugin invocation. Exact public
plugin-wait and enclosing Code Mode proofs retain the original request/invocation.
Late explicit Protocol/Settings installation leaves the original requests, two
journals and two Runtime files byte/mtime/inode-identical. Each next real prompt
executes plugin MCP and reads complete Unicode/LF/CRLF skills. Both full host
retirements confirm. After the old BEAM exits, a new BEAM accepts stopped Protocol
resume/installed retry and Chrome reload with no added Provider/HTTP/hook/MCP work
(counts 12/4/8, two MCP starts and two calls). All 32 captured files keep their
contents; 31 also keep ns mtime/inode. One existing empty skill-invocations sidecar
rewrites `[]` on resume; it is not claimed metadata-identical. The browser connects
without overflow and served JS matches local assets. Owned services/tabs are
closed. This is controlled-provider source/client acceptance, separate from the
installed-package results below and the unchanged 4580 service. Evidence:
`/tmp/sigma-alignment50-em57u8o6/client/final-client-acceptance.json`.

Actual 1.10.48 client acceptance now covers normal native installation completion:
real Deno through Protocol and Chrome's Settings Install button both complete the
original waiting call with its exact public request ID and `completed/user_confirmed`.
The next real turn reads the complete installed skill, including Unicode and LF/CRLF.
Live reload and a full BEAM exit/new PID, followed by Protocol resume and explicit
browser reload, preserve nine selected durable files byte-for-byte, including
mtime/inode, with no additions to the 10 Provider/4 HTTP calls. Served JS hashes
match local static assets. The owned 4675/42765 services and tabs are closed;
the original 4580/PID815717 service is unchanged. The Provider/registry are controlled
fixtures; this is source/client acceptance, not an installed release or deployment.

Automatic LiveView reconnect has a separate observed limitation: while loading,
`select_model` can be replayed with only `_target`, causing `FunctionClauseError`.
Explicit reload succeeds without new Provider/HTTP calls or durable writes. The
model-selection handler is outside this change; automatic reconnect is not claimed
error-free.

The same normal installation flow is independently accepted on **1.10.49** through
actual Protocol/real Deno and Chrome/Settings. Before explicit installation the
original calls stay pending, with no automatic installation HTTP or next Provider
request. Exact public request IDs, immutable invocation facts and actual
`:protocol`/`:settings` confirmation sources agree with the complete native results
and Writer JSONL. The next real turns read complete Unicode/LF/CRLF skills. Reload,
a full BEAM exit/new PID, Protocol resume/installed retry and browser reload keep
all nine selected files' bytes, SHA256, ns mtime and inode unchanged; Provider/HTTP
counts remain 10/4. Three successful browser cards, two installed rows, connected
LiveViews, no overflow and served JS/local hashes agree. This run's automatic
reconnect succeeds, with expected connection-refused messages while the owned
server is stopped; the earlier loading-time model-selection race is not reproduced
or fixed. Both owned BEAMs, the local registry and tabs are closed. Evidence:
`/tmp/sigma-plugin-client49-0a0m9b03/{final-client-acceptance,native-facts,cold-comparison}.json`.
This is controlled-provider source/client acceptance, independent of the package
probe below; it does not settle #141/#142 or alter the original 4580 service.

Historical 1.10.48/49 cancellation clients exposed
[Backplane #142](https://github.com/gsmlg-opt/backplane/issues/142): PostToolUse
presentation changes the outer backend module, so the old `cooperative_outer`
module check missed enclosing coverage despite an exact nested wait registration.
The four root variants then passed three and failed real Deno with PostToolUse.
1.10.50 replaces that module assumption with actual Code Mode worker registration;
all four original cases now pass with hooks, exact proofs, continuation and full
retirement intact. Normal 1.10.49 completion/client results above remain historical
and are not retroactively cancelled-flow or 1.10.50 installed-package evidence.

## Code Mode generator yields between timer slices

Backplane 1.10.49 fixes [#140](https://github.com/gsmlg-opt/backplane/issues/140).
A timer slice can return while JavaScript is still running. If its generator then
yields before the next `wait` attaches, the public worker retains that yield and
its output until the next caller, then advances only on the following wait.
Sigma consumes that public contract without replacing the worker or encoder.

The deterministic `:code_mode_slice` consumer regression stops only its own real
Deno process, obtains a zero-duration native wait slice, resumes Deno and observes
the arriving generator before issuing another wait. It fails on official 1.10.48
and passes unchanged on 1.10.49. All three text fragments retain their order and
appear once, the nested Plan updates once, JSONL projections round-trip and Deno
exits with confirmed resource cleanup. Six selected Code Mode functional cases
pass (seed 43160); the two admission/authority cases are excluded under the current
verification scope. The plugin cancellation comparison still yields 3 pass/1 fail
at #142, and both resource-scope full-retirement assertions still fail at #141 on
1.10.49. These selections overlap earlier results and are not added together.

## Extracted production release functional acceptance

The new Linux x86_64/Nix archive independently covers the five official **1.10.52**
packages. Standard prod Mix release assembly is archived, moved away and separately
extracted. Public BEAM code identity matches all 565 product BEAMs across six Sigma
and five Backplane applications to the current prod build. The nine unchanged
functional files and Events fixture run against actual packaged modules:
**47 tests, zero failures/excluded/skipped** (seed 43225). Source/snapshot hashes
and all 565 product-module paths are checked before and after execution. This is
the same source selection, not 47 additional independent behaviors.

A second packaged BEAM cold-loads the newly created six clock Stores/ten terminal
runs and six journals. Public ToolEffects revalidates four clock and two Deno outer
proofs against original intents and independent binding ledgers. All 44 captured
files retain bytes/hash/ns mtime/inode. The two BEAM PIDs differ and both exit;
the cold reader does not resume an Agent, Provider or old effect. The suite's
logged detached-helper cleanup error is its existing expected unconfirmed case,
not a newly confirmed retirement; its exact helper is absent after test cleanup.

Evidence: `/tmp/sigma-packaged52-h_29umea/{acceptance.json,beam-code-identity.json,
runner-packaged-functional-acceptance.json,packaged-cold-read.json,
clock-file-comparison.json}` and `package/archive.json`. No source or lock changes
were needed. The initial build alias encountered an old nested release cache;
it was preserved, and standard Mix release used the verified current prod build
with ordinary dependency checks. This does not qualify #147 before publication
or extend real online-model acceptance to 1.10.52. Port 4580 has no listener and
was not started or restarted.

### Packaged Protocol and Chrome acceptance on 1.10.52

Actual Protocol and Chrome clients use independent temporary repositories and the
same extracted package with a controlled Provider. Each completes nine Provider
requests and six successful results (`create_goal`, `mcp_events`, two real `exec`
calls, `get_goal`, `update_goal`). An automatic UserPromptSubmit veto retains its
actual pre-Runtime host-effect settlement; ordinary Events work and fresh
automatic completion preserve the same durable Goal and original settlement.
Public Goal `thread_id` matches the dump's top-level session header; durable Goal
identity is checked separately. Events preserve exact Unicode/CRLF cursors/pages,
real Deno MRTR and the original caught native error before successful continuation.

Both original roots return confirmed durable retirement. After complete owned
BEAM exit, a distinct packaged BEAM resumes each session twice through Protocol;
an explicit Chrome reload retains all six successful cards and completion text.
Both complete canonical dumps remain exact. During stopped resume/reload, all 27
session files and two Provider/hook logs retain bytes/hash/ns mtime/inode;
Provider18, hooks25 and Events10 counts remain fixed. Reconnection adds only six
MCP discovery/subscription/tool-list reads. Final orderly shutdown is a separate
write boundary: two host-retirement ledgers change, each including a confirmed
new empty-host closure with no native bindings; the other 27 files remain exact.
No old native tool, Provider, hook or Events execution repeats.

Chrome is connected without overflow and both served JS hashes match the package.
Two favicon requests return 404; intentional BEAM stops also log connection-refused
messages. Initial launch without Deno is retained as a failed preflight; the
corrected devenv launch uses a fresh session. Offline harness field assertions
were corrected against the retained dump and facts without replaying prompts.
Owned services/fixtures/tab are closed. Evidence:
`/tmp/sigma-packaged52-h_29umea/client/{client-acceptance.json,
protocol-initial-acceptance.json,cold-read-acceptance.json,
resume-comparison-command.json,file-comparison.json,
final-retirement-inspection.json,final-stop.json}` and `client/browser/`.
At this historical 1.10.52 boundary, full-tool/online evidence was still 1.10.51
and #147/#148 were unresolved. Current 1.10.53 adoption and original continuation
acceptance resolve both; its full 42-tool package evidence is recorded above.
Online-model acceptance remains scoped to the earlier writerless profile.

### Earlier full-tool package acceptance on 1.10.51

The prior full-tool/client acceptance below retains its **1.10.51** scope.
The assembly is packed, moved away and independently extracted; version and module
path checks resolve the actual Sigma/Backplane BEAMs inside that package. The same
eight-file functional selection runs there with unchanged source assertions:
**43 tests, zero failures** (seed 43188), covering Events, resource cancellation,
plugin cancellation, Goal hook settlement and preparation failures.

The actual packaged Engine/Runtime also executes all 42 default native tools,
MCP resources/discovery/structured results, six V2 collaboration tools, same-child
Deno/followup, independent interruption and cross-turn PTY/cells, then fully
retires. Three independent packaged BEAMs cover execution, stopped cold reads and
an explicit fresh prompt. Cold reading retains 122 canonical messages, exact
images and two async cards; all 27 captured durable/effect files retain bytes,
SHA256, nanosecond mtime and inode. Provider/MCP-event/hook counts remain 67/12/55.
Fresh work adds 12 Provider calls, continues the original completed child through
real Deno/MCP and fully retires. Old journal prefixes and patch effects do not
replay. The interrupted child's historical accounting/archive boundary remains.

Separate actual Protocol and Chrome sessions use this same extracted package.
Each creates a Goal, encounters a real automatic UserPromptSubmit veto, retains
the exact host-effect settlement, and completes ordinary plus fresh automatic
work on the original Goal. Direct Events, real-Deno MRTR and a caught native RPC
error followed by another Events call retain exact pages and the original message.
Both roots fully retire. A new BEAM then resumes Protocol and reloads Chrome in
the stopped state: each retains six complete results, all 23 selected durable
file contents are identical, and 22 also retain ns mtime/inode. One existing empty
skill-invocations sidecar rewrites `[]`. Provider/hook/Events execution does not
increase; MCP reconnect adds two sets of server discovery, subscription and
tool-list reads. The selected sessions used 18 Provider calls; global logs retain
nine preparatory calls from an earlier fixture attempt, which are not counted as
another successful client run. Chrome is connected without overflow or console
warnings/errors, and both served scripts match package bytes.

All owned BEAMs, MCP fixture processes and the created tab are closed. This is
local controlled-provider package/client acceptance; it does not establish live
model, other-platform, remote-CI, publication or deployment acceptance, and does
not replace the service on 4580. Evidence is under
`/tmp/sigma-alignment51-o9l_8mm3/package/` in `archive.json`,
`packaged-contract-acceptance.json`, `first-acceptance.json`,
`cold-read-unchanged.json` and `resume-acceptance.json`; client facts and differences
are in `../client/final-client-acceptance.json` and `full-retirement.json`.

The following **historical 1.10.50** Linux x86_64/Nix archive carries all five official
**1.10.50** packages. The assembly is packed, moved away and independently
extracted. All probed Sigma/Backplane BEAMs, the terminal helper and MCP guardian
resolve inside that extracted package. The actual Engine/Runtime executes all
42 default native tools, real MCP resources/discovery/structured results, all
six V2 collaboration tools, same-child Deno/followup, independent interruption,
cross-turn PTY/cells and full retirement.

Three independent packaged BEAMs establish first execution, stopped cold reads
and an explicit fresh prompt. Cold reading restores 122 canonical messages,
exact image bytes/detail and two async cards without an Agent; all 27 captured
durable/effect files retain bytes, SHA256, nanosecond mtime and inode. Provider,
MCP events and hook commands remain 67/12/55. Fresh work adds 12 Provider calls
and continues the original completed child through real Deno/MCP, then fully
retires. The original journal prefix and patch bytes/mtime remain unchanged.
The interrupted child's historical uncertainty and archive boundary remain.

The original four root plugin cancellation cases and two paginated child resource
cases also run against installed BEAMs: **six pass**, seed 43166, with the
resource/plugin/Code Mode proofs, late installation, continuation and final
retirement assertions unchanged. The harness copies of both source test files
are byte-identical. Only ExUnit is supplied by the host test harness; Sigma and
Backplane modules resolve inside the extracted package. An initial tag-selector
mistake ran the broader file selection and reproduced the two already excluded
child-inventory failures; that result is retained separately. The corrected
selection executes only the six intended cases, without changing production
code, grants or assertions.

The separate packaged PluginRuntime/Dispatcher probe verifies exact Unicode/CRLF
results, the actual packaged guardian parent, exit 0, confirmed cleanup and a
no-effect repeated close. The package's JS hash matches the current source asset.
All owned BEAMs/tool processes are stopped. This is controlled-provider local
package acceptance; it adds no browser, hosted-model, remote-CI or other-platform
claim and does not replace the original 4580 service. Evidence:
`/tmp/sigma-installed-native50-e0xmk4o3/{archive,first-acceptance,cold-read-unchanged,resume-acceptance,packaged-contract-acceptance}.json`
and `plugin-component/release-functional-acceptance.json`.

The following **historical 1.10.49** package acceptance retains its version scope.
A local Linux x86_64/Nix production archive with all five official 1.10.49
packages was assembled, packed and extracted into an independent directory. The
assembly directory was moved away. Every probed Sigma/Backplane BEAM, the terminal
helper and the MCP guardian resolve inside the extracted release.

The actual Engine/Runtime executes all 42 default native tools, including Plan,
raw patch, typed image bytes/detail, local environment startup, synchronous and
correlated asynchronous questions, Skills, Memory, History/Notes, Goal and all
nine board tools. Successful turns retain a real 24x120 PTY and a real Deno cell;
subsequent stdin preserves Unicode/whitespace and exit 7, and wait returns only new
output. Actual MCP resources, deferred discovery, structured results and all six
V2 collaboration tools execute, including the same child's real Deno, followup,
message and independent Provider-only interruption. Full host retirement succeeds.
The public Goal completion still reports `accounting_uncertain: true` for the
interrupted Provider; no unknown usage is converted to zero.

A second independent release BEAM reads all 122 canonical messages, exact image
bytes/detail and the two consumed/notice cards without starting an Agent. All 28
observed durable files preserve bytes, SHA256, nanosecond mtime and inode; Provider
calls remain 67, MCP log events 12 and hook commands 55. A third BEAM receives an
explicit fresh prompt, reads prior Notes/Memory/History/Board/Goal state and follows
up the original completed child Session through real Deno/MCP. It fully retires;
the old journal remains an exact prefix and the original patch bytes/mtime are
unchanged. The fresh work adds 12 Provider calls as expected, for 79 total.

The interrupted child is separate from the completed child used by cold followup.
The public archive explicitly excludes historical `unknown_outcome`, even when
independent retirement is confirmed. An earlier 1.10.48 probe reached that boundary
and returned `agent was not found`; it does not establish interrupted-child archive
continuation. No local eligibility change, synthetic snapshot or effect replay was
added. A retired binding also withdraws old PTY/cell handles; cross-turn retention
is checked between successful turns before that retirement.

An independent packaged PluginRuntime/Dispatcher call confirms complete Unicode
and CRLF structured content. Its actual parent executable is the packaged guardian;
the public cleanup report confirms guardian exit 0 and both OS processes disappear.
Repeated close has no new invocation. All three profile BEAMs and owned tool
processes are stopped. This is local installed-package acceptance with a controlled
Provider and stdio fixture, not remote CI, another platform, a hosted model,
publication or deployment. Actual browser/Protocol installation results above
have independent 1.10.48 and 1.10.49 source/client evidence; this package probe
does not execute a browser. Its historical #141/#142 failures are resolved in
the separate 1.10.50 source/client and installed-package acceptance above.

Evidence: `/tmp/sigma-installed-native49-yi4ktiel/{archive,first-acceptance,cold-read-acceptance,cold-read-unchanged,resume-acceptance}.json`,
the three functional logs and `plugin-component/release-functional-acceptance.json`.
The durable source regression for #140 is
`apps/sigma_agent/test/sigma_agent/backplane_codex_code_mode_test.exs:89`.

## Cancelled tool-card display

A tool call without a result no longer shows `running` after its own durable turn
is cancelled. It uses DuskMoon's existing neutral `pending` state with the explicit
label `turn cancelled`; this states the turn outcome without inventing a tool
settlement. Terminal metrics refresh every tool-bearing assistant row of that
turn. Existing success/error results retain their exact result and state, and a
later active turn cannot make the old card run again.

For stopped reload, the UI restores only cancelled assistant messages already
present in the captured selected branch, reading their originals from the Writer
journal. It does not restore sibling messages or change repaired Provider input,
Runtime records or JSONL. The functional regression covers incremental updates,
multiple rows, preserved results, the next turn and reload, including unchanged
journal bytes, Writer-selected branch isolation and still-repaired model context.
All eight selected Web functional checks pass (seed 43165). Final-source Chrome
cold load/reload preserves the cancelled card without a result and the four
successful MCP/Skills cards; no console warning/error or overflow is observed.
All 32 captured files retain bytes, ns mtime and inode during this display check.
Orderly host shutdown is separate and may append its own host-retirement facts.
Evidence: `/tmp/sigma-alignment50-em57u8o6/client/ui-final-acceptance.json`.

## ApplyPatch production admission

Root and managed-child profiles restore default and explicit `apply_patch` through
the published native implementation. The raw custom input, complete ordered
add/update/move/delete result and JSONL projection are preserved. Real Deno uses
the same public backend. No local parser/executor or permission/preflight adapter
is added; the old #104/#105 suspension described by earlier evidence is retired.

With a transcript Writer and root archive, the default root catalog contains 42
tools: 12 core, 1 environment, 2 Skills, 4 Memory, 4 History, 5 Notes, 2 async,
3 Goal and 9 message-board tools. Writerless roots retain 19 tools. Optional MCP
resources, discovery, configured functions, two configured plugin tools and V2
collaboration add their actual contracts. Managed children share the root board
but do not expose root Goal3.

## Catalog and transport

Build native declarations with `Codex.profile/4`. Pass an admitted profile to
`Sigma.Agent.Backplane.ToolCatalog.admit/4` through `profiles: [profile]` to
compose it with MCP descriptors and collaboration contracts. Composition retains
the actual registry descriptors, including custom grammar, output schema and
process-local session binding. The final Runtime catalog must have exactly the
same names as its authority grants; a stale caller/run profile is rejected.

The resulting `registry`, `tools` and `authority` form one bundle. Provider
requests use the Runtime request's admitted definitions. Native contracts must
not be copied into legacy Sigma tool modules or reconstructed as generic JSON
functions.

OpenAI Responses supports native function and custom declarations, namespace
groups, grammar formats, output schemas, call replay and typed tool outputs.
Sigma validates requests and calls through the public AI protocol and delegates
tool frame parsing to its public Responses stream codec. Existing host HTTP,
reasoning and response-terminal handling remain in Sigma. Chat Completions and
Anthropic reject native custom/namespace/output-schema requests before HTTP,
including incompatible replay history; they do not silently change the tool
contract when the user switches providers.

Malformed, truncated or conflicting tool frames fail the provider response.
The adopted codec rejects explicitly unfinished tool items at frame and
response-terminal boundaries. It includes the
[backplane#76](https://github.com/gsmlg-opt/backplane/issues/76) fix, so Sigma's
temporary status guard has been removed while its regressions remain. Runtime
still requires a successful response terminal before dispatch.

Calls use canonical names such as `clock::curr_time`. Function arguments remain
maps. Custom calls carry `input_kind: :custom` and the exact binary input;
JSON-looking custom text is still raw text. JSONL decoding accepts the closed
input-kind tags, preserves raw strings, and rejects mismatched or untagged binary
arguments. Existing untagged map-based history remains readable. Reading history
does not dispatch tools.

## Results and images

`Sigma.Agent.Backplane.Provider` keeps JSON-safe native results under
`metadata.structured_result`, independently of their text/image projection.
Structured siblings of `content` are preserved. Malformed content, nonboolean
error flags and process handles are rejected instead of creating an unreadable
journal entry. Runtime errors retain their public class/message/details, with
their private cause excluded.

The native `view_image` result contains raw image bytes and a data URL. The model
receives an image content block with base64 data and MIME type. The journal keeps
the canonical data URL, path, detail and byte count, without inserting raw binary
bytes into UTF-8 JSON. Responses encodes text/image tool outputs for both function
and custom calls. LiveView projects validated image blocks into their existing
assistant tool card, alongside text and status. React uses the existing DuskMoon
`Chat.ToolResult`; loading a transcript restores the preview without rerunning
the tool. Tool previews accept PNG/JPEG/GIF/WebP, at most four images and 10 MiB
per image and in total, matching the native image limit. MIME/signatures, strict
base64 and GIF structure are validated; valid animated GIFs are supported. User
uploads retain their separate 5 MiB per-image and single-frame GIF policy. Invalid
or oversized tool images are omitted while text and error status remain available.
Image-only results also render in the tool card. This is an inline preview rather
than a separate full-size viewer.

## Session resources

`Sigma.Agent.Backplane.CodexResources` owns a Runtime `Command`, `Plan` and,
unless supplied by another host, `Codex.Session`, plus a public DynamicRuntime
for MCP resources. The long-lived Subagents host owns these resources for native
root sessions; the temporary Engine task owns only its run and responder.

1. Bind a fresh turn authority with `CodexResources.bind/3`.
2. Obtain the host context with `context/2`, then build the selected native
   profile and start a Runtime Conversation using that binding.
3. Let Conversation attach, validate effects, durably finish and detach the run.
   A new turn uses a distinct run ID and can continue the retained command handle.
4. Failure/cancellation closes admission and reconciles resources through
   Runtime Session. Stale bindings cannot authorize subsequent effects.

Owned resources close their Session before stopping command/plan processes.
Borrowed Sessions stay under their existing host's ownership; explicit resource
close requires that host to confirm Session closure first. Host death stops the
resource process without restarting or replaying commands. Bindings, tokens,
PIDs and callbacks are ephemeral and do not enter canonical history.
Confirmed Session cleanup and skill-resource closure are retained independently
from complete child shutdown. If a later process stop times out, admission stays
closed; after that process exits, another close can finish using the retained
public receipts. A dead Session is not called again and a partial close is never
reported as confirmed.

The production command adapter is `Sigma.Agent.Backplane.PlainCommand`.
Non-PTY jobs delegate to the public Linux `Tools.LocalCommand`, preserving its
empty environment and process-group cleanup. On Linux with the packaged helper
available, `tty: true` starts an independent `PtyJob` and Native helper with a real
24-row/120-column terminal. These jobs do not share the UI terminal. PTYs inherit
the existing Native helper environment, including terminal variables; Native does
not accept per-command environment overrides. This integration uses ordinary
commands and does not activate the separate sandbox adapters.

Backplane 1.10.43's optional first-party PTY is not a drop-in replacement.
LocalCommand's active-workspace guard rejects a second retained PTY in the same
workspace, whereas Sigma's existing functional regression requires two independent
jobs. The Hex package ships C source and requires explicit `mix backplane.pty.build`;
no generated helper is present in the current dependency or build directories.
Its environment and nonzero-exit representation also differ. This is a source
audit, not a claim of new first-party PTY execution. Keep the existing public
Command adapter and accepted behavior; do not add a local fanout or weaken tests.

Launch acknowledgement follows the helper's actual started event. UTF-8 output
is assembled across frames, cursor reads return only new text, and stdin is split
into the Native API's 16 KiB frames without changing its contents. Invalid or
incomplete final UTF-8 is displayed with replacement characters. A nonzero shell
exit remains a completed command result with its real exit code, rather than a
tool-dispatch error. Deadline, output limit and cancellation retain their actual
termination and cleanup receipts.

Fast natural exit previously let `ShellExited` overtake queued output, losing the
tail. The helper now cleans remaining slave holders, drains output to EOF within
the existing shared five-second shutdown budget, and publishes output before
shell exit and cleanup. Drain failure remains explicit. `PtyJob` waits for final
Native events and process exit before confirming cleanup, so a later fatal event
cannot be lost by an early acknowledgement. Results remain available until the
public release acknowledgement. A live host retains results after execution-owner
death; closing or losing the host cleans the terminal and retires its job.

The PTY writer remains owned until slave cleanup and natural-exit draining finish.
`portable-pty` intentionally writes newline/EOF when that writer drops; releasing
it before cleanup can echo an extra CRLF into otherwise exact command output.
A real echo-enabled slave-holder regression reproduces the extra line before the
ordering fix and preserves the exact original output afterward. No output trim,
protocol replacement or extra shutdown budget is used.

A payload exit code does not confirm process-group cleanup. A result with
`cleanup_status: pending` retains its `session_id`, including after exit code 0;
the caller can continue polling until cleanup is confirmed. Tests follow this
public distinction rather than requiring immediate handle removal on exit.

Backplane 1.10.37's default concurrent-cleanup fix (#103) passed a 32-Session
real CodexResources/Conversation functional check: 16 closes and 16 cancellations
start behind one release barrier, terminal events precede status sampling, all
OS PIDs exit and earlier running-command settlements remain unchanged. The
earlier 1.10.36 public reproduction reported uncertain cleanup across 32
independent Sessions; current consumer lifecycle evidence is recorded separately.
Cleanup errors remain visible without timeout increases, production serialization
or replay of uncertain effects.

Integration fixtures exercise real `exec_command`/`write_stdin` across distinct
runs, `update_plan`, cancellation and cleanup. Raw `apply_patch` production
admission and functional acceptance are described above; #104/#105 restrictions
belong to the earlier 1.10.36 evidence.
`update_plan` returns a revision/status receipt; actual plan content is read from
the public host Plan process and projected separately as described below.

Ordinary command acceptance covers 19 selected Elixir functional cases: 14 adapter
cases, three actual root/child Engine cases, the 32-independent-Session concurrent
cleanup case and the direct completed-handle error case. Four native output tests
cover exact Unicode/CRLF, long tails, empty output and remaining slave holders.
Real Deno receives PTY results, and a managed child can continue stdin through
Deno after its first turn completes. With 1.10.42, both direct and real-Deno
completed-handle regressions pass: the normal error fulfills the nested Promise,
and another command still runs. No security, permission or sandbox tests were run.

An independent WebSocket and a new Chrome session used the default entrypoints on
isolated port 4626. Both retained a terminal across two prompts, preserving exact
Chinese/whitespace/CRLF, exit 7/3 and confirmed cleanup; the browser also reloaded
between prompts. After the owned BEAM fully exited and a new PID started, protocol
resume and browser reload retained all three tool results per session. Provider
logs stayed at five calls per session; their hashes and nanosecond mtimes, both
single-launch markers and original journal bytes remained unchanged. Served JS
matched the local artifact, and the final LiveView was connected without console
warnings/errors or horizontal overflow. A cold reconnect separately logged an
out-of-scope `select_model` FunctionClauseError for a form payload containing only
`_target`; manual reload succeeded. This form-handler issue was recorded without
changing model settings. The owned service/tab were closed; 4580 was unchanged.

## Confirmed Plan projection

Engine reads public `Plan.read/1` after successful root `update_plan`, `exec` and
`wait` results. This captures the final prepared input and actual nested updates,
instead of guessing from the model's original arguments. A changed plan is stored
as bounded `metadata.native_plan` on the existing canonical tool result; the
native receipt and model result stay intact. Its source identity belongs to the
root publication and does not invent a nested invocation identity.

The session details rail displays the last confirmed snapshot. Loading and turn
startup read the selected raw journal ancestry through `Writer.selected_journal/1`,
which serializes behind accepted appends and uses Writer's configured storage and
active leaf. Plans survive compaction and context-window resets, while retry and
fork exclude sibling branches. Engine hydrates public Plan state before starting
Conversation; a branch without a saved plan clears a retained sibling plan, and
an unchanged plan does not receive another update. Snapshot order follows branch
chronology because a restarted Plan process can have a lower revision.

Snapshots allow at most 128 steps, 4 KiB per step, 8 KiB explanation and 64 KiB
total. Failed root calls retain the prior published snapshot: a nested update
inside a failed outer `exec` is not a confirmed publication. This is recovery of
published plan content, not replay of historical tools or persistence of every
in-flight Plan mutation.

An independent WebSocket client exercised the default protocol entrypoint with a
direct plan and a real Deno nested update. Chrome displayed both confirmed
snapshots and retained the latter across reload and a complete isolated server
restart; the resumed turn did not call another tool. LiveView was connected,
there was no horizontal overflow, and final console checks found no warnings or
errors. This used a controlled provider, independently from the scoped branch,
hook-transformation and compaction tests.

## Durable Goal host and production lifecycle

Root `get_goal`, `create_goal` and `update_goal` now use the actual Writer,
Runtime Store, public Codex Session binding and ExtensionRuntime. `GoalIntegration`
opens and reconciles the thread before admission; Engine retains its Goal context
when deferred discovery rebuilds the catalog. Native backend context uses the
published `resource_owner.session_binding`, including real Deno calls. Children
receive public usage-only delegation rather than root Goal tools.

`GoalStore` serializes complete private Goal records and tombstone revisions with
CAS, file-data sync and atomic rename. `GoalUsage` uses actual cumulative provider
counters; input includes cache, so public Goal accounting subtracts cache reads
once. Missing/inconsistent counters stay unknown. A complete sample does not
establish endpoint-wide authoritative budget capability.

`GoalCoordinator` owns the public Goal outside the Agent call cycle. `GoalRuns`
persists exact run/incarnation and immutable journal header identity before a
binding is returned. Reopen reconciles the complete index before mutation or
idle admission. Retained terminal receipts use public `GoalBridge.redeliver/3`
and #109's `:goal_outbox_acknowledged` command; receipt identity/payload and
terminal outcome remain intact. Failed usage commit or ACK retains the actual
cause and outbox. Matching redelivery charges once; no Provider/tool is replayed.
An acknowledged public Store fence may advance the current incarnation beyond
the immutable Goal index. Recovery binds original receipt attribution and sends
the exact retained receipts to ACK under the current fenced incarnation.

Two root functional cases force an actual Engine usage-write failure, confirm
the exact Provider task's death and public Session/resource close, then settle
the provider-only run through public Store/Kernel transitions. Repeated Goal
commit or ACK failures retain their actual causes and charge once. Production
Agent reopening restores the blocked Goal without a Provider request and accepts
a fresh ordinary prompt. A separate full-BEAM exit/restart acceptance preserves
the original index/outcome, charges exactly 13 tokens and increments ACK by one
revision. Before the fresh prompt, the journal and three-request Provider log
are byte-identical; only the fresh prompt adds the fourth request. This uses a
controlled Provider and explicit independently evidenced host reconciliation.

Production startup now performs that provider-only root reconciliation through
`RunRecovery`, before the existing terminal validation and Goal accounting.
The immutable Writer header and original indexed run identify every matching host
lifetime. All native generations in those lifetimes need their exact close receipts,
alongside async-hook shutdown and the independent SessionEnd completion. Each recorded
Provider attempt must have its original durable stopped observation. Dispatch
completion preserves SessionEnd outcome/warnings; it does not assert handler success.

The eligible snapshot has only its original active Provider: tools, children,
dependencies, active waits and other uncertain execution intents block recovery.
A transition outbox may retain only the exact matching Provider execution intent,
including operation identity and reservation. It is not treated as an empty effects
list or discarded without matching termination evidence. No live owner is closed
from the coordinator and no unfinished Conversation is resumed.

The controller uses public Store fencing, cancellation and exact cleanup settlement.
A failed write retains the actual cause and committed stage. Reopening continues
an already fenced/cancelling run without another incarnation increment; original
Provider identities and Goal receipts never change. Only after confirmed terminal
settlement does the existing redelivery/current-fence ACK path account the receipts.
An ordinary Runtime storage failure with no Goal follows the same path without
inventing receipts. Terminal `unknown_outcome` and runs with other outstanding work
remain boundaries for this ordinary nonterminal controller. The prospective
terminal-unknown lifetime path below additionally requires the acknowledged public
ownership tree; arbitrary retained work remains unsupported.

Functional cases cover actual usage-write failure, subsequent Goal commit/ACK
failure, each recovery-stage write failure, missing native/hooks/SessionEnd or
current/earlier Provider facts, and an actual no-Goal Runtime failure retaining a
Provider outbox. A fresh production Agent accepts replacement work without replay.
Separate complete-BEAM acceptance opens an actual failed root directly through
production startup: the original run is cancelled under the newer fence, the original
index is retained, and the failed response contributes 13 tokens once. Before a new
prompt, journal, Provider log, both component ledgers and the run index retain exact
bytes and nanosecond mtimes; only the Runtime and Goal records change. Replacement
work keeps the committed context and adds the fourth Provider request. Another fresh
BEAM reopens with eight files byte/mtime-identical and no further Provider requests
or usage changes. This is controlled-Provider acceptance, not a release or deployment.
The final eight-file functional selection passes 50 cases; dev/test compilation with
warnings as errors, the three changed Elixir files' formatting and the diff check
also pass. This overlaps prior lifecycle selections rather than adding to their
counts; injected-failure and teardown diagnostics remain visible.

`GoalDescendants` resolves actual child admission receipts, independent Runtime
stores and originating root runs from the Writer ledger. Empty/nil outboxes need
no Goal settlement, including ordinary running children created without a Goal.
Nonempty outboxes require the exact original Goal/run receipt identity and a
confirmed terminal snapshot with no unresolved effects, cleanup or intents.
Ordinary actual-child usage is charged through public MultiAgent delegation.

Earlier 1.10.42 functional cases retained receipts from an actual child usage-write
failure, stopped the owned tree and proved Provider process death. Public Store.fence
and Kernel cancel/cleanup_settled use exact provider-only cleanup evidence; no
tool/child/dependency effects are fabricated as settled. Recovery keeps original
receipt/admission incarnation while terminal ACK uses the newer fenced run
incarnation. A failed usage commit or terminal ACK then survives actual Goal,
Store and Writer process restarts and charges exactly 13 tokens once. This is
same-BEAM accounting evidence. The five current child regressions use production
close and retain exact fence/receipt/usage assertions; the prospective lifetime
controller below adds replacement admission and fresh-BEAM acceptance. Uncertain
effects remain recovery boundaries.

Child host retirement now has a distinct private `host-retirement.etf` ledger,
serialized by the existing child Runtime Store. Production Subagents passes the
actual immutable root Writer header; ChildIO resolves its own Writer header and
creates a host lifetime independent of native Session generations. Every successful
Session bind records the exact run/incarnation and native owner/incarnation before
extension preparation or admission. All memberships survive followups and native
generation replacement; no live binding, PID, reference or callback is persisted.
The sidecar does not modify ordinary Runtime snapshots, revisions or outboxes.

`CodexResources.close` records only its actual confirmed native close, and
`ChildIO.retire` separately joins async-hook shutdown before recording `async_hooks`.
Actual confirmations survive a later failed receipt write for an exact retry;
unconfirmed hook shutdown retains its original cause rather than retrying a dead
runtime. Explicit retirement runs outside ChildIO's message loop, which stays
available for existing commit callbacks while refusing new preparation and hook
delivery. Subagents awaits and stops retired children outside its own message
loop, including when its aggregate manager close remains `unknown_outcome`.
A successful child component receipt never upgrades that aggregate result.
A transient receipt-write failure can retry through production Subagents close;
only its resolved `cleanup_unconfirmed` error clears after aggregate and child
confirmation, preserving unrelated errors. A failed followup binding retains its
previous owned ExtensionRuntime until close actually joins it; no callback owner
is forgotten before a native receipt is recorded.

A separate full-BEAM acceptance creates an actual managed-child usage-write
failure, independently observes that exact Provider task exit, and closes through
production Subagents. After all owned repository processes and the old BEAM exit,
a new BEAM opens only Store: all exact memberships, native/async-hook receipts,
original Runtime snapshot and Goal outbox are unchanged. Eight captured journal,
Runtime, Goal, index, receipt and Provider-log files retain their bytes and mtimes;
no Agent is resumed and no Provider, tool, Kernel settlement or Goal redelivery
runs. This establishes durable component evidence across BEAM replacement, not
automatic child failure recovery.

Roster `closure: :closed` can still mean successful detach with retained commands.
Kernel settlement covers its provider/tools/children/dependencies; Goal ACK adds
no owner-close evidence. These component receipts do not prove Kernel settlement,
SessionEnd execution or whole-root retirement. Root SessionEnd now has a separate
completion fact, described below. The prospective lifetime controller separately
requires the complete acknowledged public tree before replacement admission.
Terminate fallback can no longer service
ChildIO callbacks; an active cleanup may therefore remain unconfirmed, with its
actual error retained instead of a fabricated receipt.

Root native generations now use the same Store-owned ledger. The Agent resolves
its immutable Writer header after Goal initialization and fixes a distinct root
host lifetime across turns/generations; both header fields name the actual root
transcript and `child_session_id` is nil. Subagents passes this context to every
root CodexResources, so binding registration and confirmed native closure use the
same production path as children. Writer-only callers without an actual transcript
path keep capture disabled.

`Agent.retire_host/1` closes components in a task while the Agent remains available
for existing callbacks. New prompt admission stays closed, including after late
phase notifications from the previous turn. Native closure, strict async-hook
shutdown and synchronous SessionEnd completion remain separate facts. SessionEnd
uses a fresh scoped AsyncRuntime so its command workers also supply actual cleanup
reports; it never reuses the retired runtime. Its receipt preserves dispatch
completion, the full hook outcome and warnings: completion does not mean every
handler succeeded. Transcript flush, dispatch and cleanup failures retain their
actual causes. The original hook acknowledgement and SessionEnd attempt are cached;
a later receipt-write failure retries persistence without rerunning either effect.
A lost retirement-task result remains uncertain and cannot trigger SessionEnd again.

The ledger is now version 2 with an independent root-only `session_end` slot.
Version-one reads add that slot in memory without rewriting the old bytes or
inventing completion. Existing binding lookup `status` continues to describe
native plus async-hook confirmation; it is not a whole-root status. Root retirement
also checks its separate SessionEnd completion. Rename/adopt/delete retire the root
host before stopping Store or moving files; failed file operations establish a new
hook runtime and host lifetime before unlocking admission. An idle orderly shutdown
captures components before Store exits. Active/uncertain terminate cannot serve
Agent callbacks, so it joins hooks/runs orderly SessionEnd but leaves native cleanup
unconfirmed instead of blocking those steps on a native-close call cycle.

Published 1.10.42 had a separate confirmed command-close blocker,
[Backplane #118](https://github.com/gsmlg-opt/backplane/issues/118). A bounded
retained-command diagnostic captured `proc_stat_unreadable` / `:esrch` from the
default LocalCommand reconciler; its scanner only treats `:enoent` as a vanished
proc entry. The resulting native close stayed uncertain. The original assertions
were retained without a local scanner, dependency patch, timeout change or effect
retry. #118 is distinct from the earlier #103 concurrency fix.

Upstream [commit d9d2f53](https://github.com/gsmlg-opt/backplane/commit/d9d2f539fababd609464cc438b553aae18018114)
fixes #118: both `:enoent` and `:esrch` mean that an individual proc entry vanished,
while the remaining group is still scanned and other read errors stay uncertain.
Backplane 1.10.43 now publishes this fix and Sigma has adopted all five official
Hex packages. The original seed 261088 passes all seven root-retirement cases
and the 32-Session concurrent close/cancel case: eight functional tests, with
their assertions unchanged. Ordinary retained commands and cross-turn root
retirement are accepted; active termination still retains its separate actual
unconfirmed result. The issue-linked TODO has been removed from RootRetirement.

Earlier child-retirement verification covers 81 combined cases (Coding 18, Agent 63),
three selected production retirement/retry cases, eight existing Runner lifecycle
cases and five native PTY-output cases. Dev/test warnings-as-errors compilation,
12 changed Elixir files' format checks, both changed Rust files' format checks and
`git diff --check` pass. The independent child-failure BEAM replacement only reads
Store; fault injection and root teardown retain real unknown-outcome/owner-down
diagnostics. No security, permission or sandbox development/tests were performed.

Root-retirement verification adds 56 selected functional passes: 11 root/host
receipt cases and 45 Goal/board/hooks lifecycle cases (Coding 10, Agent 35).
The original 65-case integrated run had one retained-command cleanup failure;
the later passing seed does not erase it. A bounded diagnostic reproduced #118,
and affected assertions remain unchanged. Dev/test warnings-as-errors compilation,
the seven changed Elixir files' format checks and `git diff --check` pass.
These scopes overlap previous lifecycle checks and are not cumulative totals.

A separate root acceptance uses actual Runtime/Provider/Plan turns, three run
memberships, two native generations, an async SessionStart command and SessionEnd.
After confirmed component retirement and all owned processes exiting, a new BEAM
opens only Store: exact version-two ledger and three Runtime records survive;
eight journal/Runtime/Goal/receipt/Provider files retain their bytes and mtimes.
Provider requests remain at five and SessionEnd at one. It starts no Agent or
LocalCommand jobs and performs no effect replay, Kernel settlement or Goal
reconciliation. This proves root component persistence across a full BEAM restart,
without accepting the retained-command path or completing automatic recovery.

Native Provider workers now supply an independent lifecycle fact needed by the
recovery controller. At the public adapter entry, before invoking Sigma's Provider,
the actual worker registers the exact Runtime `run_id`, `incarnation`, `step_id`
and `attempt_id` with the existing Store. These are the public Kernel provider
identity, not Sigma's metrics turn ID or an assistant message ID. Root Engine
passes its actual Store; managed children use their own Store directly, outside
Agent/ChildIO callback loops. Explicit legacy callers retain their existing path.

Store persists an observing entry in `provider-lifecycle.etf` before acknowledging
registration, then monitors that exact caller. Only its actual DOWN changes the
entry to stopped. A Store-instance observer ID and the exit category are durable;
PIDs, references and callback functions are not. The sidecar uses the existing
serialized writer, file sync and atomic rename without changing Runtime revisions,
snapshots, Goal receipts or journals. It follows the Runtime directory on file
operations. An observation-write failure prevents that Provider request; a failed
DOWN write retains the actual fact and cause in the owner, and explicit flush
retries persistence only. Exact repeated flush does not rewrite the receipt.

Explicit ChildIO retirement also requires durable Provider termination observations
before acknowledging closure. A failed write keeps ChildIO/Store alive; a later
close retries the same fact before releasing their path registrations. Store
retirement refuses live monitors or pending writes and returns its actual error
without waiting for a DOWN that was never requested. Read-only reopening never
reattaches old monitors or turns an observing entry into a stopped one. Abrupt
owner/BEAM death can therefore leave incomplete observations. Ordinary writer
retirement is not a claim that every historical Provider stopped.

This is evidence of that exact worker's exit, not a response outcome, Kernel
provider/tool/child/dependency settlement, native shutdown, Goal ACK or whole-host
recovery. Public `Store.fence` alone does not supply any of those facts. The root
provider-only controller above consumes these observations with independent component
receipts; the child provider-only and prospective lifetime controllers consume
these same exact facts. No Provider/tool effects are retried.

Functional verification covers actual root attempts across turns/generations,
managed-child followups, registration failure, retained DOWN-write errors and
child-owner retention/close retry. Existing actual root/child usage-write failure
cases also require the exact stopped Provider identity before their explicit
fenced reconciliation. The integrated seven-file functional selection passes
41 cases; 11 selected root/host retirement cases also pass, for 52 selected
functional passes. Five retained-command cases were outside that earlier selection under #118;
1.10.43 acceptance above now covers the unchanged assertions. Dev/test warnings-as-errors
compilation, eight changed Elixir files' format checks and `git diff --check`
pass. These scopes overlap previous lifecycle counts; no security, permission
or sandbox development/tests were performed.

An actual child usage-write failure separately runs through production close and
all owned processes exiting, then a full old-BEAM exit. A new BEAM opens only Store:
the exact Provider lifecycle ledger, native/hooks receipts, original Runtime and
Goal outbox survive. Eleven persisted files keep bytes and mtimes; no Agent is
resumed, and no Provider/effect replay or Kernel/Goal reconciliation occurs. The
root aggregate remains unknown. This proves durable exit evidence across BEAM
replacement, not automatic failure recovery.

### Prospective failed-child lifetime retirement

Backplane 1.10.43's [#119](https://github.com/gsmlg-opt/backplane/issues/119)
reconciliation contract is integrated for future provider-only failed-child
admissions. In 1.10.42, MultiAgent read a cached or failed live Conversation,
Session retained its first cleanup result, and independent child Store/Goal
settlement could not confirm aggregate closure. The new path records the missing
ownership evidence before execution; it does not reconstruct absent old facts or
rewrite a historical terminal result.

`LifetimeRecovery` owns one serialized writer at
`<root_transcript>.subagents/lifetime-recovery.etf`. It stores immutable child
admissions, configuration and inventory, relative Store references, observed exact
Conversation identities and actual DOWN facts, public manifests, CAS receipts and
immutable receipt versions. Writes use the existing sync/atomic-rename filesystem
boundary; directory fsync and cross-node exclusion are not supplied. Borrowed
Stores remain owned by their existing hosts; retirement closes only readers this
writer created. The writer is anchored to the actual journal header through
rename/adopt, while each manager retains its admitted session route identity.
Writerless callers do not create this persistence owner.

Production child retirement first confirms all native generations, async hooks
and every exact Provider attempt. Only provider-only work may pass the existing
RunRecovery checks. The exact observed failed Conversation is then stopped and
its actual DOWN persisted; `Conversation.cancel` alone cannot join a
`storage_failed`/`recovery_required` executor. Nonterminal child Stores use public
fence/cancel/cleanup, preserving original run attribution and committed history.
No child Provider, command or hook is replayed.

The owning host closes admission and reconciles the public ownership tree:
Registry owner → child Session → descendant child before ancestor → manager →
root Session. Each confirmed receipt must also have the actual correlated public
ACK; a stored receipt alone cannot establish ownership retirement. Root native,
async-hook and independent SessionEnd confirmations remain additional requirements.
Already-confirmed ordinary closure and preparation failures use their existing
close path without invented reconciliation receipts.

Goal ACK advances Store revisions. Before roster/root admission, the controller
reseals receipts using current Store fences in the same bottom-up order. Actual
public ACKs remain associated with their immutable original receipt versions,
even after a later seal changes the current receipt. A failed receipt or admission
write retains its real cause and committed progress; retry repeats persistence
and observation only. Missing child/manager/Session ACKs reject the new root.
Nested-child coverage exercises both descendant and ancestor Goal ACK changes.

GoalCoordinator now admits a **new root run** only after complete prospective
lifetime proof, independent root retirement and ordinary Goal receipt accounting.
Original receipts retain their admitted thread/run identity, charge once and ACK
with the current fence. The old root's `unknown_outcome`, uncertain Provider intent,
incarnation and journal are unchanged. The new prompt starts from committed
context; this never resumes the old execution. Missing legacy observations,
unrelated active work or uncertain tool/dependency effects remain errors. Archive
export/restore and old-child continuation are separate capabilities.

The next real prompt now drives this sequence on a live failed host. Agent retains
the exact admitted item, IDs, attachments and prepared resources in
`pending_host_prompt`, fences automatic Goal admission and waits for any existing
idle task. A supervised read-only probe checks only the current host lifetime's
root bindings and owned children. Healthy hosts retain their commands and child
Sessions. An indexed missing Runtime record remains an error; the only unstarted
exception is an unindexed binding with its exact native close confirmation.

For an unhealthy host, retirement runs outside the Agent callback loop. Agent
retains original and partial acknowledgements before asking the public
`GoalIntegration.recover_retired` entry point to rescan indexed runs even when its
Coordinator was previously ready. After reconciliation it adopts a fresh host and
AsyncRuntime, hydrates Writer-selected committed context and submits the same
item. Queued followups, retries and idle async answers use the same path. Failed
host preparation starts no Provider or user journal entry; cancellation retains ongoing
retirement/reconciliation, releases resources once and allows remaining accepted
followups to advance. Failed retry inspection restores its original context.
Receipt persistence retries never redispatch an uncertain SessionEnd.

Ordinary shutdown checks the actual public ownership ACK tree without requiring
root hooks/SessionEnd that termination has yet to write. New-work admission still
requires those independent component facts. This separates completing retirement
from proof sufficient to create a new host, without a circular shutdown
prerequisite or journal writes during the read-only check.

Automatic Goal continuation probes the host **before** public `Goal.idle` creates
a reservation. An unhealthy host is left unreserved for a real prompt to recover.
For a healthy host, release creates the ordinary turn Task before acknowledging
submission. In 1.10.45 the coordinator monitors that exact Task before allowing
pure provider-hosted preparation. A host-owned atomic gate separates preparation
from any hooks, startup children or Runtime effects, and atomically records
cancellation or supersession before the gate opens. A configuration failure or
executor exit before effects permanently seals the complete admission. Only its
actual DOWN allows public
[`Goal.settle_unstarted_admission`](https://github.com/gsmlg-opt/backplane/issues/127)
with exact admission, confirmed executor termination, never-started Runtime,
fenced future start and no dispatched effects. The Agent joins the durable
settlement before terminal events or new admission; this path does not run
interrupt hooks. Persistence failures retain the seal and actual cause for
persistence-only recovery, never another execution. A successful historical
settlement can be read back after restart without disturbing a newer reservation.
An uncommitted reservation cannot be reconstructed after its Goal owner restarts.

On a reusable live host, the next real prompt calls
`GoalIntegration.prepare_admission` from its supervised inspection Task before
starting hooks, writing the canonical user or preparing a new Session/Runtime.
This retries only the original sealed no-start settlement. An unresolved write
returns its actual cause and leaves the user history, host bindings and run index
unchanged. A host that requires retirement still takes the existing component
retirement and indexed-run reconciliation path. Explicit host Goal set, clear
and fork use the same narrow preparation before recording instructions or
exporting a snapshot. Ready is a no-op; indexed runs and other unresolved outcomes
remain blocked with their existing errors. This does not call general recovery
to clear an unknown state or reconstruct a lost reservation.

Actual Engine regressions verify provider configuration failure without Runtime
or Provider execution, a committed preparation_failed receipt before agent_end,
the next real prompt and a new automatic admission after an explicit user
mutation, retaining the same Goal/thread. Complete admission identity is passed
to its real binding. Once the effect gate opens, hook rejection or pre-Runtime
failure still requires its actual execution/cleanup evidence; this narrow
settlement does not infer no effects from absent records, withdraw after release,
reset Goal or fabricate Runtime receipts. Complete 1.10.44 Goal records gain only
the two new admission maps in memory; reads preserve bytes, hash, mtime and inode
until an actual mutation. Public fork imports its independent complete snapshot.
Faultable-writer regressions also cover settlement persistence failure through
the real Engine, failed admission without a new canonical user or host binding,
and repaired storage followed by a new prompt, explicit mutation, clear or fork.
The source keeps its committed receipt; the public fork starts independent empty
admission ledgers. A separate indexed-run regression preserves both the index
and its unresolved recovery error. Faults are ordinary write errors.

The historical 1.10.49 hook/Goal probe reproduced the distinct **post-effect,
pre-Runtime** gap tracked by
[#145](https://github.com/gsmlg-opt/backplane/issues/145). An explicit host Goal
instruction launches automatic work; its real UserPromptSubmit command appends
the exact payload, then stops that turn before Engine/Runtime binding. There is
one actual hook effect, no Provider attempt, Runtime record or Goal run index for
the stopped run. After its executor ends, idle still returns `already_reserved`.
Removing the hook condition and completing a new ordinary real prompt succeeds,
with a fresh Runtime and one Provider attempt, without repeating the old hook
payload or changing the Goal/thread identity. Idle nevertheless remains
`already_reserved`; the new run's receipts cannot settle the original admission.
The separate whole-host retirement probe reports confirmed; that component receipt
alone does not prove Goal admission settlement.

The original continuation regression also failed unchanged on 1.10.50. Its probe
and failure log remain historical evidence under
`/tmp/sigma-goal-hook49-mxvoa8bv` and `goal-hook50-baseline.log`. Official 1.10.51
now supplies `Goal.settle_host_admission/4`, consumed by the hook execution scope
and Coordinator described above. The complete regression passes through ordinary
and fresh automatic work on the same Goal, original instructions and full host
retirement. Actual ordered effects, executor DOWN, cleanup and future-start fencing
remain required; `effects: :none_dispatched` would contradict the hook execution.
No Goal reset, synthetic Runtime receipt or dependency patch is added. #127's
effect-free preparation settlement and indexed-run recovery remain separate.

Provider-hosted configuration now validates
before Session reservation and Goal indexing; arbitrary missing indexed records
are still rejected. Terminal-unknown structural eligibility is checked before
looking up transcript evidence, preserving its original recovery conflict.

The dedicated lifetime selection covers actual failed children, ordinary repeated
turns and successful same-child followup, nested failures, missing evidence and
each missing public ACK, Goal ACK followed by a receipt-write failure, root
admission I/O failure and independent-BEAM production reopen. The existing five
child Goal usage/ACK regressions now use production close and preserve exact
fencing, deduplication and missing-component assertions.

A separate full-BEAM harness executes real child Deno → command once, induces an
actual Goal usage-write failure, and confirms production host retirement before
exiting. A new BEAM reopens the production Agent without replay, charges the child
13 tokens exactly once, and accepts a new root prompt with committed context.
Provider calls increase only for that prompt (six → seven); the command marker
stays `once\n`. Another independent BEAM reopens without a prompt: all 15 durable
files retain bytes, hashes and nanosecond mtimes. Orderly closure then adds only
one empty new root host's confirmed hooks/SessionEnd facts; all historical host
facts and the other 14 files remain unchanged. The original assertion that even
this new host's retirement must write nothing was a harness error; its failed log
and exact decoded evidence are retained. This is controlled local-provider
acceptance, not online-model, archive, release or deployment acceptance.

Actual WebSocket and browser Message/Send/Stop flows also exercise live recovery
without explicit retirement. Each scenario runs one real child Deno command,
induces a child usage-write failure, cancels the old root and submits a real next
prompt. Both old unknown snapshots remain exact; each new host keeps committed
context and adds 13 retained child tokens plus 13 tokens from the new response.
After both scenarios the command marker is exactly `once\nonce\n`, Provider calls
are 12 and Goal usage is 117. A complete BEAM replacement followed by WebSocket
resume and browser reload preserves both results, connected LiveView, no console
errors/warnings or horizontal overflow, and exact Provider/command bytes, hashes
and nanosecond mtimes. An additional fresh-BEAM Store read confirms both original
snapshots and Goal usage unchanged. This uses a controlled Provider with actual
Engine, Runtime, Deno and commands; the existing 4580 service is untouched.

Earlier 1.10.42 independent child Store/Goal tests and the cold durable-data copy
remain valid component evidence. Their root-first rejection was the old consumer
boundary, superseded only for the fully evidenced prospective path above. They do
not establish arbitrary terminal-unknown recovery.

Preserving an archived child's identity/history for `followup_task` after manager
replacement requires the separate archive integration from
[Backplane #117](https://github.com/gsmlg-opt/backplane/issues/117). A public-only
1.10.42 reproduction completes a real child, acknowledges manager closure, stops
that manager, and starts a fresh one with a new parent run and independent store.
The fresh roster is empty; both the old canonical name and old run ID return
`not_found`, without new admission or Provider work. That version has no public
archive import API. This same-BEAM ephemeral reproduction establishes the old gap,
not production cold recovery. Do not replace the child identity, reuse old Session
bindings or populate private manager state. New-child admission and the local
retirement-receipt/controller work remain separate.

On 2026-10-27, source commit
[`a93bb8034a8deee6a132c8d715bdf2fc96d1a891`](https://github.com/gsmlg-opt/backplane/commit/a93bb8034a8deee6a132c8d715bdf2fc96d1a891)
closes #117 and #119. It adds public MultiAgent `recovery_manifest`,
`reconcile_child`, `reconcile_close`, `export_child` and `restore_child`, alongside
Session/ResourceRegistry reconciliation and a host evidence/receipt CAS adapter.
The official 1.10.43 release now contains these APIs and all five Sigma Hex
dependencies are updated. They require opt-in host evidence, immutable admission
references and receipt CAS; a version update alone does not enable recovery.
The prospective #119 consumer and its functional acceptance are described above;
#117 archive integration now uses these public contracts. No local dependency
patch or private-state workaround is introduced.

The original 1.10.43 normal-child consumer exposed a published-contract blocker,
[Backplane #126](https://github.com/gsmlg-opt/backplane/issues/126).
Registry-owner, Session and child receipts were all confirmed, but public
`MultiAgent.export_child/3` rejected the committed assistant message fields
`timestamp`, `usage`, `provider`, `model`, `api` and `stop_reason`. Archive's strict
message whitelist omits them, producing `:validation` / "recovery schema has missing
or unknown fields". The real Runtime rename assertion failed. Backplane 1.10.44 admitted those
assistant fields; its separate ordinary Error boundary is described below.

A second actual #126 reproduction occurs before that field check. A completed
native child can retain a normal `%Backplane.AgentRuntime.Error{class: :not_found}`
under a committed tool message's `result.error`. Public Archive history passes the
raw messages to `Evidence.public/1`, whose JSON normalization rejects structs with
"recovery data must be bounded unambiguous JSON without runtime handles". A fresh
BEAM reads the actual preserved child through public Store: completed, revision
73/incarnation 1, with empty public Kernel cleanup requirements. The exact Error
has only class/message/empty details/nil cause. Both its normalization and complete
history normalization fail; evidence bytes stay unchanged. This probe establishes
the second representation boundary, not successful archive restoration. The public
export/restore fix must cover ordinary native errors followed by continuation as
well as assistant metadata. Sigma does not strip or rewrite either result.
The ordinary archive lifecycle regression now creates this exact command error,
continues through real Deno, and checks the original JSONL result before rename.
It retains the expected successful rename/restore, exact historical results,
same-child Deno followup and single command marker assertions. The 1.10.44 package
failed at rename with the same normalization error; later restore assertions were
unreached in that batch. The Goal-accounted case independently preserves complete assistant metadata.
With current 1.10.48, the original Error archive and its continuation assertions pass.

The user subsequently authorized consumer preparation assuming the upstream fix.
`ChildArchives` now stores the exact public export as immutable evidence through
the existing LifetimeRecovery writer, rather than introducing another sidecar or
writer. Selection matches the durable roster's original Sigma agent/run identity;
an earlier successful archive cannot replace a newer failed or unfinished run.
`ChildArchiveEvidence` reconciles eligible retired children, obtains their actual
receipt, exports through public MultiAgent and restores parents before descendants.
Restored rows preserve original child Session, Sigma agent/run and origin identities;
a real followup starts a new public execution. Ordinary repeated root turns retain
the current manager. New-manager observations received during preparation are
buffered and reconciled with its actual initial snapshot.

Archive restoration also opens the original child Store through LifetimeRecovery.
ChildIO now explicitly takes ownership of that exact cached Store: it links before
the recovery writer unlinks, and the recovery writer retains only a borrowed
reference. ChildIO retires the Store; a later recovery read opens a fresh owner.
Normal or abnormal Store exit stops ChildIO with the actual cause. This fixes the
local `already_started` collision without changing public Runtime state.

With 1.10.44, the three handoff lifecycle cases and the Goal-accounted rename,
repeated-turn and exact-selection cases pass. The unchanged ordinary Error case
still fails at export, leaving its real-Deno restored-result/no-command-replay
assertions unreached. The combined selection is seven cases with one failure.
No assistant fields or Error results are removed or repacked.

An independent producer/consumer probe in two fresh BEAMs also passes the
Goal-accounted path: real rename, complete Unicode/CRLF assistant metadata, original
child identity, fresh followup run, unchanged journals/effects on cold reopen and
unchanged original accounting facts. Exactly three fresh Provider responses add
six tokens; old work is not charged again. Public child/host retirement is confirmed
before only the probe's repository is stopped. This is a controlled Provider probe,
not real-Deno cold archive acceptance; actual plugin helper-crash behavior is
verified separately below.

The 1.10.44 idle restored-child consumer exposed a different public defect,
[#133](https://github.com/gsmlg-opt/backplane/issues/133). The existing plugin-child
cold test traces successful public restore, an archived/confirmed roster and
ResourceRegistry transfer readiness, followed by MultiAgent.transfer_ready
returning the exact reconciliation Error. Public restore installs no PID or
snapshot, while transfer requires one of them. The final Provider response is
complete, but parent detach fails and the run becomes unknown. The original
assertion remains active; no forced followup, synthetic snapshot or local
dependency patch is used. The original idle-child transfer regression passes on
current 1.10.48; the separate installed-plugin inventory boundary is described below.
Public archives still pin the terminal Store revision and retirement receipt
digest; later Goal accounting must not be hidden by resealing an old archive.

Goal run-index I/O failure after Session reservation now closes the prepared
collaboration Session through its existing host. The original preparation error
is retained; a failed cleanup remains separately visible. A real Engine regression
checks no Provider starts on failure and a subsequent real prompt can acquire a
fresh Session after the index is restored.

Automatic continuation uses the ordinary Agent admission slot in two phases.
The public idle call reserves without effects; release submits that exact slot.
Confirmed cancellation/supersession withdraws only the prevented reservation.
Cancellation durably defers continuation without pausing the Goal; an accepted
real prompt can resume it. Ambiguous release keeps its recovery boundary.

Repository operations close children, flush the Writer and drain terminals,
then retire GoalCoordinator, the owned root Runtime Store, GoalStore and board
writer before moving files. Both `<transcript>.runtime` and `.subagents` follow
rename/adopt and are removed on delete. Fork does not copy Runtime receipts/index:
it imports the complete public Goal fork snapshot under the target Writer's new
header into an independent store. A stopped source uses a temporary actual Writer
and recovery without invoking the Provider. Failed file operations reopen the
original Runtime Store before Goal, preserve bytes and retain the actual error;
release failure no longer hides a performed file-operation result.

The alignment Goal maintained by the development agent is separate from these
product-session Goal tools.

## Plugin catalogs and durable requests

An optional `plugins` object in `~/.pi/agent/settings.json` selects the registry:

```json
{"plugins":{"registryUrl":"https://registry.example","requestsRoot":"/absolute/plugin-requests","headers":{}}}
```

Only `registryUrl` is required. `requestsRoot` defaults to
`<ConfigManager.agent_dir()>/plugins`; `headers` defaults to an empty map. The
example is a configuration shape, not a selected service. A trusted Agent startup
option, `native_plugins`, overrides the settings snapshot; explicit `nil` disables
it. Managed children inherit the same snapshot across followups.

Configured roots and children expose `list_available_plugins_to_install` and
`request_plugin_install` through the public Codex DynamicRuntime profile. Both
initial and rotated run inventories retain the plugin adapter, alongside the
existing MCP adapter. Native descriptors carry the actual host and public Session
binding; existing Session validation runs at dispatch and writer entry.

`PluginResources` calls public `Backplane.PluginProtocol.Client.catalog/1` through
Req at `/plugin-protocol/v1/catalog`. It returns the complete catalog, leaves
storage absent on reads and does not retry HTTP requests. HTTP failures become
ordinary tool errors, allowing a later catalog call.

One application-owned GenServer per request root serializes mutations in
`requests.json`, independently of root/child Session lifetime. Version-one records
retain `status: "requested"`, a durable host ID, the registry URL, all four exact
arguments, original Runtime invocation identity and timestamp. New native requests
also retain the public `plugin_request_id`. The durable ID hashes the
registry and ordered caller/run/incarnation/step/attempt/invocation/enclosing
invocation/tool-call/turn identity. An exact retry returns its original record
without changing bytes, mtime or inode, including after writer replacement.
The public DynamicRuntime owns the outer `request_id`. Legacy request-only host
records remain immutable; new native calls wait for the confirmed installation
outcome described below.

The writer rereads JSON for each mutation and uses the existing file-data sync
and same-directory atomic rename helper. Malformed storage returns an actual
error; unacknowledged persistence remains `unknown_outcome`, without automatic
retry. This is a single-BEAM application writer, not cross-node serialization or
parent-directory power-loss durability. Journal history retains the complete
result; reopening hydrates that history without reissuing HTTP or request writes.

Five plugin functional tests cover actual HTTP, root direct/real Deno calls,
managed-child followups, exact Unicode/CRLF arguments, cross-turn and Writer-backed
reopening, ordinary HTTP errors and writer replacement. Together with the five
environment functional tests, the final selection passes 10 cases with seed
261128. Development/test warnings-as-errors compilation and formatting of the nine
changed Elixir/test files pass.

Independent Protocol and Chrome acceptance on isolated port 4631 loads ordinary
`settings.json` configuration and the default agent-directory request root. Each
client completes two root turns, an actual child and its followup, with direct
and real-Deno catalog/request calls. The combined 34 Provider requests and 14 HTTP
catalog reads produce ten durable requests across four journals. Live Protocol
tool events retain all nine canonical root result contents. Public `session.dump`
artifacts for both roots match their journals and are byte-identical after recovery.

Page reload and complete BEAM exit/new-BEAM resume preserve all seven tracked
journal/request/Provider/HTTP files with exact bytes, nanosecond mtimes and inodes;
no extra calls or request writes occur. Chrome restores nine successful cards,
including the actual `requested` receipt, remains connected without horizontal
overflow or console warnings/errors, and serves the verified local JS artifact.
Both owned BEAMs, registry and page were stopped; existing 4580/PID 815717 stayed
untouched. That earlier directory/request acceptance is distinct from the product
installation evidence below. It does not select a production registry or establish
automatic MCP catalogs, archived-child followup after cold recovery (#117),
arbitrary failed-manager recovery without prospective evidence, release or
deployment. `requested` is never
reported as installed or activated.

Explicit local installation is now available to the host through
`PluginResources.install(host, durable_request_id)`. It reads the saved request,
resolves its exact registry/plugin through public `Client.resolve/2`, and uses
public `Client.download/3` for the artifact and package. The existing shared writer
also serializes version-one `installations.json`. Each intent pins the request,
registry, plugin/release IDs, artifact and canonical content digests, immutable
`packages/<digest>` root and registry/plugin-specific data directory before package
files are published. Files retain exact bytes and executable modes; the existing
file-data sync helper writes a staging tree before its same-directory rename.
This has the same directory/power-loss and single-BEAM limits as the request store.

An installed retry returns the original receipt without HTTP or file rewrites.
Preparation failures precede the intent and leave requests intact. A package-write
failure records its actual cause and remains failed on retry. An uncertain final
receipt retains `installing`; a subsequent explicit call can confirm the already
complete tree by its public Archive digest and persist only the receipt. Missing
or incomplete publication stays unknown, without redownloading or launching MCP.
Temporary-tree cleanup failures remain part of the returned and recorded cause.

`PluginResources.activate(host, durable_request_id, run_id)` starts the public
`Backplane.AgentRuntime.Plugins.Session` from an installed receipt. The caller owns
and must stop that run-specific Session. Its public catalog, MCP calls, skill
loading and resource reads use the installed package; installation itself starts
no process. Neither API changes the native `requested` result. Real root/child
bindings prepare their independent PluginRuntime catalogs as described below;
failure-path retirement uses #122's published close contract below. Installed skill
resources enter the next real run through the separate immutable snapshot path.

Explicit product installation now uses the same `Sigma.Agent.PluginInstallations`
boundary in `/settings/plugins` and Protocol `plugins.requests`/`plugins.install`.
Settings opens the configured global host; Protocol requires `plugins.install.v1`
and resolves the actual live Agent's `native_plugins` snapshot, including explicit
nil. Opening the host and installing happen outside the Agent callback. No registry
is chosen or configured by these actions.

The application writer reads both ledgers together. Newest-first summary pages
join immutable requested receipts to separate installation states. Revisions bind
the complete request/installation snapshot and configured root/registry; stale
continuations resync from page zero. This is an application-host inventory, not
inferred selected-branch provenance from arbitrary nested tool results. Summaries
omit private host terms and leave exact arguments/invocations in the original
native result and store. Explicit installation addresses only its durable request
ID. The LiveComponent runs reads and installs asynchronously, keeps a successful
receipt when a subsequent refresh fails, and shows saved installed state on reload.
Protocol returns `plugins.installed` without a later refresh. Whole rows are paged
within V1 bounds; an oversized installation projection preserves a compact actual
success ACK instead of discarding the committed outcome. Full DTO details are in
[Protocol V1](protocol-v1.md#explicit-plugin-installation).

Before automatic MCP preparation, fourteen plugin, three installed-skill, five
environment, three Protocol-host, four Protocol-DTO and five Web functional cases
passed together (34 cases, seed
261130). The host cases include a real HTTP artifact,
executable stdio MCP, exact
Unicode/CRLF skill resources, process shutdown, concurrent exact retries, writer
replacement, pending-receipt reconciliation, preparation and ordinary file-write
failures. The added production path covers run-pinned root/managed-child skill
listing, complete resources, followup, writer replacement, next-turn history and
repository reopening, including released prior snapshots and no plugin MCP start.
The separate installed-skill cases cover same-named local/plugin sources, exact
metadata and long UTF-8 resource paging, new release bindings and cleanup.
Development/test warnings-as-errors, fifteen-file formatting and scoped diff checks pass.
Two earlier independent BEAM reads preserve nine package/request/ledger/log files
with exact bytes, nanosecond mtimes and inodes. A third cold BEAM explicitly
activates the package and makes one real MCP call without registry access; the
eight installation/request/HTTP files remain unchanged and the MCP process exits.
Two additional independent BEAMs exercise production CodexResources binding and
public ExtensionRuntime installed-skill reads, then confirm snapshot release.
All 24 original package/request/ledger/journal/runtime/log files retain exact bytes,
nanosecond mtimes and inodes, with no plugin MCP or registry call.
Those earlier host-component checks are distinct from product installation.
The installation UI and Protocol entry also have independent acceptance on an owned
4673 server with ordinary settings and a local HTTP registry. Chrome explicitly
installs one real native request; Protocol installs a second. Both sessions read
the complete installed skill on their next turn. Ten controlled Provider calls and
four actual registry requests produce two immutable requested receipts and two
installed receipts; repeated installs cause no HTTP. Reload preserves all 23
observed files' bytes, nanosecond mtimes and inodes. After the old BEAM fully exits,
a new PID resumes both clients and returns their existing install receipts without
Provider/HTTP replay: 21 plugin/package/journal/runtime/log files retain bytes and
metadata. Two pre-existing empty `skill-invocations.json` sidecars retain `[]` bytes
but change inode/mtime because `SkillInvocationStore.recover/2` unconditionally
rewrites its recovered list. The broader 23-file metadata-equality check therefore
fails only for those two auxiliary files; this unrelated recovery behavior is
recorded without a local fix. Chrome remains connected with two installed cards,
no horizontal overflow and no console errors/warnings. Both owned BEAMs, registry
and page are stopped; the existing 4580 service is untouched. This controlled
Provider/local-registry evidence does not select a production registry, establish
automatic plugin MCP catalogs, or test a live commercial model.

Under the user's assumed-upstream-fix instruction, `PluginRuntime` now owns the
actual public Plugins.Session handles for the immutable installations pinned by a
native resource binding. CodexResources refreshes the application writer and
installed inventory for each new binding, then prepares the runtime before public
tool discovery. Exact public plugin names, descriptions and schemas become deferred
MCP candidates. An optional callback on the existing MCP.Tool routes execution to
that public Session; Dispatcher still owns hooks, structured/image normalization
and ordinary error continuation. No public Runtime dependency is added to Coding:
the Agent adapter preserves the original public Error and translates uncertain
callback outcomes into Coding.ToolError without losing its details.

Each real child has independent Sessions and callbacks, filtered to the names
committed by its parent's public catalog. Followups close the prior plugin runtime
and pin a fresh inventory. Close retains every actual result and never repeats an
uncertain stop; partial preparation retains earlier successful handles. Native
retirement includes this result before closing skill snapshots and command hosts.
No request or installation effect is replayed by discovery, history or reopening.

Six dedicated runtime cases pass, including actual process cleanup after partial
preparation. Actual root Engine direct/Deno, cross-turn
catalog refresh, normal process closure and history reopening also pass. The real
child direct call and Deno followup execute through distinct processes; the combined
cold-child case now reaches #133's idle-archive parent transfer failure. An owned 4634 WebSocket client installs a
durable request and executes deferred plugin calls, including an ordinary MCP
isError followed by successful calls. A fresh BEAM/PID and Chrome reload retain
the six complete tool results, the error card and successful continuation without
more Provider/MCP/HTTP/request/installation effects. Effect-log bytes and exact
mtimes remain unchanged; the journal retains its original prefix, allowing ordinary
model-change metadata. Eight controlled Provider requests and four actual MCP calls
are observed. One earlier fixture HTTP 404 is retained alongside the two successful
resolve/artifact requests. These are controlled-Provider/local-registry checks,
not live commercial-model or deployment acceptance.

[Backplane #122](https://github.com/gsmlg-opt/backplane/issues/122) shipped the
bounded public `Plugins.Session.close/1` and `cleanup_status/1` contract in 1.10.44.
PluginRuntime now captures each exact close report before calling public stop.
Stop observes the same memoized cleanup attempt and retires a confirmed Session;
an unconfirmed Session and its original report/error remain inspectable. Runtime
close caches that same result, so a repeated call does not repeat cleanup effects.

All seven dedicated functional cases pass, including the original failure case
that returned false success on 1.10.43. Two controlled independent bindings retain
their exact per-component errors and reports with one cleanup attempt each; work
on the other binding continues. A real stdio normal close also retains its confirmed
report after Session retirement. An additional actual managed-child case uses the default stdio adapter. The fixture's
logged target and process start identity bind its exact packaged guardian; only
that helper is crashed. Public ChildIO.retire retains the original unconfirmed
PluginSession/component/connection/transport report, including missing waitpid,
pipe and successful-helper-exit receipts and actual exit 137. Repeated retirement
returns the same error and identities without additional requests, starts or
calls; the independent root plugin still runs and its turn completes. Aggregate
host retirement remains explicitly unconfirmed in teardown. A non-running target
is not proof of reaping, and fixture cleanup does not create a Runtime receipt.
This passes through existing production entrypoints without an injection adapter;
it does not establish successful retirement or automatic recovery after that crash.

The public plugin MCP adapter now selects verified stdio cleanup and needs the
package-owned native guardian. Hex includes its C11 sources and public build task,
not a prebuilt executable; activation never runs a compiler. `mix sigma.rel-build`
and the test/release workflows explicitly run `mix backplane.mcp.stdio.build`.
Devenv supplies the C compiler. Artifact assembly checks and probes the installed
`backplane_mcp_protocol-*/priv/bin/backplane-mcp-stdio-guardian`. The public task
and its protocol-1 probe pass locally; remote runner/artifact results are separate.
Ordinary configured MCP keeps its current transport and shared-client ownership.

The local Linux production package has now passed a separate installed-component
check. Production warnings-as-errors compilation, the public guardian build and
`mix release sigma --path <temporary-root>` succeed. A fresh tarball is extracted;
all five official packages report 1.10.44, and PluginRuntime, Dispatcher, public
Session and MCP Client load from that extracted release. Its guardian passes
protocol 1 and is the actual executable parent of the fixture plugin server.
One real stdio call through PluginRuntime/Dispatcher preserves complete Unicode
and CRLF output. The exact public close report confirms cleanup and guardian exit
0; both OS processes disappear, and repeated close leaves the call log unchanged.
The packaged application asset matches the browser-tested artifact. Evidence is
under `/tmp/sigma-plugin-completion44-1cpucbw5/release-*`. This validates the local
packaged plugin component; other platforms, remote CI and deployment remain separate.

The fixed Codex handler was checked directly at revision
`46fdd5ef39735f4159cdcf0ec5e85c10521494e5`: it waits for host installation and verifies
installed components before returning `completed`/`user_confirmed`. Backplane
1.10.44 publishes the corresponding `{:completed, outcome}` adapter variant in
[#124](https://github.com/gsmlg-opt/backplane/issues/124). Sigma now uses the
user-selected original-call wait: saving a request does not finish the native call.
The waiter runs outside the application writer and checks the original public
Session while Settings or Protocol performs the explicit existing install action.

Settings passes the actual `:settings` confirmation source; Protocol passes
`:protocol`. The installer reads the saved exact request, completes the existing
package installation and verifies the actual installed public Archive. A separate
`native-installations.etf` fact retains the original public request and invocation,
source, timestamp and actual success or Error. Only that exact successful fact and
a still-valid original binding can produce `completed: true`, `user_confirmed: true`
and the original tool/action/plugin IDs. Public Runtime supplies the outer
`request_id`. No automatic installation, inferred confirmation or rewrite of an
already settled `requested` history occurs. Older host calls without a public
request ID retain request-only behavior.

Actual failures are durable and exact native retries do not repeat installation
effects. Explicit host checks may still reconcile an independently pending
installation using its already-published complete package, without replacing the
settled native failure or repeating download/activation.
Closing the original binding rejects a late native completion. If the native fact
cannot persist after a successful installation, Settings/Protocol retains its
successful installation acknowledgement while the native waiter reports the
actual uncertainty. The existing Runtime effect deadline is unchanged.
Protocol's next Provider request and flushed JSONL retain the same complete public
completed result; the four Protocol and five Web functional cases pass. Root/child
direct and real-Deno coverage, package failures and cold reopening are verified
separately from the actual managed-child/default-stdio cleanup-failure case above.

Started native plugin cancellation now uses #135's public observation-wait
contract. The application writer first commits the exact request; only its wait
for explicit Settings/Protocol installation is wrapped in
`DynamicRuntime.plugin_install_wait`. The callback performs no installation or
activation. Cancellation yields public typed `native_plugin_wait_retirement` and
`code_mode_retirement` proofs. LifetimeEvidence loads the exact authoritative
Store cleanup proof, matches the original obligation identity, stores it unchanged
under a digest reference, and lets public reconciliation validate it.

Root direct and real-Deno regressions now complete fresh binding, installed
catalog/MCP work and full retirement. Late explicit installation leaves the
cancelled request, journal and original Runtime files unchanged. Two additional
actual managed-child cases prove cancellation, exact proofs, late-install
isolation, root continuation and full retirement. Their later archived-child
followup fails explicitly with `child authority exceeds parent grants`: the
original 43-entry ceiling omitted `tool_search`, while the newly installed package
adds that discovery entry to the proposed inventory. This is distinct from #135
settlement and #133 transfer. The remaining followup/MCP assertions stay in place;
this batch does not change admission policy or widen the old ceiling.

The completed native result also passes independent clients on an owned port 4674
service. Chrome creates and prompts its own session with a direct request; a
WebSocket client requests installation through real Deno. Both original calls stay
pending, without installation HTTP or a second Provider request, until the actual
Settings button or `plugins.install` action completes installation. Their exact
public request IDs and complete results match the next Provider request and JSONL.
The durable facts retain the original identities and distinct `:settings` and
`:protocol` confirmation sources. Each next real turn lists and reads the installed
skill with exact Unicode, LF and CRLF content.

Live reload, complete owned-BEAM exit/new-PID startup, Protocol resume and repeated
installed checks do not replay effects: Provider/HTTP stay at 10/4, and all nine
plugin, log and journal files retain exact bytes, hashes, nanosecond mtimes and
inodes. Chrome retains three successful tool cards and both installed entries;
both LiveViews are connected without horizontal overflow or console warnings/errors.
The served application JavaScript matches the local artifact. Owned processes and
pages are closed; 4580/PID815717 is unchanged. Evidence is under
`/tmp/sigma-plugin-completion44-1cpucbw5`. This is controlled-Provider/local-registry
acceptance of the new native completion flow, separate from live-model,
installed-release and managed-child archive acceptance.

## Skill resources

The default native profile includes `skills::list` and `skills::read` through the
public ExtensionRuntime host adapter. `SkillResources` uses the actual
`Skills.Catalog` automatic/resolve rules; manual-only and disabled skills are not
model-readable, including guessed references. Executor authority is supported;
cloud authority reports unsupported capability. Repository/global duplicate names
retain independent opaque packages and `skill://` resource identities.

For a configured plugin host, every root and managed-child binding re-resolves the
application writer before reading its installed inventory. `PluginPackages.installed`
selects the newest completed installation per plugin in that registry, ordered by
installation timestamp and request ID; this read performs no HTTP or storage
mutation. Replacing the writer between successful turns does not strand a retained
CodexResources generation on its old PID or retry a request/install effect.

`PluginSkills` pins those records for the run, verifies their public Archive content
digests, and loads descriptors through public PluginProtocol and the existing
Skill Protocol document parser. Explicit `plugin:<source-digest>/<skill-name>`
references include registry, plugin, release, artifact and content identity; they
do not collide with repository/global references or another plugin's same-named
skill. Public package diagnostics join the list warnings. Installed skills use the
existing automatic document semantics, exact descriptions and metadata; instructions
and relative resources retain complete UTF-8 and LF/CRLF bytes. An installation
completed during an active run appears at its next binding. New runs and child
followups refresh the inventory and release their previous prepared snapshots.
Listing and reading installed skills never starts a Plugins.Session, MCP server
or script. New native binding preparation independently starts the optional plugin
function runtime above; the read-only property of skills does not imply that a
whole configured run has no MCP startup effects.

Listing pins descriptors; the first read lazily prepares a verified immutable
bundle through `Skills.Snapshot` and public Skill Protocol `Resource.read`.
Subsequent reads and continuation pages use that snapshot. There are 20 catalog
entries per page and at most 16 KiB UTF-8 text per page, with bounded bundle/read
caches and TTL. Scripts are readable resources and are never executed by these
tools. They do not restore the old `activate_skill` implementation.

The cache is owned by CodexResources; ExtensionRuntime rotates at every run.
Session validation fences run, incarnation, foreign bindings and detachment.
Eligibility is checked again before reading, so revocation invalidates existing
packages/cursors. Explicit cleanup reports `unknown_outcome` if a snapshot cannot
be released and retains the owned handle for retry; bind/TTL cleanup failures
block further dispatch. Owner termination is best-effort and logs unconfirmed
roots rather than claiming confirmed cleanup.

## Persistent Memory resources

The default native catalog admits `memories::add_ad_hoc_note`, `memories::list`
and `memories::read`. `ExtensionResources` routes these and Skills through one
public ExtensionRuntime. The trusted host chooses a Sigma root, defaulting to
`ConfigManager.agent_dir()/memories`; model arguments cannot select a root.
Agent state fixes it for that process's lifetime, including generation changes.
This is user-scoped storage shared across repositories, not Codex's own memory
folder or a thread-private history store.

`MemoryResources` has one application-owned writer per root. Session close does
not stop this shared process. Each invocation validates the exact public Session
binding both before dispatch and inside the serialized writer. The next run
opens a replacement if that writer died. A dispatched note call without an
acknowledgement returns `unknown_outcome`; Runtime stops that turn without a
false success settlement or automatic retry.

The note tool requires an explicit remember/forget/update/correction instruction
and the existing mutable-tool permission gate. Dedicated system instructions
are appended even to a custom prompt. As in pinned Codex, explicit user intent
is an instruction policy, not a fabricated backend consent field. The tool
creates `extensions/ad_hoc/notes/<timestamp-slug>.md` exclusively, preserving the
requested UTF-8 bytes and line endings; it never replaces generated memory files.
New directories use 0700 and notes 0600; existing directory permissions stay
unchanged. File data is synced, without directory-fsync or cross-node guarantees.
The configured parent directory must exist. Stable path/ancestor symlinks,
absolute paths and traversal are refused; hostile concurrent path replacement
is outside this boundary.

Listing returns visible immediate children or one selected file, sorted by
relative path. Pages cap at 2,000 entries. Instead of pinned decimal offsets,
opaque cursors bind the Session/run, query and directory revision. Up to 256
traversals live for five minutes; signed offsets preserve retry-safe pages and
do not consume a new slot on every continuation. A traversal remains usable at
capacity; changed directories and foreign/expired cursors return typed errors.
Reads retain one-based offsets, CRLF/final-LF behavior, UTF-8 validation and the
pinned 20,000 approximate-token middle truncation. Reading an absent store does
not create it.

Memory read results use the complete JSON object in model messages, protocol
events and canonical history, preserving `path`, `start_line_number` and
`truncated` alongside `content`. A generic content-envelope projection would
discard these fields; a regression checks the actual next Provider request and
the following turn's seed.

An independent WebSocket client exercised the default protocol entrypoint with
direct note/read/list and real Deno nested Memory/Skills calls. After a complete
isolated BEAM stop and restart, both resumed and fresh Sessions read the persisted
note. Note hashes and modification times stayed unchanged across restart and
browser reload, confirming that history did not replay writes. Chrome displayed
the complete JSON results and successful cards, retained them after restart, and
remained connected with no final console warnings or errors. The ten actual
Provider requests used a controlled fixture, not an online model. The disposable
listener was stopped; the existing port 4580 service was not restarted.

`memories::search` now uses the published tagged match-mode schema (#92). The
shared MemoryResources writer searches the real durable tree with `any`,
`all_on_same_line` and `all_within_lines`, case matching and optional normalization.
Normalization matches Rust Alphabetic-or-Number Unicode behavior, including
alphabetic combining marks. Matches use minimal windows, 1-based line numbers,
CRLF-compatible line context, caller query order and deterministic path/line sort.
Pages default to and cap at 200 matches; the existing opaque traversal machinery
binds the complete ordered result revision. Functional checks include actual
Engine/next-Provider JSON, real Deno, subsequent turns, writer reopen and a fresh
Session. This extends the earlier add/list/read browser evidence.

## History and rollout Notes

`HistoryResources` and `NotesResources` provide real hosts for all nine pinned
History/Notes tools through `ExtensionResources` and the public ExtensionRuntime.
`NativeTools` admits them for root sessions with a Writer and transcript path;
managed children inherit the trusted root archive with their own agent path and
exact child Session identity. `CodexResources` rotates the dispatch binding with
each run. Writerless roots omit these tools instead of creating a substitute
archive. Neither host uses the in-memory reference backend.

### Selected original history

`history::list_windows`, `history::list_items`, `history::read_item` and
`history::search_contents` query original journal messages, independently of the
display tail and active Provider context. The root Subagents owner supplies the
root Writer, live child resource references and durable registration roster.
History captures a live Writer with public `Writer.selected_journal/1`, then
uses public `Journal.Index.path` to walk that selected raw ancestry. Resolving a
child Writer through ChildIO happens outside the Subagents owner call, avoiding
an owner/child call cycle. Stopped sources use the persisted journal's latest
conversation ancestry without recreating a child, Provider or tool resource.
Journal diagnostics and normalization failures remain errors, not partial
archives.

Window IDs are the immutable journal header ID for the initial window and the
persisted `context_window` entry IDs for subsequent windows. Item IDs derive from
message-entry IDs; assistant tool calls become separate `<entry_id>:call:<n>`
items alongside ordinary assistant content. Raw custom input stays raw, while
map arguments become JSON text. Tool namespace/name fields support filtering.
Persisted entry order and call-part order determine results, rather than message
timestamps. Compaction and `new_context` change context projections without
removing older original items from this archive; sibling branches stay absent.
A live Writer checkout is visible immediately but remains transient until the
next append records the selected branch; disk-only reopen cannot restore an
unappended checkout.

Names beginning with `/` are absolute agent paths; other supplied names resolve
beneath the current agent. An omitted name in a child preserves that child's
exact Session binding. Explicit names prefer the current live source, then the
matching durable `registered` event with the greatest event revision, including
when a name is reused across Sessions. This rule is Sigma's deterministic
interpretation of same-name generations, not a rule specified by the pinned
Codex backend; incarnation and message timestamps do not select a generation.

Lists default to 100 items/windows; item previews default to 1,000 Unicode
scalars. Reads use zero-based scalar offsets and default to 20,000 scalars,
returning the full scalar count, next offset and truncation status. Positive
explicit limits are honored. Search is literal, case-sensitive substring search,
with role/window/tool filters and persisted-order or reversed-order results.
Read results retain image attachments in canonical structured metadata, and the
Provider emits them as separate image blocks beside the text JSON. JSONL and
subsequent reconstruction preserve both representations without replaying the
read. Encrypted remote history envelopes are not implemented.

### Shared virtual Notes

`notes::list_files_by_prefix`, `notes::read_file`, `notes::search_contents`,
`notes::append_to_file` and `notes::write_file` share one application-owned
`NotesResources` process per absolute root transcript. Root and managed children
use the same `<root_transcript>.subagents/notes.json` store, distinct from global
Memory notes. Relative paths resolve beneath `<current_agent>/notes/`; absolute
virtual paths such as `/root/reviewer/notes/findings.md` address another agent.
These are virtual JSON keys, not workspace files.

`write_file` replaces the exact text, including an empty string.
`append_to_file` concatenates exact text without adding a newline, creating a
missing file. Each file retains valid UTF-8 up to 1,000,000 bytes; replacement
and append enforce the same final size. Results include path, byte size and
created/updated Unix-microsecond timestamps; replacement retains creation time,
and persisted ordering makes updates monotonic.

Reads return `contents`, complete-file `n_lines` and metadata. Positive line
numbers are one-based, negative numbers count from the end, and both endpoints
are inclusive. Physical lines retain LF/CRLF terminators; a trailing newline
does not add an empty line, and an empty file has zero lines. Lists sort by name,
creation or update time in the requested direction, with path tie-breaking.
Search matches literal case-sensitive substrings within physical lines and
returns one-based line numbers. Default search order is path; `recent_file_first`
uses creation time, not last update. Prefixes and explicit file/match limits are
honored; omitted Notes limits do not impose a hidden result cap.

The shared GenServer serializes reads and writes, rereading the JSON store for
each operation so no cached note contents survive a rollout move or path reuse.
Opening or reading an unused store creates no files. Session closure leaves the
application-owned writer alive. Existing SessionFiles rename/adopt operations
move the `.subagents` subtree, delete removes it, and forks start with independent
Notes storage. Writes sync a same-directory temporary file and atomically rename
it through the existing Store filesystem; this does not include directory fsync
or cross-node exclusion. Failed write acknowledgements preserve their actual
storage reason and remain uncertain without automatic retry. The local JSON
result shape is Sigma-defined because the pinned remote backend does not specify
a canonical Notes output schema. `notes.thread_hint` and remote encrypted History
are not implemented. The user deferred both on 2026-10-27 as TODOs outside this
phase's completion gates; the existing local History4/Notes5 retain their scope.

In pinned Codex `46fdd5ef39735f4159cdcf0ec5e85c10521494e5`, `notes.thread_hint` is a
full-context contribution, not a sixth Notes tool or an input field. The HistoryNotes extension
calls its actual backend at `alpha/notes/v2/thread_hint` with the real session ID
and agent path. It accepts a nonempty `text` of at most 4,000 UTF-8 bytes; missing,
failed, oversized or empty results contribute no hint. The session projects the
fragment as `notes.thread_hint` in its independent developer
`token_budget.context_window` message alongside first/current/previous window
UUIDs, rather than reinjecting it in ordinary incremental context. Its tests'
recent-note fixture does not define a local summary algorithm. Sigma has neither
that actual backend nor this full-window contribution path. The public
ConversationAdapter host context callback is a possible future projection boundary;
the absence of a dedicated ExtensionRuntime hook alone is not a confirmed
Backplane blocker. Any future implementation requires backend selection and the
full-context contract before functional acceptance.

### Exposure and functional evidence

All nine descriptors retain the public `DirectModelOnly` exposure enforced by
Backplane 1.10.37 (#90). They are available to direct model calls in root and
managed-child profiles, and absent from the real Deno `ALL_TOOLS` catalog.
Skills and Memory remain callable from that same Deno execution.

`backplane_history_functional_test.exs`, `backplane_notes_functional_test.exs` and
`backplane_history_notes_integration_test.exs` exercise selected ancestry before
compaction/reset, stable windows/items, tool-call parts, Unicode/media reads,
exact Notes mutation/line/order/limit behavior, concurrent append, writer reopen
and moved stores. Real Engine/next-Provider and JSONL checks cover root/child
calls, followups, same-name generations, stopped archives and reconstruction
without replaying Notes writes. The Deno test uses the actual executor. The
functional scope passed 33 cases (History 5, Notes 11, integration 6, raw/Deno
patch 3 and Memory search 8; seed 673067). Another 19 exact named functional
regressions passed (Agent 18, Web 1; seed 977385), giving 52 distinct cases with
zero failures and no skips. These overlap earlier acceptance batches; counts
are not cumulative. InteractionResponder cancellation and teardown
`peek_steering` owner-exit diagnostics remain in the logs.

Independent acceptance on isolated 4625 used a real Protocol WebSocket for all
nine tools, `new_context` and original History/Notes reads, with 14 Provider
calls. Chrome used a separate new Session with nine successful tool cards and
10 calls. Opened read cards retained complete JSON, Chinese text, whitespace and
CRLF; LiveView remained connected with no console warnings/errors or overflow.
Served `app-4ec935d5.js` bytes matched the local artifact. Refresh preserved
Notes/Provider SHA256 and nanosecond mtimes. A full owned-BEAM exit followed by a
new-PID start, Protocol resume and Chrome reload recovered cards and original
content with stable item IDs. Both Notes stores and Provider logs retained their
hashes/mtimes, both Session journals retained their original byte prefixes, and
Provider calls remained 14 + 10 with no effect replay. The owned listeners and
browser tab were closed; original 4580/PID815717 stayed untouched. Evidence is
under `/tmp/sigma-alignment38-archive-20261026-v2`, with harnesses
`/tmp/sigma-alignment38-archive-{server.exs,client.mjs}`. These local controlled
Providers do not establish online commercial-model, release or deployment
acceptance. No new UI implementation or security/permission tests are included.

## Context windows and budget

`get_context_remaining` uses public Conversation status, the actual admitted tool
definitions, the same ContextBuilder as the model request, and the selected
Provider's actual output-token cap. Unknown, stale or incompletely estimated
context returns null. Providers expose the optional `output_token_limit/2`
callback; built-in HTTP request bodies use the same cap implementation.

`new_context` clears the Runtime conversation messages without summarizing them.
Before acknowledging the next Provider request, Engine processes preceding events
and commits a synced `context_window` JSONL entry through the Writer. A failed
append or cancellation prevents that request. An empty/tool-only new window
receives AGENTS, skills and hooks reminders only in provider context; no fake user
message or compaction is written to the display transcript.

Snapshots retain separate `messages`, `context_messages` and `context_window`
projections. Boundaries are branch-local and idempotent; a fresh run's window
number is not globally ordered against previous runs. Later turns, actual retry,
fork and restart seed only the selected active window. Compaction summarizes that
window and cannot bring pre-reset content back into model context.

If Engine exits while an accepted boundary append is held, Writer can commit it
after the caller is gone. Interrupted/error turns therefore require durable
reconciliation before the next prompt's effects or Provider request.
`Writer.context_snapshot/1` serializes behind accepted appends and reads the
Writer's selected branch through its configured storage. Failure stops request
admission and promptly rejects retry so its checkout can roll back; a later
successful read permits recovery. Full display history remains independent.

An independent real WebSocket client exercised default ProtocolSessionOptions,
all four Skills/context operations, the next turn, and resume after a complete
isolated server restart. Provider requests retained base instructions and excluded
the old prompt/resource contents after reset; JSONL and the display count retained
them. This used a controlled provider, not an online model. Protocol snapshots
retain their existing bounded last-five-message projection.

The remaining local backends also have actual execution checks:

- `view_image` reads a real PNG inside the bound workspace and refuses an
  existing image outside it. Sigma projects the actual bytes and writes the
  result to JSONL; replay still supplies the image after the source is deleted.
- `clock::curr_time` returns UTC bounded by the real test clock.
- `clock::sleep` performs a measured wait. Official 1.10.53 registers actual
  clock ownership before executor/tool start and retires through public
  `native_clock_wait_retirement`, without a successful cancelled result. Original
  immediate Stop, next-Provider, old-Session-DOWN and new-resource assertions pass;
  the new PostToolUse case additionally validates the exact proof and confirmed
  full retirement without allocation/ACK gating. Root/managed-child direct and
  real-Deno paths retain their independent acceptance. Session closure or worker
  DOWN alone does not supply proof. The 1.10.51 missing contract (#146), 1.10.52
  pre-ACK gap (#147) and intervening failed release (#148) are historical.

The root-production catalog tests compare an explicit set of all 42 default
tools, including environment readiness, Goal3 and Board9. Stopped-hook tests
assert that `stopReason` stays in the model tool-result presentation while
`additionalContext` is separate feedback, including the next turn and unchanged
actual Plan settlement. Resource-owner/Plan loss retains actual command/process
cleanup and unchanged previous tool results; a prompt rejected during host
inspection emits its exact `turn_failed` before Engine starts, so no Engine
`agent_end` event is required on that path. Controlled owner-loss diagnostics
remain visible and do not claim confirmed aggregate retirement.

These execution tests cover the seven local tools. Root Engine and entrypoint
acceptance are covered separately below; image rendering and PTY support remain
separate features. Complete owned infrastructure shutdown is checked separately
from worker/OS execution cleanup.

## Code Mode execution and continuations

The public `Codex.profile(:code_mode_only, context, authority)` exposes `exec`
and `wait`. Explicitly selected native target contracts enter
`context.code_mode_contracts`; Runtime supplies nested dispatch through the
current Conversation. Sigma does not introduce another JavaScript executor or
dispatch path.

Real Deno tests execute JavaScript, emit incremental output, yield a cell, resume
with `wait` and call native `update_plan`. A retained cell survives one successful
run and the first Conversation's termination. On the next run, a granted clock
call succeeds while the removed plan tool is rejected and the Plan stays
unchanged. This verifies that resumption uses the current admitted authority.

Termination, cancellation of CPU-bound JavaScript and host close stop the worker
and its OS execution. `/proc` checks accept an absent or nonrunning (`Z`/`X`)
process; they do not prove that every zombie has been reaped. Exec/wait results
also pass Sigma's Provider normalization and JSONL encode/decode without private
handles, tokens, PIDs or references. These tests use `EphemeralStore`: retained
cells are process-local resources, not restart recovery from a journal.

The project shell now includes Deno (verified with 2.8.3). The test workflow and
release verification job install Deno 2.8.3. Execution tests require a real Deno
binary and verified Linux lifecycle support; absent capability is rejected, and
the execution tests do not silently skip when Deno is missing. Native root
sessions now admit Code Mode through the same complete profile bundle.

An ordinary completed-command handle has separate direct and Code Mode
acceptance. Direct `write_stdin` returns a structured `not_found` error and the
same turn executes another command, preserving the error in JSONL. Real Deno
also passes after adopting the published
[backplane#111](https://github.com/gsmlg-opt/backplane/issues/111) fix in 1.10.42:
the ordinary error fulfills the nested Promise and the same JavaScript executes
another command. The earlier native Error encoding crash remains historical
evidence; no local encoder or dispatcher conversion is used.

On 1.10.43, a managed child's old command handle after an interrupted generation
likewise returns the exact ordinary `not_found` / "command session is unknown"
result. A subsequent command succeeds and both child and parent complete with
confirmed close. The former test expectation that this tool error must force
an unknown outcome was corrected after inspecting the actual persisted result
and continued Provider request. Six selected child lifecycle checks pass; the
mixed test file's permission cases were excluded. Active-termination diagnostics
remain distinct from the successful explicit-close assertions.

## Native input preparation

`Sigma.Agent.Backplane.ToolPreparation` implements the public `prepare_tool/2`
callback. Explicit native Conversations install it through `hooks: ToolPreparation`
and supply trusted `provider_context.permission_options` for the existing
`Sigma.Coding.PermissionInterceptor`. Runtime supplies the pinned `input_kind`.
The adapter never dispatches a tool or changes its descriptor, backend or authority.

Function input patches merge with the original map; Codex `updatedInput` replaces
it completely. PreToolUse runs before the Sigma permission resolver, which sees
the transformed input. Resolver map edits become the final function input, and
Runtime subsequently validates it, checks grants and commits the invocation before
backend execution. A denial, malformed final input or cancelled preparation wait
must not dispatch an effect.

Custom inputs pass through unchanged as exact strings. The existing hook/resolver
edit contract supports maps only: nonempty map edits or replacements of a raw
custom input are rejected. Empty context-only patches preserve the raw string;
binary replacement resolver responses remain unsupported. Hook JSON formats have
not changed. Nonempty additional hook context uses Runtime's live
`append_feedback/1` callback through `HookContext`; an explicit
`provider_context.on_hook_context.(final_invocation, text)` remains an observer
or a fallback when no Runtime callback exists. Missing both fails closed; context
never becomes tool arguments. Receipt and observer semantics are described below.

Preparation tests use native Plan/apply_patch backends and the real Sigma Store.
A fixture gates acknowledgement after writing and reloading the actual disk
snapshot: the final input is present in the durable invocation while Plan/file
state is still unchanged. Releasing acknowledgement permits the intended effect.
This validates Sigma's permission resolver and Runtime's commit-before-dispatch
boundary. Runtime's separate `requires_approval` interaction is covered by the
host integration below. Engine installs preparation for selected native tools
through `Sigma.Agent.Backplane.Hooks`; MCP retains its existing Dispatcher path.

### Correlated root approval waits

For explicit root Conversations, trusted `provider_context.permission_interaction:
true` routes the Sigma permission resolver through Runtime's public `interact/1`.
The request is serializable and uses a separate `:sigma_tool_permission` kind with
the PreToolUse-prepared call; resolver edits can still change the final input.
It is not Runtime's built-in `:permission` approval protocol.
The resolver callback remains in host memory. Default direct preparation retains
its existing bounded-worker behavior.

`Sigma.Agent.Backplane.InteractionResponder` owns the host side for one run and
incarnation. `PermissionResponder` remains a compatibility entry point with the
same child identity and public API. Start it with a trusted owner, downstream
subscriber and existing
`permission_request_fn`; use it as the Conversation subscriber and `attach/2`
before prompting. It checks requests against the Conversation's current
checkpoint, then runs the resolver and public `Conversation.resolve/3` outside
the responder actor. Interaction and terminal event claims must match public
Conversation state before changing the wait or forwarding those events. Malformed,
stale and duplicate requests cannot start a second resolver. A resolver that exits
without resolving the current interaction is denied, including normal self-exit.
Cancellation, terminal events and owner/Conversation shutdown stop the resolver;
Sigma's existing waiter monitor clears its pending question. Late answers cannot
revive a cancelled interaction. Runtime's independent `:permission` requests are
never passed to Sigma's policy resolver; they use the separate optional handler
below or remain forward-only.

Normal responder shutdown and owner loss also cancel the attached unfinished run
through public `Conversation.status/1` and `Conversation.cancel/2`, after checking
its run ID and incarnation. Cancellation acknowledgement fences further callbacks;
cleanup and its durable terminal checkpoint finish asynchronously. Tests require
the actual stored run to become cancelled with no pending interaction, including
exit before prompting, and preserve completed checkpoints. Terminal, cancelling,
storage-failed and recovery-required runs are left in their current state. Abrupt
responder kills still require the embedding host's supervision policy.

The opt-in tests use the actual Sigma question/answer API and file-backed Runtime
Store. An approval waits beyond both original run/effect budgets while Runtime
is `:waiting_interaction`, then the transformed input is committed before native
Plan execution. Denial, cancellation, owner/Conversation/responder exit, resolver
failure and malformed or forged active-wait events have separate checks. These focused checks cover the host API. Engine and browser acceptance below
exercise the same boundary through actual session entrypoints.

### Runtime built-in approval

An explicit root host can additionally install the trusted
`runtime_permission_request_fn: fn request, current? -> ... end` option on
`InteractionResponder`. Runtime's `:permission` request contains the final
prepared invocation under `operation`; it has already passed final validation
and the authority checks that precede approval. The responder validates the
exact persisted pending request, interaction ID, run and incarnation before
starting its owned worker and again before resolving. The callback accepts only
`:approved`, `:denied` or `{:error, reason}`. Sigma `:allow` responses, input
patches and client-supplied decision or resolver-identity maps cannot approve it.
Invalid responses, handler loss and cancellation cancel the current run through
the public API. With no handler, the existing forward-only behavior is preserved.

Public `Conversation.resolve/3` accepts the decision atom. Runtime then constructs
its own approval ID, final-arguments digest, revision and binding and uses
`resolver_id: "host"` internally. Sigma neither fabricates that record nor treats
an arbitrary resolver string as authentication. The embedding host must
authenticate its responder before exposing approval; these checks do not prove
that a UI signed a digest generated later by Runtime, or that an approval record
was independently persisted.

Real Store/native Plan and raw `apply_patch` tests cover approval, denial,
handler errors, cancellation, stale/forged events and late replies. Preparation
from A to B makes the handler see B. Gated disk checkpoints prevent the callback
before request acknowledgement and prevent any native effect before invocation
acknowledgement. Human waits pause the original run/effect deadlines. Separate
public `Approval.decide/2` tests verify the 1.10.32 identity fix and refusal of
mismatched approval IDs, argument digests, revisions and bindings. The Engine supports this separate trusted handler, but these focused tests do
not establish independent client authentication or implement the
`request_permissions` grant-management tool.

### Native synchronous user input

Explicit root Conversations can also install the public `Codex.Control`
`request_user_input` contract. Configure `InteractionResponder` with
`user_input_request_fn: UserInput.resolver(agent_pid)` and use it as the
Conversation subscriber. The owner must be the question Agent or a host that
guarantees that Agent's lifetime. Permission and question handlers can share the
same responder, while Runtime's built-in `:permission` requests stay separate.

`Sigma.Agent.Backplane.UserInput` validates the entire supported batch before
opening a host question: one to three questions, unique nonblank string IDs,
headers of at most 12 Unicode characters, and two or three label/description
options per question. It presents questions sequentially through the existing
`Sigma.Agent.ask_user_question/3`, prefixes the visible question with `[header]`,
retains option labels/descriptions and permits freeform text. Human waits default
to infinity; an embedding host can provide an explicit timeout. No option is
implicitly selected. Accepted text, including Chinese and newlines, is returned
unchanged under each stable question ID in `%{answers: %{id => %{answers: [text]}}}`.

The responder compares the exact persisted pending request, interaction ID, run
and incarnation with public `Conversation.status/1`. The adapter checks freshness
before each question and after each answer; the responder checks again before
resolution and requires the complete answer-ID set with one nonblank answer per
question. Unsupported batches, malformed replies, user cancellation and resolver
loss cancel the matching current run through public APIs. Error tuples never
become successful answers. Serializable checkpointed requests must reach the
mapper even if question IDs are malformed: silently dropping a duplicate-ID
request would leave Runtime waiting forever.

Real Store tests gate acknowledgements after the actual request/answer checkpoint
writes. No question opens before the request acknowledgement, and no dependent
Plan effect runs before the resolved checkpoint acknowledgement. Three sequential
questions retain one pending Runtime interaction until the full answer is ready.
A human wait exceeds the original run/effect deadlines. Request-write failure
opens no question; answer-write failure preserves the original pending disk
checkpoint and prevents the dependent effect.

Cancellation after this native tool has been committed conservatively persists
`:unknown_outcome`, with no pending interaction after successful cleanup and no
dependent Plan execution. This differs from the pre-dispatch permission path,
whose tests persist `:cancelled`. External cancellation, user cancellation and
owner/responder exit clear the existing Sigma waiter and reject late answers;
Agent and Conversation death have separate cleanup checks. Public status guards
are observational: `Conversation.cancel` is run-level, not an atomic
interaction-token-fenced cancellation API.

Engine now installs this adapter for native root sessions. The Protocol bridge
below and LiveView carry its live questions through actual entrypoints.
Persisting a synchronous request alone does not recover its waiter after service
restart. The separate durable async inbox described below restores cards and reply
receipts without reconstructing synchronous waiters. `request_permissions` still
requires a host callback that actually enforces its returned grants and is not
made available by either question adapter.

### Protocol question bridge

Protocol V1 adds the opt-in `questions.v1` capability. Negotiated subscribers
receive `question.required` with `requestId` and a whitelisted `request`, and
`question.resolved` for generic questions they know about. Display fields include
the question text, option labels/values/descriptions, freeform flag, placeholder,
tool-call ID and bounded source identity. Private callbacks, PIDs and arbitrary
host metadata do not enter the wire DTO. Existing permission events remain
separate; subscribers without the capability receive neither new event.

The public command is
`question.resolve {requestId, action: "answer", answer: "..."}` or
`question.resolve {requestId, action: "cancel"}`. It looks up the still-pending
question in the selected root session or its existing child host, validates the
reply against its original choices/freeform policy, then calls the existing
`Runtime.answer_question` route. Accepted text is unchanged. Blank, malformed,
oversized, invalid UTF-8, unknown-field, wrong-session and replayed replies cannot
consume a pending question. Generic question and permission commands refuse each
other's request kinds.

Capable attach/status snapshots add `pendingQuestions` from current host waiters;
they do not reconstruct waiters from the journal. Clients upsert/remove by
`requestId` and use the existing cursor/resync mechanism when updates are lost.
A snapshot and queued question events can overlap. The subscription tracks
generic request IDs only to distinguish resolution from permission cleanup;
this is not a durable reply queue or an atomic question-recovery protocol.
The relay validates the final envelope after adding session, turn and cursor
fields. An oversized question produces `question_payload_too_large` while the
host retains its complete original request. A dropped final question immediately
produces one coalesced resync marker, even without subsequent events. Further
generic question deltas wait for a successful live snapshot to restore the
subscription; permission and legacy delivery retain their existing behavior.
Ordinary child host questions use the existing child route. The native MultiAgent
adapter below uses exact cancellation. Focused codec/subscription tests are
complemented by the separate real browser/WebSocket acceptance below.

## Managed child interactions

`ChildInteractionResponder.attach/2` subscribes through public MultiAgent APIs and
recovers pending requests from an atomic snapshot. Every answer/cancel carries
manager, agent, run, incarnation and interaction IDs. Event payloads alone cannot
open a waiter. Observation failure reports `observation_unavailable` and preserves
active workers; only a successful snapshot can establish that a request changed
or settled. A handler that has never started may retry observation after recovery.
Started handlers and submitted answers are not automatically replayed.

The adopted package exposes `MultiAgent.cancel_interaction/3`. Handler failure,
invalid replies and unsubmitted worker loss cancel that exact interaction once.
`:ok` confirms the terminal checkpoint and cleanup acknowledgement; an already
committed native question may conservatively finish as `unknown_outcome`.
Target-only interruption is not used to simulate cancellation. Once an answer or
cancel was submitted, a lost acknowledgement is not retried or followed by a
second mutation. Submitted workers survive observations that omit the pending
request so that their acknowledgement uncertainty is not silently lost.

Child Sigma policy replies use `ChildPermission`'s closed string-keyed JSON
envelope, distinct from generic input and Runtime approval. Allow/map edits and
deny reasons must fit the complete public JSON boundary without coercion. All
other answers are also bounded before submission, including trusted callback
freeform answers. Invalid UTF-8 and oversized replies take the exact cancellation
path before resolve; they cannot leave a seen-but-unresolved approval behind.
Runtime decisions remain `:approved`/`:denied` on their independent channel.

`ChildStore` captures accepted feedback at terminal settlement only. `ChildIO`
seeds canonical feedback metadata into the next run and persists each stable ID
once. Mid-batch projection cannot insert a user message between an assistant call
and its tool results.

The published [backplane#86](https://github.com/gsmlg-opt/backplane/issues/86)
contract admits a child-owned Session through the real MultiAgent manager. ChildIO
allocates resources and supplies the binding; the manager adopts it after validating
the child options. Root and siblings keep independent Command/Plan state. Each
followup gets a fresh run/incarnation binding, while a successful prior turn can
retain its command handles. Confirmed closure allows regeneration; unexpected
Session loss or uncertain cleanup refuses replacement. Failed pre-adoption
preparation cleans up only the matching reserved attempt.

Child profiles use `root?: false`, exclude root-only questions/reset and compute
context remaining from the actual current child messages, admitted catalog and
provider output reserve. Native preparation uses the exact child permission
route. Confirmed Plan metadata is captured into the child's canonical journal and
hydrated from its selected branch, without replaying effects. Child MCP functions
use deferred discovery as described below. Resource profiles borrow the existing root MCP clients;
the child never starts or closes those connections. A nonempty actual client map
and inherited grants are both required for the three resource tools. ChildIO fixes
the trusted root owner and server-ID ceiling at initial admission. Its fenced
getter returns that descriptor before the resource caller queries the owner's
current client map, then revalidates the exact child run/incarnation and intersects
the map with the original ceiling. The root lookup works between parent turns and
never calls back into the child host; ChildIO does not hold a synchronous call to
the root. Missing/stopped owners fail explicitly, without falling back to retired
references. The public Session binding still fences execution and followups cannot
add newly connected servers to an existing child's ceiling.
Real-manager tests cover direct resource calls, real Deno nested reads, permission
denial without a remote `resources/read`, and followup reuse. Reload tests confirm
the old process and Registry reference retire, both root and existing child use
the replacement, reads continue while the parent is idle, and a later followup
rejects the old binding with exactly two MCP initializations. Concurrent removal
during an already dispatched remote call still has the bounded cancellation
behavior described below. Unrelated Session attachment still fails with `collaboration belongs to
another session`; Sigma does not strip metadata, remove collaboration grants,
rebind the root manager or use private dependency PIDs.

Backplane 1.10.37 publishes #98's invocation-bound handle lookup receipts.
The production public local Backend supplies the actual Runtime operation to
native command lookup. A completed handle's lookup rejection is therefore settled
before stdin is dispatched. Actual root and managed-child direct/real-Deno
functional checks now accept ordinary `not_found`, successful command continuation
in the same turn, completed child Store state and exact JSONL error/nested payloads
(three cases, seed 43151). No local receipt producer or executor is added.
Generic errors remain insufficient evidence of non-dispatch. The original native
Error archive regression now passes on 1.10.48 without rewriting results; cancelled
both original resource-scope full-retirement cases also pass with 1.10.50 #141.
Security/permission development and verification remain excluded.

Direct parent completion after active-child interruption is accepted with the
1.10.37 #99 fix. The real manager test starts a retained OS command, holds the
child Provider, interrupts it, observes command/Provider closure, and completes
the parent directly without a replacement followup.

The #100 fix propagates committed root discovery through the public Session and
manager lifecycle. ChildIO partitions its inherited tools using the same actual
connected-client identity check as root Engine. Only those deferred definitions
enter `ToolCatalog.deferred_candidates/2`; complete active tools remain available
to the existing Dispatcher callback after public publication. Initial catalog
composition includes only eager functions, native profiles and collaboration.
`tool_search` is selected only with a nonempty inherited candidate inventory.
Every followup binds a new run and rebuilds that inventory; it never resets a
live DynamicRuntime or manually expands the parent catalog. The Provider request
handshake records actual tools for subsequent context accounting without a
synchronous ChildIO-to-Conversation call.

Six functional cases cover fresh child/followup search, complete function schemas,
direct MCP/real Deno execution, actual Provider context accounting and spawning
before root discovery. Two initial deferred assertions failed before the change;
three empty-inventory cases failed before their correction. Only functional tags
are selected in the mixed test file. One initialization and two remote calls
serve both runs. Independent Protocol/Chrome acceptance on isolated 4627 exercises
the same root search/spawn, child search/direct call and followup search/real Deno.
Each client has seven root and six child Provider requests; two initializations
serve four actual MCP calls in total. Both child journals retain four complete
tool results, including original Unicode. After refresh and full owned-BEAM
exit/new-PID restart, all four root/child journals and the Provider log retain exact
bytes/hashes/mtime. Resume reconnects the two root clients without another function
call or Provider request. Chrome restores six successful root cards, remains
connected and has no overflow or console errors/warnings. Initial fixture logs
contain supervised Provider workers exiting with `:killed`; assertions and restored
results pass. The two owned BEAMs and browser tab are closed; 4580/PID815717 is
unchanged. Evidence/scripts are under `/tmp/sigma-child-deferred-20261026` and
`/tmp/sigma-child-deferred-{server.exs,client.mjs,evidence.py}`. The Provider is a
controlled fixture and the MCP server is a real Python stdio process.

## Native post-tool hooks and feedback

`Sigma.Agent.Backplane.ToolPostHooks.decorate/2` adds synchronous PostToolUse to an
explicit native profile before catalog admission. It retains schema, safety,
binding and lifecycle fields, then calls the original backend once without
Dispatcher. Execution removes only its private marker from the current context;
Runtime-injected `interact`, nested dispatch and catalog callbacks must survive.
A real decorated Code Mode execution calls native `update_plan` and checks both
the nested and outer hook payloads.

Success hooks receive the committed function map or exact custom input. The
adapter returns the original native result unchanged, including structured
fields, typed errors, invocation rejection receipts and unknown outcomes. Failed
native returns do not invoke success hooks. Image hook payloads remove raw bytes
only when they match the canonical data URL; the native result retains its bytes.
Unsafe or oversized JSON projections skip the hook with a diagnostic rather than
stringifying process-local data.

`HookContext` now uses Runtime's public `append_feedback/1` callback for both
PreToolUse and PostToolUse. IDs derive from immutable invocation identity and hook
stage, so retries cannot evade deduplication by changing text or tool arguments.
Runtime owns correlation, checkpointing, stale-producer fencing and projection.
Receipt mode is explicit: only a durable Store gives durable acceptance. The
native result and final tool arguments are independent of the feedback record.
The receipt does not attest to final argument bytes or successful dispatch.

An optional `on_hook_context.(operation, text)` remains a compatibility observer
after Runtime acceptance, or a fallback sink outside that callback boundary.
The observer is not invoked when append fails. Pre observer refusal can prevent
dispatch after feedback is already accepted; it cannot roll back that history.
Post observer/hook failures retain the completed native settlement and produce a
diagnostic. Public `ToolEffects.present/3` now separates actual settlement from
consumer presentation. `run.tool_results` retains the successful native result;
`run.tool_presentations` retains its accepted block/stopped decision. A block
reaches both the model and nested Code Mode as an error before nested success
can continue. Stopped output replaces the model result while nested code retains
the completed native value. Additional context uses its own feedback path.

Root and child Plan projection consult the actual public Store settlement,
including nested invocation identity. Canonical tool metadata records the
confirmed Plan and actual-success observation even when its displayed result is
a block error. JSONL and later Session hydration restore that selected snapshot
without running the tool again. Functional coverage includes root/child ×
direct/nested × block/stopped, next Provider requests, later turns and recreation.

The pinned hooks target remains `7a152fbcf9ecd32d9fb4b45edf80127ee4c8499e`,
separate from the tools inventory. Its 14-event catalog has no PostToolUseFailure;
suppressOutput/updatedMCPToolOutput are unsupported there. Backplane 1.10.38
publishes [#107](https://github.com/gsmlg-opt/backplane/issues/107), preserving
explicit empty stopped text. ToolPostHooks now forwards it to public presentation
instead of the old diagnostic bypass. Four empty-content cases first failed on
1.10.37; all twelve root/child direct/real-Deno presentation cases now pass,
including canonical history, subsequent turns and resource recreation. Actual
Plan settlements and revisions remain intact; no fallback reason is invented.

Async native command post hooks require a session-owned Writer and AsyncRuntime;
standalone or writerless contexts refuse them before effects. Runtime's
invocation-bound `append_feedback` callback expires when its producer completes.
`HookDelivery.factory/2` instead captures immutable origin identity and saves
original context directly to the long-lived Writer. Callback expiry is therefore
not an upstream blocker. The uncorrelated legacy ETS context callback does not
serve as a durable delivery receipt.

Runner command workers register with the owned AsyncRuntime before a fresh-reference
startup gate permits any OS launch. Registration is independent of the eight async
slots and model-request observers. Shutdown kills outer hook tasks, requests the
registered workers' managed process-group cleanup, and joins those workers before
acknowledging closure. Merely joining the outer task leaves a cleanup race. A
closed runtime rejects the worker before launch; completed hooks retain their
deliberately detached helpers. Root SessionEnd runs synchronously after this join,
using a fresh scoped AsyncRuntime for its own command cleanup reports rather than
the retired binding. Legacy non-native callers retain their existing final-shutdown
dispatch.

Retirement uses the distinct `AsyncRuntime.shutdown_confirmed/1` contract; legacy
`shutdown/1` remains best-effort and idempotent. Each actual Runner command worker
sends an ordered, one-way cleanup report before exiting, and strict shutdown joins
both that report and its normal DOWN. A normal worker return after a caught error
is not confirmation. Runner retains actual signal/exception evidence and observes
its managed Linux group/waiter; missing reports, unknown startup groups, failed
cleanup or unavailable observation remain unconfirmed. Natural completion still
preserves intentionally detached helpers: a live group yields an unconfirmed
retirement result instead of changing that behavior. Duplicate command/observer
monitors join independently, without killing a worker that is still cleaning up.

The async-hook ledger has separate Sigma-owned `hook_feedback` facts in
the existing session journal. `Sigma.Session.HookFeedback` uses closed JSON
schemas and immutable session/invocation/branch/handler identity, including the
original handler index and config digest. It retains up to 64 KiB of original
UTF-8 context without truncation. The reducer separates received, dispatching,
admitted, consumed, delivery-unknown and discarded states; canonical message IDs
and actual Runtime admission IDs are distinct. Old receipts never reset an
uncertain or terminal item to a dispatchable state.

Writer validates its trusted session, expected leaf and raw ancestry before
appending. New facts sync their file before acknowledgement; this does not sync
the containing directory. Exact duplicates return the original journal receipt,
including after Writer restart. Global receipts prevent repeated admission while
selected-branch projection hides sibling items. Replay rejects invalid scopes,
cross-sibling transitions and conflicts; hook facts neither become model messages
nor advance the conversation leaf or create branch alternatives. Runner can bind
each async callback before queueing with the handler's index in the complete
configuration, preserving distinct identical handlers. A failed factory prevents
execution and does not fall back to the legacy callback.

These are host receipts, not Runtime `host_feedback` receipts or invocation
authority. `HookDelivery` separately loads the public Store's exact consumed tool
intent, matching run/incarnation/turn/step/attempt/invocation/call/tool identity and
a successful result. Runtime cancellation/failure/unknown terminals and selected
durable host cancellation discard that source even if its tool completed.

Root Engine uses public `Conversation.steer/2` while running. Idle output remains
received until a real prompt passes UserPromptSubmit, then enters that prompt's
first Provider request. ChildIO owns a separate Writer, Store and AsyncRuntime;
its supervised worker verifies public run identity and active phase outside IO
before steering. Prompt preparation waits for the actual admission-ID mapping;
ordinary checkpoint projection must remain available while admission is pending.
Synthetic hook messages bypass UserPromptSubmit only through that trusted mapping.
Neither path starts an idle turn or retains the producer's expired callback.

Consumption requires both the selected raw-journal canonical user message with
matching session/destination/item metadata and the destination Store's matching
message ID and content. Initial prompt hooks may return the canonical ID; that
case additionally requires exact feedback metadata in the Runtime checkpoint.
Steering-queue admission alone and same-text/wrong-ID messages do not prove
consumption. A sibling canonical message cannot prove selected consumption.
Unknown admissions remain non-dispatchable across restart, although later exact
evidence may confirm consumption. Host shutdown stops owned hook workers before
their Writer. Root reconciliation errors use the existing persistence-failure
channel. Child reconciliation errors reject the triggering checkpoint and fence
subsequent IO. If the Runtime sidecar already committed, the projection error
retains `runtime_committed: true` and the actual revision; it does not claim a
rollback or retry the hook effect.
Configured MCP calls in native root/child sessions use this same HookDelivery
ledger. The ToolBackend passes the complete public Runtime operation to the root
or ChildIO adapter, which binds a Writer factory before Dispatcher schedules the
hook. Identities are never reconstructed from the outer request or tool-call ID;
real Deno nested MCP invocations retain their own identity. Child active polling
also works for MCP-only grants. Dispatcher forwards an optional factory only
when supplied, preserving independent `native_tools: false` callback callers;
an explicitly rejected factory cannot fall back. Permissions, PreToolUse and MCP
execution remain in Dispatcher, while native profile resources keep their own
post adapter. MCP `isError` and execution errors skip success PostToolUse hooks
and retain their original error. Child checks use explicit static grants and do
not by itself establish dynamic manager delegation; the separate 1.10.37
real-manager MCP/Deno acceptance now covers that lifecycle.

Runtime inserts canonical host-feedback messages at the natural provider
continuation. Sigma Provider projects them with stable Message IDs and preserved
feedback metadata. Real Conversation/file Store/Plan tests prove pre/post feedback
appears once in the next Sigma provider request, nested invocations remain
distinct, conflicting retries are rejected, and a failed pre checkpoint admits no
feedback receipt or native effect. This adopts
[backplane#82](https://github.com/gsmlg-opt/backplane/issues/82), without adding a
second journal or disguising feedback as collaboration/steering.

`CanonicalHistory` lifts JSONL feedback metadata into Runtime seed messages and
projects public checkpoint feedback, including terminal accepted-but-unprojected
records. Engine persists stable message IDs in its main transcript, deduplicates
natural provider continuations, and captures terminal feedback when no next
provider call occurs. Real Store/JSONL reload and a fresh Conversation prove the
next run retains feedback. Provider context may strip host-only metadata, while
the canonical user text still reaches the model. Sidecar durability and main
transcript persistence are tested as distinct boundaries.

## Root admission and resource shutdown

Both `SessionLive` and `ProtocolSessionOptions` keep the retired `tools: []` list
empty and enable `native_tools: true`. Engine admits the ten core native tools
plus actual MCP descriptors, collaboration contracts and optional resource tools
as one registry/tools/authority bundle. Native tools use preparation/post hooks
and a run-owned InteractionResponder; MCP stays on Dispatcher. Direct Agent
callers retain an explicit opt-in; native execution without a long-lived session
host is refused.

Successful turns detach while the long-lived host retains Command, Plan, cells
and DynamicRuntime. Failure/cancellation closes the generation before reuse.
Owner loss and abnormal owned-resource failure fence admission; actual retained
OS-command tests verify process cleanup and no next provider/effect. Unconfirmed
cleanup remains an error. `Session.close` confirms resource cleanup and leaves an
inspectable closed Session; normal Session termination separately stops its owned
registry and supervisors. CodexResources closes Session before stopping its owned
processes. Borrowed Sessions retain their original owner.

LiveView uses the public current Agent transcript for active display only, keeping
pending tool cards across refresh. Saved-history repair still removes incomplete
batches for runtime replay. Tool-result lifecycle events attach to their assistant
card and do not create standalone conversation rows. Protocol message events retain
the complete nested native question/options arguments within a finite 16-level
outgoing payload limit and the unchanged 64 KiB envelope limit. Canonical snapshots do not
restore process-local waiters after restart. Runtime snapshot hydration reads raw
durable metric facts before sampling public Agent status. It normalizes the
independently generated journal header to the trusted runtime session ID and
preserves only that Agent's exact active turn/request identities. Requests must
also match the active turn, including nil for auxiliary requests. All other
unfinished work retains ordinary interrupted recovery; durable terminal facts
remain unchanged. Snapshot reads append no metrics or execution effects. Direct
journal replay still finalizes in-flight work by default, and an absent, dead or
idle Agent provides no live exemption.

## MCP resource host

The three resource tools and `mcp_events` appear only with actual connected clients. Their trusted
turn-fenced getter borrows current root clients, including for children; it creates
no second registry and owns no shared connection. Results preserve server/URI,
text/blob, explicit-server cursors and the pinned partial-list behavior.

The adapter surrounds each logical operation with public
`DynamicRuntime.resource_request_scope/2`, then starts each page through
`resource_request/2` in the actual effect caller. It preserves every reserved MCP
Client option. Omitted-server listings sort and query servers/pages sequentially,
sharing the public deadline, one active request and at most 128 total slots per
invocation. Existing page/item/cursor limits remain. Cancellation, unknown outcome
and budget errors propagate rather than becoming partial success.

Original root and managed-child list/template/read interruption checks pass on
1.10.48. New direct/real-Deno pagination cases preserve an earlier completed page,
cancel only the exact pending next page, never dispatch a later server, retain an
independent same-client caller and single initialization, then complete the parent.
On 1.10.48/49 their final whole-host retirement failed with `lifetime has no exact
tool retirement evidence`. [Backplane #141](https://github.com/gsmlg-opt/backplane/issues/141)
now publishes the typed `resource_scope_retirement` and reconciler support in
1.10.50. Sigma retains that unchanged authoritative record; both original final
whole-host retirement assertions pass. Immediate cancellation and durable
started-tool retirement remain separate facts. No fabricated proof, shared-client
shutdown, private state or replacement executor is used.

`mcp_events` adopts 1.10.51's public `DynamicRuntime.event_request/2` and
`Client.start_list_events/2` over the same borrowed client. It returns one raw
server page: event descriptor order, boolean/object schemas, namespaced metadata,
empty pages and exact opaque cursors remain intact. It never automatically follows
`nextCursor`. The public client owns any MRTR continuation and its individual wire
IDs; Sigma does not create a second request tracker or connection.

Cancellation retains the authoritative `event_request_retirement` alongside
resource, plugin-wait and Code Mode records in LifetimeEvidence. The public
reconciler validates the original invocation, Session generation and nested digest.
Confirmed local cleanup does not establish remote rollback. Functional checks use
a real HTTP MCP Events fixture and actual two-wire MRTR requests, direct and real
Deno calls, root cancellation and child interruption, with PostToolUse enabled.
They assert every wire ID, the exact pending-wire cancellation, independent caller
survival, one discovery handshake, same-client reuse and full host retirement.
Same-child followups after interruption and repeated JSONL reads preserve exact
results without additional requests. RPC code/message/data and the complete
domain-error page are retained in public Error details, since its cause alone
is not part of `Error.to_map/1`. Direct model/history results retain those details;
Code Mode follows its public native Error contract and rejects the Promise with
the original message. Catching that failure permits a fresh Events call in the
same JavaScript invocation; authoritative Runtime Store results retain the full
error in both modes. This differs from ordinary MCP function `isError` values
described below. All **nine Events cases** pass (seed 43185), also included in the
43-case integrated selection, repeated against actual 1.10.51 package BEAMs.
Actual packaged Protocol/Chrome Events and independent-BEAM stopped recovery also
pass as described above; earlier versioned client evidence keeps its original scope.

For ordinary MCP function results, non-null `structuredContent` supplies the full
JSON value to the model and takes precedence over display content, matching the
comparison checkout's Codex `CallToolResult.as_function_call_output_payload`
behavior (`9a8a85bc539325f2819dd0717f88b6ba6286495e`). The old
empty-content fallback emitted Elixir syntax and truncated arrays/strings; a
nonempty text summary hid structured output entirely. Jason encoding retains
complete data, while result metadata keeps the original MCP envelope and
`isError` keeps its ordinary tool-error meaning. Results without structured output
retain existing text/image projection. Embedded resources, resource links and
unknown blocks use complete JSON text, matching Codex's
`convert_mcp_content_to_items` fallback. The previous `inspect` fallback emitted
Elixir syntax and could truncate large content. The JSON fallback preserves each
block's fields, metadata and position among ordinary text blocks. Typed-media and
encrypted-content transport remain separate work; this change does not implement
those special result paths.

Two regressions first failed at the actual next Provider JSON read, then passed
through real root Engine and managed-child Sessions, stdio MCP, real Deno, another
turn/followup and Writer-flushed JSONL reads. They cover 80 entries, Unicode and
exact CRLF/whitespace, null/booleans, absent/empty content, structured output with
a text summary, and ordinary error/text results. Both the old fallback and the
old text-first precedence produced independently observed failures. Both journals
and MCP logs remain unchanged across repeated storage
reads. These regressions use a controlled Provider. Independent client and
full-BEAM restart acceptance is recorded below; online-model acceptance remains
separate.

Two additional root/managed-child regressions first failed on the non-JSON
fallback, then passed through direct and real Deno calls, another turn/followup
and Writer-flushed JSONL reads. They cover ordered text/resource/resource-link/
unknown blocks, the complete 80-entry payload, Unicode/CRLF, nulls, booleans and
namespaced metadata. Repeated journal reads preserve both files and MCP call
counts.

Two further root/actual-managed-child tests cover ordinary MCP `isError: true`
inside real Deno. Its JSON-safe result fulfills the Promise with `is_error: true`,
retaining all 80 records and the original envelope. The same JS invocation then
completes another MCP call, followed by direct calls in the current and next
turn/followup. Provider context and repeated Writer-flushed JSONL reads retain
the complete nested result without changing journals, MCP logs or call counts.
These seven MCP/discovery regressions originally covered JSON-safe MCP errors
separately from the native Error struct failure in #111. The latter now also
passes on 1.10.42 through the separate direct/real-Deno command-handle regressions.
No local encoder or dispatcher workaround is installed.

Independent clients exercised the real WebSocket endpoint and Chrome on temporary
port 4629, with a controlled Provider and the actual stdio MCP fixture. Each
client completed two root turns and an actual child followup: 24 root plus 16
child Provider requests and 16 MCP calls in total. All four Writer journals kept
complete direct and real-Deno JSON, including the 80 records, Unicode/CRLF,
nulls/booleans, ordered resource/link/unknown blocks and raw details. Chrome
created and sent its own session, reloaded between prompts, and displayed the
last record and mixed resource content in successful tool cards.

Protocol V1 ordinary events are bounded text previews. One 16,588-byte canonical
nested result becomes an exact 4,096-character prefix (4,380 UTF-8 bytes) in the
live event. Verification checked that projection separately and used actual
`session.dump` commands to obtain the complete host artifacts. Both submitted
turns ran once.
Complete artifacts were read locally from the returned host paths, rather than
streamed as full V1 event payloads. No protocol limit or product encoder changed.

The serving BEAM fully exited (PID 1776565) and a new BEAM (1786340) resumed both
clients. Protocol resume/attach/status, browser reconnect and dump reads added
no Provider requests or MCP calls. Four journals and the Provider log retained
exact bytes, hashes and nanosecond mtimes; the MCP log only appended connection
discovery/initialization. Both root dumps were byte-identical before and after
restart. Chrome remained connected, had no console warnings/errors or horizontal
overflow, and served JS matched the current static artifact. The temporary
service/page were closed; original port 4580/PID 815717 remained unchanged.
This is functional local-client evidence, without online-model or deployment
claims.

Image fidelity now uses 1.10.42's published #112 AI Codec. MCP accepts bare
base64 and existing data URIs without double-prefixing and retains
`_meta["codex/imageDetail"]` (`auto`, `low`, `high`, `original`, default `high`).
Responses builds typed result messages paired with the actual function/custom
call and delegates encoding to the public Codec. Native `view_image`, ordinary
MCP images, history and JSONL preserve optional detail and ordered media. Tool
previews accept existing data URIs; the separate user-upload policy is unchanged.
Unsupported audio/resources/links still fail the native Responses transport;
#108 remains only an Anthropic PDF URL subset.

Three dedicated functional files verify six cases through real HTTP, stdio MCP,
root/managed-child direct and real-Deno calls, later turns/followups and journal
reopen. Deleting the original PNG before root reopen proves historical images
come from persisted results. Provider context projection and canonical journal
metadata are checked separately; the existing metadata projection is unchanged.

On isolated port 4630, an independent Protocol client and a newly created Chrome
session each exercised root Goal3, board, a real managed child, native/MCP images
and real Deno. The clients produced 34 Provider requests and eight MCP tool calls
across four journals. Full `session.dump` preserves ordered image detail and the
complete MCP envelope; Protocol V1 bounded events remain a separate projection.
Chrome loaded all three tool-card images, with no console warning/error or
horizontal overflow. Served JS matched the current local artifact.

The complete serving BEAM exited (3729854), then a new BEAM (3736894) resumed both
clients without a new prompt. Public Agent Goal reads returned complete with 208
tokens used for each root and a completed child. Provider requests stayed at 34,
MCP tool calls at eight; MCP initialization appended normally. All four journals,
Goal/board/Runtime files retained their exact bytes and nanosecond mtimes; the
skill-invocations sidecar retained identical bytes with a refreshed mtime. Full
Protocol dumps were byte-identical. Chrome reloaded and decoded all images.
The owned 4630 service/page were stopped; original 4580/PID 815717 was untouched.
This controlled local-client acceptance does not establish online-model or
storage-failed child recovery, release or deployment acceptance.

## Entry-point acceptance and remaining work

Protocol `session.resume` recovers legacy skill-invocation records through
`SkillInvocationStore.recover/2`. Recovery previously rewrote every ledger,
including `[]`, and created an empty file when none existed. It now compares the
recovered records under a per-session local `:global` transaction and writes only real
preparing/queued/running → interrupted transitions. Missing, empty and terminal
ledgers stay untouched, preserving raw JSON whitespace, original fields and file
identity. Real transitions keep the existing ordered records and atomic writer;
the second recovery is a read.

Three functional regressions first reproduce the old writes. The initial combined
run also exposed a caller-lifecycle defect: the first caller owned a shared ETS
lock table, so its exit could crash an unrelated session's operation when releasing
its lock. A fourth public-API regression holds an actual recovery read with a FIFO,
joins the completed caller's exit, then completes the read. It first reproduces the
exact `:ets.delete` failure. Per-session local `:global.trans` now owns mutual
exclusion, following the existing session-store convention, without a caller-owned
table or polling loop. The atomic writer and idempotency-conflict behavior remain.
All seven checks pass asynchronously in source (seed 43194); the initial serial
six-case run (seed 43190) is historical. The original direct Protocol and WebSocket
resume cases pass separately by exact location (seeds 43195 and 43196).

The ledger-idempotence 1.10.51 production archive is independently extracted and its assembly
moved away. Public BEAM code identity matches the current prod module; raw file
equality is inapplicable because release assembly strips BEAM debug chunks.
Both original sessions each resume twice through actual Protocol, and Chrome
loads/reloads the original browser session. All 23 selected durable files retain
bytes, SHA256, nanosecond mtime and inode; the absent browser invocation ledger
remains absent. Each client retains six complete results and the original Goal
settlement. Provider/hook/Events execution does not repeat. MCP reconnect adds
only the same two discovery/subscription/tool-list sequences. Chrome is connected
without overflow or console warnings/errors; served scripts match the package.
This supersedes the prior package's 22-of-23 metadata result without rewriting
that historical observation. Dev/test/prod strict compilation, scoped formatting
and diff checks pass. Owned service, fixture and tab are closed; 4580 is unchanged.
Evidence: `/tmp/sigma-skill-recovery-4kpxqdhj/client-acceptance.json`,
`package/archive.json` and the functional logs. An initial attempt selected an old
release-build cache and stopped at dependency-version checks; the current prod
cache was verified as 1.10.51 before successful compilation and assembly. No
dependency or lockfile was changed.

The subsequent lock-fix archive is independently extracted with its assembly moved
away. All seven unchanged store assertions pass against its actual production
BEAMs (seed 43197, 32-case concurrency); the loaded module path and public BEAM
code identity match the current prod build. A separate package BEAM repeatedly
resumes both original Protocol sessions and reads six complete results per client.
All 23 durable files and the Provider/hook logs retain bytes, SHA256, ns mtime and
inode; the absent ledger remains absent and original Goal identity/settlement
remains exact. Only two MCP discovery/subscription/tool-list sequences are added;
no Provider/hook/Events execution repeats. This lock-only change did not repeat
Chrome; its preceding ledger-only package acceptance above remains separate.
Owned service and HTTP fixture are joined and stopped; 4580 is unchanged. Evidence:
`/tmp/sigma-skill-recovery-4kpxqdhj/package-lock/{archive,packaged-contract-acceptance,client-acceptance}.json`
and `lock-{red-raw,green}.log`. No dependency or lockfile changes are required.

The earlier 1.10.42 functional selection passed 56 cases (seed 261055), including
actual-child receipt recovery and preparation failure cleanup. Development/test
warnings-as-errors compilation, 40-file formatting and `git diff --check` pass.
Injected storage failures retain their actual shutdown uncertainty diagnostics.
That bounded selection excluded safety, permission and sandbox checks. During
the 1.10.43 continuation a worker mistakenly ran two whole mixed test files,
including permission cases (90 tests, six failures). The user was informed, the
worker stopped, and no security/permission source or tests were changed. That
selection is not repeated or represented as functional-only verification. The
older exact-key metadata failure predates this candidate and is left untouched.

Earlier 1.10.43 live-recovery verification passed 134 tests across 18 functional-only
files (seed 43131), plus six native-child lifecycle and two hosted-tool cases
selected by exact test line (eight passed, 17 excluded; seed 43132). It includes
ordinary shutdown and live next-prompt recovery, cancellation during retirement,
receipt persistence failure, resource release, remaining queued followups and
retry-context restoration. Two initially failing existing regressions were
reproduced with the pre-live source in a separate BEAM and fixed without changing
their assertions. Dev/test warnings-as-errors, scoped formatting and diff checks
pass. Actual WebSocket/browser live recovery and cold-BEAM evidence are described
with the lifetime controller above. The separate #127 released-admission and
#128 failed-readiness characterizations were historical failures; 1.10.45 consumer
acceptance above supersedes those specific results without extending the older
browser or production-package evidence to this version.

The earlier 1.10.45 combined selection executes 80 cases across 12 functional-only
files (seed 43153): 75 pass and five retain the original upstream failures, three
child-resource cancellations at #131, one ordinary Error archive at #126 and one
idle archived-child transfer at #133. All new unstarted-admission, exact-DOWN,
cancel/supersede, persistence-only retry, delayed-cancel error preservation,
legacy Goal read/fork and readiness/Deno/history cases pass. Dev/test strict
compilation, 16 scoped formatting checks, the five-entry lock audit and final
diff checks pass. A fixture teardown race now joins the exact Session DOWN;
its original cleanup-failure assertions remain unchanged. The 662-file baseline
has 19 authorized existing files changed and two new functional tests; the other
643 files are identical. No new browser or 1.10.45 installed-release acceptance
is claimed. The original port 4580 service remains unchanged.

The admission-recovery batch adds five functional cases. The four real-Engine
admission/mutation cases failed against the original source; after integration,
all five pass, including the separate indexed-run boundary. The final eight-file
Goal selection passes **44 cases** (seed 43155). An expanded ten-file selection
runs **65 cases with 16 failures**: three child-recovery cases and thirteen
lifetime-recovery cases. Repeating the two affected files against the exact
pre-change Agent/Coordinator/Integration source produces **21 cases with the
same 16 failure names**. The current source was then restored and verified.
These failures are retained, not excluded from the alignment completion gate;
the 44-case selection isolates the successfully verified changes. Counts overlap
the earlier selections and must not be added.

The live-manager consumer now breaks that ordering cycle with explicit stages.
Both close entrypoints first run execution retirement as its own job.
`Subagents.close_execution` returns only actual native/child acknowledgements and
retains the manager, Session/Registry, CodexResources and LifetimeRecovery owners.
Full-close waiters continue in a separate job, so archive failure or completion
task death cannot replace an already committed execution result. RootRetirement
uses this first stage to persist independent hooks and SessionEnd facts.

Web and Protocol `turn.cancel` use `Subagents.close_execution` when the root turn
has finished and children remain active. Stop therefore waits for actual child
execution retirement while retaining the owners required for later Goal ACK and
archive completion. The host saves the actual `execution_result` on failure as
well as success; a retirement-file write error retains its original `:eisdir`
cause and leaves closure unconfirmed. Protocol keeps its existing public
`runtime_error` projection. A repaired write can complete retirement without
another Provider call. This cancellation path does not retire root hooks or
SessionEnd, or satisfy the full file-operation gate. The no-live-Agent
`Runtime.close_subagents` fallback still performs full close.

SessionLive now projects the actual cancellation result: `cancelled_children`
preserves the root's completed phase, `already_cancelled` selects cancelled,
and an ongoing cancellation selects cancelling. An actual command error displays
the existing public error message and preserves the phase. Previously a completed
root could remain on “Cancelling…” indefinitely after its children stopped.

Admission then recovers original Goal receipts and their exact Store ACKs. Full
`Subagents.close` refreshes the public child → manager → captured root Session
acknowledgements before exporting archives. Only then does it stop the retained
Session and retire LifetimeRecovery. Generation-correlated acknowledgements save
the completed archive and Session-stop stages before continuing; a later failure
retries only the remaining owner finalization. Original export errors remain
separate from execution confirmation. Both generation replacement paths require
full closure.

Agent component retirement facts and `completion` are independent. Explicit
retirement and session-operation release complete this gate outside the Agent
callback; reopening requires completion and preserves the old host/error if it
fails. Repository rename/adopt/delete keep Goal alive through required child
accounting before retiring Goal/Store or moving files. Root-only retirement leaves
ordinary root recovery to its existing opening/admission boundary. Failed Goal
preparation without a Conversation still fully closes its reserved Session.
Graceful shutdown attempts the live archive gate before the original owners stop;
active or unconfirmed shutdown retains its real recovery boundary.

The preceding staged-retirement batch's nine-file Goal/root selection passes
**51 functional cases** (seed
43156). Four additional stage-boundary cases pass, including blocked archive
completion with independent execution confirmation, exact Goal-write failure and
retry, operation reopening, and actual Runtime rename after failed-child accounting.
An expanded three-file child/archive selection runs **30 cases with 18 failures**:
all sixteen earlier failure names remain, plus the new complete live-flow case
and the existing ordinary Error archive case. Eleven still call full close with
pending Goal delivery obligations; six reach final root completion after archive
restore; one retains #126's Error normalization failure. The original assertions
are unchanged. A public-only trace proves successful restore and Registry transfer,
then #133's `MultiAgent.transfer_ready`/`Session.prepare_detach` refusal. Passing
stage boundaries do not establish these full flows. The four stage cases overlap
the thirty-case selection; counts must not be added across runs.

A subsequent source/log/public-trace audit classifies the eleven direct-full-close
failures as archive-before-Goal-ACK conflicts. The original cold cases deliberately
keep delivery obligations until after shutdown; replacing them with live ACK
would change their coverage. Preserving that guarantee across manager retirement
requires #134's public offline completion contract. Of the six final-root failures,
one has the exact public #133 trace described above; the other five use the same
restore path but have not each been independently traced. Generic cancelled or
unknown-outcome output does not by itself prove #133. The remaining Error archive
failure is #126. This audit establishes no additional independent Sigma production
fix for those eighteen cases and does not replace their full assertions.

An adjacent command/environment/plugin selection runs 13 cases with one failure
in the standalone plugin fixture's on-exit `GenServer.stop`, which races a real
Session shutdown. That file and PluginRuntime are unchanged in this batch; the
failure is recorded without expanding the fixture or changing its assertions.
Evidence is under `/tmp/sigma-archive-stages45-xvd3049x`. No new browser,
installed-release or online-model acceptance is claimed.

The detached-Stop batch uses seed 43157. A twelve-file Goal/root, Provider,
environment and command selection passes **63 functional cases**. The integrated
lifetime selection executes **six cases** (four existing stage cases and two new
cancellation cases; 23 discovered, 17 excluded), and SessionLive executes **two
new cases**. They verify exact Provider DOWN, retained owners, unchanged root
state, later full retirement, real retirement-file write failure, preserved
cause and repair. The expanded child/lifetime/archive selection runs **32 cases
with 18 failures**: the exact eighteen failure names from the preceding 30-case
run remain, with no added or missing failure names. Original assertions remain
active; these overlapping selections must not be added as distinct case totals.

An isolated service on port 4685 also accepts actual Phoenix `/agent` WebSocket
commands and Chrome's New Session → Send → Stop subagents flow on 1.10.45. Browser
acceptance first reproduces the stuck cancelling phase, then confirms Completed
after the fix. An actual child retirement-file failure displays the public error,
preserves Completed and leaves execution/archive unconfirmed; after fixture
repair, explicit host retirement completes. Four sessions across these flows
record twelve actual controlled-Provider calls and twelve matching observed
DOWN facts. Two owned full-BEAM replacements, Protocol reads/resume and browser
reload make no additional Provider calls. On the second cold read all ten
journal/log files retain exact bytes and mtimes, and the served asset hash
matches the local build. Both pages are connected without horizontal overflow
or console warnings/errors. The isolated service and pages are closed; the
original port 4580/PID 815717 remains untouched. Evidence is under
`/tmp/sigma-cancel-stages45-vvuyjawz`, including the cold-read comparisons and
failure-name comparison. This is local controlled-Provider/client acceptance;
it does not establish online-model, installed-release, deployment, #133 idle
continuation or #134 offline archive completion. Passing assertions retain
expected fixture/cleanup diagnostics in their logs.

Public #134 staged export now supports orderly shutdown before pending Goal
receipts can be acknowledged. `RecoveryJournal` commits the actual command input
atomically inside each authoritative Runtime snapshot, with explicit revision and
incarnation transitions. Public reads convert only Sigma's known Message and
ProviderStopReason value types without dropping fields; original records remain
unchanged. Legacy records never gain a fabricated admission prefix. The Provider
adapter passes an atom stop reason to the public Lifecycle and retains the raw
reason in its original message.

After actual execution and independent root components are confirmed, failed
strict archive completion remains an error. Orderly termination separately queues
`Subagents.stage_shutdown` behind existing preparation/close/resync jobs, then
uses public `MultiAgent.stage_child_export` for every eligible unarchived child,
deepest first, while its manager and evidence writer still exist. Success records
an immutable stage, never full completion. Completed or aborted completion-task
shutdown branches use the same gate and do not redispatch SessionEnd. Stage errors
are reported independently of the original completion error.

Cold Goal recovery redelivers actual receipts, commits exact Store ACKs and
refreshes descendant-first lifetime receipts. Before parent-first archive restore,
`ChildArchives.complete_staged` calls public `MultiAgent.complete_child_export`
without the old manager. Missing stages may be absent; once a selected stage exists,
missing receipt or completion evidence propagates. Exact stages, complete command
prefixes and public suffix validation preserve original history and attribution.

Actual cold Goal usage/ACK faults, nested descendants, original pending bytes,
owner DOWN, same-child followup, an independent fresh BEAM, queued-stage shutdown
and a completed-but-unconsumed retirement Task are covered. Strict live/file/new
admission gates still require full archives. Abrupt loss before any durable stage,
legacy missing evidence and unrelated uncertain execution remain errors.

For the preceding admission-recovery batch, dev/test strict compilation and
formatting of the four changed Elixir files pass. Its 664-file baseline has seven
existing files changed and
one new functional test; the remaining 657 files are unchanged. No dependency
lock entry, archive executor, security/permission feature or related test changes
in this batch. No new browser, installed-release or full-BEAM admission-failure
acceptance is claimed; uncommitted no-start reservation recovery still requires
the live Goal owner.

The staged-retirement batch also passes dev/test strict compilation, formatting
of its six changed Elixir/test files and diff checks. Its 665-file baseline has
ten existing source/test/document files changed; the other 655 files and all
dependency lock entries are unchanged. These checks do not extend the earlier
browser, cold-continuation or installed-release evidence.

The detached-Stop batch passes dev/test strict compilation, explicit formatting
checks of its five changed Elixir/test files and final diff checks. Against its
665-file baseline, eight authorized existing source/test/document files change
and one Web functional file is added; the other 657 files and `mix.lock` remain
identical. The canonical Agent Note is revision 75 with exact readback; both
original removed-tool chapters, title, labels and attachments are preserved.
The final 2026-10-27 21:33 Asia/Shanghai upstream check still finds Hex 1.10.45
and open #126/#131/#133/#134. No dependency update occurred in this batch.

The earlier 1.10.44 functional selections execute 59 distinct cases: 54 pass and five retain
upstream failures. Resource/PluginRuntime14 has three child-interruption failures
(#131); archive/handoff7 has one ordinary Error export failure (#126); eight
ChildIO/MCP cases selected by exact line pass; plugin21, Protocol4 and Web5 have
one idle-archive parent transfer failure (#133). The new explicit host-reconciliation
case first reproduced the local cache regression, then passed with the original
native failure fact unchanged. The additional real-child stdio helper-crash case
passes while preserving actual aggregate unconfirmed diagnostics. These counts
do not add repeated runs or historical
selections. Dev/test strict compilation, 26 scoped Elixir formatting checks, exact
13-entry lock audit and diff checks pass. The 661-file preservation audit finds
only the 28 authorized existing files changed, plus one new functional handoff
file; unrelated content remains identical. Two-BEAM archive acceptance and public
lifecycle traces are described above. The separate local Linux production archive
and installed plugin-component check also passes. Remote CI, other platforms and
online-model acceptance have not run.

The earlier 1.10.43 assumed-fix preparation had a separate 37-case functional selection
(seed 43141): 31 pass and six fail on locked 1.10.43. Three failures preserve the
actual #128 startup cause assertions through Readiness/Control; the other three
are normal-child rename, Goal-accounted rename and plugin-child cold reopening
at #126's archive boundary. The Goal case first verifies the actual child charge
and an empty committed usage outbox. All assertions remain active. The dedicated
PluginRuntime selection passes six cases, including partial-start cleanup.
An adjacent 26-case functional selection also passes, while teardown still logs
the actual #126 unconfirmed retirement; passing assertions do not establish
confirmed aggregate closure. These selections overlap prior evidence and are not
added to historical test totals.

The earlier 1.10.43 combined functional verification passed 93 tests across 13
functional-only files (seed 43121), including lifetime recovery and existing file
operations. Rename exposed a route-name/header mismatch in the new writer; the
writer now follows the actual immutable journal header, and all eight file
lifecycle regressions pass. Separate native-child verification selects only the
six functional cases (six passed, 11 excluded; seed 261146). The transient-child
receipt failure now requires the aggregate generation to remain unconfirmed with
the same actual cause and retains the evidence owner until close succeeds; no
closure requirement was relaxed. Excluded mixed cases are not run.

Earlier controlled-provider integration tests exercised real Engine, stores, permission
interception, native patch/plan/command backends, UI waiters and JSONL. LiveView
and Channel tests cover refresh, question resolution, permission approval,
actual file creation and late-answer rejection. Separate Chrome acceptance uses
an isolated local server and a real external WebSocket client. These checks do
not establish compatibility with a live commercial model or an already running
older development process.

Remaining families and the full 27-extension inventory are enumerated in the
[active checklist](../superpowers/plans/2026-10-24-codex-tools-alignment.md).
Remaining work includes additional environment types and command platforms,
archived-child plugin discovery whose new inventory exceeds its original ceiling,
abrupt loss before a durable export
stage, missing legacy
lifetime facts or unrelated unfinished execution, and the board raw argument
envelope. Native installation completion, controlled per-component plugin close
reports, root resource cancellation and Goal-accounted archive followup now have
consumer evidence described above. Effectful pre-Runtime Goal settlement (#145)
is implemented and accepted on 1.10.51 as described above.
All 27 extensions are now registered
where their actual root/child hosts apply; registration alone does not complete
the remaining behavior and platform acceptance. Dynamic permission development/tests remain excluded
by the current scope. Skills, context controls, Plan projection, all four Memory
tools and all nine History/Notes tools are integrated. Unsupported/unconfigured capability is not advertised
as completed from inventory names or the transitive plugin dependency.
The external `web::run`/`image_gen::imagegen` backends, actual plugin-registry
selection, remote encrypted History and `notes.thread_hint` remain user-deferred
TODOs, outside this phase's completion gates. Local History4/Notes5 and configured
plugin lifecycle work retain their scope.

`wait_for_environment` now binds the selected local workspace lifecycle to actual
command-runtime startup. CodexResources creates an environment ID for its resource
generation and initially records `starting`. Its PlainCommand server starts
asynchronously but performs the same real LocalCommand initialization and existing
Native capability checks before accepting commands. The separate resource owner
receives that result and publishes `ready` or `failed`; no shell probe, fixed-ready
callback or extra workspace provisioning is used. PlainCommand's default standalone
startup remains synchronous. Pending commands queue on its server, and a failed
startup returns the original typed error to command calls.

The public Control/Readiness callback reads the current resource owner. Root Engine
and ChildIO append its actual `<environment_context>` to every Provider request,
including custom prompts, and use the same projection for token accounting.
Successful turns and child followups retain the ID; closed resources require a
new startup and ID. Journal recovery preserves tool results, never a live environment.
With 1.10.45's published
[#128](https://github.com/gsmlg-opt/backplane/issues/128), failed startup immediately
returns execution_failure with the exact environment ID, original startup class
and a UTF-8 reason bounded to 256 bytes. Closed/unavailable environments return
not_found; starting still waits with the existing timeout/cancel semantics.
Control presents terminal errors as ordinary is_error results rather than
aborting the native call. The actual PlainCommand validation failure passes
through Readiness, Control, a native root Conversation and real Deno, after which
a native Plan still runs. Writer/Log retain the complete paired tool-call/error
history. The failed-state callback uses that actual startup error; this is not
full Engine startup-failure injection, and no production injection boundary or
local readiness replacement was added. The environment describes the local
command host; PTY helpers still start per job. Permission/sandbox development and
tests remain outside the current scope.

`tool_search` uses the published metadata search and owner-fencing fixes from
[backplane#87](https://github.com/gsmlg-opt/backplane/issues/87) and
[backplane#88](https://github.com/gsmlg-opt/backplane/issues/88).
The published 1.10.36 fixes have passed a public DynamicRuntime check: description
metadata finds the candidate, and distinct caller/run/incarnation owners stage it
without collisions. This checks staging, not actual Conversation publication.
Root Engine now snapshots actual connected MCP definitions into deferred
contracts through ToolCatalog, retaining the existing Dispatcher callback. It
does not admit those names eagerly at the same time. CodexResources prepares one
DynamicRuntime inventory per binding, with a candidate cap covering the complete
snapshot; a new run replaces it only after public Session.bind succeeds. Search
selection does not require MCP resource clients. Publication becomes active at
the outer batch boundary. The existing Provider handshake refreshes host catalog
revision/tools before context accounting and the next request; guessed same-batch
calls remain unauthorized. Legacy non-native sessions stay eager; managed native
children snapshot only inherited, already committed connected functions and use
their own public discovery inventory.

Actual public Conversation checks passed ordinary and real Deno publication,
repeat search and subsequent execution. The old 1.10.36 trusted settled-error
fixture exposed #97 candidate consumption after a discarded staged publication.
The fix is published in 1.10.37 and retained in 1.10.38. A separate
functional ChildIO/public Session fixture now injects a test-only ordinary outer
contract through the existing `prepare/5` contract argument. Its nested search
stages a candidate before an explicitly settled outer error. The next Provider
sees no catalog advance; same-run direct search then republishes the complete
definition, and Dispatcher executes one real MCP call. Canonical history retains
the outer error, successful search and actual result. No production API or
settlement is changed. The shipped root and managed-child catalogs have no
ordinary outer-error trigger after nested search: only Code Mode consumes nested
dispatch, and a normal JS return remains a successful outer result. A real Deno
exception is an uncertain outcome that terminates the run; post-hook presentation
does not change the actual outcome used for publication. Same-run root/tree
discard recovery is therefore not applicable to the current product inventory.
If a real nested-dispatch tool with explicitly settled outer errors is introduced,
add its product acceptance then. The standalone fixture does not establish that
product path. No injection API, local search engine or private Runtime reset is
installed.

The published [backplane#89](https://github.com/gsmlg-opt/backplane/issues/89) fix
has passed a public Conversation check: identical async questions in the same
step expose distinct nonempty tool-call and invocation identities. The same
check confirms acceptance without subscriber processing, including no subscriber.
`accepted: true` alone does not promise durable user receipt in either backend.
The host now implements a separate durable inbox/reply path, described below;
synchronous question waiters remain a different lifecycle.

### Durable async interactions

Native root sessions with a Writer admit `request_user_input_async` and
`send_message_to_user_async`; managed children and writerless sessions omit them.
`AsyncInbox` treats live Runtime events as hints. It captures a card only after
the exact run/incarnation/invocation/call matches a consumed successful execution
intent and tool result in the public Store. Recovery considers only root runs
anchored in the selected raw journal ancestry and never executes effects.

`Sigma.Protocol.AsyncInteractions` is the pure lifecycle reducer. Writer persists
`received`, `reply_saved`, `dispatch_started`, `admitted`, `runtime_admitted`,
`consumed`, `dismissed` and `delivery_unknown` facts before acknowledging projection changes. Every
mutation checks trusted session identity and expected leaf, including idempotent
receipt reuse. Corrupt facts block further inbox writes. Global validated facts
remain available for deduplication, while selected cards exclude off-branch
origins and any card with lifecycle facts on a sibling branch. This prevents
cross-branch answers and duplicate redispatch; returning to the original branch
restores its original status and receipt.

The projection retains global receipts without lifetime card/fact ceilings;
replay covers 2,051 cards and 4,100 facts. Per-fact limits remain 128 KiB except
`reply_saved` at 384 KiB. Replies separately bound each answer to 32 KiB, aggregate
answer text to 96 KiB, its encoded strings to 128 KiB and the complete contextual
reply to 256 KiB. Full question titles and ordered original answers are retained.
These durable budgets are independent of Protocol V1's smaller wire limits.

Inbox facts are auxiliary siblings, including in branch-summary projection. They
never create alternative executions or displace the active conversation leaf;
real fork/retry branches remain visible.

The file-backed runtime Store prepares the deployed atom vocabulary before its
first safe ETF read. It loads module inventories from a fixed set of Backplane
protocol and Sigma host application specifications, then loads that code without
starting applications. Module loading can execute `@on_load`; the current selected
source trees contain no such callbacks. Application/module load failures stop the
Store. Record contents never select modules or create atoms, `[:safe]` decoding
and envelope/revision/incarnation validation remain unchanged, and no format
migration is needed. Dynamically created or removed historical vocabulary is not
implicitly admitted. A separate fresh-BEAM test reads an actual completed
Conversation snapshot exactly and rejects a unique unknown atom without adding
it to the atom table; restarting a GenServer in one BEAM cannot prove this.

The long-lived Agent saves a complete ordered reply, records dispatch intent,
then admits it as steering during active work or as a new prompt while idle.
Host-generated message IDs and correlation metadata cannot be chosen through
ordinary prompt options. Engine records the public prompt/steer admission in a
`runtime_admitted` fact containing `reply_id`, `run_id` and `runtime_message_id`;
the projected immutable `delivery` holds the two destination IDs independently
of status. Engine restores the trusted canonical user before Provider context
construction. Consumption requires both the selected canonical user with exact
correlation/destination run and the public Store's checkpoint message with that
Runtime ID and complete matching content. Journal-only correlation, an idle
reply appended before failed Engine preparation, or a queued steer checkpoint
cannot prove consumption. Missing records are unconfirmed; other Store errors
propagate. An interrupted admission without that evidence becomes
`delivery_unknown` and is never automatically redispatched. Explicit retries
reuse confirmed receipts or preserve uncertainty.

The initial prompt hook retains the Runtime-supplied ID while restoring the
complete host message, including attachments and metadata. Engine's existing
Runtime-to-canonical map restores Provider context. Replacing the ID with the
canonical journal ID had made an actually delivered idle reply look unknown;
the exact admission/checkpoint requirement remains unchanged by this fix.

Cancelled/failed origins dismiss open/saved questions. Recovery also checks
validated host `turn_finished` auxiliary facts whose parent is on the selected
ancestry and whose session/run match the card: the host can fail after Runtime
already completed. Disk failures propagate and a later refresh retries the
durable close. Completed questions remain answerable, and notifications are not
closed merely because their originating turn ends. Dismissal closes a card
without cancelling the agent's current work.

LiveView displays complete batches, optional notice replies and distinct
saved/queued/received/unknown states. Reload loads the current durable inbox.
The `async_interactions.v1` protocol carries full ordered cards, strict
reply/dismiss commands and separate acknowledgements; legacy subscriptions
receive neither new snapshots nor events. Final wire envelopes are validated
without truncating questions or replies. This legacy mode requires the complete
snapshot to fit the 64 KiB envelope, 200-entry collection and 32 KiB string limits.
The mutually exclusive `async_interactions.pages.v1` mode replaces complete
snapshot fields with a selected-view SHA256 descriptor. It lists bounded
summaries and reads recursively sorted complete card JSON in 12 KiB base64
chunks, checking the current revision on every query. Branch/status/content
changes reject earlier reads; queued notifications only invalidate a client's
view. Summary pages shrink to fit actual wire bytes. Overflow requires a validated
snapshot bound to the attached Agent/session and async mode before delivery
resumes. A successful mutation retains its disk acknowledgement even when the
subsequent snapshot fails. No wire limits are enlarged.

`AsyncReplyUploads` adds the optional `async_interactions.uploads.v1` capability,
requiring paged inbox mode. Each Agent owns up to eight volatile buffers of at
most 256 KiB with a fixed five-minute monotonic deadline. Raw 12 KiB chunks append
contiguously; exact contained byte retries are idempotent, and final length/hash
must match. Chunk receipt never invokes reconciliation or Writer/Provider effects.
An explicit commit decodes complete JSON and validates the full original reply
against the current visible card before entering the existing save/admit path.
Session/selected-leaf/item fences are checked on every chunk and commit; the
leaf is not immutable buffer identity, so exact commits can retry with a fresh
current leaf after conversation progress. Cancellation drops only staged bytes.
Complete buffers remain bounded for receipt retries; restart loses them and
requires reupload, then durable deduplication still prevents another dispatch.

A missing `admitted` disk acknowledgement after real dispatch returns an explicit
error with the existing durable `dispatching` receipt and requests a snapshot;
it cannot report confirmed admission or lose acceptance. Unknown deliveries with
no saved reply reject new answers rather than fabricating an acknowledgement.
These rules cover ordinary replies as well as upload commits. See the protocol
contracts for [paging](protocol-v1.md#paged-async-inbox) and
[reply upload](protocol-v1.md#chunked-async-replies).

### Provider-hosted search

`HostedTools` negotiates public `Codex.Hosted` declarations and observations for
OpenAI Responses. Provider or selected-model `hostedTools.webSearch` must
explicitly declare support and enablement; the model's complete map replaces
provider defaults. The capability defaults off, and managed children strip the
root option. Cached/indexed/live configuration remains native. No local registry
entry, grant or fabricated tool-result message represents hosted execution.

`OpenAIResponses.Hosted` validates ordered native search/message/function/custom
and reasoning items, progress identity, action consistency and URL-citation annotations. It
retains the complete `openai_responses_hosted` envelope in assistant metadata,
bounded to 128 items and 1 MiB aggregate native data. Replay requires the same
provider, model and normalized actual Responses endpoint fingerprint, as well as
canonical text/call consistency; mismatches fail before HTTP. Native replay
counts once toward context accounting. Explicitly unknown usage counters remain
nil through JSONL decode and Writer reopen, rather than being replaced by zero
or making a valid hosted response unreadable.

Every output item from enabled hosted turns is retained in native order,
including reasoning summaries/encrypted content and turns without a search call.
Unknown item types are rejected rather than silently filtered. Opaque reasoning
does not become visible assistant text or a fabricated local tool result.
Actual HTTP fixtures verify interleaved reasoning/search/reasoning/function/text,
JSON persistence and exact subsequent input with tool output; production Engine
fixtures also verify followup and Writer reopen. This does not extend general
non-hosted reasoning transport.

Metrics JSONL encoding preserves null and boolean primitives before converting
other atom labels to strings, recursively through containers. This keeps unknown
usage/identity values identical in live and reloaded request summaries; it does
not fabricate counters or rewrite existing journal records.

LiveView projects ordered, deduplicated validated HTTP(S) citations through
escaped DuskMoon links. Raw progress observations are transient; terminal native
metadata is durable. Controlled actual HTTP/SSE and Runtime tests cover native
declarations, observation, origin rejection, followup and reopen replay. These
checks do not establish online-provider authorization or deployment.

Protocol clients opt in with `provider_hosted.v1`. Live messages and selected
snapshot summaries expose only the complete hosted metadata key, while
`provider.hosted` carries validated unaltered search observations and the normal
cursor/session/turn identity. Legacy subscribers receive neither. The final
64 KiB envelope, nesting, collection and string limits remain unchanged. A
capable hosted snapshot bypasses the legacy compact-message fallback: complete
data either fits or yields explicit hosted bounds/rejection errors. Final
attachment/cursor fields participate in validation inside activation, before the
relay becomes ready or publishes queued observations. Failed attachments clean
their relay, and failed queries on an existing subscription retain it. Transient
observations are not replayed from history.

Large durable output is available through the mutually exclusive
`provider_hosted.pages.v1` mode. `ProtocolHostedResults` captures the actual
Writer-selected raw journal once (or the stopped session's persisted branch),
then decodes complete source messages independently of compaction/context/display
projections. `HostedResultPages` validates each full native envelope, hashes
canonical JSON and binds the directory revision to trusted repo/session, leaf,
ordered entry/message IDs and content hashes. List/read commands return bounded
summary pages and 12 KiB base64 chunks, with final Codec validation. Stale views,
foreign/sibling source pairs and malformed metadata fail explicitly. A live
Agent missing its Writer cannot silently fall back to disk. Stopped reads do not
start an Agent or invoke Providers/tools; read-only access never writes the
journal. Mode changes on an attached relay are rejected. Committed-result
invalidation hints request a fresh snapshot; this mode does not send or claim
recovery of transient raw observations. Full fields and retry rules are in
[Protocol V1](protocol-v1.md#durable-hosted-result-pages).

The actual HTTP boundary previously inherited the portable SSE framer's 256 KiB
frame limit despite accepting up to 1 MiB native metadata. Explicit hosted-mode
framing now permits that native limit plus bounded outer framing (1 KiB), with
a finite two-frame buffer. Native aggregate/item limits, complete origin/content
validation, ordinary Provider framing and Protocol wire limits are unchanged.

### Message-board state and durable writer

`MessageBoardState` implements a pure, JSON-serializable reducer for the nine
board operations. Trusted host metadata supplies stable root/agent identities,
membership paths, time, post UUID and logical invocation identity. State retains
channels, posts, separate channel/thread subscriptions, explicit opt-outs,
accepted-call metadata and a permanent-delete tombstone. Retrying an accepted
call returns its saved metadata with no second notification intent. Queries use
Unicode scalar offsets, full case-fold substring search, pinned ordering and
bounded offset cursors. Results stay within 8000 encoded bytes; shrinking a page
also regenerates its cursor, and mutations check acknowledgment capacity first.
Concurrent insertion can shift offset pages, as in the pinned Codex backend.

`MessageBoardStore.open/1` now obtains one application-owned writer per absolute
root transcript using the existing DynamicSupervisor/Registry. The immutable
JSONL root ID is supplied by the host; the board lives at
`<root_transcript>.subagents/message_board.json`. Each call rereads actual JSON,
then applies the pure operation. Opening and reading an absent store create no
files or directories. Changed states use existing Store.FileSystem file-data sync
and atomic same-directory rename. Unchanged reads and accepted-call retries do
not rewrite the file. The writer serializes calls in one BEAM; it does not claim
distributed exclusion or parent-directory fsync.

Only a confirmed commit returns transient notification intents. An exact accepted
retry returns its durable result and no intents, including after a real rename
whose acknowledgement was lost. Failed write acknowledgements retain typed
`unknown_outcome` with the original storage cause; the host does not automatically
retry effects or notifications. Eight functional cases cover concurrent root/child
updates, close/reopen, unchanged retry hashes/mtime, full Unicode/CRLF pagination,
persisted opt-outs, precommit failure, committed-but-unacknowledged writes and fresh
disk reads. These eight cases establish the storage-host boundary; production
registration and notification delivery have separate acceptance below.

RepositoryProcess now retires the application-owned writer after existing child
closure, Writer flush and terminal drain, before rename/adopt/delete touches files.
The queued retirement drains accepted board calls and confirms normal process exit;
the transient child specification prevents a normal stop from restarting the old
path. Abnormal retirement preserves the actual cause and blocks the file mutation.
Failed file operations leave durable bytes/receipts intact and permit reopening
the same header ID. Rename/adopt preserve header identity; recreating the old path
can open a fresh header. Fork keeps the source writer and starts an independent board.
Seven functional cases exercise the real Runtime entrypoints, including a held
commit draining before rename and failure before file mutation.

`MessageBoardResources` registers all nine tools under `collaboration::` in
root and managed-child profiles. Each call uses the actual public Session,
Subagents membership and immutable root Writer header. Public MultiAgent active
notifications run after the durable commit and outside the Subagents lock, using
exact manager/agent/run/incarnation identities and stable post/recipient IDs.
A notification failure logs its actual reason while preserving the successful
post result, matching Codex's best-effort behavior. Neither effect is retried.
Idle recipients do not start or receive queued substitutes. #110 expires accepted
but unconsumed notices before a later followup; consumed notices can remain in
history. Ordinary queued messages retain their independent behavior.

Five production cases exercise all nine root tools, real Deno, complete Unicode/
CRLF and pagination, root-to-child, child-to-root and sibling notification
consumption/expiry, ordinary queued messages, and actual post/reads after rename
and independent fork. Seven lifecycle cases separately cover file operations and
writer retirement. The original 128 KiB raw argument envelope remains missing:
the reducer sees compact decoded arguments and cannot recover discarded raw
whitespace. This batch does not expand safety/permission development for that gap.

### Command sandbox preparation outside current scope

The accepted default policy is a writable workspace, isolated home and denied
network. `sigma-sandbox-launcher` implements a Linux x86_64 host-only config:
openat2-anchored workspace/cwd/runtime mounts, private user/PID/network/IPC/UTS
namespaces, dropped capabilities, a private home and cleared environment.
Exact Nix store closures and merged-/usr are separate supported layouts.
For Nix, the host resolves fixed `/bin/sh` and `/usr/bin/env` into that exact
closure. Sandbox-owned `/bin` and `/usr` mounts contain only those interpreter
aliases and become read-only before execution; no host bin directories enter
the sandbox. The `env` alias preserves its basename for multicall coreutils.
Tests execute workspace shebang scripts through the kernel, without shell
fallback, and verify that even chmod cannot make the alias directories writable.
Network denial includes workspace UNIX sockets, inherited socket descriptors,
io_uring and alternate syscall ABIs; native FD mounts consume their anchors
rather than leaving writable host paths available through procfs. A private PID
namespace and parent-death handling contain tested setsid descendants.

`CommandHost` serializes launch and bind, validates the public Session binding
for execution/read/write, and retains authenticated cleanup obligations after
detach. New bindings can operate retained jobs; stale/forged jobs cannot. A
payload exit 125 is never interpreted as proof of non-execution. `CommandRuntime`
selects trusted programs and exact closures, not ambient PATH directories, and
uses bounded public Command probes with confirmed cleanup. `CommandLauncher`
checks the compiled size/SHA256 manifest before making a 0500 executable in a
0700 directory outside the workspace; the app reuses that snapshot. Runtime
reads resolve the packaged application path, and preexisting nonregular sources
are rejected. Normal shutdown removes the snapshot; abrupt VM death can leave
private temporary files. Concurrent hostile replacement of host mount topology
or source paths is outside the verified filesystem guarantee.

These modules are **not selected by production CodexResources**. The earlier
1.10.36 public probe exposed ambient-PATH bootstrap/cleanup and the dependency
handshake path. Backplane 1.10.37 publishes #95's trusted bootstrap contract.
Production sandbox integration and related security/permission development or
tests are excluded by the latest user instruction. Existing implementation and
historical evidence below remain; the global PATH is unchanged.

Native tests pass on the current host, including real i386 ABI denial and owner
death. An official Ubuntu Base payload also passes workspace/home/runtime,
network/syscall and exit-status checks under this host's kernel; it does not
prove remote Ubuntu AppArmor behavior. Bubblewrap >=0.10 is required for native
FD mounts. CI pins official 0.11.2, grants userns narrowly to its root-owned
executable where AppArmor requires it, and has an FD-exec/mount namespace
preflight. Both native binaries are built before Elixir compiles the manifest
and verified in release archives. These CI changes have not run remotely.

The native crate now passes 28 tests (14 terminal and 14 sandbox). Launcher-only
concurrency acceptance starts four retained commands in the same workspace,
verifies distinct mount/PID/network namespaces and private home/tmp contents,
and exchanges exact Chinese/whitespace input through their separate pipes.
Killing one launcher stops its setsid descendant while all three peers continue;
their outputs and exit statuses remain distinct. A fresh sandbox keeps shared
workspace files without inheriting private state. This test calls the native
launcher directly and does not establish LocalCommand cleanup under #103.

Local installed-release acceptance now builds optimized native helpers before a
fresh production warnings-as-errors compile, creates a release archive, and
extracts it into a different directory. The original compile and first release
paths are made unavailable. `scripts/verify-release-native-smoke.py` runs the
installed `bin/sigma eval` without Mix and verifies both the loaded CommandLauncher
BEAM and default native source are under that installed application's directory.
The build-pinned manifest, 0700/0500 snapshot permissions, rejection of a modified
candidate copy, retained snapshot bytes and normal snapshot cleanup all pass.
The original development native artifacts and archived/installed binary hashes
remain unchanged; compiled inputs match the current dirty-main snapshot.

Two real packaged-launcher invocations preserve workspace data while using fresh
private homes, hide host home/sibling data, clear ambient environment, verify the
runtime mount's kernel read-only flag, deny IPv4/IPv6/UNIX socket creation, and
preserve payload exit 23. The packaged PTY helper separately reports an actual
91-column/25-row terminal, exact Chinese/whitespace input, shell exit 17 and
confirmed cleanup. This is direct native-helper acceptance on the current Linux
x86_64/Nix host, not installed production Session/LocalCommand isolation.

The Linux amd64 release job now provisions bubblewrap, extracts the exact archive,
and runs that standalone smoke before uploading it. YAML and Bash syntax/order
checks pass locally; the remote Ubuntu/AppArmor path and other platforms remain
unverified. This older archive evidence predates the ordinary PlainCommand PTY
integration accepted above; an installed release containing that new adapter has
not been verified. Permission/sandbox development and tests remain excluded from
current work.

## Browser and independent protocol acceptance

Isolated 4628 used the 1.10.37 package with independent Protocol and Chrome
sessions. Each exercised real root/child environment readiness, actual commands
and a real-Deno child followup: 24 Provider requests, four command effects and four
distinct stable generation IDs. Refresh and a complete old-BEAM exit/new-PID
recovery preserved exact results and original journal prefixes. Three journals,
the Provider log and command effects kept exact bytes/hash/ns mtime. The browser
journal appended one same-model marker via existing LiveView form recovery;
the original strict whole-file hash assertion failed, and the explicit delta
check identified that sole append. Recovery did not replay prompts or effects.
Chrome retained six successful root cards, connected without overflow or final
console warnings/errors. The owned service/tab were stopped; 4580 was unchanged.

Isolated 4629 exercised 1.10.38's empty-stopped fix through independent Protocol
and Chrome sessions, including real managed children. Direct and nested Plan
calls retained eight exact empty presentations and confirmed Plan content.
Provider requests totaled 22 and actual hook commands eight. Reload, full BEAM
exit/new-PID resume and another reload preserved original journal prefixes and
Provider/hook log bytes/hash/ns mtime. One same-model browser marker was appended.
Six successful root cards and the Plan survived, with connected LiveView, no
overflow and no final console warnings/errors. Both owned BEAMs/tab were stopped;
the user's 4580/PID815717 remained unchanged. Fixtures use controlled Providers;
these checks do not establish online-model, installed-release or deployed status.

With the locked 1.10.36 package, an independent WebSocket client used default
`session.create` options to execute `view_image`, root `tool_search`, a discovered
MCP function and a real Deno nested MCP call. The next model request used catalog
revision 2. A real PNG reached both model output and the existing assistant tool
card, including an image-only result. Chrome confirmed a connected LiveView, a
decoded image, no horizontal overflow and no final console warnings/errors.
Reload preserved provider/MCP request logs and image/journal hashes, sizes and
modification times: it did not replay effects. The served JavaScript matched the
built asset bytes.

This acceptance used a controlled provider and a real Python stdio MCP server on
an isolated temporary service at port 4613. That service has been stopped; the
user's existing service at 4580 was not restarted. These are source and consumer
checks, without a claim of live commercial-model or deployed-service acceptance.

A separate isolated service at port 4614, with a real HTTP/SSE fixture at 4615,
exercised the async and hosted-search paths through independent WebSocket and
Chrome clients. Identical question batches had distinct identities; active replies
steered ongoing work, idle replies started a new turn, optional notice replies
worked, dismissal remained independent of cancellation, and exact retries did
not call the Provider again. The real Provider received the complete replies,
including whitespace and non-ASCII text, with trusted correlation metadata.

The actual Responses request declared cached native `web_search`; search produced
no local tool events. Capable clients received complete native metadata and the
unmodified search observation; Chrome displayed the original citation URL/title.
After a complete BEAM stop/start, Protocol resumed identical durable cards and
metadata without replaying transient observations. Browser reload retained cards
and citations, with connected LiveViews, no horizontal overflow or final console
warnings/errors. The served asset matched the built JavaScript. Provider/HTTP
counts and file hashes stayed unchanged through restart and repeated replies.
The initial cold-read failure and phantom-branch display were reproduced before
the Store and branch projection fixes. The owned 4614/4615 listeners were stopped;
the existing 4580 listener stayed on the same PID. This still uses controlled
Providers and does not establish online-model, release or deployed acceptance.

Isolated port 4618 additionally verified live metrics with two real native Plan
turns, each holding its second controlled Provider request. WebSocket snapshots
and Chrome reload retained `running`; actual completion and reload retained
`completed`. Both journals stayed byte-identical during live reload. An abrupt
owned-BEAM SIGKILL followed by a fresh BEAM, Protocol resume/attach and Chrome
reload recovered the unfinished turn as `interrupted` and kept the completed turn
terminal. Each journal retained exactly one native result and its original byte
prefix; only the completed session gained one ordinary model-change marker.
Provider calls stayed at four with an unchanged log hash and exact mtime. No
interrupted terminal fact was written. Both final LiveViews were connected, with
no overflow or console warnings/errors, and served JavaScript matched the local
SHA256. The owned listener and browser tabs were closed; 4580/PID 815717 remained
unchanged. This fixes the former live-reload presentation limit without replaying
work or treating unfinished cold recovery as live.

## Verification targets

The earlier 1.10.38 selection passed 58 distinct functional cases: 50 across real
environment waits, ordinary/PTY commands, concurrent cleanup, board storage and
file lifecycle, and all twelve root/child direct/Deno presentation cases; six
tagged child-discovery cases; two exact HTTP function/custom empty-output cases.
Four explicit-empty regressions first failed on 1.10.37. Tests involving security,
permissions or sandbox policy were not run. Dev/test strict compilation and the
changed-file format/diff checks passed. Process-failure injection logs remain
visible. Older overlapping test totals below are historical, not additive.

Native async hook acceptance also used an isolated service on port 4616 and an
independent WebSocket client. Real default session creation separated active
admission from consumption, retained idle context until the next real prompt's
first request, and preserved original Chinese text and whitespace. Only three
real UserPromptSubmit calls ran; Provider requests totaled six and actual hook
commands two. Chrome rendered both feedback messages. Full BEAM stop/start,
Protocol resume/attach and browser reload did not replay hooks or model work.
Provider/hook/submit logs retained exact hashes and mtimes. The original 40
journal records were byte-identical; Web cold hydration appended one ordinary
model_change marker, so the entire journal hash changed. Protocol snapshots still
use their existing last-five-message limit with total count and truncation flag.
The final LiveView was connected without horizontal overflow or console
warnings/errors; served JavaScript matched the local artifact SHA256. The owned
listener and browser tab were closed; the existing 4580 process was unchanged.

MCP async hooks additionally passed default Protocol creation and a fresh
LiveView-created session on isolated port 4617 with a real Python stdio server.
Root discovery preceded actual MCP execution. The protocol client separated
active admission from consumption, and idle output entered the next real prompt's
first Provider request with its exact Chinese text and whitespace. Chrome also
exercised an idle receipt and the next real prompt. Feedback arriving at the
terminal boundary retained `delivery_unknown` and was not retried; the later
controlled idle item was consumed exactly once. Full BEAM stop/start, Protocol
resume/attach and Chrome reload preserved history. Provider/MCP/hook/submit logs
kept their exact hashes (16/4/4/7 calls across both sessions); original journal
prefixes stayed byte-identical, allowing only ordinary model-change metadata.
The final LiveView was connected with no console warnings/errors. The owned
service and tab were stopped; 4580 remained on PID 815717. This is controlled
Provider acceptance, separate from online-model or deployed verification.

The current combined scoped regression covered 109 files and passed 1,366 tests
with zero failures and nine explicit skips (seed 471025): AI 89, Coding 211,
Protocol 66, Agent 683, Session 168 and Web 149. It brings the later hosted paging,
inbox uploads and cold-recovery changes into the same Engine/Writer/hooks/MCP/Web
run. Six production raw-patch checks retain #104/#105; the other skips retain
#95/#99/#100. These capabilities remain unverified. Intentional fault injection
and teardown diagnostics remain visible in the log; zero assertion failures do
not establish confirmed concurrent LocalCommand cleanup under #103. The 109
test source hashes and preexisting dirty status stayed unchanged during the run.
This is a scoped integration check, not a whole-umbrella, remote-CI, browser or
online-provider acceptance claim; counts overlap prior runs and are not additive.

Hosted paging coverage includes complete native bounds/origin checks, UTF-8
across chunks, exact source identity, revision/session/branch fencing,
compaction/context-reset/display-tail independence, stopped-session reads,
Writer loss and replacement, target-session fork/switch, relay mode binding,
committed-result hints and actual near-1-MiB HTTP SSE framing. Earlier formatting
for its 15 changed Elixir files and dev/test warnings-as-errors passed; the
combined verification made no implementation changes and diff checks passed.

An independent WebSocket on isolated 4623, backed by the actual OpenAI Responses
Provider and controlled HTTP/SSE on 4624, reconstructed a 1,030,712-byte native
metadata envelope in 84 chunks. It preserved 999,996 characters of encrypted
reasoning, the ordered output, origin and a 30,000-byte Chinese citation title.
Disconnect/reconnect, exact retries, stale/source/offset errors and exclusive
subscription modes passed; every final envelope retained the 64 KiB wire bound.
The second actual HTTP input contained the original native output unchanged.
Complete owned-BEAM exit/new-PID restart then recovered and reconstructed both
results with matching hashes. HTTP remained at two calls with unchanged log
hash/mtime, and the original journal remained byte-identical; reads caused no
writes. The fixture explicitly configured its large session context budget,
independently of model capacity. Both owned listeners were stopped; original
4580/PID 815717 was unchanged. This is protocol/controlled-HTTP acceptance,
separate from browser, online-provider, installed-release or deployed evidence.

The preceding inbox/upload regression passed 317 tests, zero failures and four
explicit skips: Protocol 55, Agent 139, Session 11 and Web 112. Three raw-patch
checks retain #104/#105 and production sandbox activation retains #95. It covers
2,053 ordered cards, complete saved replies beyond 64 KiB, strict DTOs, current
view fencing, actual-envelope page fitting, branch/restart reads, scoped resync,
bounded uploads/expiry/cancel, active/idle commits and preserved acceptance after
failed admission persistence or refresh. Formatting for nine changed Elixir
files, dev/test warnings-as-errors and diff checks passed. Counts overlap prior runs.

Isolated 4622 additionally passed independent WebSocket acceptance for a real
native three-question batch and 90,157-byte original reply JSON. Disconnecting
mid-upload preserved staged bytes without journal/Provider effects; duplicate,
gap/conflict, cancellation, stale-leaf and exact-commit checks passed. Complete
owned-BEAM exit/new-PID restart discarded staged buffers. Reupload then returned
the durable consumed receipt without redispatch: three Provider calls total,
unchanged log hash/mtime and original journal prefix, allowing ordinary model
metadata. The owned listener was stopped; 4580/PID 815717 was unchanged. This was
a controlled Provider fixture, not new browser, online-model or release acceptance.

An independent WebSocket on isolated 4621 read 225 real Writer cards, reassembled
a 72,468-byte card and verified exact bytes/hash, then exercised real reply
consumption, dismissal and deduplicated retries. A complete owned-BEAM exit and
new-PID restart preserved cards/receipts without another Provider call: one total,
with unchanged log hash and mtime. Original journal prefixes stayed identical,
allowing ordinary model-change entries. The owned service was stopped; original
4580/PID 815717 was unchanged. This is controlled-provider protocol evidence;
no new LiveView or online-provider acceptance is claimed for the paging change.

The preceding regression run covered 29 files and 436 tests: zero failures and eight
explicit skips (AI 20, Protocol 21, Agent 175 including six skips, Session 103,
Web 117 including two skips). Six production raw-patch checks retain their original
assertions behind #104/#105; the remaining skips are existing #95/#99 cases. They
do not establish those capabilities. The prior 119-file scope was not rerun in
this batch, and the overlapping counts are not additive. Formatting for the 22
changed Elixir files, dev/test warnings-as-errors and diff checks passed.

An isolated 4619/4620 Engine/Runtime/Deno/HTTP and WebSocket run additionally
verified active steering, idle question/notice replies, exact text, idempotent
retries, default-catalog patch omission, reasoning/search/message native order
and the complete unchanged output in the next actual HTTP input. Chrome sent a
real prompt, answered the full batch while idle with Chinese, whitespace and
newlines, observed consumed, and dismissed a notice. Both hosted responses kept
their original citation URL/title; opaque reasoning stayed outside visible text
and unknown usage remained unknown. Reload and a complete BEAM exit/new-PID
restart preserved these states through Protocol resume/retries and both pages.
Provider/HTTP counts stayed 8/2 with exact log hashes and mtimes; original journal
prefixes were byte-identical, with only one ordinary model-change entry appended
per Web session. Both final pages were LiveView-connected without horizontal
overflow or console warnings/errors. Served app-4ec935d5.js matched the local
artifact SHA256. The owned listeners and tabs were closed; 4580/PID 815717 was
untouched. Controlled Provider/HTTP fixtures do not establish online-model or
deployment acceptance.

The prior combined scoped run covered 119 files and 1,379 tests: zero failures,
three skips. The earlier 1,301-test run failed at upstream #103's cancellation
cleanup boundary. This seed did not reproduce it; the independent public-API
reproduction still blocks confirmed concurrent cleanup. The skips retain
#95/#99/#100's unresolved acceptance.
Both dev/test warnings-as-errors and formatting for 174 relevant Elixir files
passed. Native root/child async delivery has 18 targeted passing tests, including
fail-before/fix-after regressions for the child steering/checkpoint deadlock and
the triggering checkpoint's receipt-append failure. A focused seven-file run
also passed all 58 delivery, ChildIO, ledger and callback-identity tests; these
overlap the combined run and are not additional unique tests. The combined run
also includes 14 root/child MCP delivery tests and the Dispatcher error regression.
It additionally covers exact live metric identity versus ordinary interrupted
recovery, the LiveView reload/completion regression, and joined hook-command
shutdown. The latter suspends the real Runner worker and proves closure cannot
acknowledge before managed cleanup finishes; owner death, occupied async slots,
closed-runtime refusal, detached completed helpers and SessionEnd remain covered.
This local hook fix does not resolve the separate default LocalCommand #103.

- `apps/sigma_ai/test/sigma_ai/provider_contract_test.exs`
- `apps/sigma_ai/test/sigma_ai/providers/{openai,anthropic}_test.exs`
- `apps/sigma_agent/test/sigma_agent/backplane_tool_catalog_test.exs`
- `apps/sigma_agent/test/sigma_agent/backplane_store_test.exs`
- `apps/sigma_agent/test/sigma_agent/backplane_codex_{resources,results,local_tools,code_mode,preparation,post_hooks,user_input}_test.exs`
- `apps/sigma_agent/test/sigma_agent/backplane_{interaction_responder,user_input}_test.exs`
- `apps/sigma_agent/test/sigma_agent/backplane_{codex_runtime_approval,runtime_approval_contract}_test.exs`
- `apps/sigma_agent/test/sigma_agent/backplane_codex_hook_context_test.exs`
- `apps/sigma_agent/test/sigma_agent/backplane_hook_delivery_test.exs`
- `apps/sigma_agent/test/sigma_agent/backplane_child_hook_delivery_test.exs`
- `apps/sigma_agent/test/sigma_agent/backplane_mcp_hook_delivery_test.exs`
- `apps/sigma_agent/test/sigma_agent/backplane_child_mcp_hook_delivery_test.exs`
- `apps/sigma_session/test/sigma_session/hook_feedback{,_writer,_durability}_test.exs`
- `apps/sigma_coding/test/sigma_coding/hooks/async_callback_identity_test.exs`
- `apps/sigma_agent/test/sigma_agent/backplane_child_interaction_responder_test.exs`
- `apps/sigma_protocol/test/sigma_protocol/questions_test.exs`
- `apps/sigma_agent/test/sigma_agent/protocol_questions_test.exs`
- `apps/sigma_agent/test/sigma_agent/subagent_host_test.exs`
- `apps/sigma_agent/test/sigma_agent/backplane_child_io_test.exs`
- `apps/sigma_agent/test/sigma_agent/backplane_child_mcp_discovery_test.exs`
- `apps/sigma_agent/test/sigma_agent/backplane_mcp_structured_functional_test.exs`
- `apps/sigma_agent/test/sigma_agent/backplane_message_board_store_functional_test.exs`
- `apps/sigma_agent/test/sigma_agent/backplane_discovery_discard_functional_test.exs`
- `apps/sigma_agent/test/sigma_agent/backplane_deferred_discovery_test.exs`
- `apps/sigma_coding/test/sigma_coding/permission_test.exs`
- `apps/sigma_session/test/sigma_session/entry_{decoder,encoder}_test.exs`

- `apps/sigma_agent/test/sigma_agent/backplane_native_production_test.exs`
- `apps/sigma_agent/test/sigma_agent/backplane_mcp_resources_test.exs`
- `apps/sigma_agent/test/sigma_agent/backplane_memory_{resources,integration}_test.exs`
- `apps/sigma_agent/test/sigma_agent/backplane_goal_{store,usage,runs,coordinator}_test.exs`
- `apps/sigma_agent/test/sigma_agent/backplane_canonical_history_test.exs`
- `apps/sigma_agent/test/sigma_agent/backplane_child_{permission,io,native_tools}_test.exs`
- `apps/sigma_agent/test/sigma_agent/backplane_native_child_host_test.exs`
- `apps/sigma_web/test/sigma_web/image_attachments_test.exs`
- `apps/sigma_web/test/sigma_web/{live/session_live,session_channel,protocol_session_options}_test.exs`

These tests establish local protocol, HTTP-fixture and Runtime integration behavior.
Separate browser/external-client acceptance is described above; neither proves
live-provider, release or deployed-service acceptance.
