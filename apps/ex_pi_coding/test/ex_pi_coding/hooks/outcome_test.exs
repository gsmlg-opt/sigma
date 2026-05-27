defmodule PiCoding.Hooks.OutcomeTest do
  use ExUnit.Case, async: true

  alias PiCoding.Hooks.Outcome

  # ---------------------------------------------------------------------------
  # join/2 — lattice properties
  # ---------------------------------------------------------------------------

  describe "join/2 commutativity" do
    @pairs [
      {:proceed, {:block, "r"}},
      {:proceed, {:halt, nil}},
      {:proceed, {:ask, "r"}},
      {:proceed, {:modify, %{"k" => "v"}}},
      {:proceed, {:context, "text"}},
      {{:block, "r"}, {:ask, "r2"}},
      {{:block, "r"}, {:halt, "h"}},
      {{:ask, "r"}, {:defer, "d"}},
      {{:modify, %{"a" => 1}}, {:context, "t"}}
    ]

    for {a, b} <- @pairs do
      @a a
      @b b
      test "join(#{inspect(@a)}, #{inspect(@b)}) == join(#{inspect(@b)}, #{inspect(@a)})" do
        assert Outcome.join(@a, @b) == Outcome.join(@b, @a)
      end
    end
  end

  describe "join/2 :proceed is identity" do
    @outcomes [
      :proceed,
      {:block, "r"},
      {:halt, nil},
      {:ask, "x"},
      {:defer, "d"},
      {:modify, %{}},
      {:context, "c"}
    ]

    for o <- @outcomes do
      @o o
      test "join(:proceed, #{inspect(@o)}) == #{inspect(@o)}" do
        assert Outcome.join(:proceed, @o) == @o
        assert Outcome.join(@o, :proceed) == @o
      end
    end
  end

  describe "join/2 :halt is absorbing" do
    @outcomes [
      :proceed,
      {:block, "r"},
      {:ask, "x"},
      {:defer, "d"},
      {:modify, %{}},
      {:context, "c"}
    ]

    for o <- @outcomes do
      @o o
      test ":halt absorbs #{inspect(@o)}" do
        assert {:halt, _} = Outcome.join({:halt, nil}, @o)
        assert {:halt, _} = Outcome.join(@o, {:halt, nil})
      end
    end
  end

  test ":halt idempotent: join(:halt, :halt) is :halt" do
    assert {:halt, _} = Outcome.join({:halt, "a"}, {:halt, "b"})
  end

  describe "join/2 precedence: block > defer > ask > modify/context > proceed" do
    test "block wins over ask" do
      assert {:block, _} = Outcome.join({:block, "r"}, {:ask, "x"})
    end

    test "block wins over modify" do
      assert {:block, _} = Outcome.join({:block, "r"}, {:modify, %{}})
    end

    test "defer wins over ask" do
      assert {:defer, _} = Outcome.join({:defer, "d"}, {:ask, "x"})
    end

    test "ask wins over modify" do
      assert {:ask, _} = Outcome.join({:ask, "r"}, {:modify, %{"k" => "v"}})
    end

    test "ask wins over context" do
      assert {:ask, _} = Outcome.join({:ask, "r"}, {:context, "t"})
    end
  end

  describe "join/2 modify patch merging" do
    test "non-conflicting patches merge" do
      assert {:modify, %{"a" => 1, "b" => 2}} =
               Outcome.join({:modify, %{"a" => 1}}, {:modify, %{"b" => 2}})
    end

    test "conflicting patches escalate to :ask" do
      assert {:ask, _} =
               Outcome.join({:modify, %{"key" => "v1"}}, {:modify, %{"key" => "v2"}})
    end

    test "same patch value is not a conflict" do
      assert {:modify, %{"key" => "same"}} =
               Outcome.join({:modify, %{"key" => "same"}}, {:modify, %{"key" => "same"}})
    end
  end

  describe "join/2 context concatenation" do
    test "contexts concatenate" do
      {:context, combined} = Outcome.join({:context, "a"}, {:context, "b"})
      assert combined =~ "a"
      assert combined =~ "b"
    end

    test "context is capped at 10_000 chars" do
      big = String.duplicate("x", 6_000)
      {:context, result} = Outcome.join({:context, big}, {:context, big})
      assert byte_size(result) <= 10_000
    end
  end

  # ---------------------------------------------------------------------------
  # fold/1
  # ---------------------------------------------------------------------------

  describe "fold/1" do
    test "empty list folds to :proceed" do
      assert Outcome.fold([]) == :proceed
    end

    test "single :proceed" do
      assert Outcome.fold([:proceed]) == :proceed
    end

    test "deny beats allow — AC-8" do
      outcomes = [:proceed, {:block, "denied"}, :proceed]
      assert {:block, "denied"} = Outcome.fold(outcomes)
    end

    test "halt wins regardless of position" do
      outcomes = [{:block, "b"}, {:halt, "stop"}, {:ask, "a"}]
      assert {:halt, "stop"} = Outcome.fold(outcomes)
    end

    test "multiple :proceed stays :proceed" do
      assert Outcome.fold([:proceed, :proceed, :proceed]) == :proceed
    end
  end

  # ---------------------------------------------------------------------------
  # decode/3 — exit codes
  # ---------------------------------------------------------------------------

  describe "decode/3 exit 0" do
    test "empty stdout → :proceed" do
      assert Outcome.decode(:pre_tool_use, %{exit: 0, stdout: "", stderr: ""}, :codex) == :proceed
    end

    test "plain stdout → {:context, text}" do
      assert {:context, "hello"} =
               Outcome.decode(:pre_tool_use, %{exit: 0, stdout: "hello", stderr: ""}, :codex)
    end
  end

  describe "decode/3 exit 2" do
    test "PreToolUse exit 2 → :block with stderr as reason" do
      assert {:block, "denied"} =
               Outcome.decode(:pre_tool_use, %{exit: 2, stdout: "", stderr: "denied"}, :codex)
    end

    test "Stop exit 2 → :block" do
      assert {:block, _} =
               Outcome.decode(:stop, %{exit: 2, stdout: "", stderr: "continue"}, :codex)
    end

    test "UserPromptSubmit exit 2 → :block" do
      assert {:block, _} =
               Outcome.decode(
                 :user_prompt_submit,
                 %{exit: 2, stdout: "", stderr: "blocked"},
                 :codex
               )
    end

    test "non-blocking event exit 2 → :proceed" do
      # PreCompact exit 2 is non-steering in v1
      assert :proceed =
               Outcome.decode(:pre_compact, %{exit: 2, stdout: "", stderr: "err"}, :codex)
    end
  end

  describe "decode/3 non-zero, non-2 exit" do
    test "exit 1 → :proceed (non-blocking error)" do
      assert :proceed =
               Outcome.decode(:pre_tool_use, %{exit: 1, stdout: "", stderr: "err"}, :codex)
    end
  end

  describe "decode/3 JSON stdout — new schema" do
    test "permissionDecision allow → :proceed" do
      json = Jason.encode!(%{"hookSpecificOutput" => %{"permissionDecision" => "allow"}})

      assert :proceed =
               Outcome.decode(:pre_tool_use, %{exit: 0, stdout: json, stderr: ""}, :claude)
    end

    test "permissionDecision deny → :block" do
      json =
        Jason.encode!(%{
          "hookSpecificOutput" => %{
            "permissionDecision" => "deny",
            "permissionDecisionReason" => "not allowed"
          }
        })

      assert {:block, "not allowed"} =
               Outcome.decode(:pre_tool_use, %{exit: 0, stdout: json, stderr: ""}, :claude)
    end

    test "permissionDecision ask → :ask" do
      json = Jason.encode!(%{"hookSpecificOutput" => %{"permissionDecision" => "ask"}})

      assert {:ask, _} =
               Outcome.decode(:pre_tool_use, %{exit: 0, stdout: json, stderr: ""}, :claude)
    end

    test "updatedInput → :modify with patch" do
      json =
        Jason.encode!(%{
          "hookSpecificOutput" => %{
            "permissionDecision" => "allow",
            "updatedInput" => %{"command" => "ls -la"}
          }
        })

      assert {:modify, %{"command" => "ls -la"}} =
               Outcome.decode(:pre_tool_use, %{exit: 0, stdout: json, stderr: ""}, :claude)
    end

    test "continue:false → :halt" do
      json = Jason.encode!(%{"continue" => false})

      assert {:halt, _} =
               Outcome.decode(:stop, %{exit: 0, stdout: json, stderr: ""}, :codex)
    end

    test "additionalContext is joined as context" do
      json =
        Jason.encode!(%{
          "hookSpecificOutput" => %{
            "permissionDecision" => "allow",
            "additionalContext" => "some context"
          }
        })

      # allow + context → context wins (modify/context > proceed)
      result = Outcome.decode(:pre_tool_use, %{exit: 0, stdout: json, stderr: ""}, :claude)
      assert {:context, "some context"} = result
    end
  end

  describe "decode/3 JSON stdout — legacy schema" do
    test "decision block → :block" do
      json = Jason.encode!(%{"decision" => "block", "reason" => "bad"})

      assert {:block, "bad"} =
               Outcome.decode(:pre_tool_use, %{exit: 0, stdout: json, stderr: ""}, :codex)
    end

    test "legacy approve → allow → :proceed" do
      json = Jason.encode!(%{"decision" => "approve"})

      assert :proceed =
               Outcome.decode(:pre_tool_use, %{exit: 0, stdout: json, stderr: ""}, :codex)
    end
  end

  describe "decode/3 PostToolUse dialect divergence — AC-3" do
    test "Codex block → substitute (returns :block)" do
      json = Jason.encode!(%{"decision" => "block", "reason" => "feedback"})

      assert {:block, "feedback"} =
               Outcome.decode(:post_tool_use, %{exit: 0, stdout: json, stderr: ""}, :codex)
    end

    test "Claude block → annotate alongside (returns :context)" do
      json = Jason.encode!(%{"decision" => "block", "reason" => "feedback"})

      assert {:context, "feedback"} =
               Outcome.decode(:post_tool_use, %{exit: 0, stdout: json, stderr: ""}, :claude)
    end

    test "updatedToolOutput → substitute regardless of dialect" do
      json = Jason.encode!(%{"hookSpecificOutput" => %{"updatedToolOutput" => "replaced"}})

      assert {:modify, %{"tool_output" => "replaced"}} =
               Outcome.decode(:post_tool_use, %{exit: 0, stdout: json, stderr: ""}, :codex)

      assert {:modify, %{"tool_output" => "replaced"}} =
               Outcome.decode(:post_tool_use, %{exit: 0, stdout: json, stderr: ""}, :claude)
    end
  end
end
