# Image Attachments End-to-End Design

## Status

Conversation design approved on 2026-08-29. Written-spec review is pending.

## Context

Sigma renders `phoenix_duskmoon`'s `dm_chat_input`, backed by
`@duskmoon-dev/el-chat`. In version 1.7.2 the nested markdown input retained
selected files, but the chat input emitted only the text value. Consequently,
the LiveView, session journal, provider request, and user bubble never received
the image.

Upstream issue `duskmoon-dev/duskmoon-elements#77` was resolved by pull request
`#78` and released in DuskMoon Elements v1.7.4. The updated chat input emits
`{ value, files }`, exposes `getFiles()` and `clearFiles()`, and clears submitted
files when `clear-on-send` is enabled.

Sigma already has most of the server-side representation needed for the fix:

- `Sigma.Ai.Message.image_content` represents base64 image data and MIME type.
- user and tool-result message content may contain image blocks.
- the JSONL entry decoder validates and replays image blocks.
- `Sigma.Agent.MessageTransformer` preserves user content lists.

The missing work is the browser-to-LiveView bridge, provider-specific image
encoding, and image rendering in user bubbles.

## Goals

- Send attached raster images to supported Anthropic-compatible and
  OpenAI-compatible models with the accompanying user text.
- Persist the same text/image blocks in the existing JSONL session journal.
- Render persisted images inside the originating user chat bubble after live
  updates, reload, and replay.
- Preserve images when retrying a user message.
- Keep text-only prompts and slash commands backward compatible.
- Reject unsupported or oversized attachments before invoking a provider.

## Non-goals

- PDF, archive, source-code, or general document ingestion.
- Durable asset storage, HTTP upload endpoints, or remote image hosting.
- OCR, image transformations, thumbnails, or image editing.
- New provider capability discovery or model-selection UI.
- Migration of historical text-only session entries.

## Decision

Images will be encoded as base64 in the browser and sent over the existing
LiveView socket. Sigma will store the image blocks inline in JSONL, matching the
existing message schema and the checked-in upstream pi representation.

This is preferred over Phoenix uploads or an HTTP asset service because the
provider APIs ultimately need inline image data, existing sessions are already
self-contained, and the approved scope is limited to small raster attachments.

## Supported Input Contract

The accepted MIME types are the common raster formats supported by both provider
families:

- `image/png`
- `image/jpeg`
- `image/gif` when the file contains exactly one frame
- `image/webp`

A submission may contain at most four images. No individual image may exceed
5 MiB of decoded bytes, and the combined decoded image payload may not exceed
10 MiB. The browser checks these limits before reading files, and the server
repeats validation after base64 decoding. The server validates file signatures
rather than trusting the browser-supplied MIME type and rejects animated GIFs.

Because 10 MiB expands to approximately 13.4 MiB when base64 encoded, the
implementation must verify that the LiveView transport accepts at least a
16 MiB frame, including JSON framing overhead. If the current transport is
smaller, raise its explicit frame limit to 16 MiB and lock the boundary down
with an end-to-end transport test.

An image-only prompt is valid. A submission with neither non-whitespace text nor
an accepted image remains a no-op.

## Architecture and Data Flow

### 1. Dependency update

Update the explicitly pinned `@duskmoon-dev/el-*` packages and
`@duskmoon-dev/elements` from 1.7.2 to 1.7.4 as one coherent package family.
Keep `@duskmoon-dev/core` and `@duskmoon-dev/css-art` on their independent
release versions. Regenerate the DuskMoon rich-element bundle using the
repository's existing Mix task. Do not create or adopt a new npm lockfile.

Remove the resolved `# TODO(upstream): duskmoon-dev/duskmoon-elements#77`
marker. No local upstream workaround remains after consuming v1.7.4.

### 2. Browser bridge

Extend the existing `ChatInputHook` rather than adding a second hook or a new
component system.

The hook will listen for the DuskMoon `send` event, whose detail now contains a
text value and a snapshot of `File` objects. It will:

1. validate count, MIME type, individual size, and total size;
2. read accepted files as data URLs;
3. strip the data-URL prefix and build serializable image maps containing
   `data` and `mime_type`;
4. push one `send_prompt` event with `value` and `images`, then wait for the
   LiveView acknowledgement;
5. push an `attachment_error` event without sending the prompt when client
   validation or conversion fails, allowing `SessionLive` to show the error
   through its existing flash UI.

Remove `duskmoon-send-send` from the child chat input so the generic
`WebComponentHook` does not also forward raw `File` objects or submit a duplicate
text-only prompt. Set `clear-on-send` to false. The hook clears text and files
through the released `setValue("")` and `clearFiles()` APIs only after LiveView
acknowledges an accepted prompt. Rejected submissions retain their text and
attachments for correction or retry.

`attachment_error` carries only a bounded error code from
`unsupported_type`, `animated_gif`, `too_many`, `too_large`, or `read_failed`.
`SessionLive` maps those codes to trusted flash text and never renders an
arbitrary client-provided error string.

### 3. LiveView normalization

`SessionLive` will normalize the incoming text and image maps into canonical
message content:

```elixir
[
  %{type: :text, text: "Describe this image"},
  %{type: :image, data: "...base64...", mime_type: "image/png"}
]
```

The text block is omitted when the prompt is image-only. Text-only input remains
a binary to preserve current journal and hook behavior.

Validation returns a user-visible error and does not call `Sigma.Agent.prompt/3`
when the image count, size, MIME type, base64 encoding, or file signature is
invalid. `send_prompt` replies with an explicit accepted/rejected status so the
hook knows whether to clear the composer.

Attachments combined with text beginning with `/` are rejected; local and
expanded slash commands remain text-only. This avoids silently ignoring images
for local commands such as `/reload-tools` and keeps existing command semantics
unchanged.

User-prompt hooks run once for every accepted prompt with its text projection,
which is an empty string for image-only input. A hook block cancels the entire
multimodal prompt. Hook-added or transformed text becomes the canonical text
block before the original image blocks; leaving the projection empty preserves
an image-only prompt.

### 4. Agent and journal

`Sigma.Agent` will accept either existing binary prompt content or canonical
text/image content. It will construct one user message without introducing a
new process or persistence layer.

The existing context transformer and JSONL writer remain the authority. Focused
tests will lock down that image blocks survive message conversion, append, and
replay without changing pi-compatible field names.

Retrying a rich user message resubmits the complete canonical content, including
all image blocks. Existing binary retry behavior remains unchanged.

### 5. Provider encoding

Provider adapters translate the canonical image block only at the HTTP boundary.

Anthropic-compatible messages use:

```json
{
  "type": "image",
  "source": {
    "type": "base64",
    "media_type": "image/png",
    "data": "..."
  }
}
```

OpenAI-compatible chat-completions messages use:

```json
{
  "type": "image_url",
  "image_url": {
    "url": "data:image/png;base64,..."
  }
}
```

Text blocks continue to use each provider's existing text representation.
Provider failures, including a model that does not accept images, continue
through the existing stream error path.

### 6. User bubble rendering

Rich user content renders through the default `dm_chat` slot so text and images
can share one bubble. Text uses the existing DuskMoon markdown renderer. Images
render as constrained, responsive `<img>` elements with lazy loading, async
decoding, and descriptive fallback alt text.

The image source is built only from server-validated MIME types and base64 data.
Text-only messages keep the current `content`-attribute path and appearance.

## Error Handling

- Unsupported file types: reject before reading and identify the supported
  formats.
- Too many or oversized images: reject the entire submission; do not send a
  partial multimodal prompt.
- FileReader failure: push only `attachment_error`; do not push `send_prompt`,
  and retain the composer state.
- Invalid base64 or signature mismatch: show a LiveView flash and do not invoke
  the agent.
- Provider rejection: preserve the existing provider error behavior so the
  user sees the actual model/API limitation.

No fallback silently turns an invalid image submission into a text-only prompt.

## Testing Strategy

Follow red-green-refactor at the narrowest real seams:

1. **Dependency/browser contract** — verify v1.7.4 emits attached files and
   clears them after send.
2. **LiveView submission** — verify text-plus-image and image-only payloads
   produce canonical user content; invalid type, signature, count, and size do
   not prompt the agent.
3. **Agent/journal replay** — verify canonical image blocks reach the provider
   context and survive JSONL append/replay.
4. **Anthropic request capture** — assert the nested base64 `source` shape.
5. **OpenAI request capture** — assert the `image_url` data URL shape.
6. **User bubble rendering** — assert persisted images render inside the user
   bubble while text-only markup remains stable.
7. **Retry behavior** — assert retries preserve images.
8. **Browser end-to-end check** — attach a small fixture through the released
   DuskMoon picker and verify one LiveView submission, persisted image content,
   and rendered image without sending a request to a paid external provider.
9. **Transport boundary** — prove a 10 MiB decoded aggregate payload survives
   base64 and JSON framing through the configured LiveView transport.

Run only the affected provider, agent, session, and LiveView suites, followed by
targeted format, compile, asset-build, and browser checks.

## Delivery and Cleanup

- Work in `.trees/codex/image-attachments` on branch
  `codex/image-attachments`.
- Preserve unrelated changes in the main worktree, including `AGENTS.md`,
  `CLAUDE.md`, `devenv.nix`, and `package-lock.json`.
- Run GitNexus impact analysis before modifying each existing symbol and
  `gitnexus_detect_changes` before any implementation commit.
- Record the completed feature in agent-note with label `project: sigma`.
- Do not commit or adopt the unrelated root `package-lock.json`.

## Acceptance Criteria

- Selecting a supported image and sending a prompt produces exactly one agent
  turn containing both text and image content.
- The configured provider request contains the correct provider-specific image
  representation.
- The user bubble displays the image immediately and after page reload.
- The JSONL session contains pi-compatible text/image blocks and replays them
  without diagnostics.
- Image-only prompts and rich-message retries work.
- Invalid images never reach the agent or provider.
- A rejected or unreadable submission retains its text and attachments.
- The approved 10 MiB aggregate limit is accepted by the configured socket
  transport without disconnecting the LiveView.
- Existing text-only prompts, slash commands, hooks, and retries remain green.
- The scoped tests, compile check, format check, asset build, and browser proof
  all pass.
