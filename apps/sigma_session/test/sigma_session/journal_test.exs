defmodule Sigma.Session.JournalTest do
  use ExUnit.Case, async: true

  alias Sigma.Agent.Message
  alias Sigma.Session.{Journal, Snapshot}

  test "replays a linear v3 journal into a deterministic snapshot" do
    entries = [
      Map.put(header("session", "/repo"), "parentSession", "parent-session"),
      message_entry("entry-1", nil, "message-1", "user", "hello")
    ]

    assert {:ok,
            %Snapshot{
              header: %{"id" => "session", "cwd" => "/repo"},
              session_id: "session",
              cwd: "/repo",
              parent_session_id: "parent-session",
              active_leaf_id: "entry-1",
              branch_entry_ids: ["entry-1"],
              messages: [%Message{id: "message-1", role: :user, content: "hello"}],
              mode: "none",
              diagnostics: []
            } = snapshot} = Journal.replay(entries)

    assert Journal.replay(entries) == {:ok, snapshot}
  end

  test "restores the latest behavioral state only from the selected branch" do
    entries = [
      header("session", "/repo"),
      message_entry("root", nil, "message-1", "user", "hello"),
      state_entry("left-model-old", "root", "model_change", %{
        "model" => "anthropic/old"
      }),
      state_entry("left-model", "left-model-old", "model_change", %{
        "model" => "anthropic/claude-left"
      }),
      state_entry("left-thinking-old", "left-model", "thinking_level_change", %{
        "thinkingLevel" => "medium"
      }),
      state_entry("left-thinking", "left-thinking-old", "thinking_level_change", %{
        "thinkingLevel" => "high",
        "configured" => "auto"
      }),
      state_entry("left-tier-old", "left-thinking", "service_tier_change", %{
        "serviceTier" => "standard"
      }),
      state_entry("left-tier", "left-tier-old", "service_tier_change", %{
        "serviceTier" => "priority"
      }),
      state_entry("left-mcp-old", "left-tier", "mcp_server_selection_change", %{
        "serverIds" => ["old"]
      }),
      state_entry("left-mcp", "left-mcp-old", "mcp_server_selection_change", %{
        "serverIds" => ["fs", "git"]
      }),
      state_entry("left-mode-old", "left-mcp", "mode_change", %{
        "mode" => "plan",
        "data" => %{"file" => "OLD.md"}
      }),
      state_entry("left-mode", "left-mode-old", "mode_change", %{
        "mode" => "build",
        "data" => %{"file" => "BUILD.md"}
      }),
      state_entry("left-compact-old", "left-mode", "compaction", %{
        "summary" => "old summary",
        "firstKeptEntryId" => "root"
      }),
      state_entry("left-compact", "left-compact-old", "compaction", %{
        "summary" => "latest summary",
        "firstKeptEntryId" => "root"
      }),
      state_entry("left-summary-old", "left-compact", "branch_summary", %{
        "fromId" => "root",
        "summary" => "old left branch"
      }),
      state_entry("left-summary", "left-summary-old", "branch_summary", %{
        "fromId" => "root",
        "summary" => "left branch"
      }),
      state_entry("right-model", "root", "model_change", %{
        "model" => "openai/gpt-right"
      }),
      state_entry("right-mode", "right-model", "mode_change", %{
        "mode" => "plan",
        "data" => %{"file" => "PLAN.md"}
      })
    ]

    assert {:ok,
            %Snapshot{
              active_leaf_id: "left-summary",
              provider_id: "anthropic",
              model_id: "claude-left",
              reasoning_level: "high",
              configured_reasoning_level: "auto",
              service_tier: "priority",
              mcp_server_ids: ["fs", "git"],
              mode: "build",
              mode_data: %{"file" => "BUILD.md"},
              compaction: %{"id" => "left-compact", "summary" => "latest summary"},
              branch_summary: %{"id" => "left-summary", "summary" => "left branch"}
            }} = Journal.replay(entries, leaf_id: "left-summary")

    assert {:ok,
            %Snapshot{
              active_leaf_id: "right-mode",
              branch_entry_ids: ["root", "right-model", "right-mode"],
              provider_id: "openai",
              model_id: "gpt-right",
              reasoning_level: nil,
              configured_reasoning_level: nil,
              service_tier: nil,
              mcp_server_ids: [],
              mode: "plan",
              mode_data: %{"file" => "PLAN.md"},
              compaction: nil,
              branch_summary: nil
            }} = Journal.replay(entries)
  end

  test "applies default model changes and replaces state with clearing values" do
    entries = [
      header("session", "/repo"),
      state_entry("model-default", nil, "model_change", %{"model" => "openai/initial"}),
      state_entry("model-scoped", "model-default", "model_change", %{
        "role" => "reviewer",
        "model" => "ignored/scoped"
      }),
      state_entry("model-nil-role", "model-scoped", "model_change", %{
        "role" => nil,
        "model" => "anthropic/final"
      }),
      state_entry("thinking", "model-nil-role", "thinking_level_change", %{
        "thinkingLevel" => "high",
        "configured" => "auto"
      }),
      state_entry("thinking-clear", "thinking", "thinking_level_change", %{
        "thinkingLevel" => nil,
        "configured" => nil
      }),
      state_entry("tier", "thinking-clear", "service_tier_change", %{
        "serviceTier" => "priority"
      }),
      state_entry("tier-clear", "tier", "service_tier_change", %{"serviceTier" => nil}),
      state_entry("mcp", "tier-clear", "mcp_server_selection_change", %{
        "serverIds" => ["fs"]
      }),
      state_entry("mcp-clear", "mcp", "mcp_server_selection_change", %{"serverIds" => []}),
      state_entry("mode", "mcp-clear", "mode_change", %{
        "mode" => "plan",
        "data" => %{"file" => "PLAN.md"}
      }),
      state_entry("mode-clear", "mode", "mode_change", %{"mode" => "none"})
    ]

    assert {:ok,
            %Snapshot{
              provider_id: "anthropic",
              model_id: "final",
              reasoning_level: nil,
              configured_reasoning_level: nil,
              service_tier: nil,
              mcp_server_ids: [],
              mode: "none",
              mode_data: nil,
              diagnostics: []
            }} = Journal.replay(entries)
  end

  test "records compaction state without collapsing branch messages" do
    entries = [
      header("session", "/repo"),
      message_entry("root", nil, "message-1", "user", "one"),
      state_entry("compact", "root", "compaction", %{
        "summary" => "earlier work",
        "firstKeptEntryId" => "root"
      }),
      message_entry("leaf", "compact", "message-2", "assistant", assistant_text("two"))
    ]

    assert {:ok,
            %Snapshot{
              compaction: %{"id" => "compact", "summary" => "earlier work"},
              messages: [
                %Message{id: "message-1"},
                %Message{id: "message-2", content: [%{type: :text, text: "two"}]}
              ]
            }} = Journal.replay(entries)
  end

  test "diagnoses malformed payloads deterministically without losing valid messages" do
    caller_diagnostic = %{kind: :storage_warning, entry_index: nil, entry_id: nil}

    entries = [
      header("session", "/repo"),
      state_entry("orphan", "missing", "mode_change", %{"mode" => "plan"}),
      message_entry("root", nil, "message-1", "user", "hello"),
      state_entry("bad-model", "root", "model_change", %{"model" => "invalid"}),
      state_entry("bad-model-role", "bad-model", "model_change", %{
        "role" => 42,
        "model" => "anthropic/valid"
      }),
      state_entry("bad-mcp", "bad-model-role", "mcp_server_selection_change", %{
        "serverIds" => ["ok", 42]
      }),
      message_entry("bad-message", "bad-mcp", "message-2", "user", nil)
    ]

    assert {:ok,
            %Snapshot{
              messages: [%Message{id: "message-1", content: "hello"}],
              diagnostics: diagnostics
            } = snapshot} = Journal.replay(entries, diagnostics: [caller_diagnostic])

    assert diagnostics == [
             caller_diagnostic,
             %{
               kind: :invalid_entry,
               entry_index: 1,
               entry_id: "orphan",
               reason: :missing_parent
             },
             %{
               kind: :invalid_payload,
               entry_index: 3,
               entry_id: "bad-model",
               reason: :invalid_model
             },
             %{
               kind: :invalid_payload,
               entry_index: 4,
               entry_id: "bad-model-role",
               reason: :invalid_model_role
             },
             %{
               kind: :invalid_payload,
               entry_index: 5,
               entry_id: "bad-mcp",
               reason: :invalid_mcp_server_ids
             },
             %{
               kind: :invalid_payload,
               entry_index: 6,
               entry_id: "bad-message",
               reason: {:invalid_content_for_role, :user}
             }
           ]

    assert Journal.replay(entries, diagnostics: [caller_diagnostic]) == {:ok, snapshot}
  end

  test "keeps unknown entries in the branch but out of model context" do
    entries = [
      header("session", "/repo"),
      message_entry("root", nil, "message-1", "user", "hello"),
      state_entry("future-entry", "root", "future_extension_state", %{
        "data" => %{"x" => 1}
      }),
      message_entry("leaf", "future-entry", "message-2", "assistant", assistant_text("done"))
    ]

    assert {:ok,
            %Snapshot{
              active_leaf_id: "leaf",
              branch_entry_ids: ["root", "future-entry", "leaf"],
              messages: [%Message{id: "message-1"}, %Message{id: "message-2"}],
              diagnostics: []
            }} = Journal.replay(entries)
  end

  test "returns the index error for an unknown explicit leaf" do
    entries = [
      header("session", "/repo"),
      message_entry("root", nil, "message-1", "user", "hello")
    ]

    assert {:error, {:leaf_not_found, "missing"}} = Journal.replay(entries, leaf_id: "missing")
  end

  defp header(id, cwd) do
    %{"type" => "session", "version" => 3, "id" => id, "timestamp" => iso(), "cwd" => cwd}
  end

  defp message_entry(entry_id, parent_id, message_id, role, content) do
    %{
      "type" => "message",
      "id" => entry_id,
      "parentId" => parent_id,
      "timestamp" => iso(),
      "message" => %{
        "id" => message_id,
        "role" => role,
        "content" => content,
        "timestamp" => 1
      }
    }
  end

  defp state_entry(id, parent_id, type, payload) do
    Map.merge(
      %{"type" => type, "id" => id, "parentId" => parent_id, "timestamp" => iso()},
      payload
    )
  end

  defp assistant_text(text), do: [%{"type" => "text", "text" => text}]

  defp iso, do: "2026-07-21T00:00:00Z"
end
