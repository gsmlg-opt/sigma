# Architecture and acceptance history

## Initial command yield alignment (2026-11-27)

Backplane Runtime 1.10.107
([#196](https://github.com/gsmlg-opt/backplane/issues/196)) separates the initial
command wait from stdin polling: `exec_command` defaults to ten seconds and yields
within thirty seconds with the same running session; empty stdin polls retain
their five-minute bound. Sigma's root and child timeout selectors reserve the
effective initial wait plus five seconds for result settlement.

The release is published on Hex with documentation, and Sigma locks 1.10.107.
Registry checksum and downloaded package contents match the qualified archive
from Backplane commit `9334ba6a`. Against that downloaded package, eighteen
runtime/policy cases and one Writer-backed Agent turn pass, including the real
thirty-second command regression, command-number cases and root/child timeout
cases. The Agent turn resumes the same command through stdin and persists exactly
one initial command result.

Standalone Runtime and Sigma's Elixir compilation pass with warnings as errors
in isolated build directories; the consumer also rebuilds the command helper and
Code Mode runner. Frontend assets are not qualified: the isolated checkout lacks
generated frontend resources and logs a vendor prebundle error during compilation.
The running service remains on 1.10.106; no restart or deployment was performed.
Historical unknown outcomes and the separate command cancellation-proof gap are
unchanged.

## Malformed tool arguments and session controls (2026-11-27)

The live `fork_ad237257be91cb4e` transcript contained a function-style
`write_stdin` call with `chars: {}` and numeric session ID 4902. SessionLive
called `String.trim/1` on that map while projecting the tool card, crashing both
the live update and asynchronous history reload. The browser repeatedly
reconnected and displayed Loading instead of the persisted failed turn.

Tool summaries now trim only binary input and display only scalar summary
fields. Structured malformed values stay intact in the raw tool input. A
Writer-backed LiveView regression reproduced the original crash before the fix
and exercises live updates and history reload. See
[tool projection and deletion](session-tool-projection.md) for the complete
behavior and validation boundaries.

The fork's final Runtime revision 249 independently records `unknown_outcome`
for a later `write_stdin` with empty characters and `eof: true`. Its execution
intent started, but its result is absent. Provider work finished; native and
manager retirement records are confirmed, while async-hook and SessionEnd
acknowledgements are absent. The old service used Runtime 1.10.104. Two
RepositoryLive delete confirmations are logged; the user's screenshot confirms
the existing active-turn rejection. Delete now reserves admission, requests the
existing Stop flow and waits for owned tasks and actual retirement before
removing files. Queued resources are released without starting their work.
The reservation covers recovery decisions and owner loss; failed retirement
retains its evidence and supports an explicit retry. Five Agent and one LiveView
cases pass on the public dependency graph (seed 527311), including the lost
acknowledgement case. No real session was deleted or continued during diagnosis.

## Dependency upgrade and Formata image metadata (2026-11-27)

`mix hex.outdated` and `mix deps.update --all` updated the five Backplane packages
to 1.10.106, the DuskMoon Bundler native family to 10.1.15, the HTTP family to
stable 1.0.0 and lazy_html to 0.1.16. Direct requirements use two version
components. Image dimension estimation now calls `Formata.ImageInfo.info/2`;
the redundant ex_image_info dependency and unused lock entries are removed.

The Phoenix Hex package and all direct DuskMoon npm packages share release
2.1.0. Hex offers duskmoon_phoenix 2.2.0, but the corresponding npm
`duskmoon_phoenix@2.2.0` is not published. The lock retains the complete common
release until both package registries offer it. This is the only remaining
update reported by the final `mix hex.outdated` check.

The npm layout places Core dependencies beneath individual Elements packages.
Sigma's OXC task now retains importer-relative `node_modules` lookup before the
umbrella fallback. Its unchanged self-containment check and all three selected
asset cases pass; Bun's AST reports no imports in the intermediate or final app
bundle. No dependency source was patched.

Runtime 1.10.106 is now available from Hex. Its published archive has SHA256
`08627899d080be2dc1caffe2828cc4488d33823a6e791948ac701f1d2c1d5a88`.
All 152 source files match the qualified candidate below; archive ordering,
compression and Hex build metadata account for the archive checksum difference.
Current validation uses the actual locked public packages without path
overrides. Earlier candidate acceptance below retains its historical scope.

Public-package validation passed 64 selected Agent cases (seed 527312), two
additional active-delete Runtime cases (seed 527311), 45 HTTP/stream/recovery
cases (seed 527307), 13 tool-projection cases (seed 527310), and 46 JavaScript
hook cases. Native builds and the session, pipe and exit-acknowledgement probes
passed. The selections do not claim the full suite, Linux execution or remote CI.
The earlier five Linux `/proc` failures below retain their historical scope.
Evidence: `/Volumes/Data/tmp/sigma-deps-upgrade-zwchi4ni/`.

## Automatic uncertain-operation recovery and incident collection (2026-11-27)

Matched live root terminal callbacks now reserve automatic continuation through
the existing public cessation and durable source-to-target decision. The original
unknown result remains absent. Queued user followups retain their content and
resources; otherwise the fresh run instructs the model to report uncertainty,
inspect current state and continue. Stop wins before replacement host adoption.
An ineligible synthetic probe restores the original failed identity; preparation
failure never recursively schedules another attempt. Cold reads do no work.
See [Automatic recovery](automatic-recovery.md) for the complete behavior.

Live root/child tool, Provider and selected Runtime failures and root recovery
transitions produce bounded immutable JSON records under the repository session
directory's `.incidents/<root-header-id>/`. Actual session file lifecycle checks
verify retention through rename, cross-directory adoption and deletion, with an
independent header for forks. The collector is auxiliary: it supplies no cleanup
proof, invented result, uploader or retention daemon. The
[incident format](operation-incidents.md) defines correlation, bounds, static
summaries, publication durability and future collector discovery.

The serialized Runtime 1.10.106 extracted-package consumer passed 24 Agent cases
(seed 527211) and four selected LiveView cases (seed 527210), including real reads,
commands, gated SessionEnd, Stop before admission, stale terminals, queued
resources, lost preparation acknowledgement, cold explicit continuation and
original Store preservation. Strict compilation and asset builds passed. The broader lifecycle
and command selection passed 51/56 cases (seed 527207). The five failures reached
existing Linux `/proc/<pid>` assertions on this macOS host; they are not claimed
as passes. Intentional missing-acknowledgement and older teardown diagnostics
remain in the evidence logs.

This was candidate acceptance before Runtime 1.10.106 publication. Sigma's
lock and running dev service retained 1.10.104 at that boundary. Published
dependency adoption is described above; committed source validation and
orderly service replacement are separate acceptance steps.
Evidence: `/Volumes/Data/tmp/sigma-eof-qualification-issiln0c/auto-*.log`.

No real Provider prompt or Continue was submitted by this validation. A new
readback found the real journal and four lifecycle/index files had advanced at
13:07–13:16 CST, before these tests began at 13:37. Their actor is not inferred.
All 326 other files in the original 331-file manifest, including the original
unknown Runtime snapshot and journal blocks, remain byte-identical. The current
JSONL still starts with the entire saved original journal. The earlier 331/331
manifest check describes its earlier observation, not this later state.

## Command stdin EOF and historical continuation (2026-11-27)

The failed `session_PcoLfe8yF82ZZONs` ended at a non-PTY `write_stdin` request
with empty characters and `eof: true`. Its tool result is absent; all Provider
requests completed. The generic lost-worker outcome does not establish a worker
crash. PlainCommand lacked the public input-close callback, and ordinary macOS
Port pipes could not implement half-close. Subsequent unconfirmed retirement
obscured that first failure. The earlier journal timeout is a separate incident.

PlainCommand delegates non-PTY input close to public LocalCommand with
`pipe_stdin: true`. The upstream macOS session helper owns the actual child stdin
pipe, flushes accepted input before acknowledging EOF, and independently drains
stdout/stderr through exit. Exact guardian evidence, guardian reaping and a
successful broker Port exit remain required for cleanup confirmation. macOS
cleanup covers the original process group; it does not claim Linux session-wide
process discovery. A dropped EOF acknowledgement retains uncertainty.

PTY jobs expose their actual transport. Unsupported EOF is rejected through the
SDK's existing pre-dispatch contract before any accompanying characters are
written. PTY input remains usable afterward. No control character substitutes
for pipe EOF. Setup, development startup and release assembly build Backplane's
macOS command helper or Linux pipe/PTY helper for the selected platform.

A lost historical command result remains `unknown_outcome`. Continue requires
the original executor observation and actual native, async-hook and SessionEnd
acknowledgements, then reserves a fresh run. It never reconstructs the old result
or replays the old command. Root continuation does not require a full recovery
journal export; child archive export keeps its separate contract and limits.

Runtime 1.10.106 candidate acceptance used an extracted Hex-format archive with
SHA256 `6ba64184d49bf060eab5d86f8ae30b2cb36486e0accd7d4be7520766db296166`.
The consumer passed 30 EOF/adapter/command/continuation cases (seed 517106),
then eight selected QuickBEAM and managed-child cases (seed 517107). The native
macOS suite passed all seven cases, including slow-reader backpressure and
descendant cleanup. A separately compiled dropped-EOF-ACK fixture preserved
`unknown_outcome` and subsequently confirmed actual cancellation. Native build
and probes also passed from a package path containing a space. Strict compilation,
documentation generation, scoped formatting and diff checks passed.

Earlier consumer attempts retained two unconfirmed command-cleanup results;
their cause was not established. Ten independent full-startup repetitions, six
instrumented Mix repetitions and the final serialized matrix passed without a
cancellation-source change or weaker receipt checks. Concurrent compilation was
present in the earlier attempts, but this does not establish causation. Existing
unconfirmed teardown diagnostics remain in the captured logs. Linux execution,
other architectures and remote CI were not run for this change. Evidence is under
`/Volumes/Data/tmp/sigma-eof-qualification-issiln0c/` and
`/Volumes/Data/tmp/backplane-active-cancel/`. No real prompt or Continue was
submitted to the affected session during qualification.

## Private Runtime Store journal format (2026-11-27)

Sigma's file-backed Store keeps the public Backplane snapshot and recovery
journal contracts unchanged. The private snapshot now embeds a version 2 head
descriptor; immutable content-addressed blocks live beside that record under
`<record>.runtime.journal/`, inside the session's existing `.runtime` tree.
Each block preserves one exact command input, run identity and predecessor.
Explicit journal reads verify hashes, run/revision/incarnation continuity and
the original admission prefix before applying the existing public host-value
projection. Ordinary loads and commits validate the selected descriptor without
traversing historical blocks.

The writer syncs and publishes a block before atomically renaming the ordinary
snapshot. That final rename remains the commit point. A failed block or snapshot
write leaves the previously acknowledged snapshot/journal pair selected;
unreferenced blocks may remain and retries can reuse them. There is no garbage
collection in this change. Fence commits use the same publication order after
the existing prepared-fence ledger. As before, file data is synced, while the
directory is not synced; this is not a new power-loss durability guarantee.

Uncompressed ETF, compressed ETF and Zstandard legacy records remain readable
without a migration write. A private Store-owned ETS cache retains only the
extracted snapshot, original record bytes and validated prefix metadata.
Every operation first rereads the authoritative file and requires exact bytes
for a cache hit. Changed bytes are decoded again; read errors never use cached
state. The next legitimate mutation preserves the complete original legacy
record verbatim as an immutable prefix block, then links its new entry. Missing
or incomplete journal prefixes remain incomplete. Cache entries are discarded
after version 2 publication.

All references are relative to the enclosing runtime tree, so recursive
copy/move/adopt operations preserve independent journal ownership. This removes
the accumulated journal from routine save/read costs; it does not reduce the
logical size of historical full-conversation inputs. A first cold legacy decode
and an explicit complete journal export can still require substantial memory
and time. Recovery reads never execute Provider calls, tools or outbox effects,
and format migration supplies no missing lifecycle acknowledgements.

Local functional acceptance passed 27 selected Store/journal/child cases
(seed 410232), then all ten storage cases after extending growth to 16/32/64
checkpoints and removing the source before copy reopening (seed 868877).
Five selected Web cases passed (seed 620163), including controlled Providers
that remain active while failed/cancelled/completed events arrive. Strict
compilation, scoped formatting and diff checks passed. Excluded security and
permission cases were not run.
The separate real-Store commit-timeout case also passed (seed 331408): after
the exact timeout and Store resumption, the same Agent completed a fresh
controlled turn with the original image context intact.
After merging the concurrent skills SDK adoption, the published Skill Protocol
1.10.103 consumer passed all 18 selected journal/storage/timeout/cloud-search
cases (seed 607636) and the five Web cases again (seed 453700). Runtime remains
locked to 1.10.104; dependency requirements retain the two-component `~> 1.10`
form. The matching isolated development snapshot passed forced compilation
with warnings as errors.

An independent copy of the actual failed continuation loaded its legacy record
in 2,010 ms; subsequent loads took 8,554–24,904 microseconds. A public fence on
that disposable copy published version 2 in 253 ms, preserving all 51 tool
results and every unrelated run field. Its main raw record is 31,055,693 bytes,
versus 31,055,531 for the current snapshot alone. A new BEAM read the exact
snapshot in 42 ms after the copied tree was moved and its source removed;
all ten copied files remained byte-identical. All eight original transcript
and Runtime files also remained unchanged during these checks. Evidence is
under `/Volumes/Data/tmp/sigma-journal-acceptance-zfayuqdh/`. These are local
controlled and copied-data checks, not another model run in the user's session.

Cold recovery of a retired run also accepts a fully settled boundary between
Provider requests: `running` or `cancelling`, no active Provider/tools/children/
dependencies/wait, empty effects/outbox and only consumed/cancelled intents.
Require a nonempty original-incarnation Provider inventory, every exact Provider
DOWN and all existing host retirement receipts. The public fence/cancel/cleanup
sequence reaches `cancelled`, retaining historical context, results and intent
facts. Failed writes during any of those three transitions can be retried from
the authoritative revision. Active-Provider and terminal-unknown recovery keep
their separate existing requirements.

The root recovery matrix passed 14 cases (seed 126613), including an actual
filesystem publication followed by a lost Provider-completion ACK, a completed
clock result, cold reopening and a fresh controlled turn. Missing Provider DOWN
still blocks without changing the old snapshot. On an independent copy of the
affected session, public root reconciliation took 585 ms and reached revision
692 from 689, preserving all 51 results, 34 Provider attempts, 85 consumed intents,
the exact legacy prefix and transcript bytes. No Agent was started by that
copied-data check. The five existing child recovery cases also passed
(seed 705550), along with strict compilation, scoped formatting and diff checks.

## QuickBEAM Code Mode consumer wiring (2026-11-26)

The migration consumer wiring uses only Backplane's public Code Mode APIs.
`CodexResources.resource_context/2` remains the common context for root and
managed-child profiles; Runtime discovers the same immutable packaged runner
for both, while each cell starts its own process. Sigma does not introduce an
executor, a nested dispatcher or another resource ledger.

Setup builds the development runner with `mix backplane.code_mode.build`.
On macOS, a pre-assembly step builds the existing host process-observation helper,
so direct `mix release sigma` packages it as well as `sigma.rel-build`. Sigma's
Mix release post-assembly step calls the runner task with
`--output <release root>/backplane_code_mode_runner --no-compile`, using the
release build's compiled artifacts. This also applies to the isolated
`_build/<env>/sigma_rel` build used by `sigma.rel-build`; development artifacts
are not copied into that release. Rebuilds replace only their generated runner
directory. The full runner directory includes its own ERTS, application beams,
NIF and JS bootstrap and moves with the enclosing release.

The release workflow checks the archive inventory and executes the extracted
runner on each existing Linux/macOS x86_64/ARM64 target. Its smoke script sets an
empty `PATH` and a temporary working directory and home, supplies no host secrets,
and checks ready, ordered text output, generator yield/configure/resume and EOF
exit. On macOS it also probes the separately packaged host process helper against
the verifier's real OS identity.
This standalone smoke does not establish root/child dispatch, Protocol Stop,
cold journal reads or cross-platform acceptance by itself. Functional consumer
preflights now check public `CodeMode.contracts/1`, preserving actual execution,
results, history and lifecycle assertions. Permission-related cases remain
outside this migration's selected verification scope.

Local macOS ARM64 acceptance used an actual unpublished Hex-format Runtime
candidate in a disposable independent Sigma copy, with its dependency override
confined to that copy. The tracked lockfile still selects the published Runtime;
adopting the QuickBEAM release remains a delivery gate. The final verified
candidate SHA256 is
`9b991b6c142d88f8892cf5d48668419a40bbb7ffc9ef08889525156b3e25b74f`.

The selected functional matrix passed 29 cases (seed 175978), covering public
exec/wait, retained generators and incremental output, timer slices, real child
followups, structured MCP/Unicode/error results, clock cancellation, hooks and
archive reads. The slice fixture uses a real delayed JS timer after its initial
yield so that a paused OS process cannot prevent the required configure ACK.
Two additional child-history cases (`backplane_history_notes_integration_test`
lines 197 and 335) failed on macOS with the original locked Runtime as well;
their retirement/reused-child failures were preserved without migration fixes.

Production warnings-as-errors compilation and direct `mix release sigma` passed.
The tarred/extracted archive passed standalone empty-PATH runner and macOS host
helper probes. The extracted Sigma host also completed an actual native Code
Mode tool call through its controlled Provider, preserving exact output/value 42
and a completed public Store run with four canonical messages. That host smoke
used an isolated home and `/usr/bin:/bin` PATH without Deno, Elixir or Mix.
The same final candidate also passed a real loopback WebSocket Stop followed by
a fresh native Code Mode invocation in the same session (one selected case,
seed 175978). Its fixture preserves custom-tool `input_kind` metadata in the
journal and uses a canonical temporary path on macOS.
A separate stopped BEAM read 31 journals produced by this final run, containing
327 messages and 112 tool results, without starting Sigma applications; all 222
durable/effect files retained their bytes, size, mtime and inode. Evidence is under
`/tmp/sigma-quickbeam-acceptance-5z_3z8gn/`. These checks do not establish Linux,
other architectures, remote CI, actual publication or deployment. The final
macOS archive SHA256 is
`2ee95264410b8e8bad2a1e1fda1ecc2b532f244fd5265505c7cb92b7e7ad43e6`.
Historical versioned acceptance below retains
the engine and limits used at that time.

Moved verbatim from `AGENTS.md` on 2026-11-09 so agent context stays small. These notes record design boundaries plus historical, version-scoped acceptance evidence (Backplane versions, seeds, `/tmp` evidence paths). Check the stated version before relying on any evidence here.


- The 2026-11-04 delivery merges remote `7a2e480` without discarding its Provider repairs, ordered tool projection or 90% compaction policy. Current dependencies retain the remote lock graph: five Backplane 1.10.55 packages, HTTP 0.21.19, ex_json_pointer 0.9.0 and plug_crypto 2.2.1; four direct Backplane minima are 1.10.55. Historical 1.10.53 packaged 55-case/default42/cold-read evidence below keeps its original version and is not 1.10.55 package acceptance. This delivery uses scoped source functional checks and skips automatic CI because existing push workflows include excluded tests.
- The merge's scoped functional checks, strict compilation and formatting pass. Local `mix assets.build` is blocked at Tailwind by duskmoon_vize 10.0.9's GNU NIF requiring GLIBC 2.43 while this Nix host supplies 2.42. Upstream [duskmoon-bundler#9](https://github.com/duskmoon-dev/duskmoon-bundler/issues/9) explicitly makes the newer baseline intentional and is closed as not planned. Do not repeat that compatibility report or introduce a local workaround; full asset validation requires a supported environment. Details and exact functional counts are in the alignment plan.
- User prompts enter through `Sigma.Web.SessionLive`, call `Sigma.Agent.prompt/2`, stream through a `Sigma.Ai.Provider`, then persist/broadcast `Sigma.Agent` events.
- Providers implement `Sigma.Ai.Provider.stream/1` and return lazy streams of tagged events such as `{:start, msg}`, `{:text_delta, idx, text, msg}`, `{:toolcall_*, ...}`, and `{:done, reason, msg}`.
- Configured MCP tools use `Sigma.Coding.Dispatcher`; native collaboration uses Backplane contracts. Shared dispatch and its task supervision remain host infrastructure.
- Child MCP resources borrow the root Agent's current connections through a trusted owner lookup, bounded by the server IDs admitted when the child was created and its current Session/run binding. Resolve the root outside ChildIO's GenServer call to avoid a shutdown call cycle; child closure never owns these connections.
- Legacy built-in tools and their extension registry have been retired; do not restore the old tool app or implementations. Web and protocol sessions select `native_tools: true` while keeping the legacy `tools: []` list empty. Engine composes public Backplane Codex profiles with actual MCP and collaboration contracts; native preparation, permissions, hooks and session resources use explicit host adapters. Unsupported native Provider transports fail before HTTP. Backplane 1.10.36 provides managed-child admission: each child owns its Session/resources and the public manager adopts the binding; an unrelated Session still cannot attach the root manager.
- The historical 2026-10-30 acceptance locked Backplane 1.10.53 for all five protocol packages (source `012b7a750dcee5cfa48118d9c3eb87e03e411e22`). Four direct minima are updated; relative to 1.10.52 only those five lock entries change. HTTP 0.21.17, ex_json_pointer 0.8.0 and plug_crypto 2.2.0 remain; locked resolution passes. #126/#131/#133 shipped in 1.10.46, #134/#135 in 1.10.47, sequential resource scopes #139 in 1.10.48, generator slice retention #140 in 1.10.49, resource_scope_retirement #141/register_code_mode #142 in 1.10.50, and caller-owned Events #144/actual host-effect Goal settlement #145 in 1.10.51. LifetimeEvidence and ToolPostHooks preserve public records/callbacks. Production root/child apply_patch and images retain public raw input/results, call identity, data URIs/detail and replay. #108 does not enable full Anthropic native profiles or Responses audio/resources/links. Existing service 4580 was not started or restarted.
- The prior full-tool Linux x86_64/Nix production release acceptance independently covers 1.10.51: all 42 default native tools, actual MCP resources/discovery, managed-child Deno/followup/interruption, cross-turn PTY/cells and full retirement. Three distinct extracted-release BEAMs prove stopped cold reads (122 messages, 27 durable/effect files and Provider/MCP/hook counts unchanged), then an explicit fresh prompt with the original completed child identity and no old patch/journal replay. The same eight-file 43-case functional selection also passes against actual packaged BEAMs (seed 43188). Actual packaged Protocol and Chrome sessions preserve original Goal host-effect settlement through veto, ordinary work and fresh automatic completion, plus exact Events/MRTR/native-error continuation. Independent BEAM replacement preserves 23 durable file contents, Provider/hooks/Events execution counts and six results per client; 22 files also retain ns mtime/inode, while one existing empty skill-invocations sidecar rewrites []. MCP reconnect adds only discovery/subscription/tool-list reads. Served JS matches the package. Owned services/tabs are closed; 4580 is unchanged. Prior 1.10.49/50 evidence retains its historical scope. Historical unknown_outcome children remain outside the public archive contract, even after confirmed retirement. Other platforms, remote CI, live models and deployment remain separate.
- The historical 1.10.51 root-production audit corrects the explicit 42-tool catalog and stopped-hook presentation assertions. Resource-owner/Plan loss cleans actual retained commands and reports the exact pending turn’s `turn_failed` before Engine starts; old results remain unchanged. Its 16-case selection has 15 passes, one failure and five excluded mixed-file cases (seed 43204). That failure led to backplane#146. Its published 1.10.52 registered-wait fix is adopted below; the original immediate-stop continuation exposed the separate startup gap #147, now accepted on 1.10.53 below. Earlier package/client/online evidence retains its exact version.
- Native clock cancellation now adopts 1.10.53 pre-executor ownership registration and the public `native_clock_wait_retirement`. Runtime owns registration ACK, waiter/executor joins, timer retirement, completion fencing and nested Code Mode correlation; Sigma retains the unchanged authoritative proof and existing callbacks. The original immediate-Stop regression passes with its full continuation assertions (seed 43221, one selected/20 excluded). A new PostToolUse case cancels at public tool_execution_start without waiting for allocation/ACK, validates the proof against the original Store intent and independent binding, completes new work with replacement Session/resources, preserves old effects and confirms full retirement. The four original root/managed-child × direct/real-Deno cases remain; nine-file source selection passes 48 cases (seed 43227). Deno outer exec start is not nested clock admission proof. No local delay, proof, cancellation bypass or dependency patch is added.
- A new independently archived/extracted Linux x86_64/Nix 1.10.52 production package repeats the nine unchanged functional files: 47 passes, zero failures/excluded/skipped (seed 43225), with all 565 product BEAM code identities and runtime paths verified across six Sigma/five Backplane apps. A distinct packaged BEAM cold-loads its newly produced six clock Stores/ten runs and six journals; public ToolEffects revalidates four clock and two Deno outer proofs against original intents and independent binding ledgers. All 44 files retain bytes/hash/ns mtime/inode, with no Agent/Provider/effect resumption. Both BEAMs exit. The detached-helper cleanup error is the existing expected unconfirmed case; its exact helper is absent after cleanup, without rewriting the old result. Evidence: `/tmp/sigma-packaged52-h_29umea/acceptance.json`. The stale nested release cache is preserved; standard Mix release assembled from the verified current prod directory with ordinary checks. No product source/lock changes. At this historical 1.10.52 boundary full-tool/online evidence was still 1.10.51; current 1.10.53 full-tool acceptance below supersedes the package scope only. Separate 1.10.52 client acceptance below covers Events/Goal and stopped recovery. This historical package does not cover the later #147 startup fix; current 1.10.53 acceptance is below.
- Actual 1.10.52 extracted-package Protocol and Chrome clients each complete nine controlled Provider requests and six successful results, preserving exact Events cursors/pages, real Deno MRTR, native-error continuation, the same Goal and its original host-effect veto settlement. Both roots return confirmed durable retirement. A distinct packaged BEAM resumes both original sessions twice through Protocol and Chrome explicitly reloads; complete dumps remain exact. All 27 session files plus Provider/hook logs retain bytes/hash/ns mtime/inode during resume/reload, with Provider18/hooks25/Events10 unchanged and only six MCP discovery reads added. Final orderly shutdown separately writes two host-retirement ledgers for confirmed empty host lifetimes with no native bindings; the other 27 files remain exact. Chrome retains six successful cards, stays connected without overflow, and serves exact packaged JS. Two favicon URLs return 404; intentional stops also log connection refusal. Initial missing-Deno preflight and offline harness-field corrections are retained without prompt replay. Owned services/fixtures/tab are closed; 4580 stays without a listener. Evidence: `/tmp/sigma-packaged52-h_29umea/client/client-acceptance.json`. This historical scope does not extend full-tool/online coverage; #147/#148 are resolved separately on 1.10.53.
- Official [1.10.53 Release 40981188107](https://github.com/gsmlg-opt/backplane/actions/runs/40981188107) publishes #147 commit `54cb4b1f79a5d690498718dd99c18591610e03bb`; #148 is closed and the original consumer regression passes. The earlier Release 40912562108 migration timeout remains historical evidence, not a current blocker; no upstream workflow/tests were rerun. Two local fixes were reproduced before correction: Operations.dump now converts tuple diagnostics to JSON arrays without dropping repair facts or rewriting journal data (Operations4, seed 43230); SessionLive restores selected-branch cancelled tool-only cards during both idle and later active views, keeping Provider input repaired (Web3, seed 43234). An independently archived/extracted final 1.10.53 Linux x86_64/Nix package matches all 565 product BEAM identities and package paths, and passes the unchanged tool48 + Operations4 + Web3 selection: 55 cases, zero failures/exclusions/skips (seed 43237). A distinct packaged BEAM cold-loads seven Stores/twelve runs/seven journals; public ToolEffects revalidates five clock/two Deno outer proofs against original intents and independent binding ledgers. All 53 files retain bytes/hash/ns mtime/inode, with no Agent/Provider/effect resumption. Expected detached-helper uncertainty stays unchanged; its exact process is gone. Evidence: `/tmp/sigma-clock53-e742ylg6/complete/accepted/`. The stale nested release cache remains preserved; the package uses ordinary verified prod release assembly.
- Actual final-package Protocol/Chrome acceptance preserves each original immediate clock cancellation, new Session/resources, next clock and real Deno command work, three successful results/five controlled Provider requests and confirmed durable host retirement. Fresh final-package BEAM resume twice per original session and explicit Chrome reload preserve exact complete dumps and 27 files including metadata, with Provider11/hooks10 unchanged. The earlier cold fixture erroneously replayed a consumed explicit retirement control, changing one empty-host ledger; that failed comparison is retained and the corrected proof uses a new post-retirement baseline. Chrome then starts a fresh turn, reloads while active with the original cancelled card retained, and completes; original Store/proof, journal prefixes, hooks and effects remain exact. A string/list bug in that controlled Provider accounts for one retained failed request before the successful fresh request; total Provider13/hooks10. Initial directory preflight, original dump-script failure and packaged-harness configuration omissions are retained separately. No old prompt/effect is replayed. Final current host retirement is confirmed; owned services/helpers/page are closed, 4580 has no listener. Current full 42-tool package acceptance is 1.10.53 as recorded below; real-online evidence remains the 1.10.51 writerless profile. Evidence: `/tmp/sigma-clock53-e742ylg6/client/`.
- The same final 1.10.53 extracted Linux x86_64/Nix package now executes all 42 default native tools, actual MCP resources/deferred discovery, six V2 tools, managed-child real Deno/followup and independent interruption, cross-turn PTY/cells, Goal and hooks. Three distinct packaged BEAMs verify five versions and 19 core module paths, then cover execution, stopped cold reads and explicit new work. Cold reads retain 122 canonical messages, all 42 tools’ results, exact images and two async cards without starting an Agent; all 27 durable/effect files retain bytes/hash/ns mtime/inode, with Provider67/MCP-event12/hooks55 unchanged. Explicit new work reads original Notes/Memory/pre-reset History/Board/completed Goal and continues the same completed child through real Deno/MCP; Provider rises to 79, original journal prefixes and patch bytes/mtime remain exact, and full retirement is confirmed. All owned BEAMs/MCP processes exit. The unchanged functional fixture only substitutes version/local identities; no product code, dependency or global settings change. Evidence: `/tmp/sigma-full53-21bk2iaf/acceptance.json`. This controlled-provider package evidence does not extend online-model scope.
- Real online acceptance now uses the user-selected `prov_3592 / gpt-6.1-sol`. Sigma's Responses projection supplies a nonempty description on every namespace; the missing-description HTTP 400 was reproduced, and the wire regression passes after the local fix. A fresh extracted 1.10.51 package completes six writerless-profile turns / 19 real Provider requests: clock, Plan, raw patch, Unicode command reads, three real Deno cells, exact image consumption, MCP discovery/direct/nested followup and LF/CRLF fidelity. A separate BEAM cold-loads six completed public Store records while all 12 selected files retain bytes/mtime/inode. This is the existing writerless native19 plus MCP4/discovery1 profile, without Writer/managed-child online recovery. The complete Writer-backed profile is still rejected by the chosen service with HTTP 400 requiring encrypted `history.search_contents.query`. That historical failure preceded the local Responses namespace projection. The original complete-profile failures remain separate from the clock startup gap #147 now resolved on 1.10.53. Owned processes are closed and 4580 is unchanged; details are in the alignment checklist.
- Connected root and managed-child MCP functions start as deferred candidates. Children only snapshot functions from the parent's committed catalog; an empty child inventory omits `tool_search`. Public search publishes at the next model boundary and retains Dispatcher/hooks. Every followup builds a new inventory; context accounting follows the actual Provider tool snapshot. Never reset private runtime state.
- Optional `settings.json` `plugins.registryUrl` configuration adds `list_available_plugins_to_install` and `request_plugin_install` to native root and managed-child profiles. PluginResources uses the public PluginProtocol HTTP catalog and one application-owned writer per `plugins.requestsRoot` (default `~/.pi/agent/plugins`) for `requests.json`. Keep exact arguments and original Runtime invocation identity; exact retries return the original durable request without rewriting. Session closure leaves the writer available, and history/reopen never replays requests. Actual Protocol and Chrome flows accept ordinary settings loading, child followup, real Deno and full-BEAM history recovery without additional Provider/HTTP/request effects. `requested` records a request only. Explicit host install/activate APIs use public PluginProtocol resolve/download and a caller-owned Plugins.Session, with immutable packages and separate installation receipts under the same writer. Retried installed calls and cold reads do not repeat HTTP, writes or MCP starts; pending publication is confirmed only from an existing complete tree. `/settings/plugins` and Protocol `plugins.requests`/`plugins.install` now share PluginInstallations: revision-checked global host summaries and explicit immutable-request installation. Protocol requires `plugins.install.v1` and the live Agent's actual configuration; installation runs outside the Agent callback. Keep successful receipts independent of later refresh or V1 size errors, and keep the native requested history unchanged. Automatic plugin MCP preparation and the original-call installation-completion flow are described below. No registry is selected by default; root defaults remain 42 tools, writerless 19, with two additional tools only when configured.
- Each real root/managed-child binding refreshes the application plugin writer and pins the newest installed release per plugin in its configured registry. PluginSkills reads those immutable installations through public PluginProtocol/Archive and the existing Skill Protocol parser; SkillResources merges their explicit registry/plugin/release references with automatic local skills. Native `skills::list`/`skills::read` use the existing immutable Snapshot, paging and cleanup. Installation during an active run appears at the next binding. These reads do not activate MCP or scripts; a new binding independently prepares the optional PluginRuntime catalog below.
- PluginRuntime owns independent public Plugins.Session instances per root/child binding and exposes their actual function descriptors as deferred MCP candidates through the existing Dispatcher. Children filter their own callbacks against the public manager's committed names. With 1.10.44, explicit close captures the exact public Session.close cleanup report before stop; both observe the same memoized cleanup attempt. Seven functional cases pass, including the original controlled cleanup-failure case, unchanged errors, one attempt and continued work on another binding. An actual managed-child/default-stdio helper-crash case also passes: the fixture target binds its exact packaged guardian, public ChildIO.retire retains the original unconfirmed report with missing waitpid/pipe/helper-exit evidence, repeated retirement returns the same error, and the independent root plugin continues. Aggregate retirement stays unconfirmed; process non-running is not proof of reaping. No production injection boundary was added.
- Native plugin installation now uses 1.10.44's #124 completion outcome. The original call waits outside the application writer for an explicit Settings/Protocol installation. New requests retain public plugin_request_id and immutable original invocation; native-installations.etf separately records actual :settings/:protocol confirmation and the installed public Archive result or exact Error. Only the exact successful fact and a still-valid original binding return completed/user_confirmed; never infer confirmation, auto-install, or rewrite settled requested history. A successful host installation survives later native-fact persistence failure; the waiter retains the actual uncertainty. Public Runtime owns the outer result identity.
- Cancelling a started native plugin request uses public DynamicRuntime.plugin_install_wait around observation only, after the immutable request commit. LifetimeEvidence preserves the exact authoritative native_plugin_wait_retirement/code_mode_retirement for public reconciliation. With 1.10.50, root direct/real-Deno cancellation with and without PostToolUse, late explicit installation, fresh binding/catalog/MCP and full retirement pass unchanged. #142 registers the actual Code Mode worker before execute/resume through the public callback retained by ToolPostHooks; no local cancellation bypass or hooks removal. Two strengthened managed-child cases reach proof reconciliation/full retirement, then reject archived followup when installation introduces tool_search absent from the original ceiling. This independent inventory boundary stays outside the excluded permission scope; do not expand grants. Original request/history/Runtime files remain unchanged; no installation replay or fabricated not_started proof.
- Actual 1.10.48 and 1.10.49 Web/Protocol installation completion passes with local fixture registries: real Deno/Protocol and Chrome/Settings wait for explicit installation, retain completed/user_confirmed with original public request identity, and read complete installed skills on the next turn. Each version's live reload and independent BEAM replacement plus explicit browser reload preserve all nine selected durable files and the 10 Provider/4 HTTP counts. The 1.10.49 run independently checks exact invocation facts and actual settings/protocol confirmation sources, three successful browser cards, two installed rows and served JS hashes; its owned services/tabs are closed. This is controlled-provider source acceptance, separate from installed-package acceptance and the unchanged 4580 service. The 1.10.48 automatic reconnect exposed select_model without a model value while loading and FunctionClauseError. The 1.10.49 run reconnects successfully, with expected connection-refused messages during intentional shutdown; the earlier loading race was not reproduced or fixed. Preserve that historical UI limitation without silently changing unrelated model selection.
- MCP resource operations use #131/#139 public DynamicRuntime.resource_request_scope/resource_request in the actual effect caller. Sorted servers/pages are sequential, share the public invocation deadline and 128-slot total bound, and preserve reserved Client options. Root/managed-child interruption preserves the exact pending request, earlier completed pages, independent caller, same-client reuse and parent continuation. With 1.10.50 #141, LifetimeEvidence also retains the unchanged public resource_scope_retirement record from the authoritative Store. Both original direct/real-Deno paginated-child full-retirement assertions pass; public reconciliation validates exact scope/invocation identity. No local proof parser, shared-client shutdown or inference from immediate cancellation is added. Connected profiles also admit mcp_events through public DynamicRuntime.event_request/2 and Client.start_list_events/2. Return one raw page with exact opaque cursor, descriptor order, schemas and metadata; Client owns MRTR wire identities. Preserve authoritative event_request_retirement for public reconciliation. RPC code/message/data and domain-error pages belong in public Error details, since cause is omitted from model serialization. Native Code Mode rejects with the original message; callers can catch and continue, while Store retains complete errors. Nine functional cases cover direct/Deno, root/child cancellation, same-client/same-child reuse, history without replay and full retirement.
- Actual 1.10.50 Protocol/real-Deno and Chrome Stop cancellation with automatically loaded PostToolUse retains exact cancelled proofs; late explicit Protocol/Settings installation leaves the original requests, two journals and two Runtime files byte/mtime/inode-identical. Both next prompts execute plugin MCP and read complete Unicode/LF/CRLF skills; full retirement confirms. Independent BEAM replacement and stopped resume/reload add no Provider/HTTP/hook/MCP work: 32 durable file contents match, 31 also retain ns mtime/inode; one existing empty skill-invocations sidecar rewrites `[]` on resume. Owned services/tabs are closed. This is local controlled-provider source acceptance; the 1.10.50 installed production-package acceptance above is independent.
- Goal post-effect/pre-Runtime settlement now uses official 1.10.51 public Goal.settle_host_admission/4 (#145). One hook execution scope belongs to each actual automatic executor: retain ordered command/MCP results, seal future starts, join actual workers/cleanup and executor DOWN, then join the durable settlement before terminal events. Persistence failure keeps original facts and cause for persistence-only retry; uncertain cleanup stays unconfirmed. Hook ownership extends through Session/Goal binding and run-index preparation. Engine hands off to Runtime only after preparation succeeds. A real index failure requires confirmed reserved-Session closure before host settlement; cancellation during preparation fences binding. A successful binding/index followed by uncertain handoff/startup retains ordinary indexed-run recovery, never a no-start inference from missing Store. The original hook-veto continuation plus real index-failure/cancel regressions pass through same-Goal continuation and full retirement. The unchanged 1.10.50 failure is historical; no Goal reset, invented receipts or dependency patch is added.
- The requested one-hour check at 2026-10-27 13:48 Asia/Shanghai found 1.10.43 only. Subsequently official 1.10.44 was published and adopted; historical unavailability is not a current blocker. Original functional regressions still determine consumer acceptance. Root/child plugin MCP now uses the public verified stdio cleanup path, which requires explicitly building `mix backplane.mcp.stdio.build`; the local release alias and CI/release workflows prepare the package-owned helper, and artifact assembly probes its installed copy. Ordinary configured MCP retains its existing transport mode. No helper is compiled on activation.
- Managed-child MCP resource tools borrow the root's actual connected clients under inherited grants, with run/incarnation-fenced access; children do not own those connections. Backplane 1.10.37 propagates committed root discovery to managed children; real MCP execution and a real Deno followup are accepted. Do not manually expand parent authority or rebind an active Session.
- Native image results stay in their assistant tool card, including image-only results. Tool previews validate raster bytes with a 10 MiB per-image/aggregate limit and accept valid animated GIFs; keep the separate user-upload policy unchanged. Public #98 completed-handle rejection is accepted in root and real child direct/Deno execution: native lookup returns a settled not_found error before stdin, the same turn continues, and child Store/JSONL retain the result. Generic errors do not prove non-dispatch; never invent receipts. The original Error archive regression now passes on 1.10.48; the original cancelled MCP resource-scope full-retirement regressions also pass on 1.10.50.
- Cancelled-turn tool cards with no result use the existing neutral pending component state and explicit `turn cancelled` label. Per-message durable turn identity controls the label, including earlier assistant rows, later turns and reload. Stopped display restores only cancelled assistant messages present in the captured branch from the Writer journal; Provider replay remains repaired, and no tool result or Runtime settlement is invented. Settled success/error results keep their original state.
- Native skill resources use the actual automatic catalog and immutable Skill Protocol bundles; listing/reading never activates a skill. Context resets persist a branch-local window before the next Provider request; display history and provider context are separate projections. After interrupted turns, reconcile through the selected Writer branch before new prompt effects.
- Protocol skill-invocation recovery writes only when preparing/queued/running records actually become interrupted. Missing ledgers remain absent; empty and terminal ledgers retain original bytes and file identity. Per-session local :global transactions replace the caller-owned ETS polling table: a completed caller exiting must not break another session's in-flight recovery. A public-API FIFO regression first reproduces that crash; all seven store checks now pass asynchronously in source and against actual extracted production BEAMs, with separate direct Protocol/WebSocket resume coverage. The lock-fix package repeatedly cold-resumes both original Protocol sessions, preserving all 23 durable files' bytes/hash/ns mtime/inode, the absent ledger and Provider/hook/Events counts. The preceding ledger-only package independently passed Chrome load/reload; Chrome was not repeated for the lock-only change. Earlier 22/23 metadata evidence describes the pre-fix package. Owned services/fixtures/tabs are closed; 4580 is unchanged.
- Writer-backed native root sessions expose History4, Notes5, Goal3 and Board9, making 42 native tools including environment readiness before optional MCP and V2 collaboration; writerless roots retain 19. History reads the Writer-selected raw ancestry, including before compaction/reset, with persisted window/item IDs and independent image blocks. Resolve child Writers outside Subagents; omitted names retain the exact child Session, while named archived lookup uses the latest durable registration. Notes share one application-owned serialized writer at `<root_transcript>.subagents/notes.json`, preserve exact UTF-8/LF/CRLF, and follow session file lifecycle. History/Notes retain public direct-model-only exposure and are excluded from nested Code Mode. Reads and recovery never replay effects. History and Notes are local. Remote Codex archive services, encrypted archive replay, and `notes.thread_hint` are outside the project scope.
- Confirmed native Plan content is projected from the public Plan process into canonical tool-result metadata. UI reload and Engine hydration use the selected raw journal ancestry, including plans before compaction/reset, without replaying effects or restoring sibling-branch state.
- Native async questions/messages use a Writer-owned durable inbox. Runtime acceptance is not user delivery: require a settled successful invocation, persist reply facts and exact Runtime admission identity, and prove consumption from both the correlated selected canonical user and matching full-content Runtime checkpoint. Keep global receipts without lifetime card/fact ceilings while projecting only the selected raw branch; never automatically retry an uncertain delivery. Protocol V1 retains its explicit wire limits. Use mutually exclusive `async_interactions.pages.v1` for complete outbound cards: selected-view revisions, summary pages and base64 JSON chunks; changed events are invalidation hints, and stale reads resync. Use optional `async_interactions.uploads.v1` with pages for inbound complete reply JSON: eight volatile 256 KiB buffers per Agent, 12 KiB raw chunks, fixed five-minute monotonic expiry, explicit commit and current Writer fences. Chunk receipt must not reconcile or write facts; restart requires reupload, then durable dedup still applies. Preserve durable dispatching receipts and the actual error if a later admission write fails; reply-less unknown origins cannot acknowledge new answers. Preserve successful mutation receipts when a later snapshot fails. Restore trusted steering metadata by the exact Runtime admission ID before building Provider context.
- Native async post hooks require an owned Writer and AsyncRuntime. Bind callbacks by original handler index before queueing and save original context directly to the Writer; do not retain invocation-bound callbacks. HookDelivery verifies the exact successful public Store intent, discards cancelled/failed origins, and uses active steering or the next accepted real prompt without starting an idle turn. Separate journal receipts from admission and consumption: require the selected canonical message and matching Runtime checkpoint; never redeliver unknown outcomes. Child steering runs outside ChildIO to avoid commit call cycles. Receipt persistence failures reject the triggering checkpoint while preserving any actual sidecar commit. Native root/child MCP callbacks bind the same Writer factory to the full public Runtime operation through Dispatcher; MCP-only children also poll active feedback. MCP isError/tool failures skip success hooks. Explicit native_tools:false callers retain their independent callback; dynamic child delegation has separate 1.10.37 consumer acceptance. Block/stopped decisions use public ToolEffects.present: actual settlements and model/nested-consumer presentations remain separate. Backplane 1.10.38 preserves explicit empty stopped text through root/child direct/Deno results and recovery; never rewrite a completed native settlement or substitute fallback text.
- Runtime Store startup loads the fixed deployed host/protocol module inventories before safe ETF decoding; a process restart inside the same BEAM does not test this cold-start boundary. Never derive modules or create atoms from record contents. Async inbox facts remain auxiliary entries in both selected-history and branch-summary projections.
- Provider-hosted web search is opt-in OpenAI Responses configuration, outside the local registry/grants. Persist complete native output/citations with provider/model/endpoint affinity, including reasoning/encrypted content on turns without a search call; reject unknown output and reject incompatible replay before HTTP. Do not fabricate local tool results or pass native metadata through truncating generic projections.
- Protocol clients may select mutually exclusive `provider_hosted.pages.v1` for complete durable native results. Capture the Writer-selected raw ancestry once; bind revisions to trusted repo/session, leaf and ordered entry/message/content hashes. Discovery includes sources before compaction/context reset and outside the display tail. Bounded base64 chunks return the complete validated envelope. Stopped reads have no Agent/Provider effects; a live Agent without its Writer fails. Changed events are refresh hints; this mode does not transmit or recreate transient raw progress frames. Hosted SSE framing explicitly accommodates the existing native 1 MiB bound; ordinary Provider and Protocol limits remain unchanged.
- Native Memory add/list/read/search share one application-owned writer per trusted Sigma root (`~/.pi/agent/memories` by default); an Agent fixes that root across generations. Session closure does not stop the shared writer. Every call validates its public Session binding; note writes require explicit user instructions and exclusive creation. Search uses the published tagged any/same-line/within-lines modes, Unicode normalization, matching line contexts and pagination. Root Goal3 uses the actual Writer, Runtime Store and Session binding, public delegation accounting and two-phase ordinary idle admission. Retained terminal receipts use #109's exact public ACK without effect replay. Rename/adopt move both `.runtime` and `.subagents` after owner retirement, delete removes both, and fork imports the complete public Goal snapshot into an independent target store. Actual-child usage/ACK failures have process-restart and fresh-BEAM production recovery through the bounded provider-only lifetime controller below; current fenced incarnations may exceed original receipt/admission incarnations. Failed Goal preparation closes its already-reserved Session before another prompt, preserving actual preparation/cleanup errors.
- Root Goal startup uses `RunRecovery` to reconcile retired provider-only nonterminal runs before receipt accounting, including ordinary storage failures without a Goal. It requires the original indexed run/Provider identity, all touched host lifetimes' native-generation, async-hook and independent SessionEnd receipts, and durable stopped facts for every recorded Provider attempt. Other active work, uncertain intents or missing evidence remain errors. Only the exact current Provider intent may remain in the transition outbox. Public Store fencing, cancel and cleanup_settled preserve partial progress; retries do not refence or dispatch effects. Original indexes/receipts retain attribution, ACK uses the current incarnation, and replacement prompts start new runs from committed history. Actual usage/ACK failures, write-failure stages and full-BEAM production reopening have functional acceptance. Terminal unknown_outcome needs the additional prospective lifetime proof below; missing historical facts remain boundaries. Child roster `closure: :closed` can also describe detach with retained resources. Production children persist all exact native binding memberships and separate native/async-hook close confirmations in Store-owned `host-retirement.etf`; root/child Writer headers and a distinct host lifetime identify this sidecar. Explicit retirement runs outside ChildIO/Subagents loops and retains actual causes and partial confirmations, even when aggregate manager closure remains unknown. Strict async-hook retirement requires the actual Runner cleanup report and normal worker exit; legacy shutdown remains best-effort. Failed followup indexing retains its previous ExtensionRuntime until actual close. Native/async-hook receipts alone do not prove Kernel settlement, SessionEnd completion or whole-root retirement. Never infer shutdown from an empty effects list or Goal ACK.
- Root native generations now record the same exact binding memberships under an Agent-owned host lifetime and actual root Writer header. Version-two host-retirement ledgers add an independent root SessionEnd completion/outcome/warnings fact; version-one reads migrate only in memory. Agent.retire_host runs outside its callback loop, retains original hook/SessionEnd acknowledgements across write failures and never replays an uncertain completion. SessionEnd uses a fresh scoped AsyncRuntime for its own command-cleanup reports; dispatch completion is not handler success. File moves retire the host before Store; failed operations reopen a fresh hook/root lifetime. Active terminate keeps native cleanup unconfirmed while joining hooks and running orderly SessionEnd, avoiding a blocked Agent callback. Backplane 1.10.43's #118 procfs vanished-entry fix is adopted: all seven root-retirement tests plus the 32-Session concurrent close/cancel test pass with the original failing seed and unchanged assertions. No local scanner, timeout increase, effect retry or dependency patch was added. These component facts still do not settle Kernel work or complete the recovery controller.
- Native root/child Provider workers register the public Runtime run/incarnation/step/attempt identity with the existing Store before Provider code runs. Store monitors that exact caller and persists only its actual DOWN in `provider-lifecycle.etf`, independently of Runtime snapshots, Goal receipts and native retirement. Missing/lost observations remain incomplete after Store/BEAM replacement. Failed DOWN writes retain the original fact and cause for persistence-only retry; explicit child retirement requires these facts before stopping ChildIO/Store. Writer retirement refuses active monitors or pending writes and returns the actual error without waiting for a nonexistent shutdown ACK. A stopped Provider worker does not itself settle Kernel tools/children/dependencies or authorize effect replay; root/child provider-only controllers consume it alongside independent host facts and the public lifetime receipts.
- GoalDescendants now reconciles retired provider-only child runs before loading retained Goal receipts through shared RunRecovery. Original Writer admissions and receipt accounting threads are distinct from the actual child transcript header; confirm both, every touched host lifetime/native generation, async-hook closure and all stopped Provider attempts before public fence/cancel/cleanup. Repeated loads do not refence, and accounting retains original attribution with current-fence ACK. Missing facts leave the run unchanged. Independent cold-BEAM child Store/Goal accounting is accepted; this does not resume the Agent or confirm its root.
- Backplane 1.10.43's #119 public reconciliation is integrated for prospective provider-only failed-child lifetimes. LifetimeRecovery serializes immutable admissions/configuration/inventory, relative Store refs, exact Conversation observations/DOWN and versioned public receipts in `<root_transcript>.subagents/lifetime-recovery.etf`. The writer follows the durable journal header through rename/adopt; each manager retains its own admitted route identity. Join actual Provider and component retirement before stopping the exact failed Conversation; only then reconcile child Stores and public Registry → child Session → deepest child → manager → root Session. Require each actual public ACK, not a confirmed receipt alone. Goal ACK can advance Store revisions: reseal descendants before ancestors and before roster/root admission gates, while retaining the original receipt version correlated with its ACK. Only complete root native/hooks/SessionEnd and lifetime proof permits a new root run. Preserve historical `unknown_outcome`, uncertain intents, original Goal receipt attribution and committed history; never resume old execution or replay effects. Missing legacy observations and unrelated unfinished work remain errors. Actual nested children, receipt/admission write failures, same-child successful followup, file lifecycle and full-BEAM production reopening have functional acceptance; archive continuation is separate.
- Backplane 1.10.43 publishes source commit `a93bb8034a8deee6a132c8d715bdf2fc96d1a891` for #117/#119: public MultiAgent recovery manifests, reconciliation and child export/restore, plus Session/ResourceRegistry reconciliation. The five official Hex packages are updated. #119's bounded host evidence/receipt CAS consumer is integrated as above; publication alone does not prove other recovery paths.
- ChildArchives uses public #117 exact immutable exports and #134 stage_child_export/complete_child_export. RecoveryJournal atomically captures actual command inputs with each Store snapshot; fences are explicit, read projection preserves all fields of Sigma Message/ProviderStopReason, and missing legacy admission prefixes remain unsupported. Raw Runtime/history records are never rewritten. Backplane.Provider now supplies the public atom stop reason at its boundary while retaining the original message reason. ChildIO owns the exact restored Store. Original native Error archive, rename/followup, idle restored-child transfer, nested Goal recovery and independent-BEAM continuation regressions pass on 1.10.48.
- Live manager retirement keeps execution and full archive completion distinct. Subagents.close_execution records actual acknowledgements; strict close/file/admission gates still require Goal ACK, exact archive and owner retirement. Orderly Agent shutdown with confirmed components but failed full completion queues Subagents.stage_shutdown behind control/resync jobs and persists all eligible unarchived children deepest first before owners stop. Staging never marks full completion or erases the original error. Completed/aborted host-completion Task branches use the same confirmed-component gate without repeating SessionEnd. Cold recovery performs actual Goal redelivery/ACK and descendant-first receipt refresh before offline completion, then parent-first restore with original identities. Pending Goal bytes, cold exactly-once accounting, queued-stage/completed-task races and fresh-BEAM new work pass. Abrupt loss before a stage, missing legacy facts or uncertain effects remain errors.
- Web/Protocol Stop for detached active children uses Subagents.close_execution. It preserves the completed root phase and retains the actual failed execution_result, including its original storage cause; Protocol keeps its existing public error projection. This does not confirm root hooks/SessionEnd or archive completion. Explicit retirement, generation replacement and file operations still require the full gate; Runtime.close_subagents remains full-close for the no-live-Agent file-operation fallback.
- Real prompts retain their exact item/resources while a supervised current-host probe selects reuse or retirement. Retirement and ready-Coordinator rescan run outside Agent callbacks; cancellation preserves the original facts and releases resources once. Ordinary shutdown needs the public ownership ACK tree before root hooks/SessionEnd can finish; new-work admission additionally requires those independent root facts. Automatic Goal idle probes before public reservation, then releases an exact coordinator-monitored Task. Pure provider-hosted configuration precedes hooks, startup children and Runtime admission; a host-owned atomic gate separates preparation, effect opening, cancellation/supersession and sealing. Only actual executor DOWN before effects allows public #127 settle_unstarted_admission; the Agent joins its exact durable acknowledgement before terminal events and skips interrupt hooks on this path. Store failures retain the seal and actual cause for persistence-only recovery. On a reusable live host, the next prompt retries only this sealed settlement in its supervised inspection Task before canonical input, hooks or a new Session/Runtime. Explicit host Goal set/clear/fork share the same preparation; persistent write errors return their actual cause without new instructions or Provider work. Indexed-run/unknown errors retain separate recovery requirements, and unhealthy hosts keep the existing retirement path. Fork retains the source receipt and starts independent empty admission ledgers. Forward the complete admission to real Goal binding. After the effect gate opens, hooks/Session/Runtime failures retain ordinary recovery boundaries; never infer no effects from a missing indexed Runtime record, withdraw after release, reset Goal or fabricate receipts. GoalStore reads complete 1.10.44 records with only the two new admission maps defaulted in memory, preserving original bytes until a real mutation; public fork keeps its independent complete snapshot.
- MessageBoardStore owns one application writer per root transcript at `<root_transcript>.subagents/message_board.json`. All nine `collaboration::` tools use the actual root/child Session, Subagents membership and Writer identity. Changed state is synced and atomically renamed before active-only public MultiAgent notifications run outside the Subagents lock. A failed best-effort notification does not change the committed post result or retry either effect; accepted-call retries do not notify again. #110 prevents unconsumed notices leaking into later followups; ordinary queued messages remain independent. Rename/adopt/delete drain and confirm writer retirement before file changes; fork starts an independent board. Failed operations preserve bytes and actual causes. The original 128 KiB raw argument envelope remains an explicit gap.
- A completed command handle returns a normal tool error and permits another command, directly and through real Deno with 1.10.42's #111 error serialization. Keep the functional regression; do not add a local encoder or dispatcher replacement.
- Production commands use `PlainCommand`: non-PTY jobs delegate to public LocalCommand, while each Linux PTY owns an independent Native helper and a 24×120 terminal. PTYs inherit Native's existing environment and do not accept per-command environment overrides. Root, child, real Deno and cross-turn stdin have functional acceptance. Natural exit drains output before publishing exit; retained jobs wait for the final Native events and public release acknowledgement. Host shutdown reaps jobs; journal recovery restores results without restarting commands. Retain the PTY writer through slave cleanup and output draining: portable-pty writes newline/EOF on writer drop, which otherwise races into echoed command output.
- CommandHost/CommandRuntime and the native sandbox launcher remain historical preparation, outside current security/permission development and testing. Do not change global PATH or claim production isolation from those fixtures. Native builds must precede Elixir compilation so the private launcher snapshot uses the packaged binary's compiled manifest.
- `wait_for_environment` uses the real local command-runtime startup in root and managed-child profiles. CodexResources owns each generation's environment ID and starting/ready/failed state; asynchronous PlainCommand boot reports actual LocalCommand/capability initialization to this independent owner. Commands wait on the command server, while public Readiness polls the resource owner. Provider and context-budget projections use the same current `<environment_context>`, including custom system prompts. Successful turns reuse the ID; closed resources and cold recovery require a new startup/ID. This reports command-host readiness; PTYs still start per job. Published #128 Readiness returns execution_failure immediately for failed startup, preserving the environment ID, startup class and bounded original UTF-8 reason; closed/unavailable return not_found. Control presents these as ordinary is_error tool results, including through real Deno, so subsequent tools can run and history preserves the complete error. Starting waits still retain timeout/cancel behavior. No local readiness backend or startup injection boundary was added; do not substitute fixed-ready results or claim sandbox readiness.
- Default LocalCommand concurrent cleanup in Backplane 1.10.37 passed functional acceptance with 32 independent Sessions, 16 concurrent closes and 16 cancellations; original running settlements remain intact. Keep cancellation/cleanup failures visible; do not enlarge timeouts, serialize production commands, retry uncertain effects or claim confirmed closure as a workaround.
- Nix sandbox script interpreters use fixed host-owned `/bin/sh` and `/usr/bin/env` aliases into the exact runtime closure. Their sandbox-owned directories are read-only; do not bind host bin directories or accept model-controlled alias maps.
- Permission checks go through `Sigma.Coding.PermissionInterceptor` and `Sigma.Coding.PermissionPolicy`; LiveView approval waits must stay aligned with the interceptor timeout.
- Session JSONL files are stored per repository/workdir. In dev, sessions live under `apps/sigma_web/priv/sessions/<base64-url-workdir>/`.
- Known repositories are stored in dev at `apps/sigma_session/priv/repos.jsonl`.
- Agent/provider/MCP config is pi-compatible and stored at `~/.pi/agent/`: `settings.json`, `auth.json`, `models.json`, `mcp.json`, and `AGENTS.md`.
- Context assembly prefers `AGENTS.md` over `CLAUDE.md` in each ancestor directory, ordered root-to-workdir so deeper project instructions have later precedence.

