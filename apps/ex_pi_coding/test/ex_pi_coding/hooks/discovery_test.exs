defmodule PiCoding.Hooks.DiscoveryTest do
  use ExUnit.Case, async: true

  alias PiCoding.Hooks.Discovery
  alias PiCoding.Hooks.Spec
  alias PiCoding.Hooks.Spec.Command

  describe "parse/2 — Codex format" do
    test "parses a PreToolUse command hook" do
      json =
        Jason.encode!([
          %{
            "event" => "PreToolUse",
            "hooks" => [
              %{
                "matcher" => "Bash",
                "hooks" => [%{"command" => "echo hello", "timeout" => 10}]
              }
            ]
          }
        ])

      {:ok, specs} = Discovery.parse(json, :codex)

      assert [
               %Spec{
                 event: :pre_tool_use,
                 matcher: "Bash",
                 handler: %Command{cmd: "echo hello", timeout_ms: 10_000}
               }
             ] = specs
    end

    test "parses multiple events" do
      json =
        Jason.encode!([
          %{
            "event" => "PreToolUse",
            "hooks" => [%{"matcher" => "Bash", "hooks" => [%{"command" => "a"}]}]
          },
          %{
            "event" => "PostToolUse",
            "hooks" => [%{"matcher" => "*", "hooks" => [%{"command" => "b"}]}]
          }
        ])

      {:ok, specs} = Discovery.parse(json, :codex)
      assert length(specs) == 2
      assert Enum.any?(specs, &(&1.event == :pre_tool_use))
      assert Enum.any?(specs, &(&1.event == :post_tool_use))
    end

    test "matcher nil becomes :any" do
      json =
        Jason.encode!([
          %{"event" => "Stop", "hooks" => [%{"hooks" => [%{"command" => "x"}]}]}
        ])

      {:ok, [spec]} = Discovery.parse(json, :codex)
      assert spec.matcher == :any
    end

    test "matcher * becomes :any" do
      json =
        Jason.encode!([
          %{
            "event" => "SessionStart",
            "hooks" => [%{"matcher" => "*", "hooks" => [%{"command" => "x"}]}]
          }
        ])

      {:ok, [spec]} = Discovery.parse(json, :codex)
      assert spec.matcher == :any
    end

    test "regex matcher is compiled" do
      json =
        Jason.encode!([
          %{
            "event" => "PreToolUse",
            "hooks" => [%{"matcher" => "mcp__.*", "hooks" => [%{"command" => "x"}]}]
          }
        ])

      {:ok, [spec]} = Discovery.parse(json, :codex)
      assert %Regex{} = spec.matcher
    end

    test "default timeout is 600_000ms" do
      json =
        Jason.encode!([
          %{"event" => "PreToolUse", "hooks" => [%{"hooks" => [%{"command" => "x"}]}]}
        ])

      {:ok, [spec]} = Discovery.parse(json, :codex)
      assert spec.handler.timeout_ms == 600_000
    end

    test "UserPromptSubmit default timeout is 30_000ms" do
      json =
        Jason.encode!([
          %{"event" => "UserPromptSubmit", "hooks" => [%{"hooks" => [%{"command" => "x"}]}]}
        ])

      {:ok, [spec]} = Discovery.parse(json, :codex)
      assert spec.handler.timeout_ms == 30_000
    end

    test "explicit timeout in seconds is converted to ms" do
      json =
        Jason.encode!([
          %{"event" => "Stop", "hooks" => [%{"hooks" => [%{"command" => "x", "timeout" => 5}]}]}
        ])

      {:ok, [spec]} = Discovery.parse(json, :codex)
      assert spec.handler.timeout_ms == 5_000
    end

    test "timeoutSec alias works" do
      json =
        Jason.encode!([
          %{
            "event" => "Stop",
            "hooks" => [%{"hooks" => [%{"command" => "x", "timeoutSec" => 15}]}]
          }
        ])

      {:ok, [spec]} = Discovery.parse(json, :codex)
      assert spec.handler.timeout_ms == 15_000
    end

    test "unknown event is silently skipped" do
      json =
        Jason.encode!([
          %{"event" => "UnknownEvent", "hooks" => [%{"hooks" => [%{"command" => "x"}]}]}
        ])

      {:ok, specs} = Discovery.parse(json, :codex)
      assert specs == []
    end

    test "http handler is marked unsupported" do
      json =
        Jason.encode!([
          %{
            "event" => "PreToolUse",
            "hooks" => [%{"hooks" => [%{"url" => "http://example.com"}]}]
          }
        ])

      {:ok, [spec]} = Discovery.parse(json, :codex)
      assert spec.unsupported_reason =~ "not supported"
    end

    test "returns error on invalid JSON" do
      assert {:error, {:json_decode, _}} = Discovery.parse("not json", :codex)
    end

    test "additive: multiple sources produce all specs" do
      json1 =
        Jason.encode!([
          %{"event" => "PreToolUse", "hooks" => [%{"hooks" => [%{"command" => "a"}]}]}
        ])

      json2 =
        Jason.encode!([%{"event" => "Stop", "hooks" => [%{"hooks" => [%{"command" => "b"}]}]}])

      {:ok, specs1} = Discovery.parse(json1, :codex)
      {:ok, specs2} = Discovery.parse(json2, :codex)

      all = specs1 ++ specs2
      assert length(all) == 2
      assert Enum.any?(all, &(&1.event == :pre_tool_use))
      assert Enum.any?(all, &(&1.event == :stop))
    end
  end

  describe "parse/2 — Claude settings.json format" do
    test "extracts hooks from the 'hooks' key" do
      json =
        Jason.encode!(%{
          "hooks" => [
            %{
              "event" => "PreToolUse",
              "hooks" => [%{"matcher" => "Edit|Write", "hooks" => [%{"command" => "prettier"}]}]
            }
          ]
        })

      {:ok, [spec]} = Discovery.parse(json, :claude)
      assert spec.event == :pre_tool_use
      assert spec.matcher == "Edit|Write"
    end

    test "returns empty list when no hooks key" do
      json = Jason.encode!(%{"other" => "stuff"})
      {:ok, specs} = Discovery.parse(json, :claude)
      assert specs == []
    end

    test "parses map-keyed format (actual Claude Code settings.json)" do
      json =
        Jason.encode!(%{
          "hooks" => %{
            "SessionStart" => [
              %{
                "hooks" => [
                  %{"type" => "command", "command" => "node /ext/on-start.js"}
                ]
              }
            ]
          }
        })

      {:ok, [spec]} = Discovery.parse(json, :claude)
      assert spec.event == :session_start
      assert spec.matcher == :any
      assert %Spec.Command{cmd: "node /ext/on-start.js"} = spec.handler
    end

    test "map-keyed format with multiple events" do
      json =
        Jason.encode!(%{
          "hooks" => %{
            "PreToolUse" => [
              %{"matcher" => "Bash", "hooks" => [%{"command" => "check-bash"}]}
            ],
            "PostToolUse" => [
              %{"hooks" => [%{"command" => "audit"}]}
            ]
          }
        })

      {:ok, specs} = Discovery.parse(json, :claude)
      assert length(specs) == 2
      pre = Enum.find(specs, &(&1.event == :pre_tool_use))
      post = Enum.find(specs, &(&1.event == :post_tool_use))
      assert pre.matcher == "Bash"
      assert %Spec.Command{cmd: "check-bash"} = pre.handler
      assert post.matcher == :any
      assert %Spec.Command{cmd: "audit"} = post.handler
    end
  end

  describe "event name normalization" do
    for {raw, expected} <- [
          {"PreToolUse", :pre_tool_use},
          {"pre_tool_use", :pre_tool_use},
          {"PostToolUse", :post_tool_use},
          {"UserPromptSubmit", :user_prompt_submit},
          {"Stop", :stop},
          {"SessionStart", :session_start},
          {"PreCompact", :pre_compact},
          {"PermissionRequest", :permission_request}
        ] do
      @raw raw
      @expected expected
      test "#{raw} → #{expected}" do
        json =
          Jason.encode!([%{"event" => @raw, "hooks" => [%{"hooks" => [%{"command" => "x"}]}]}])

        {:ok, [spec]} = Discovery.parse(json, :codex)
        assert spec.event == @expected
      end
    end
  end
end
