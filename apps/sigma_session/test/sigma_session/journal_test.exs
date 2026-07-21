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
        "serviceTier" => "default"
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
              messages: [
                %Message{role: :compaction_summary, content: "latest summary"},
                %Message{id: "message-1"}
              ],
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

  test "renders compaction state with kept and subsequent branch messages" do
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
                %Message{role: :compaction_summary, content: "earlier work"},
                %Message{id: "message-1"},
                %Message{id: "message-2", content: [%{type: :text, text: "two"}]}
              ]
            }} = Journal.replay(entries)
  end

  test "preserves supported legacy and family service tiers exactly" do
    supported = [
      nil,
      "auto",
      "default",
      "flex",
      "scale",
      "priority",
      "openai-only",
      "claude-only",
      %{"openai" => "priority"},
      %{"anthropic" => "auto", "google" => "flex"},
      %{"openai" => "default", "anthropic" => "scale", "google" => "priority"}
    ]

    for {service_tier, index} <- Enum.with_index(supported) do
      entries = [
        header("session", "/repo"),
        state_entry("tier-#{index}", nil, "service_tier_change", %{
          "serviceTier" => service_tier
        })
      ]

      assert {:ok, %Snapshot{service_tier: ^service_tier, diagnostics: []}} =
               Journal.replay(entries)
    end
  end

  test "rejects unsupported service tier shapes with one diagnostic" do
    invalid_payloads = [
      {%{}, :missing_service_tier},
      {%{"serviceTier" => "none"}, :invalid_service_tier},
      {%{"serviceTier" => "standard"}, :invalid_service_tier},
      {%{"serviceTier" => 42}, :invalid_service_tier},
      {%{"serviceTier" => []}, :invalid_service_tier},
      {%{"serviceTier" => %{}}, :invalid_service_tier},
      {%{"serviceTier" => %{"openai" => "bogus"}}, :invalid_service_tier},
      {%{"serviceTier" => %{"future" => "priority"}}, :invalid_service_tier},
      {%{"serviceTier" => %{"openai" => "priority", "future" => "priority"}},
       :invalid_service_tier},
      {%{"serviceTier" => %{"openai" => nil}}, :invalid_service_tier}
    ]

    for {{payload, reason}, index} <- Enum.with_index(invalid_payloads) do
      entry_id = "invalid-tier-#{index}"

      entries = [
        header("session", "/repo"),
        state_entry(entry_id, nil, "service_tier_change", payload)
      ]

      assert {:ok,
              %Snapshot{
                service_tier: nil,
                diagnostics: [
                  %{
                    kind: :invalid_payload,
                    entry_index: 1,
                    entry_id: ^entry_id,
                    reason: ^reason
                  }
                ]
              }} = Journal.replay(entries)
    end
  end

  test "malformed later state preserves the previous valid value" do
    cases = [
      {
        "reasoning",
        "thinking_level_change",
        %{"thinkingLevel" => "high", "configured" => "auto"},
        %{"thinkingLevel" => 42},
        fn snapshot -> {snapshot.reasoning_level, snapshot.configured_reasoning_level} end,
        {"high", "auto"},
        :invalid_reasoning_level
      },
      {
        "service-tier",
        "service_tier_change",
        %{"serviceTier" => %{"openai" => "priority", "google" => "flex"}},
        %{"serviceTier" => %{"openai" => "bogus"}},
        & &1.service_tier,
        %{"openai" => "priority", "google" => "flex"},
        :invalid_service_tier
      },
      {
        "mcp",
        "mcp_server_selection_change",
        %{"serverIds" => ["fs", "git"]},
        %{"serverIds" => ["fs", 42]},
        & &1.mcp_server_ids,
        ["fs", "git"],
        :invalid_mcp_server_ids
      },
      {
        "mode",
        "mode_change",
        %{"mode" => "plan", "data" => %{"file" => "PLAN.md"}},
        %{"mode" => "build", "data" => []},
        fn snapshot -> {snapshot.mode, snapshot.mode_data} end,
        {"plan", %{"file" => "PLAN.md"}},
        :invalid_mode_change
      },
      {
        "branch-summary",
        "branch_summary",
        %{"fromId" => "root", "summary" => "kept summary"},
        %{"fromId" => "root", "summary" => 42},
        fn snapshot -> Map.take(snapshot.branch_summary, ["fromId", "summary"]) end,
        %{"fromId" => "root", "summary" => "kept summary"},
        :invalid_branch_summary
      }
    ]

    for {name, type, valid_payload, invalid_payload, project, expected, reason} <- cases do
      valid_id = "#{name}-valid"
      invalid_id = "#{name}-invalid"

      entries = [
        header("session", "/repo"),
        state_entry(valid_id, nil, type, valid_payload),
        state_entry(invalid_id, valid_id, type, invalid_payload)
      ]

      assert {:ok, %Snapshot{} = snapshot} = Journal.replay(entries)
      assert project.(snapshot) == expected, name

      assert snapshot.diagnostics == [
               %{
                 kind: :invalid_payload,
                 entry_index: 2,
                 entry_id: invalid_id,
                 reason: reason
               }
             ],
             name
    end
  end

  test "diagnoses malformed payloads deterministically without losing valid messages" do
    caller_diagnostic = %{
      kind: :invalid_json,
      entry_id: nil,
      reason: {:decode_error, :truncated},
      byte_offset: 42
    }

    entries = [
      header("session", "/repo"),
      state_entry("orphan", "missing", "mode_change", %{"mode" => "plan"}),
      message_entry("root", nil, "message-1", "user", "hello"),
      message_entry("bad-message", "root", "message-2", "user", nil),
      state_entry("bad-model", "bad-message", "model_change", %{"model" => "invalid"}),
      state_entry("bad-model-role", "bad-model", "model_change", %{
        "role" => 42,
        "model" => "anthropic/valid"
      }),
      state_entry("bad-mcp", "bad-model-role", "mcp_server_selection_change", %{
        "serverIds" => ["ok", 42]
      })
    ]

    assert {:ok,
            %Snapshot{
              messages: [%Message{id: "message-1", content: "hello"}],
              diagnostics: diagnostics
            } = snapshot} =
             Journal.replay(entries, diagnostics: [caller_diagnostic, caller_diagnostic])

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
               entry_id: "bad-message",
               reason: {:invalid_content_for_role, :user}
             },
             %{
               kind: :invalid_payload,
               entry_index: 4,
               entry_id: "bad-model",
               reason: :invalid_model
             },
             %{
               kind: :invalid_payload,
               entry_index: 5,
               entry_id: "bad-model-role",
               reason: :invalid_model_role
             },
             %{
               kind: :invalid_payload,
               entry_index: 6,
               entry_id: "bad-mcp",
               reason: :invalid_mcp_server_ids
             }
           ]

    assert Journal.replay(entries, diagnostics: [caller_diagnostic, caller_diagnostic]) ==
             {:ok, snapshot}
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

  test "applies only the latest compaction on the active branch" do
    entries = [
      header("session", "/repo"),
      message_entry("entry-1", nil, "message-1", "user", "one"),
      message_entry("entry-2", "entry-1", "message-2", "assistant", "two"),
      message_entry("entry-3", "entry-2", "message-3", "user", "three"),
      state_entry("compact-left", "entry-3", "compaction", %{
        "summary" => "left summary",
        "firstKeptEntryId" => "entry-3"
      }),
      state_entry("sibling", "entry-2", "message", %{
        "message" => %{
          "id" => "message-sibling",
          "role" => "user",
          "content" => "sibling",
          "timestamp" => 1
        }
      }),
      state_entry("compact-right", "sibling", "compaction", %{
        "summary" => "right summary",
        "firstKeptEntryId" => "sibling"
      })
    ]

    assert {:ok, %Snapshot{messages: [summary, kept]}} =
             Journal.replay(entries, leaf_id: "compact-left")

    assert %Message{role: :compaction_summary, content: "left summary"} = summary
    assert %Message{id: "message-3"} = kept

    assert {:ok, %Snapshot{messages: [right_summary, right_kept]}} = Journal.replay(entries)
    assert %Message{role: :compaction_summary, content: "right summary"} = right_summary
    assert %Message{id: "message-sibling"} = right_kept
  end

  test "accepts legacy firstKeptId values that refer to nested message IDs" do
    entries = [
      header("session", "/repo"),
      message_entry("entry-1", nil, "message-1", "user", "one"),
      message_entry("entry-2", "entry-1", "message-2", "assistant", "two"),
      state_entry("compact", "entry-2", "compaction", %{
        "summary" => "legacy summary",
        "firstKeptId" => "message-2"
      })
    ]

    assert {:ok, %Snapshot{messages: [summary, kept]}} = Journal.replay(entries)
    assert %Message{content: "legacy summary"} = summary
    assert %Message{id: "message-2"} = kept
  end

  test "uses legacy firstKeptId when the canonical target is nil" do
    entries = [
      header("session", "/repo"),
      message_entry("entry-1", nil, "message-1", "user", "one"),
      message_entry("entry-2", "entry-1", "message-2", "assistant", "two"),
      state_entry("compact", "entry-2", "compaction", %{
        "summary" => "legacy summary",
        "firstKeptEntryId" => nil,
        "firstKeptId" => "message-2"
      })
    ]

    assert {:ok,
            %Snapshot{
              compaction: %{"id" => "compact"},
              messages: [
                %Message{role: :compaction_summary, content: "legacy summary"},
                %Message{id: "message-2"}
              ],
              diagnostics: []
            }} = Journal.replay(entries)
  end

  test "ignores an invalid compaction target and diagnoses it" do
    entries = [
      header("session", "/repo"),
      message_entry("entry-1", nil, "message-1", "user", "one"),
      state_entry("compact", "entry-1", "compaction", %{
        "summary" => "bad summary",
        "firstKeptEntryId" => "missing"
      })
    ]

    assert {:ok,
            %Snapshot{
              compaction: nil,
              messages: [%Message{id: "message-1"}],
              diagnostics: diagnostics
            }} =
             Journal.replay(entries)

    assert Enum.any?(diagnostics, &(&1.reason == :invalid_compaction_target))
    assert [_diagnostic] = diagnostics
  end

  test "diagnoses a non-map message before a valid compaction target without raising" do
    entries = [
      header("session", "/repo"),
      state_entry("bad-message", nil, "message", %{"message" => "malformed"}),
      message_entry("kept", "bad-message", "message-kept", "user", "kept"),
      state_entry("compact", "kept", "compaction", %{
        "summary" => "summary",
        "firstKeptEntryId" => "kept"
      })
    ]

    assert {:ok,
            %Snapshot{
              compaction: %{"id" => "compact"},
              messages: [
                %Message{role: :compaction_summary, content: "summary"},
                %Message{id: "message-kept"}
              ],
              diagnostics: [
                %{
                  kind: :invalid_payload,
                  entry_index: 1,
                  entry_id: "bad-message",
                  reason: :invalid_message
                }
              ]
            }} = Journal.replay(entries)
  end

  test "falls back to an earlier compaction when the latest target is invalid" do
    entries = [
      header("session", "/repo"),
      message_entry("entry-1", nil, "message-1", "user", "one"),
      message_entry("entry-2", "entry-1", "message-2", "assistant", "two"),
      state_entry("compact-earlier", "entry-2", "compaction", %{
        "summary" => "earlier summary",
        "firstKeptEntryId" => "entry-2"
      }),
      message_entry("entry-3", "compact-earlier", "message-3", "user", "three"),
      state_entry("compact-latest", "entry-3", "compaction", %{
        "summary" => "latest summary",
        "firstKeptEntryId" => "missing"
      })
    ]

    assert {:ok,
            %Snapshot{
              compaction: %{"id" => "compact-earlier"},
              messages: [
                %Message{role: :compaction_summary, content: "earlier summary"},
                %Message{id: "message-2"},
                %Message{id: "message-3"}
              ],
              diagnostics: [
                %{
                  kind: :invalid_payload,
                  entry_index: 5,
                  entry_id: "compact-latest",
                  reason: :invalid_compaction_target
                }
              ]
            }} = Journal.replay(entries)
  end

  test "falls back to an earlier compaction when the latest summary is malformed" do
    entries = [
      header("session", "/repo"),
      message_entry("entry-1", nil, "message-1", "user", "one"),
      message_entry("entry-2", "entry-1", "message-2", "assistant", "two"),
      state_entry("compact-earlier", "entry-2", "compaction", %{
        "summary" => "earlier summary",
        "firstKeptEntryId" => "entry-2"
      }),
      message_entry("entry-3", "compact-earlier", "message-3", "user", "three"),
      state_entry("compact-latest", "entry-3", "compaction", %{
        "summary" => 42,
        "firstKeptEntryId" => "entry-3"
      })
    ]

    assert {:ok,
            %Snapshot{
              compaction: %{"id" => "compact-earlier"},
              messages: [
                %Message{role: :compaction_summary, content: "earlier summary"},
                %Message{id: "message-2"},
                %Message{id: "message-3"}
              ],
              diagnostics: [
                %{
                  kind: :invalid_payload,
                  entry_index: 5,
                  entry_id: "compact-latest",
                  reason: :invalid_compaction
                }
              ]
            }} = Journal.replay(entries)
  end

  test "clears compaction state when no compaction timestamp is valid" do
    entries = [
      header("session", "/repo"),
      message_entry("entry-1", nil, "message-1", "user", "one"),
      state_entry("compact", "entry-1", "compaction", %{
        "summary" => "summary",
        "firstKeptEntryId" => "entry-1"
      })
      |> Map.put("timestamp", "not-a-timestamp")
    ]

    assert {:ok,
            %Snapshot{
              compaction: nil,
              messages: [%Message{id: "message-1"}],
              diagnostics: [
                %{
                  kind: :invalid_entry,
                  entry_index: 2,
                  entry_id: "compact",
                  reason: :invalid_timestamp
                }
              ]
            }} = Journal.replay(entries)
  end

  test "diagnoses malformed messages across the complete compacted branch" do
    caller_diagnostic = %{
      kind: :invalid_json,
      entry_id: nil,
      reason: {:decode_error, :truncated},
      byte_offset: 42
    }

    entries = [
      header("session", "/repo"),
      message_entry("old", nil, "message-old", "user", "old"),
      message_entry("bad-before", "old", "message-bad-before", "user", nil),
      message_entry("kept", "bad-before", "message-kept", "user", "kept"),
      state_entry("compact", "kept", "compaction", %{
        "summary" => "summary",
        "firstKeptEntryId" => "kept"
      }),
      message_entry("bad-after", "compact", "message-bad-after", "user", nil),
      message_entry("tail", "bad-after", "message-tail", "user", "tail")
    ]

    assert {:ok,
            %Snapshot{
              compaction: %{"id" => "compact"},
              messages: [
                %Message{role: :compaction_summary, content: "summary"},
                %Message{id: "message-kept"},
                %Message{id: "message-tail"}
              ],
              diagnostics: diagnostics
            }} =
             Journal.replay(entries, diagnostics: [caller_diagnostic, caller_diagnostic])

    assert diagnostics == [
             caller_diagnostic,
             %{
               kind: :invalid_payload,
               entry_index: 2,
               entry_id: "bad-before",
               reason: {:invalid_content_for_role, :user}
             },
             %{
               kind: :invalid_payload,
               entry_index: 5,
               entry_id: "bad-after",
               reason: {:invalid_content_for_role, :user}
             }
           ]
  end

  test "resolves canonical compaction targets only by entry ID when IDs collide" do
    entries = [
      header("session", "/repo"),
      message_entry("root", nil, "collision", "user", "drop me"),
      state_entry("collision", "root", "mode_change", %{"mode" => "plan"}),
      message_entry("kept", "collision", "message-kept", "user", "keep me"),
      state_entry("compact", "kept", "compaction", %{
        "summary" => "summary",
        "firstKeptEntryId" => "collision"
      })
    ]

    assert {:ok,
            %Snapshot{
              compaction: %{"id" => "compact"},
              messages: [
                %Message{role: :compaction_summary, content: "summary"},
                %Message{id: "message-kept"}
              ],
              diagnostics: []
            }} = Journal.replay(entries)
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
