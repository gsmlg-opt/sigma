defmodule Sigma.Session.Journal.IndexTest do
  use ExUnit.Case, async: true

  alias Sigma.Session.Journal.Index

  test "selects the last legacy header and resolves the latest branch" do
    entries = [
      header("source", "/old"),
      entry("root", nil, "message"),
      entry("left", "root", "message"),
      entry("right", "root", "message"),
      Map.put(header("fork", "/new"), "parentSession", "source")
    ]

    index = Index.build(entries)

    assert index.header["id"] == "fork"
    assert index.header["parentSession"] == "source"
    assert {:ok, {"right", path}} = Index.path(index)
    assert Enum.map(path, & &1.entry["id"]) == ["root", "right"]
  end

  test "resolves an explicitly selected sibling leaf" do
    index =
      Index.build([
        header("session", "/repo"),
        entry("root", nil, "message"),
        entry("left", "root", "message"),
        entry("right", "root", "message")
      ])

    assert {:ok, {"left", path}} = Index.path(index, "left")
    assert Enum.map(path, & &1.entry["id"]) == ["root", "left"]
    assert {:error, {:leaf_not_found, "missing"}} = Index.path(index, "missing")
  end

  test "keeps the first duplicate and diagnoses invalid entries deterministically" do
    index =
      Index.build([
        header("session", "/repo"),
        entry("root", nil, "message"),
        entry("root", nil, "message"),
        entry("orphan", "missing", "message"),
        entry("forward", "later", "message"),
        entry("self", "self", "message"),
        Map.put(entry("bad-time", "root", "message"), "timestamp", "invalid"),
        entry("leaf", "root", "message"),
        entry("later", nil, "message")
      ])

    assert Enum.map(index.ordered, & &1.entry["id"]) == ["root", "leaf", "later"]

    assert Enum.map(index.diagnostics, &{&1.kind, &1.entry_id, &1.reason}) == [
             {:duplicate_id, "root", :duplicate_id},
             {:invalid_entry, "orphan", :missing_parent},
             {:invalid_entry, "forward", :missing_parent},
             {:invalid_entry, "self", :self_parent},
             {:invalid_entry, "bad-time", :invalid_timestamp}
           ]
  end

  test "accepts a valid header id as a legacy root parent" do
    index = Index.build([header("session", "/repo"), entry("message", "session", "message")])

    assert {:ok, {"message", [node]}} = Index.path(index)
    assert node.parent_id == nil
  end

  test "falls back to the last structurally valid legacy header" do
    invalid_header = Map.put(header("fork", "/new"), "timestamp", "not-a-timestamp")

    index =
      Index.build([
        header("source", "/old"),
        entry("root", nil, "message"),
        invalid_header
      ])

    assert index.header["id"] == "source"

    assert Enum.any?(
             index.diagnostics,
             &(&1.kind == :invalid_header and &1.entry_id == "fork" and
                 &1.reason == :invalid_timestamp)
           )
  end

  defp header(id, cwd) do
    %{
      "type" => "session",
      "version" => 3,
      "id" => id,
      "timestamp" => "2026-07-21T00:00:00Z",
      "cwd" => cwd
    }
  end

  defp entry(id, parent_id, type) do
    %{
      "type" => type,
      "id" => id,
      "parentId" => parent_id,
      "timestamp" => "2026-07-21T00:00:00Z"
    }
  end
end
