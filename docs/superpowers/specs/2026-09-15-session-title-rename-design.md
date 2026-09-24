# Session Title Rename on Repository Session List

## Status

Draft

## Context

The repository session list page (`/repository/:repository`) displays sessions in cards with a title derived from the session metadata `title` field, falling back to the session id.

Current interactions on the session list page:
- Delete session via delete button with confirmation modal
- Adopt session into repository
- Open session

There is no way to rename the display title of a session from the session list page. Session titles are stored in the session metadata `.meta.json` file under the `title` key. The session id/file name must remain unchanged.

The `SessionLive` sidebar already implements inline rename of the session **id** via `phx-submit="rename_session"` with `old_id` → `new_name`, which renames the files on disk via `Sigma.Agent.Runtime.rename_session` → `SessionFiles.rename/3`. This renames both the `.jsonl` and `.meta.json` files.

The requirement is to rename **only the display title metadata** from the repository session list page, without changing the session id/file name.

## Goals

- Add a rename capability to the session list card title from the RepositoryLive session list page.
- Double-click or long-press on the session title triggers an inline rename popover/form.
- Rename updates the `title` field in the session's `.meta.json` metadata file, leaving the session id and file names unchanged.
- The list updates optimistically after saving, showing the new title immediately.
- Cancel restores the original title and closes the rename UI.
- Save on Enter / blur, cancel on Escape, with a clear cancel button.
- Persist the change through the existing session metadata read/write paths.

## Non-Goals

- Renaming the session id/file name from the repository list page.
- Creating a separate rename page or modal.
- Changing the rename behavior in SessionLive sidebar.
- Updating session titles in other contexts (fork, adopt, etc.).

## Design

### Data Model

Session metadata is stored in `<sessions_dir>/<session_id>.meta.json` with fields including `title`, `cwd`, `branch`, etc.

The title is read from metadata by `Sigma.Session.Operations.summary/3`:
```elixir
title: metadata["title"] || session_id
```

Updating the title requires writing back the metadata file with the existing fields plus the updated `title`. The existing `SessionFiles` module handles metadata encoding safely. A new helper `SessionFiles.update_metadata/3` will be added to read the metadata, merge updates, and write atomically.

### User Interaction

1. User double-clicks or long-presses the session title in the card header.
2. The title span is replaced inline with an input field pre-filled with the current title (fallback to session id if empty).
3. Focus is placed in the input, with the input selected.
4. User types new title, presses Enter to save, or blur to save.
5. On save:
   - Validate title is non-empty and trimmed.
   - Write the title back to the session metadata file.
   - Reload the session summaries and update the list.
   - Flash info message "Session title updated." or error on failure.
6. On cancel:
   - Escape key or Cancel button restores original title and exits edit mode.

### UI Implementation

Add to `RepositoryLive`:
- Assign `:renaming_session` state to track which session is being renamed, and `:renaming_title` for the input value.
- Add `handle_event("start_rename_title", ...)` to enter rename mode.
- Add `handle_event("cancel_rename_title", ...)` to exit rename mode.
- Add `handle_event("save_rename_title", ...)` to persist the new title.

Update the card title rendering to conditionally show either a static span or an input form.

Use existing DuskMoon input components for consistency. The popover form will be inline (not a modal), with input + submit + cancel.

### Backend Implementation

Add `SessionFiles.update_metadata/3` to read current metadata, merge updates, and write atomically with the existing safe file operations pattern.

```elixir
def update_metadata(sessions_dir, session_id, updates) when is_map(updates) do
  with {:ok, meta_path} <- meta_path(sessions_dir, session_id),
       {:ok, %{exists?: true, data: data}} <- read_metadata(meta_path),
       new_data = Map.merge(data || %{}, updates),
       encoded <- Jason.encode!(new_data, pretty: true),
       {:ok, temp_path} <- unused_temp_path(meta_path),
       :ok <- File.write(temp_path, encoded),
       :ok <- File.rename(temp_path, meta_path) do
    :ok
  ...
end
```

The `RepositoryLive` handle_event will call `SessionFiles.update_metadata/3` with `%{"title" => new_title}`.

### Error Handling

- Invalid session id: flash error.
- Metadata read/write failure: flash error, do not update UI.
- Empty title: revert to existing title or session id.

### Testing

- Unit tests for `SessionFiles.update_metadata/3` with existing metadata, missing metadata, and concurrent writes.
- Integration tests for RepositoryLive rename flow: start rename, save title, cancel rename, validation.

## Decision

Implement inline title editing on the session list card with double-click/long-press trigger, inline input form with save on Enter/blur, cancel on Escape, updating only the metadata title field.

## Open Questions

- Should title be validated for length (e.g., max 120 chars)? Yes, 120 chars max.
- Should empty title be allowed (reverts to session id)? No, empty title should revert to original.

## Next Steps

- Implement UI changes to RepositoryLive.
- Add SessionFiles.update_metadata helper.
- Add tests.
