# Backplane skill discovery

Open `/settings/skills`. The global directory switch controls automatic discovery
of `~/.agents/skills`. Its default is enabled. Disabling it takes effect before
filesystem discovery, including new and restored Web and Protocol sessions.
Repository `.agents/skills` follows its existing per-project configuration.
Existing per-skill global choices apply again when the directory is re-enabled.

Add or edit a remote source and select **Backplane defaults and search** under
**Model discovery**. Sources retain manual invocation as their default mode.
The connection uses its existing Backplane provider origin and credential.
Backplane's **Always return** selection supplies the default summaries. Search
covers published skills outside that selection. Empty defaults remain empty.

The native model workflow is

1. Call `skills::list` with `authority: "executor"` to obtain defaults and `sources`.
2. Choose the configured `source_id` from `sources` and call `skills::search` with
   that `source_id` and a task-related `query`. Authority defaults to `executor`.
   Each source owns its search cursor and can be searched independently.
3. Pass the returned opaque `package` to `skills::read`. Relative resources use
   the returned `skill://` resource prefix. Reads pin the discovered revision and
   artifact digest and verify the complete package before exposing content.

Discovery and search transfer metadata. Package downloads begin on reads.
Each new online read revalidates its exact revision and digest against Backplane.
An existing text-pagination cursor retains its verified content snapshot.
Manual-only results carry `manual_only: true` and `model_readable: false` and
can be invoked through the existing `/skill <source_id>:<skill_id> arguments`
entry. Disabling or changing a source invalidates its issued model packages.
Local catalog reads perform local discovery without remote requests.

Explicit offline sources keep the existing exact cached manual invocation
behavior. Online errors do not switch to offline operation or enable the global
directory. The default directory is bounded to 4,096 descriptors and 64 pages per
source, with diagnostics when discovery cannot complete.

## Create a skill in Backplane

Native agents can call `skills::create` with `source_id`, `slug`, `name`,
`description`, and `content`. Select `source_id` from `skills::list.sources`.
The source must be enabled, online, and configured for model discovery. Backplane
checks the existing credential's `skill::write` scope. Existing connection
configuration supplies the credential.

`content` is the Markdown body. Backplane builds and publishes a single-document
skill with the supplied name and description. The result contains its exact
reference, revision, digest, and an opaque package for `skills::read`. Reading
uses the existing read authorization and bundle verification. Local and global
skill directories retain their existing behavior.

Creation sends one POST. An existing slug returns `already_exists`.

This integration currently requires the candidate Backplane Skill Protocol and
Agent Runtime discovery APIs. The repository
lockfile remains the published baseline. Old SDKs return an upgrade error for
opt-in discovery, and old runtimes retain their existing native skill tools.
Adopting the published packages and repeating the integration checks is pending. [Backplane #193](https://github.com/gsmlg-opt/backplane/issues/193)
