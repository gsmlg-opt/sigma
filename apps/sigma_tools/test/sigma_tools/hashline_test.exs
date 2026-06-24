defmodule Sigma.Tools.HashlineTest do
  use ExUnit.Case, async: true

  alias Sigma.Tools.Hashline

  describe "compute_file_hash/1" do
    test "returns a four-character uppercase hex tag" do
      assert <<_::binary-size(4)>> = tag = Hashline.compute_file_hash("one\ntwo\n")
      assert tag =~ ~r/^[0-9A-F]{4}$/
    end

    test "ignores trailing spaces, tabs, and carriage returns" do
      assert Hashline.compute_file_hash("one  \ntwo\t\r") ==
               Hashline.compute_file_hash("one\ntwo")
    end
  end

  describe "parse_sections/2" do
    test "normalizes lowercase tags and cwd-relative absolute paths" do
      cwd = "/tmp/project"

      assert {:ok,
              [
                %{
                  "path" => "lib/a.ex",
                  "file_hash" => "1A2B",
                  "diff" => "replace 1..1:\n+defmodule A do end"
                }
              ]} =
               Hashline.parse_sections(
                 "[/tmp/project/lib/a.ex#1a2b]\nreplace 1..1:\n+defmodule A do end",
                 cwd
               )
    end

    test "merges repeated sections for the same file and tag" do
      input = """
      *** Begin Patch
      [lib/a.ex#1A2B]
      replace 1..1:
      +one
      [lib/a.ex#1A2B]
      delete 3
      *** End Patch
      """

      assert {:ok, [%{"diff" => "replace 1..1:\n+one\ndelete 3"}]} =
               Hashline.parse_sections(input, "/tmp/project")
    end

    test "rejects conflicting tags for the same file" do
      input = """
      [lib/a.ex#1A2B]
      replace 1..1:
      +one
      [lib/a.ex#FFFF]
      delete 3
      """

      assert {:error, reason} = Hashline.parse_sections(input, "/tmp/project")
      assert reason =~ "Conflicting hashline snapshot tags"
    end

    test "rejects malformed section tags" do
      assert {:error, reason} =
               Hashline.parse_sections("[lib/a.ex#1A2]\nreplace 1..1:\n+one", "/tmp/project")

      assert reason =~ "4-hex content-hash tag"
    end
  end

  describe "apply_edits/2" do
    test "applies replace and delete operations" do
      assert {:ok,
              %{
                "text" => "a\nx\nd",
                "first_changed_line" => 2,
                "warnings" => []
              }} =
               Hashline.apply_edits(
                 "a\nb\nc\nd",
                 "replace 2..3:\n+x"
               )

      assert {:ok, %{"text" => "a\nd"}} =
               Hashline.apply_edits("a\nb\nc\nd", "delete 2..3")
    end

    test "applies insert operations at head, tail, before, and after anchors" do
      assert {:ok, %{"text" => "head\na\nbefore-b\nb\nafter-b\nc\ntail"}} =
               Hashline.apply_edits(
                 "a\nb\nc",
                 """
                 insert head:
                 +head
                 insert before 2:
                 +before-b
                 insert after 2:
                 +after-b
                 insert tail:
                 +tail
                 """
               )
    end

    test "auto-prefixes bare body rows and strips read-output line prefixes" do
      assert {:ok, %{"text" => "a\nfoo\nbar\nd", "warnings" => [warning]}} =
               Hashline.apply_edits(
                 "a\nb\nc\nd",
                 "replace 2..3:\n2:foo\n3:bar"
               )

      assert warning =~ "Auto-prefixed bare body row"
    end

    test "rejects unified-diff minus rows" do
      assert {:error, reason} =
               Hashline.apply_edits("a\nb", "replace 2..2:\n-old\n+new")

      assert reason =~ "`-` rows are not valid"
    end

    test "rejects combined-diff hunk headers with a hashline-specific message" do
      assert {:error, reason} =
               Hashline.apply_edits(
                 "a\nb",
                 """
                 @@@ -1,2 -1,2 +1,3 @@@
                 -a
                 +A
                 """
               )

      assert reason =~ "unified-diff hunk header"
      assert reason =~ "replace"
    end
  end
end
