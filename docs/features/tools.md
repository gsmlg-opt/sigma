# Tool availability

The 2026-11-04 delivery integrates remote `7a2e480`, retaining its Provider
stream repairs, ordered tool projection, 90% compaction policy and dependency
updates. The current source locks all five Backplane packages to **1.10.55**
with four direct minima of the same version. The complete remote lock graph is
preserved, including HTTP 0.21.19. Versioned production-package evidence below
continues to describe **1.10.53**; it is not package/online acceptance on 1.10.55.
Merge verification is recorded in the alignment plan.

Sigma has retired its own built-in tool implementations and registers replacements
through the public Backplane Codex protocol. Web and protocol entrypoints select
`native_tools: true`; their legacy `tools: []` list stays empty. This describes the
current source on `main`, not an upgrade of an already running server.

Tool permissions default to YOLO auto-approval through the existing settings
format: `{"permissions":{"default":"allow","rules":{}}}`. Web and Protocol
sessions load this policy, and managed children inherit the root policy.
Current work excludes security and permission development and tests; existing
adapters remain. Verification covers tool functionality, results, history and lifecycle.

The user deferred `web::run`, `image_gen::imagegen`, selecting an actual plugin
registry, remote encrypted History and `notes.thread_hint` on 2026-10-27. All five
remain TODOs and are excluded from this phase's
completion gates. Existing configured plugin support and its functional/lifecycle
acceptance remain in scope.

The 2026-10-30 acceptance used the five official Backplane **1.10.53** packages,
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

Real online acceptance on 2026-10-29 uses the user-selected
`prov_3592 / gpt-6.1-sol`. The first request exposed a Sigma wire bug: namespace
declarations lacked the required `description`. The existing custom/namespace
wire regression fails before the correction and passes afterward; the Responses
adapter now supplies a nonempty namespace description without changing tool
identity, order, schemas or replay bytes.

The corrected, independently extracted production package completes six turns
and 19 actual Provider requests/responses using the existing writerless native19
plus MCP4/discovery1 profile. The model executes clock, Plan, raw `apply_patch`,
Unicode command reads, three real Deno cells, `view_image` (correct left/right
colors), metadata discovery, direct MCP and nested MCP on later turns. The exact
image reaches the following request; MCP preserves LF/CRLF, outer spaces, null
and boolean values. A new BEAM loads six completed public Store records with no
pending effects/outbox; 12 selected durable/effect/snapshot files retain exact
bytes, ns mtime and inode. This does not establish Writer-backed or managed-child
online recovery.

The complete Writer-backed profile receives HTTP 400 from this service because
`history.search_contents.query` must declare encrypted arguments. This is a
recorded compatibility boundary involving the deferred encrypted History work;
its implementation remains outside this phase. Production tools, plaintext
History behavior and global Provider defaults are unchanged. The full-profile
online gate remains unverified, separately from clock startup gap #147. All owned live processes
are joined and the existing 4580 service is unchanged. Evidence:
`/tmp/sigma-live-provider51-nk_kvunj`, especially `writerless/online-acceptance.json`,
`writerless/cold-read-acceptance.json` and `attempt2/probe.json`.

Local Linux x86_64/Nix installed-package acceptance now executes all 42 default
native tools on 1.10.51, plus actual MCP/discovery and V2 collaboration. Real
cross-turn PTY/Deno, same-child followup, an independent child interruption and
full retirement pass. A new BEAM cold-reads 122 canonical messages and exact image
results without an Agent or changes to 27 durable/effect files and the 67/12/55
Provider/MCP-event/hook counts. Another new BEAM accepts an explicit prompt and
continues the original completed child through real Deno/MCP, preserving the old
journal prefix and patch effect. The same eight-file functional selection passes
43 cases against actual packaged BEAMs (seed 43188), including Events, Goal
preparation and original cancellation/full-retirement assertions. Earlier
1.10.49/50 package evidence retains its historical scope. Historical unknown-outcome
children remain unsupported for archive continuation; the interrupted child is
kept separate. These are controlled
local package results, with the existing public accounting uncertainty preserved.
Other platforms, hosted models, CI and deployment retain their separate limits.

Previous 1.10.48 acceptance (2026-10-28): the five official Backplane packages
include #126/#131/#133/#134/#135 and #139. Original Error archive, idle-child
transfer, root plugin cancellation and cold pending-Goal recovery now pass.
The preceding combined functional selection ran 84 cases: 80 pass; two paginated resource full-close
cases failed at [#141](https://github.com/gsmlg-opt/backplane/issues/141) on that version, and two archived
plugin-child followups reject a newly introduced `tool_search` beyond the original
ceiling. Five separately selected Store persistence/cold-read cases pass. Older
versioned evidence below retains its original scope. See the protocol contract for
the exact staged-shutdown and remaining-inventory boundaries.

Normal installation completion is accepted on both 1.10.48 and 1.10.49 through
actual Protocol with real Deno and Chrome's Settings Install button. The original call waits for
explicit installation and returns its exact public request ID with
`completed/user_confirmed`; the next turn reads complete plugin skills. Live reload,
independent BEAM replacement, Protocol resume and manual browser reload preserve
nine durable files and the 10 Provider/4 HTTP counts in each version's run. The
1.10.49 run independently verifies exact original invocation facts and actual
Settings/Protocol confirmation sources, three successful browser cards and two
installed rows. Served JS matches local assets. Its automatic reconnect succeeds;
expected connection-refused messages during intentional shutdown are retained.
The earlier 1.10.48 loading-time `select_model` error was not reproduced or fixed.
These are controlled-provider source/client results. Owned services and tabs are
closed; the existing 4580 service is unchanged.

PostToolUse/real-Deno cancellation originally exposed
[#142](https://github.com/gsmlg-opt/backplane/issues/142). The 1.10.50 public
worker-registration contract now preserves the original wait and enclosing Code
Mode proofs through the existing presentation adapter. Actual Protocol and Chrome
Stop cancellation, late explicit Protocol/Settings installation, next-prompt MCP
and complete skill reads, and confirmed full retirement pass. Old request/journal/
Runtime files stay unchanged after late installation. Full BEAM replacement and
stopped resume/reload add no work: Provider/HTTP/hooks stay 12/4/8 and MCP starts/
calls stay 2/2. All 32 observed file contents match; 31 retain ns mtime/inode, with
one existing empty skill-invocations sidecar rewritten as `[]`. These are local
controlled-provider source results; 1.10.50 installed-package acceptance above is
independent.

Goal continuation now consumes 1.10.51's public
`Goal.settle_host_admission/4` for
[#145](https://github.com/gsmlg-opt/backplane/issues/145). A real hook veto before
Runtime starts retains its ordered actual effects, terminal result, executor DOWN,
cleanup and future-start fence. Settlement precedes terminal events; failed writes
retry persistence without rerunning hooks. The original full continuation case
now reaches ordinary work, fresh automatic work on the same Goal and full retirement.
Its unchanged 1.10.50 failure remains historical evidence.

Hook ownership also covers Session/Goal preparation. Actual index failure requires
confirmed Session closure before host settlement; cancellation during preparation
fences binding. After a successful binding/index, uncertain handoff or Runtime
startup retains indexed-run recovery. The integrated functional selection passes
43 cases (seed 43186), covering these paths, Events and resource lifecycle.

Actual 1.10.51 extracted-package Protocol and Chrome sessions separately create
a Goal, stop one automatic turn through a real hook veto, then complete ordinary
and fresh automatic work on the same Goal. Its original host-effect settlement
stays unchanged. Direct Events, real Deno MRTR and a caught native error followed
by another Events call retain complete pages and the original error message.
Both hosts fully retire. Independent BEAM replacement and stopped resume/reload
preserve six results per client, 23 durable file contents and Provider/hook/Events
execution counts. Twenty-two files also retain ns mtime/inode; one existing empty
skill sidecar rewrites `[]`. Reconnecting MCP clients adds only discovery,
subscription and tool-list reads. Chrome stays connected without overflow or
console warnings/errors, and served JS matches the package. Owned services and
the created tab are closed; 4580 is unchanged. These are local controlled-provider
client results, separate from hosted models, remote CI and deployment.

Stopped Protocol recovery now leaves missing, empty and terminal skill-invocation
ledgers untouched. Only real pending → interrupted transitions write; subsequent
recovery retains exact original bytes and file identity. Per-session local
`:global` transactions also replace the caller-owned ETS polling table, so a
completed caller's exit cannot invalidate another session's in-flight operation.
Seven asynchronous store checks pass in source and against independently
extracted production BEAMs; the existing direct Protocol/WebSocket resume cases
also pass. The lock-fix 1.10.51 package repeatedly cold-resumes both original
Protocol clients: all 23 durable files retain bytes/hash/ns mtime/inode, the absent
ledger stays absent, and no Provider/hook/Events execution repeats. The preceding
ledger-only package independently passed Chrome load/reload; Chrome was not
repeated for the lock-only change. The earlier one-file metadata rewrite above
is the pre-fix observation. Owned services/fixtures/tabs are closed and 4580
remains unchanged; the protocol contract records exact evidence.

Cancelled-turn tool cards without results now show `turn cancelled` in the
existing neutral component state, using their own durable turn identity. All
assistant rows refresh, later turns do not revive the old running label, and
stopped reload reads only the selected branch's original cancelled messages.
Settled success/error results, repaired Provider input and journal bytes remain
unchanged; no synthetic tool result or Runtime settlement is added.
Eight selected Web functional checks pass. Final-source Chrome cold load/reload
retains that cancelled card and four successful cards, with no added effects or
changes to the 32 captured files during display; orderly host shutdown is separate.

## Current root-session tools

The native root profile currently contains twelve core tools:

- `exec_command`, `write_stdin`: real Linux command sessions and stdin, with
  handles retained across successful turns.
- `apply_patch`: native raw patches with ordered add/update/move/delete results.
- `update_plan`: the host Plan process and revision/status receipts, with confirmed
  snapshots persisted and displayed in the session details rail.
- `view_image`: workspace-confined images, model image blocks, JSONL replay and
  validated inline previews in the assistant's tool card.
- `clock::curr_time`, `clock::sleep`: namespaced clock and measured waiting;
  registered waits support full retirement; immediate Stop before registration
  ACK awaits the official #147 fix, whose publication is blocked by #148.
- Code Mode `exec`, `wait`: the public Deno executor, nested dispatch and retained
  cells with current-turn grants.
- `request_user_input`: synchronous questions through the existing Sigma UI and
  opt-in `questions.v1` protocol channel.
- `get_context_remaining`: the current admitted context and actual provider output
  cap; returns null when the budget cannot be established.
- `new_context`: a durable context-window boundary before the next model request,
  retaining display history and restoring base instructions in the new window.

`wait_for_environment` also belongs to the default root and managed-child catalog.
It waits for the actual local command runtime to finish startup through the public
Backplane Control/Readiness contract. The current environment ID, working directory
and startup state appear in `<environment_context>`, including with a custom system
prompt. Successful turns reuse the same ID; resource reconstruction starts a new
environment. PTY helpers still start separately for each job.

`apply_patch` is restored in default and explicitly selected root and managed-child
profiles using the published Backplane 1.10.37 implementation. Raw input, complete
ordered results and JSONL remain intact. The earlier #104/#105 suspension is
historical; no local parser or executor is installed. Existing permission adapters
are unchanged, and this batch adds no permission/preflight or sandbox development.

Two skill extensions, `skills::list` and `skills::read`, use the actual repository
and global catalogs plus configured installed plugin packages through the public ExtensionRuntime host adapter. They expose
eligible automatic skills, immutable prepared resources and bounded text pages;
manual-only/disabled skills remain inaccessible. They do not activate skills or
execute their scripts. Packages and cursors are scoped to the current run.
Plugin installation records are pinned at each real root/managed-child binding;
the newest completed release per plugin appears at the next run, with explicit
registry/plugin/release references. They reuse the public package readers and
existing immutable skill snapshots without starting plugin MCP.

Four Memory extensions, `memories::add_ad_hoc_note`, `memories::list`,
`memories::read` and `memories::search`, share the public ExtensionRuntime dispatcher
and one application-owned writer per trusted user memory root, normally
`~/.pi/agent/memories`. Each Agent fixes that root across generations; Session
closure leaves the shared writer available. Notes preserve the existing explicit
user-instruction and exclusive-creation behavior.

Search uses 1.10.37's tagged `any`, `all_on_same_line` and `all_within_lines` inputs.
It preserves query order, sorts by path/line, returns minimal matching windows and
line contexts, and supports case matching, Unicode normalization and at most 200
results per page. Cursors reuse the existing traversal machinery. The actual
Engine and next Provider JSON, real Deno, writer reopen and fresh Session paths
are functionally verified; earlier browser acceptance covered add/list/read.

With a transcript Writer and root archive, nine History/Notes extensions share
the same public ExtensionRuntime dispatcher:

- `history::list_windows`, `history::list_items`, `history::read_item` and
  `history::search_contents` read the original selected journal ancestry. Stable
  window/item IDs retain messages from before compaction and `new_context`;
  assistant tool calls become separate items, and images remain separate media
  blocks when read. Filters, literal search and Unicode scalar offsets operate
  on this archive rather than the current Provider or display window.
- `notes::list_files_by_prefix`, `notes::read_file`, `notes::search_contents`,
  `notes::append_to_file` and `notes::write_file` use a rollout-shared virtual
  filesystem. Relative paths belong to the current agent; absolute paths such
  as `/root/reviewer/notes/findings.md` address another agent's notes. Exact
  append/replace, including empty text, preserve UTF-8 and original LF/CRLF line
  endings, with a 1,000,000-byte limit per file.

Live History reads capture the real Writer selection through the root/child
resource owner; stopped child archives use persisted registration and journal
ancestry without restarting the child. An omitted child name retains its exact
Session binding. For an explicit reused name, the latest durable registration
event revision selects the Session, a Sigma interpretation of name reuse rather
than a portable Codex rule. A Writer checkout remains transient until the next
append persists that branch.

An application-owned writer serializes Notes operations at
`<root_transcript>.subagents/notes.json` and rereads storage on every call.
Session closure leaves it available; rename/adopt move the subtree, delete
removes it, and forks start independent stores. Same-directory temporary-file
sync and atomic rename do not provide directory fsync or cross-node exclusion.
History/Notes are `DirectModelOnly`: the real Deno `ALL_TOOLS` catalog excludes
all nine, while Skills and Memory remain callable there. Encrypted remote
history envelopes and `notes.thread_hint` are not implemented. The user deferred
both on 2026-10-27 as TODOs outside this phase's completion gates. In pinned Codex,
the latter is a backend-provided full-context contribution in the independent
developer `token_budget.context_window` message, alongside window UUIDs. It is
neither another Notes tool nor a repeated incremental summary. Sigma needs an
actual `alpha/notes/v2/thread_hint` backend and the full-context projection contract;
the test fixture does not define a local production summarizer.

Root sessions with a transcript Writer now also admit Goal3: `get_goal`,
`create_goal` and `update_goal`. The actual Writer header, Runtime Store and
Session binding own durable state, cumulative usage and ordinary idle admission.
Managed-child work contributes usage through public delegation; children do not
receive root Goal tools. Retained terminal receipts use the public #109 ACK
without replay. Automatic continuation, cancellation/defer, later real-prompt
resume and session rename/adopt/delete/fork have functional acceptance. Both
`.runtime` and `.subagents` follow session moves; fork imports an independent
public Goal snapshot rather than copying source run receipts. Actual child usage/ACK failure receipts survive public fencing and exact
provider-only cleanup followed by Goal/Store/Writer process restarts, charging
once. Root recovery now also accepts the newer incarnation produced by public
Store fencing while retaining original index/receipt attribution. Actual root
usage/ACK failures survive production Agent reopening and a separate full-BEAM
restart after confirmed provider-only cleanup, charging 13 tokens once without
Provider or journal replay; a fresh prompt then completes normally. Automatic
prospective child lifetime recovery is now integrated as described below; missing
legacy facts remain a boundary. Child host retirement persists separate native Session and async-hook
confirmations in `host-retirement.etf`, retaining every bound run across followups
and native generations. The actual root/child Writer headers identify the ledger;
ordinary Runtime snapshots and Goal receipts are unchanged. Child retirement runs
outside host message loops, and confirmed child components do not hide an unknown
root manager close. Roster `closure: :closed` may still describe detach with retained
commands; native/async-hook receipts do not prove Kernel settlement or SessionEnd.
An actual child usage-write failure also preserves these receipts and the exact
Runtime/Goal outbox across a complete BEAM exit and read-only Store reopening,
with unchanged journal/Provider logs and no effect replay. Full recovery still
requires the manager/Session reconciliation described below.
Root generations now register every exact binding in the same version-two ledger;
SessionEnd has its own completion/outcome/warnings fact. Explicit root retirement
keeps the Agent responsive, caches original acknowledgements across receipt-write
failures and never repeats SessionEnd to rebuild a lost result. Rename/adopt/delete
retire components before Store/file changes, and failure reopening creates a fresh
hook/root lifetime. Active shutdown preserves unconfirmed native cleanup while
still joining hooks and running orderly SessionEnd. The binding lookup status
remains native-plus-hooks, not whole-host completion; version-one reads do not
rewrite files or manufacture SessionEnd facts. Reliable retained non-PTY command
closure now uses Backplane 1.10.43's fix for
[Backplane #118](https://github.com/gsmlg-opt/backplane/issues/118), the reproduced
procfs ESRCH race in 1.10.42. Upstream commit
[d9d2f53](https://github.com/gsmlg-opt/backplane/commit/d9d2f539fababd609464cc438b553aae18018114)
is published and adopted. The unchanged seven root-retirement cases and one
32-Session concurrent close/cancel case pass with original seed 261088. No local
workaround is used; active shutdown still retains its independent actual
unconfirmed result. These passing cases do not imply whole-root failure recovery.
Across a complete BEAM restart, read-only Store reopening retains three root run
memberships, two native generations and all component receipts; eight persisted
files keep their bytes/mtimes, with no Provider or SessionEnd replay. This proves
component persistence; the bounded lifetime controller below additionally uses
actual acknowledged ownership retirement.
Native root/child Provider workers now register their exact public Runtime
attempt before calling the Provider. The existing Store monitors each actual
worker and saves its observed exit in a separate `provider-lifecycle.etf` sidecar.
Failed writes preserve the fact/cause for persistence-only retry. Explicit child
retirement keeps its IO/Store alive until those observations are durable; reopening
never invents missing exits. Actual usage-failure evidence survives a full BEAM
restart without changing Runtime/Goal records or replaying effects. Worker exit
is independent of Kernel settlement.

Production startup now automatically reconciles retired provider-only root runs
through public Store fencing, cancellation and exact cleanup settlement before
Goal accounting. It requires the original indexed run, complete native-generation,
async-hook and SessionEnd receipts, and exact stopped evidence for every Provider
attempt. Other outstanding work or missing facts remain errors. A retained outbox
must contain only that Provider's exact intent; ordinary storage failures without
a Goal also recover without inventing receipts. Failed writes retain their cause
and committed stage, so retry does not increase the fence again or repeat effects.
Original Goal receipts retain attribution and charge once; replacement prompts use
committed history in a new run. Actual failure cases and complete-BEAM production
reopening have functional acceptance, including unchanged journal/log/component
receipts before a new prompt and unchanged files on a further reopen.
The independent GoalDescendants loader uses shared RunRecovery to settle retired
provider-only children before receipt loading. It checks original admission/receipt
identity, actual child transcript header, all native generations and async hooks,
and every exact Provider exit. Repeated loads do not refence; usage/ACK failures
preserve original attribution and deduplication. Missing observations leave the
run unchanged. Earlier independent Store/Goal cold checks proved these components
without admitting a new root.

Backplane 1.10.43's [#119](https://github.com/gsmlg-opt/backplane/issues/119)
consumer now adds prospective manager/Session lifetime reconciliation and a new
root after actual failed-child retirement. The full acknowledged ownership tree,
independent root retirement, receipt versioning and descendant-first resealing
are described below. Historical unknown outcomes remain unchanged; missing legacy
facts and arbitrary unfinished tool/dependency work remain recovery boundaries.
A real child Deno command, usage-write failure and full-BEAM production reopening
pass without command replay; the new root retains committed context and accounts
child usage once. This does not restore archived children.

The next real prompt also recovers a failed live host automatically. Agent keeps
the original item/resources pending, checks the current host without effects,
retires it outside its callback loop and rescans the public Goal recovery path
before creating a fresh host. Healthy commands and children stay available.
Cancellation and persistence failures preserve actual retirement facts; resources
are released once and accepted followups can continue. Ordinary shutdown uses the
ownership ACK tree before recording its independent root hook/SessionEnd facts,
while new-work admission requires both. Automatic Goal idle probes before making
a reservation. With 1.10.45's
[Backplane #127](https://github.com/gsmlg-opt/backplane/issues/127), release hands
the actual Task to its coordinator monitor. Pure provider configuration precedes
an atomic effect gate. Only exact executor DOWN before that gate permits durable
unstarted settlement; cancellation/supersession fence the same token first.
Terminal events join the actual settlement acknowledgement, and no interrupt
hook runs on this no-start path. A corrected configuration permits the same Goal
to continue through a real prompt or explicit user mutation and automatic idle.
Store errors retain the seal and actual cause for persistence-only recovery.
The next prompt on a reusable host retries that sealed settlement in the
supervised inspection Task, before canonical input, hooks or a new Session.
Explicit host Goal set, clear and fork share this preparation. While the write
still fails, they return its actual error without recording new instructions or
starting a Provider. Repaired storage permits fresh work on the same Goal;
indexed runs and unknown outcomes retain their separate recovery requirements.
Fork retains the source receipt and starts independent empty admission ledgers.
Post-gate hook/Session/Runtime failures still require actual recovery evidence;
missing Runtime state cannot justify withdrawal, Goal reset or fabricated receipts.
Complete 1.10.44 Goal files default only the two new maps in memory without
rewriting their bytes; a real mutation continues their original CAS revision.

Controlled-Provider acceptance covers actual WebSocket and browser submission,
Stop and the next prompt after a real child usage failure, followed by full-BEAM
reopening and browser reload. Original unknown snapshots and committed context
are retained; each child command runs once and usage is charged once. Cold resume
does not add Provider calls or modify the command marker. This is local functional
acceptance; the existing 4580 service is unchanged.

Continuing an archived child with its old identity after manager replacement is
the separate [Backplane #117](https://github.com/gsmlg-opt/backplane/issues/117)
path. Both #117 and #119 have public APIs in upstream commit
[`a93bb8034a8deee6a132c8d715bdf2fc96d1a891`](https://github.com/gsmlg-opt/backplane/commit/a93bb8034a8deee6a132c8d715bdf2fc96d1a891),
published in all five 1.10.43 Hex packages. #119's bounded consumer is accepted;
the 1.10.43 archive candidate rejected assistant metadata at #126. Official
1.10.48 now accepts the original Error/metadata archive and idle restored-child
transfer regressions through the public exporter. No history fields are stripped.
Lifetime execution retirement and full archive completion remain separate.
Goal preparation I/O failure now closes its reserved Session, so
a later real prompt can acquire a fresh Session after the index is restored.

All nine message-board tools are registered under `collaboration::` for root and
managed children: `create_channel`, `get_channels`, `list_threads`, `search_posts`,
`read_thread`, `read_post`, `subscribe`, `unsubscribe` and `post`. They use the
actual tree membership and one durable board per root transcript. Post commits
before public active-only notifications; a failed best-effort notification logs
its cause without changing the committed result or retrying effects. #110 keeps
unconsumed notices out of later followups. Idle agents are not started, and
ordinary queued messages remain independent. Real-Deno, root/child/sibling
notifications, pagination, exact Unicode/CRLF and independent fork are verified.
The original 128 KiB raw argument envelope is still missing.

Root sessions with a transcript Writer additionally admit
`request_user_input_async` and `send_message_to_user_async`. With the archive above,
the default root catalog contains 42 tools: 12 core, 1 environment, 2 Skills,
4 Memory, 4 History, 5 Notes, 2 async, 3 Goal and 9 board tools, before optional
MCP, configured Plugins2 and V2 collaboration. Writerless roots retain 19 tools.
A configured plugin registry adds two tools to roots and managed children.
The async tools let the agent
continue working while durable cards remain available in LiveView and the opt-in
`async_interactions.v1` protocol.
All questions in a batch require an answer; notification replies are optional.
Replies preserve exact text and enter steering during an active turn or a new
turn while idle. Saving, admission and confirmed consumption are separate facts.
Consumption requires the selected canonical reply and the matching public Runtime
admission/checkpoint identity and complete content; a JSONL entry alone is insufficient.
Repeated identical replies reuse their receipt; reload never reruns a tool or
automatically retries uncertain delivery. Cancelled/failed origins close pending
questions, including recovery after a host terminal fact; completed turns keep
questions answerable. Cards and replies from another branch stay hidden while
global receipts prevent duplicate dispatch. Children and writerless sessions
omit both tools.

The inbox retains global receipts without a lifetime card/fact ceiling. Individual
facts and replies remain bounded while preserving full question titles and answer
text. Legacy `async_interactions.v1` requires the complete snapshot to fit the
64 KiB envelope, 200-entry collection and 32 KiB string limits. The alternative
`async_interactions.pages.v1` exposes a selected-view revision, summary pages and
12 KiB base64 JSON chunks for complete cards. Stale revisions fail explicitly;
notifications are invalidation hints, and no card is truncated. Accepted mutation
receipts survive later snapshot failures. `async_interactions.uploads.v1` requires
the paged mode and stages complete reply JSON in 12 KiB raw chunks before explicit
commit. Eight volatile uploads per Agent are bounded to 256 KiB each and a fixed
five-minute lifetime. Receiving bytes has no journal or Provider effects; commit
reuses selected-leaf/session/card fences and durable exact-reply deduplication.
Restart requires reupload. A failed admission-receipt write preserves the real
`dispatching` acknowledgement and error; unknown origins without a saved reply
cannot acknowledge an invented answer. Existing wire and semantic answer limits
remain unchanged.

OpenAI Responses can separately enable provider-hosted `web_search` using actual
model/provider configuration:

```json
{"hostedTools":{"webSearch":{"supported":true,"enabled":true,"mode":"cached"}}}
```

It defaults off. A model's complete `hostedTools` map replaces provider defaults;
`cached`, `indexed` and `live` modes retain their native declarations. Hosted
search is outside the local registry, authority grants and local tool cards.
Ordered search actions, native output and URL citations persist with provider,
model and normalized endpoint affinity; incompatible replay fails before HTTP.
Native replay retains reasoning and encrypted content in their original order,
including enabled turns without a search call. Unknown output types fail instead
of being silently filtered. Opaque reasoning is not rendered as assistant text.
LiveView renders validated HTTP(S) citations. Managed children omit this root
configuration. Controlled HTTP fixtures verify transport and replay; they do not
prove authorization or compatibility with an online commercial service.
Capable Protocol clients request `provider_hosted.v1` to receive complete native
metadata/citations and transient `provider.hosted` observations. The final 64 KiB
wire limit produces explicit errors rather than truncation; legacy projections
retain their original shape.

For larger durable native output, clients may instead select
`provider_hosted.pages.v1`. A Writer-selected directory lists every hosted result
in the current raw ancestry, including sources outside display/context windows.
`provider_hosted.list` and `provider_hosted.read` return revision-checked summaries
and bounded base64 JSON chunks with exact source IDs, byte lengths and hashes.
Stopped sessions remain readable without starting an Agent. This mode provides
refresh hints after committed results and excludes transient raw progress
observations. The modes are exclusive and fixed to each subscription. See
[the protocol contract](../contracts/protocol-v1.md#durable-hosted-result-pages).
Hosted Responses SSE framing accommodates the existing native 1 MiB bound;
the ordinary Provider framing and Protocol V1 wire limits remain unchanged.
Independent WebSocket/HTTP acceptance reassembled a 1,030,712-byte envelope,
continued after reconnect and recovered both durable results after a full BEAM
restart. The original native output reached the next HTTP input unchanged;
reads/recovery added no HTTP calls or journal writes. The HTTP service was a
controlled fixture, with an explicitly configured large session context budget.

Connected MCP clients additionally admit `list_mcp_resources`,
`list_mcp_resource_templates`, `read_mcp_resource` and `mcp_events`. They reuse the Agent's
current clients, preserve server names, pagination and text/blob results, and
work through Code Mode. With no connected clients these tools are absent and a
guessed call cannot execute. Connected root MCP functions start as deferred
candidates: `tool_search` searches actual metadata and publishes matching tools
at the next model boundary. Those functions keep the shared Dispatcher,
permissions, hooks and inventory refresh behavior.

`mcp_events` returns one complete raw Events page from the specified server.
Event order, schemas, metadata, empty pages and exact opaque cursors survive direct
and real Deno execution; following `nextCursor` is an explicit later call. The
public Backplane client owns MRTR continuation IDs and local request cleanup.
Root cancellation and child interruption retain the exact durable
`event_request_retirement` for public lifetime reconciliation while keeping an
independent caller and the shared connection usable. Confirmed local retirement
does not imply remote rollback. Functional acceptance uses a real HTTP MCP
fixture with PostToolUse and preserves full-host retirement assertions.
RPC code/message/data and full domain-error pages survive in public Error details
and authoritative Runtime results. Direct results/history retain those details.
Native Code Mode failures reject the Promise with the original message; catching
it permits another Events call in the same JavaScript invocation. Nine Events
functional cases pass, including same-child followup and readback without replay.

For ordinary MCP results, non-null `structuredContent` takes precedence over
display content and supplies the complete JSON value to the model, matching Codex.
Large arrays, Unicode, line endings,
nulls and booleans survive direct and real Deno calls, later turns/followups and
journal reload. The original MCP envelope remains in result metadata, and
`isError` remains an ordinary tool error. In real Deno, that result fulfills the
Promise with `is_error: true`, preserving the complete output and allowing the
same JS invocation to continue with another MCP call. Root and actual managed-child
tests also verify later turns/followups and journal reads. This JSON-safe MCP
result originally differed from the native Error struct failure in #111. With
1.10.42 that path also passes: a normal completed-command-handle error fulfills
the real-Deno Promise and another command can execute.
Without structured content, text/image
projection remains; embedded resources, resource links and unknown blocks become
complete JSON text in their original order, preserving all fields and metadata.
This text fallback matches Codex; typed-media and encrypted-content transport
remain separate alignment work.

Independent WebSocket and Chrome acceptance exercised two turns per client,
including actual managed-child followups and real Deno. A complete BEAM restart
retained all four journals without replay: Provider requests stayed at 40 and
MCP calls at 16. Complete `session.dump` host artifacts matched before and after
restart. Protocol V1's ordinary live events remain bounded display previews;
the full dump was read from the host file, rather than transmitted in those
events.

Public Responses image/data-URI/detail encoding is tracked in
[backplane#112](https://github.com/gsmlg-opt/backplane/issues/112). The released
codec rejects image tool results; structural `Request.new` acceptance is not
encoding support. Sigma retains its existing image host projection while this
public-contract integration waits for a published fix.

Native Backplane V2 collaboration declarations remain `spawn_agent`,
`send_message`, `followup_task`, `interrupt_agent`, `list_agents`, `wait_agent`,
when the collaboration host is enabled and has a transcript writer. With the
published [backplane#86](https://github.com/gsmlg-opt/backplane/issues/86) protocol,
managed children receive their own Session, Command and Plan resources and fresh
bindings. The public manager adopts each child; foreign Session attachment still
fails. Child profiles use `root?: false` and exclude root-only input/reset tools.
Successful followups retain child resources; replacement requires confirmed
closure. Child resource tools borrow the root's actual connected MCP clients,
require inherited grants and use a getter fenced to the current run/incarnation.
Child closure leaves those connections under root ownership. Real-manager tests
cover direct and Deno resource reads, permission denial without a remote read, and
followup reuse with exactly one MCP initialization. Root-client reload retires the
old reference and keeps existing children on the replacement through a trusted
owner lookup, limited to their initial server IDs and current child binding.
Tests include a read while the parent is idle and later followup reuse, with
exactly two initializations and no third connection.
Backplane 1.10.37 propagates the committed root discovery catalog through its
public Session/manager lifecycle. A managed child snapshots those inherited
connected functions as deferred candidates and searches them with `tool_search`
before execution. Empty inherited inventories omit search and still permit normal
spawning and resource reads. Every followup starts a new discovery inventory;
context accounting follows the actual Provider tools. Real direct and Deno calls
reuse one MCP connection across both runs. Sigma does not manually expand grants,
rebind an active Session or reset private Runtime state.

Resource operations now use public caller-owned sequential request scopes from
#131/#139. Every page retains its actual request identity and reserved Client
options under the invocation deadline and 128-slot bound. Root and child immediate
cancellation, earlier completed pages, independent callers, same-client reuse and
parent continuation pass. With 1.10.50
[#141](https://github.com/gsmlg-opt/backplane/issues/141), both original pagination
full-retirement assertions also pass. LifetimeEvidence preserves the exact public
resource_scope_retirement from the authoritative Store for public reconciliation.

The native profile requires OpenAI Responses transport. Chat Completions and
Anthropic reject incompatible custom, namespace or output-schema contracts before
HTTP. They do not silently rewrite the native contract when switching models.

## Optional plugin tools

Set `plugins.registryUrl` in `~/.pi/agent/settings.json` to enable
`list_available_plugins_to_install` and `request_plugin_install`. Optional
`plugins.headers` supplies HTTP headers; `plugins.requestsRoot` selects the shared
request directory, defaulting to `~/.pi/agent/plugins`. No registry is selected by
default. A trusted startup `native_plugins` option can override or disable this
snapshot, and managed children inherit it.

The catalog uses the public Backplane PluginProtocol HTTP client. Listing plugins
does not create files. Installation requests retain all four original arguments,
including exact Unicode and line endings, and original Runtime invocation
identity in `<requestsRoot>/requests.json`. New native records also retain the
public `plugin_request_id`; Runtime owns the outer result ID. Legacy request-only
receipts remain unchanged. New native calls wait for explicit installation below.
One application-owned writer per directory serializes requests and remains
available after Session closure. Exact accepted retries return the original
record without rewriting it; writer replacement reads the same durable record.
Unconfirmed writes retain the actual error and are not automatically retried.

Root direct/real-Deno calls, actual managed-child followups, HTTP failure and
continuation, cross-turn history, repository/Writer reopening and exact writer
retries have functional acceptance. The plugin/installed-skill/environment and
product-installation selection passes 34 cases (seed 261130), including real HTTP
installation, Web/Protocol entry, root/child skill reads, followup, writer
replacement and history reopening.

Separate Protocol and Chrome clients load ordinary settings on isolated port 4631
and each complete two root turns, an actual child and its followup. Direct and
real-Deno catalog/request calls produce ten saved requests, with 34 Provider calls
and 14 actual HTTP catalog reads. Reload and complete BEAM replacement preserve
all four journals, the request file and both call logs with exact bytes and
nanosecond mtimes; no effects replay. Full Protocol dump artifacts remain
byte-identical. Chrome restores nine successful cards, shows the `requested`
receipt, remains connected and has no horizontal overflow or console warnings/errors.
The owned services/page were stopped, leaving 4580/PID 815717 untouched. These runs
use a controlled Provider and local registry, without selecting an external service.

`requested` confirms a saved request. The host can separately install that durable
request with `PluginResources.install/2` and explicitly activate its public
`Plugins.Session` with `activate/4`. Packages and installation receipts persist
independently of the original request. Exact installed retries and cold reads do
not download, rewrite files or start MCP; pending publication can only be confirmed
from an existing complete package. Real stdio MCP, exact skill/resource reads and
shutdown work through the returned Session. The caller owns that Session.

Every new root/managed-child binding refreshes the application writer and loads
installed plugin skills into `skills::list`/`skills::read`, preserving exact
instructions, descriptions, metadata and relative resources. Installed records and
versions stay fixed for that run; followups refresh the inventory and expire the
old prepared snapshots. Reads start no MCP or scripts and do not access the registry.
Earlier independent BEAM reads through production CodexResources/ExtensionRuntime
release their snapshots and preserve all 24 package/request/ledger/journal/runtime/log
files with identical bytes, nanosecond mtimes and inodes.

Use **Settings → Plugins** (`/settings/plugins`) to browse durable requests and
explicitly install their packages. The configured registry is shared by root and
child requests; pages refresh when the inventory changes. Installed state survives
reload, and an installation receipt remains visible if the later list refresh
fails. Protocol clients use `plugins.requests` and `plugins.install` with
`plugins.install.v1`; they use their actual live session's configured host. These
actions keep native `requested` history unchanged and load skills on the next turn.
They do not select a registry. A new real binding separately prepares its installed
plugin MCP catalog as described below.

Independent Chrome and WebSocket acceptance installs two real native requests,
reads their full skills on the next turns, and resumes both sessions after complete
BEAM replacement without more Provider/HTTP calls. Reload preserves all 23 observed
files; cold resume preserves 21 plugin/package/journal/runtime/log files' bytes and
metadata. Two existing empty skill-invocation sidecars keep their bytes while the
older resume path rewrites their metadata; this unrelated behavior is recorded in
the tools contract. Owned services/pages are stopped and the existing 4580 service
is unchanged.

Under the user's assumed-upstream-fix instruction, each real root/child binding
now owns a PluginRuntime with independent public Plugins.Session handles for its
pinned installed releases. Public function names and schemas enter deferred
`tool_search`; the existing Dispatcher executes their callbacks and retains full
structured/image results, hooks and ordinary error continuation. Children use only
the names committed by the parent's public catalog and own their own connections.
Followups close old plugin Sessions and prepare a new inventory. Public errors and
close outcomes remain visible; uncertain cleanup is never retried as a new effect.

Six dedicated runtime checks and actual root direct/Deno, cross-turn refresh,
normal closure and history reopening pass. Actual child direct/Deno followup runs
through distinct processes; its cold-reopening completion case reaches
[#133](https://github.com/gsmlg-opt/backplane/issues/133)'s idle-archive transfer gate. An owned WebSocket client and fresh BEAM/PID restore six complete
plugin-related tool cards, including an ordinary error followed by success. Chrome
reload retains the complete result with no new Provider/MCP/HTTP/install effects,
no horizontal overflow or console warning/error. The original 4580 service remains
untouched. These checks use a controlled Provider and local registry.

Native installation completion adopts 1.10.44's
[Backplane #124](https://github.com/gsmlg-opt/backplane/issues/124) outcome contract.
The original call now waits outside the shared writer until the user installs that
exact request through Settings or Protocol. Those existing actions pass actual
`:settings`/`:protocol` confirmation provenance. A separate durable
`native-installations.etf` fact records the original request/invocation and verified
installed Archive or exact Error. A successful fact and still-valid original
binding return `completed`/`user_confirmed` with original tool/action/plugin IDs;
Runtime supplies the outer request ID. Saving a request alone does not complete
or install it, and old requested history is not rewritten.

Failed native installation is retained without automatic effect retries. Explicit
host checks can still confirm an independently pending complete package, while the
original native failure remains immutable and no download/activation repeats. A closed
binding rejects late native completion. If installation succeeds but native-fact
persistence fails, the host keeps its successful installation acknowledgement and
the native waiter reports the actual uncertainty. The Runtime deadline remains
unchanged. The next Protocol Provider request and flushed JSONL retain the exact
complete native result; Protocol4 and Web5 functional cases pass.

Started plugin observation waits now use public `DynamicRuntime.plugin_install_wait`
after the immutable request commit. Authoritative typed cleanup proofs are retained
unchanged for public reconciliation. Root direct/real-Deno cancellation, late
explicit installation without old-history changes, fresh catalog/MCP and full
retirement pass. Two actual managed-child cases reach proof reconciliation and
full retirement, then reject archived followup: late installation adds
`tool_search`, absent from the child's original ceiling. This remains a functional
inventory boundary; no admission-policy change or grant expansion is made.

Independent Chrome and WebSocket clients also verify the original-call wait on
owned port 4674: direct browser and real-Deno requests remain pending until the
actual Settings or Protocol install action. Complete results, original public IDs
and distinct confirmation sources match the durable facts, next Provider request
and JSONL. Both next turns read the exact installed skill. Live reload and a full
owned-BEAM replacement preserve all nine plugin/log/journal files byte-for-byte,
including their mtimes/inodes; Provider/HTTP remain 10/4. Repeated installed checks
do not repeat effects. Chrome retains three successful tool cards and two installed
entries, with connected views, no overflow or console warnings/errors. Owned
services/pages are closed; 4580 is unchanged. These controlled-provider checks cover
the new completion result and do not claim live-model or installed-release acceptance.

PluginRuntime adopts 1.10.44's public close/status reports from
[Backplane #122](https://github.com/gsmlg-opt/backplane/issues/122). It captures the
exact report before stopping a confirmed Session and retains unconfirmed errors
without another cleanup attempt. All seven dedicated cases pass, including the
original controlled per-component failure, independent binding continuation and
normal real-stdio close. An additional actual managed-child case crashes only its
own packaged stdio guardian. ChildIO retirement retains the original unconfirmed
report and missing waitpid, pipe and successful-helper-exit receipts. Repeated
retirement returns the same error without more requests, starts or calls; the
independent root plugin still runs and completes its turn. Aggregate host closure
remains unconfirmed, so this verifies error preservation and independent progress,
without claiming successful cleanup or automatic recovery after the crash.
Plugin MCP uses the public verified stdio helper. Local release and CI/release
builds explicitly compile it with `mix backplane.mcp.stdio.build`; release assembly
probes the installed executable. The task's local probe passes. Ordinary configured
MCP retains its current transport; activation never compiles a helper.
A local Linux production release has also been assembled, archived and extracted.
Its five official packages report 1.10.44; actual PluginRuntime/Dispatcher/Session/
MCP modules and the executing guardian come from the extracted package. A real
stdio call retains exact Unicode/CRLF output, and the public close report confirms
helper exit 0 and cleanup without repeated effects. The packaged application
asset matches the browser-tested artifact. This is local plugin-component
acceptance; other platforms, remote CI and deployment remain separate.
No registry is selected by default. The host-component cold-BEAM checks
are separate from the earlier client catalog/request acceptance. See the
[protocol contract](../contracts/codex-tools.md#plugin-catalogs-and-durable-requests).

## Retirement and retained host features

The old default tools `ask`, `read`, `write`, `bash`, `edit`, `search`, `find`,
`todo`, `activate_skill` have been removed with `apps/sigma_tools/`. The second
`Sigma.Coding.Tools` implementation directory and unused `ExtensionRegistry`
were also removed. In total the retirement covered 18 implementation/wrapper
modules and 14 distinct tool names, including `AskUserQuestion`, `glob`, `grep`,
`ls`, `url_fetch`. No old implementation has been restored.

Historical calls remain readable; loading JSONL does not run them. There is no
separate replacement `read`, `find` or `search` tool. Native commands and the
published `apply_patch` backend provide workspace file operations.

Manual skill invocation, configuration, prepared resources, hooks, permissions,
path authorization, JSONL and the UI terminal remain. The skills API still reports
`manualInvocation: true` and `modelActivation: false`. The UI terminal is a human
host feature, separate from the model's native command backend.

## Ownership, permissions and history

The long-lived session host owns Command, Plan, Codex Session, the MCP resource
DynamicRuntime and the skill-resource cache. A temporary Engine turn binds these resources to its exact
registry/tools/authority bundle. Successful turns detach and retain resources;
cancelled or failed turns close the generation. Full session shutdown also stops
owned infrastructure. No process handles, binding tokens or callbacks enter JSONL.
Partial shutdown retains confirmed Session and skill cleanup independently; a
retry can finish stopping remaining children without calling a dead Session.
Admission stays closed and uncertain cleanup remains an error until confirmed.
The Memory writer is application-owned and shared across Sessions. Closing a
Session leaves it available to other Sessions, while every call still validates
the current public binding. A writer lost during a note call yields an uncertain
outcome and stops the turn; a later run reconnects without retrying that write.

Native preparation runs existing PreToolUse and Sigma permission policy before
Runtime's final validation and durable invocation commit. Native PostToolUse runs
once on successful results. MCP continues through Dispatcher. Sigma
`:sigma_tool_permission`, generic questions and Runtime's independent built-in
`:permission` approval remain separate channels.

Synchronous PostToolUse uses public `ToolEffects.present/3`: the completed native
settlement remains in `run.tool_results`, and `run.tool_presentations` stores the
consumer presentation. A block becomes a model error and a nested Code Mode
error; stopped text replaces model output while nested code retains the completed
value. Additional context is delivered independently. Root and child direct/nested
functional tests cover the next Provider request, JSONL, later turns and resource
recreation. Confirmed Plan projection reads the actual public settlement rather
than inferring success from displayed output.

An explicitly empty stopped reason is preserved with Backplane 1.10.38's
[#107](https://github.com/gsmlg-opt/backplane/issues/107) fix. The old diagnostic
bypass is removed: root/child direct and real-Deno consumers retain empty text,
the actual settlement and confirmed Plan across later turns and recreation.
Four regressions failed before adoption; all twelve presentation cases pass. The pinned hook
catalog has no `PostToolUseFailure`; `suppressOutput` and `updatedMCPToolOutput`
are unsupported in that source version.

Async native post hooks use the root or child's owned Writer and AsyncRuntime.
Runner binds each callback before queueing, preserving the original handler index
and context. HookDelivery verifies the exact public Store intent and successful
result before active steering or the next accepted real prompt. Idle hook output
does not start a turn. Cancelled or failed origins are discarded; child context
stays in its own journal. Writerless hosts still refuse these hooks before effects.

Journal receipts retain separate canonical and actual Runtime admission IDs.
Consumption requires the selected canonical message and matching Runtime
checkpoint; queued steering alone, matching text with a different ID, and sibling
messages do not establish consumption. Receipts survive host recreation and
prevent automatic retries of uncertain delivery. Before launching a subprocess,
Runner registers its command worker with the owned AsyncRuntime. Shutdown joins
the worker's managed OS cleanup before returning and before retiring the Writer;
joining only the outer hook task is insufficient. A closed runtime refuses launch.
Retirement separately uses `shutdown_confirmed/1`, requiring the actual Runner's
one-way cleanup report and normal worker exit. Caught errors, missing reports or
unconfirmed OS cleanup preserve their cause. Legacy shutdown stays idempotent.
Completed hooks still release their intentionally detached helpers; a still-live
managed group cannot produce a confirmed retirement receipt. Native root SessionEnd
runs synchronously after async cleanup with a fresh scoped runtime for its own
command-cleanup reports; its separate receipt keeps diagnostics as well as outcome.
Child admission work runs outside ChildIO, allowing checkpoint
projection to complete without a call cycle.
Receipt append failures reject the triggering child checkpoint, retaining the
actual Runtime commit revision and fencing later IO without replaying effects.
Configured MCP calls in native sessions use the same ledger. Root and ChildIO
bind the factory to the complete public Runtime operation, and Dispatcher forwards
it before Runner queues the hook. MCP `isError` and tool failures preserve their
error and skip success hooks. Native profile resources retain their separate
adapter without duplicate post execution. Explicit `native_tools: false` callers
keep the independent callback path. Dynamic child MCP execution and Deno followup
are separately accepted with the published 1.10.37 fix.

Hook feedback is accepted by Runtime checkpoints, persisted with stable IDs in
Sigma's main JSONL, and restored into a later run. Terminal accepted feedback is
also captured when no next provider request occurs. Reading history never replays
a patch or command.

The earlier 1.10.42 adoption locked the four direct protocol packages and required
plugin protocol dependency. It adopted #109 terminal Goal ACK, #110 notice
expiry, #111 native nested errors, #112 Responses images and #114 nested context. It includes #85's exact managed-child interaction
cancellation. The responder uses the full manager/agent/run/incarnation/interaction
correlation, submits once and preserves uncertain acknowledgements. A cancelled
already submitted native question may correctly remain `unknown_outcome`.
Child Sigma permission replies have a closed, bounded JSON envelope; terminal
child feedback is persisted without breaking an assistant/tool batch. These
adapters preserve the public managed-child ownership boundary.
The published package includes #86/#87/#88/#89. Public checks confirm metadata
discovery and distinct owner staging, plus distinct identities for identical async
questions. Managed-child admission and root/child deferred publication are
integrated; the acceptance checklist distinguishes their verified paths from
remaining host work.

## Verification and limits

The 1.10.42 functional selection passes **56 cases**, covering production Goal3,
terminal/actual-child receipt recovery, preparation failure cleanup, session file
lifecycle, board tools/notifications, Responses images, direct/nested command errors and complete MCP results. No
security, permission or sandbox tests ran. Development/test compilation with
warnings as errors, 40-file scoped formatting and `git diff --check` also pass.
Injected failure cases retain the actual shutdown uncertainty diagnostics.

On isolated port 4630, a real Protocol WebSocket client and newly created Chrome
session exercised Goal, board, actual managed children, native/MCP images and
real Deno. After complete BEAM replacement both root Goals remained complete,
child history and image detail survived, and all three browser images decoded.
Provider requests stayed at 34 and MCP tool calls at eight. Four journals and
Goal/board/Runtime bytes and mtimes were unchanged; the skill-invocations sidecar
kept identical bytes with a refreshed mtime. Full Protocol dumps were identical.
MCP handshake/discovery appended normally. Chrome stayed connected with no
warning/error or horizontal overflow. The owned service/page were closed and
original 4580/PID 815717 was untouched. This is controlled local-client evidence,
not online-model, failed-child recovery or deployment acceptance.

The previous 1.10.38 functional selection passed **58 distinct cases**: 50 across
environment readiness, ordinary/PTY commands, concurrent cleanup, board storage
and file lifecycle, and root/child hook presentation; six tagged child-discovery
cases; two exact HTTP function/custom empty-output cases. Permission/security
tests in mixed files were excluded. Dev/test warnings-as-errors compilation and
the changed-file format/diff checks passed. Intentional process-failure cases
still log diagnostics; passing assertions do not imply an error-free log.

On isolated 4628 with 1.10.37, independent Protocol and Chrome sessions each ran
root/child readiness, actual commands and a real-Deno child followup. Four distinct
resource IDs stayed stable across their runs; 24 Provider requests produced four
command effects. Refresh and a full cold BEAM restart retained exact results and
original journal prefixes. Provider/effect logs and the other three journals kept
their exact bytes/hash/ns mtime. Browser reconnect appended one same-model marker,
so the initial strict whole-journal hash assertion failed and is not reported as
passing. The allowed difference was identified in the existing LiveView form
recovery path; no prompt or effect was replayed.

On isolated 4629 with 1.10.38, Protocol and Chrome each exercised direct/nested
Plan calls in both root and actual managed child. All eight presented results
stayed exactly empty while confirmed Plan content remained visible. Full cold
restart/resume and reload kept original journal prefixes and unchanged Provider/
hook logs: 22 requests and eight actual hooks. Only one browser model-change
marker was appended. Chrome retained six successful root cards, the Plan and a
connected LiveView without overflow or final console warnings/errors. Both owned
services/tabs were closed; 4580/PID815717 was unchanged. These checks use controlled
Providers, without online-model, release or deployment claims.

The integrated functional selection passed 15 cases: six child cases, including direct/real Deno execution, fresh
followup search, complete schemas, actual context accounting and empty-inventory
spawning; eight writer cases cover concurrent updates, reopen/retry, exact Unicode
and CRLF, pagination, subscriptions and write-acknowledgement failures; one separate
ChildIO/public Session fixture verifies same-run rediscovery after a settled outer
error (#97), full schemas, actual MCP execution and canonical history. That fixture
does not establish a root Engine/managed-tree product trigger. Two initial
discovery cases failed before the implementation; three empty-inventory regressions
failed before their correction. This selection excludes permission/security tests.

An independent Protocol client and Chrome new session on isolated 4627 each
completed root search/spawn, child search/direct MCP, followup search/real Deno
and parent completion. Both child journals preserve four complete results.
Refresh and full BEAM exit/new-PID recovery preserved all four root/child journals
and the Provider log byte-for-byte with unchanged hashes/mtimes. Calls remained
26 Provider/four actual MCP functions; cold resume only recreated the two root
connections. Chrome retained six successful root cards, stayed connected and
had no overflow or console warnings/errors. Initial fixture logs include
supervised Provider workers exiting with `:killed`; assertions and restored
results passed. Owned services/tab were closed; 4580/PID815717 was untouched.

The History/Notes integration passed **52 distinct functional cases, zero failures
and no skips**: 33 cases covering History (5), Notes (11), archive integration (6),
raw/Deno patch (3) and Memory search (8), plus 19 exact named functional
regressions (Agent 18, Web 1). The latter include actual MCP/Deno delegation,
direct parent completion, Web catalog/chat and hosted HTTP/history. These overlap
the earlier 39-case 1.10.37 batch and are not added to it. Logs include
InteractionResponder cancellation and teardown `peek_steering` owner-exit
diagnostics; zero assertion failures does not mean a clean log.

On isolated 4625, an independent real Protocol WebSocket exercised all nine
History/Notes tools, `new_context` and old History/Notes reads (14 Provider calls).
Chrome exercised a new Session with nine successful tool cards (10 calls), opened
read results with complete JSON and preserved Chinese text, whitespace and CRLF.
LiveView remained connected, without overflow or console warnings/errors; served
`app-4ec935d5.js` matched the local artifact. Refresh left Notes/Provider hashes
and nanosecond mtimes unchanged. After full owned-BEAM exit and new-PID restart,
WebSocket resume and Chrome reload recovered the cards, original text and stable
item IDs. Both Notes stores and Provider logs retained their hashes/mtimes, both
original journal prefixes stayed byte-identical, and calls remained 24 without
effect replay. Owned processes/tab were closed; 4580/PID815717 was untouched.
These are controlled-provider functional and browser/protocol checks. No new UI
implementation, online commercial-model, release or deployment acceptance is
claimed. Security/permission development and tests are excluded from ongoing work.


Integration tests use real Runtime stores, Linux commands, controlled raw-patch
contracts, PNGs,
Deno, JSONL and Python stdio MCP servers. Controlled providers drive model output.
Browser acceptance additionally exercises LiveView and an independent WebSocket
client; it is separate from a live commercial-model/provider test.

The earlier 1.10.36 inbox/upload scope passed 317 tests with zero failures and four
explicit skips (Protocol 55, Agent 139, Session 11, Web 112). Three skipped raw
patch checks retain #104/#105; production sandbox activation retains #95. Coverage
includes 2,053 ordered cards, complete large replies, strict DTOs, stale views,
adaptive wire fitting, branch/restart reads, scoped resync, bounded upload retries,
expiry/cancel, active steering, idle commit and preserved acceptance after failed
admission persistence or refresh. Nine changed Elixir files passed formatting;
dev/test warnings-as-errors and diff checks passed. Counts overlap earlier runs.

An independent WebSocket on isolated 4622 uploaded 90,157-byte original answers
from a real native three-question call. Partial upload survived disconnection;
duplicate chunks, gaps/conflicts, cancel, stale leaves and exact commits behaved
as documented. No journal/Provider effects occurred before explicit commit.
After full owned-BEAM exit/new-PID restart, buffers were missing; reupload reused
the consumed receipt without another Provider call. Three calls total, log
hash/mtime and original journal prefixes stayed unchanged, allowing ordinary
model-change metadata. The owned listener was stopped; 4580/PID 815717 remained.
This used a controlled Provider, with no new browser, online-model or release claim.

An independent WebSocket on isolated 4621 read all 225 durable cards and
reconstructed a 72,468-byte card with exact length/SHA256. Real reply consumption,
dismissal, stale/mixed-mode rejection and identical retries passed. After a full
owned-BEAM exit/new-PID restart, card bytes and receipts matched; Provider calls
remained one with unchanged log hash/mtime, and journal prefixes stayed identical
apart from ordinary model-change entries. The owned listener was stopped;
4580/PID 815717 was unchanged. This is controlled-provider protocol acceptance;
the LiveView UI and online provider were not newly tested in this paging scope.

The preceding 29-file regression passed 436 tests with zero failures and eight
explicit skips, including six production raw-patch checks blocked by #104/#105.
The other skips retain #95/#99; no blocked capability is counted as passing.
Formatting for 22 changed Elixir files and dev/test warnings-as-errors passed.
The prior broader 1,379-test result below is historical and overlaps this run.

Isolated 4619/4620 clients additionally verified exact async admission/checkpoint
consumption, complete idle browser answers, default patch omission, native
reasoning/search/message order and unchanged reasoning replay in the next actual
HTTP input. Both browser pages and Protocol resume survived a full BEAM exit and
new-PID restart. Provider/HTTP counts stayed 8/2, with unchanged log hashes and
mtimes; journal prefixes stayed byte-identical, allowing one ordinary model-change
entry per Web session. Citations remained visible, opaque reasoning stayed out of
text, and unknown usage remained unknown after reload. Final LiveViews were
connected without console warnings/errors or overflow; served JS matched the
local artifact. Owned listeners/tabs were closed; 4580/PID 815717 was untouched.

Independent clients also cover async active/idle replies, exact-retry deduplication,
notice dismissal, complete hosted-search metadata and original citation links.
After a full isolated BEAM restart, cards and citations recover without another
Provider/HTTP request. Runtime Store startup loads a fixed deployed module
vocabulary before safe ETF decoding; it never creates atoms from stored content.
Inbox facts do not become alternative executions. A separate fresh-BEAM regression
preserves an actual completed snapshot and still rejects unknown atoms. Runtime
snapshots now read raw metric facts and preserve only the current Agent's exact
live session/turn/request identities. Reload keeps that work running; ordinary
journal or cold-service recovery still marks unfinished work interrupted. Snapshot
reads never append terminal facts or replay Provider/tool effects.

On isolated port 4618, real WebSocket and Chrome clients verified running reload,
completed reload, and interrupted recovery after an abrupt owned-BEAM exit and
full restart. Native Plan ran once in each session; Provider calls remained four
with an unchanged log hash and mtime. Original journal prefixes were preserved,
allowing one ordinary model-change marker, and no interrupted terminal fact was
written. Both final LiveViews were connected without console warnings/errors or
overflow. The owned service and tabs were closed; 4580 was unchanged. The prior combined
119-file regression ran 1,379 tests with zero failures and three upstream-related skips;
dev/test warnings-as-errors and 174-file format checks also passed.

Commands use `PlainCommand`. Non-PTY execution retains public Linux LocalCommand's
empty environment, stdin and process-group cleanup. With the packaged Linux
helper, `tty: true` creates an independent real 24×120 terminal. PTYs retain their
handles across successful turns, including managed-child followups and real Deno
calls, and preserve UTF-8, whitespace and CRLF. PTYs inherit Native's existing
environment; per-command environment overrides are unavailable. Nonzero payload
exits keep their real exit codes in completed tool results. Commands, cells and
question waiters are process-local resources, so journal recovery restores their
historical results without restarting them after service restart.

Backplane 1.10.43 adds an optional first-party Linux PTY. Source inspection shows
its LocalCommand allows only one active command per workspace; switching would
lose Sigma's accepted same-workspace independent PTYs. It also needs an explicitly
built helper absent from the Hex package, uses a different environment and marks
nonzero exit differently. PlainCommand already implements the public Command
protocol and remains the production adapter. No replacement or local fanout is added.

The helper drains a natural exit's full output before publishing exit/cleanup.
Its PTY writer stays owned through cleanup/draining, preventing the dependency's
drop-time newline/EOF from being echoed into command output. The real slave-holder
regression failed with an extra CRLF before the ordering fix and then passed.
Jobs wait for final Native events before confirming cleanup and retain results
until public release acknowledgement. Host closure also retires the job process.
Nineteen selected Elixir functional cases and four native output cases passed,
including two independent retained PTYs, actual root/child turns, real Deno and
32 independent non-PTY Sessions. Separate WebSocket/Chrome acceptance on 4626
covered a browser reload between prompts and a complete BEAM restart: six tool
results remained intact, Provider calls stayed 5+5, and Provider/launch-file
hashes and precise mtimes stayed unchanged. Final Chrome was connected with no
console warning/error or overflow. Cold reconnect also logged an out-of-scope
`select_model` handler error for a `_target`-only payload; manual reload succeeded.
The owned listener/tab were closed and the existing 4580 service was unchanged.
Backplane 1.10.37's concurrent-cleanup fix (#103) passed real consumer acceptance:
32 independent Sessions retained commands, then 16 closes and 16 cancellations
started concurrently. Cleanup was confirmed, all recorded OS PIDs disappeared,
and the original running-command settlements stayed intact. The 1.10.36 failure
reproduction is historical. No timeout increase or production command serialization is used.
The accepted default is workspace writes, isolated home and denied network.
A separate native launcher and Session-fenced Command adapter are implemented
as preparation, with Linux namespace/FD/seccomp tests and private build-pinned
launcher snapshots. Nix shebang scripts use fixed `/bin/sh` and `/usr/bin/env`
aliases into the exact runtime closure, held in sandbox-owned read-only mounts.
Native acceptance also keeps four commands live in one workspace, verifies
separate private home/tmp and namespaces, exchanges exact stdin payloads, and
stops one command's setsid tree while its peers continue. Fresh sandboxes retain
workspace files without retaining private state. All 28 native tests pass;
this direct-launcher test does not cover production Session/LocalCommand cleanup.
Backplane 1.10.37 provides trusted bootstrap configuration for the former #95
blocker. These modules remain preparation; production uses the ordinary
PlainCommand adapter described above. Security, permissions and sandbox enforcement development/tests are
outside the current work scope. The earlier native evidence below is historical.

The optimized native helpers have also passed a local production-release archive
build, extraction into a new path and standalone installed smoke. With the old
build paths absent, the actual installed BEAM opens its build-pinned packaged
launcher. Two native invocations verify workspace persistence, fresh private home,
read-only runtime mounts, denied socket creation and exit status. The packaged
PTY helper verifies exact Chinese/whitespace input, actual size and cleanup.
`scripts/verify-release-native-smoke.py` also checks candidate tampering and private
snapshot cleanup. The Linux amd64 release job runs this after archive extraction
and before upload. This local Linux x86_64/Nix evidence does not establish remote
Ubuntu/AppArmor or production LocalCommand integration.

The Plan process is also ephemeral, but Engine hydrates its last confirmed
snapshot from the selected raw journal branch before each turn. The details rail
shows this snapshot across reload, compaction and context reset; successful
`exec`/`wait` can publish nested Plan updates. A failed outer call does not publish
an otherwise unconfirmed nested update. Inline tool previews validate raster MIME,
signatures, base64 and GIF structure, with at most four images and 10 MiB per image
and in total. Valid animated GIFs are supported; user upload limits stay separate.
Invalid images preserve text and status, and image-only tool results can render.
MCP cancellation confirms local runtime exit and discards late results; a remote
read retains its bounded client deadline.

Backplane 1.10.37's #98 pre-write lookup rejection is accepted in actual root and
managed-child execution. A completed command handle returns ordinary `not_found`
before stdin is dispatched, and the same turn can run another command, directly
and through real Deno. Child Store completion and exact JSONL results also pass.
Generic errors still do not prove non-dispatch; Sigma manufactures no receipts.
The original ordinary Error archive regression additionally passes on 1.10.48;
both original resource-scope full-retirement cases also pass on 1.10.50.

The #99 direct-parent-completion lifecycle is accepted: interrupting an active
child stops its Provider and retained OS command, closes the roster entry, and
allows the parent to complete immediately without a replacement followup.

Context windows are recovered independently of ephemeral resources. JSONL retains
the complete display transcript and a separate active provider projection; retry,
fork, compaction and restart respect the selected branch. After an interrupted
Engine, the next prompt reconciles through the Writer before sending a request.
Failed durable reads stop admission and can be retried without reviving old context.

Remaining work includes additional command platforms/environment types,
archived-child discovery beyond its original inventory, abrupt loss before a durable
export stage and missing lifetime facts. The board raw argument envelope retains
its existing boundary. Current work excludes safety/permission/sandbox development
and tests. The external web/image services, actual registry selection, remote
encrypted History and notes.thread_hint remain the five user-deferred TODOs.
See the [alignment checklist](../superpowers/plans/2026-10-24-codex-tools-alignment.md).

The public #117 archive consumer uses LifetimeRecovery's immutable evidence,
selects exact durable roster runs and restores original child identities. With
1.10.44, complete assistant metadata is admitted. ChildIO now explicitly takes
ownership of the exact recovery-opened child Store, linking before recovery
unlinks and retiring it under the child owner. Three handoff lifecycle cases and
the Goal-accounted rename/followup path pass.

An independent two-BEAM probe passes real rename, cold reopen and same-child fresh
followup with complete Unicode/CRLF assistant metadata, no old Provider/tool replay,
unchanged original Goal accounting and only six fresh tokens from three responses.
This is controlled Provider acceptance, not a real-Deno cold archive claim.
The original native Error archive and idle restored-child transfer regressions
now pass with official 1.10.48. The completed-handle error, real-Deno continuation,
rename, restored result/history and single-command-marker assertions are retained.
No result is stripped or rewritten. Historical 1.10.44 client/package and 1.10.45
Goal/readiness evidence does not claim a 1.10.48 installed release.

`tool_search` uses the published [backplane#87](https://github.com/gsmlg-opt/backplane/issues/87)
metadata search and [backplane#88](https://github.com/gsmlg-opt/backplane/issues/88)
owner fencing. Inventory is fixed for a run, refreshed on the next run, and can
exceed fifty tools without being eagerly advertised. Same-batch guessed calls
cannot execute before publication; the next Provider request or Code Mode cell
uses the admitted catalog. Legacy non-native sessions retain eager MCP functions.
Backplane 1.10.37 also publishes #97 discovery-discard recovery, #90 direct-model
History/Notes exposure and #91 conditional Goal idle withdrawal. The #97 standalone
ChildIO/public Session fixture passes; actual root Engine/managed-tree product
catalogs currently contain no ordinary settled-error trigger after nested search.
The fixture also passes on 1.10.38. If a real tool introduces that behavior, its
product acceptance must follow; a Deno exception terminates its run instead.
History/Notes
now use the real selected-Writer archive, durable agent directory and shared
rollout Notes host described above. Goal production registration, terminal ACK
and idle admission are integrated. Backplane 1.10.43's public lifetime reconciliation
also handles prospective provider-only failed children: a transcript-owned writer
retains immutable admissions, exact Conversation exits and versioned closure
receipts. Actual Provider/native/hooks retirement precedes child Store settlement;
Registry, child Session, deepest child, manager and root Session reconcile through
the public API and persist their actual ACKs. Goal receipt accounting remains
attributed to the original run and charges once. Receipt resealing follows the
same descendant-first order after Goal ACK changes Store revisions.

A new root run requires independent root native/hooks/SessionEnd facts and the
complete acknowledged ownership tree. Historical `unknown_outcome` and uncertain
Provider intents stay unchanged; only new work starts from committed context.
The writer follows the immutable journal header through rename/adopt, while each
manager retains its original route identity. Missing old observations and other
unfinished work remain explicit recovery boundaries. This does not restore or
continue archived children.
Explicit empty stopped text retains its separate 1.10.38 consumer acceptance.
With 1.10.42, Responses image results use the public typed Codec, paired to the
actual function/custom call; existing data URIs and MCP image detail survive
HTTP, JSONL and history. Tool previews do not double-prefix existing URIs, and
user-upload behavior is unchanged. Responses audio/resources/links remain
unsupported; #108 only adds the Anthropic PDF URL subset.

The selected `wait_for_environment` host now uses real local command-runtime
startup. PlainCommand boots the existing LocalCommand and checks existing terminal
capabilities asynchronously, then reports its actual result to CodexResources.
That resource owner can answer readiness queries while the command server is
starting. Commands themselves queue until startup completes or return its saved
error. Environment IDs follow resource generations, and both Provider context and
remaining-token accounting use the same projection. Published 1.10.45
[#128](https://github.com/gsmlg-opt/backplane/issues/128) returns failed startup
immediately with environment ID, original class and a bounded UTF-8 reason;
closed/unavailable return not_found. Native Control exposes ordinary is_error
results, including inside real Deno, allowing a later native Plan to execute.
Starting retains its existing timeout/cancel behavior. Functional acceptance uses
an actual failed PlainCommand bootstrap through the public callback, native root
Conversation and complete Writer/Log history; full Engine startup-failure
injection is not claimed and no production injection boundary was added. History
preserves results without recreating a live environment. This does not establish
sandbox readiness; sandbox and permission development/testing remain excluded
by the current user instruction.

The earlier 1.10.45 functional verification runs 80 cases in 12 functional-only files:
75 pass; three child-resource cancellations (#131), an ordinary Error archive
(#126) and idle archived-child transfer (#133) retain their original failures.
Dev/test strict compilation, 16 scoped format checks and the five-entry lock and
diff audits pass. This is local controlled-provider acceptance; the earlier real
browser and installed plugin-package evidence remains explicitly 1.10.44.

The earlier admission-recovery selection passes 44 functional cases in eight
files, including five new regressions. Expanding to child/lifetime recovery runs
65 cases with 16 failures; the exact pre-change source reproduces the same 16
failures in the two affected files (21 cases). They expose a consumer cycle:
archive export waits for the child's Goal ACK, while the host requires export
before returning the retirement needed for Goal recovery. Live retirement now
separates those stages: execution confirmation is committed before a separate
archive job; independent root hooks/SessionEnd permit original Goal delivery/ACK,
then public child/manager/root-Session ACK refresh and archive completion. Actual
manager, Session/Registry, resource and recovery owners remain available until
their stages finish. Later errors retain both the original cause and completed
archive/Session-stop acknowledgements.

Explicit retirement, operation reopening and rename/adopt/delete require full
completion while Goal remains available for child accounting. Root-only retirement
retains the existing deferred root-recovery boundary, and failed no-Conversation
Goal preparation fully closes its reserved Session. That batch's Goal/root selection
passes 51 functional cases; four stage cases, including actual failed-child rename,
also pass. In that 1.10.45 batch, an expanded 30-case selection had 18 failures,
retaining all sixteen earlier names plus the new full-flow case and #126's Error
archive. The next real Provider started after live recovery, but public tracing
confirmed #133 prevented final root-only completion with an idle restored child.
The current 1.10.48 outcomes above supersede that failure inventory. A separate
13-case adjacent check in that batch retained one standalone
plugin fixture on-exit shutdown failure; its code was not changed in this batch.
These selections overlap and do not constitute full-suite acceptance.

Stop subagents now uses execution-only retirement when the root turn has already
completed. Web and Protocol wait for actual child execution confirmation while
retaining the manager and archive owners; full retirement and file operations
still require Goal ACK and archive completion. The host retains original failed
execution results, including ordinary write causes. SessionLive keeps Completed
after successful child Stop and displays actual command errors without leaving
the page indefinitely on “Cancelling…”. Root hooks/SessionEnd remain independent.

The current detached-Stop batch passes 63 Goal/root/Provider/environment/command
functional cases and an integrated selection of six lifetime stage/cancellation
cases plus two new Web cases (seed 43157). The expanded child/lifetime/archive
selection has 32 cases and the exact same 18 failure names as the preceding
30-case run; all original assertions remain. Actual Chrome and `/agent`
WebSocket flows on isolated port 4685 verify successful Stop and a real
retirement-file write failure, repair and later explicit full retirement. Twelve
controlled-Provider calls have twelve matching observed DOWN facts; two full-BEAM
replacements and client reload/read add no calls. Ten journal/log files retain
exact bytes and mtimes on the second cold read. The owned service/pages are
closed and original port 4580 is untouched. This is local client and persistence
acceptance, with no installed-release, online-model or unresolved archive-path
completion claim. See `/tmp/sigma-cancel-stages45-vvuyjawz` for bounded evidence.

Orderly shutdown now persists public #134 stages before the original manager and
writer exit if actual execution/root components are confirmed but Goal/archive
completion fails. It stages all eligible unarchived descendants, queues behind
control jobs, preserves the original error and never marks full completion.
Cold recovery performs real Goal ACK and receipt refresh before public offline
completion and parent-first restore. Complete journals are committed atomically
with Runtime snapshots; missing legacy prefixes and abrupt loss before staging
remain errors. Actual nested recovery, independent-BEAM reopening, queued shutdown
and completed-task races pass with original no-replay/accounting guarantees.

See the [protocol integration](../contracts/codex-tools.md) for public contracts,
transport, approvals, lifecycle and evidence boundaries, and the historical
[retirement design](../superpowers/specs/2026-10-23-legacy-tools-retirement-design.md)
for the original removal decision.
