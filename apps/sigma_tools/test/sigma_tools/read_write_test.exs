defmodule Sigma.Tools.ReadWriteTest do
  use ExUnit.Case, async: true

  @tag :tmp_dir
  test "read returns numbered lines without snapshot tags or state", %{tmp_dir: cwd} do
    path = Path.join(cwd, "a.txt")
    File.write!(path, "\uFEFFone\r\ntwo\r\nthree\r\n")
    store = Sigma.Tools.Store.new()

    assert {:ok, %{content: [%{text: text}], details: details}} =
             Sigma.Tools.Read.execute("read", %{"path" => "a.txt", "offset" => 2, "limit" => 1},
               cwd: cwd,
               tool_state: store
             )

    assert text =~ "[a.txt]\n2:two"
    assert text =~ "Showing lines 2-2 of 4"
    assert %{path: ^path, read_lines: 1} = details
    refute Map.has_key?(details, :hash)
    assert [] = :ets.tab2list(store)
  end

  @tag :tmp_dir
  test "write creates a file without recording a snapshot and still rejects overwrites", %{
    tmp_dir: cwd
  } do
    store = Sigma.Tools.Store.new()
    params = %{"path" => "new/a.txt", "content" => "one\n"}

    assert {:ok, %{content: [%{text: "Created new/a.txt."}], details: details}} =
             Sigma.Tools.Write.execute("write", params, cwd: cwd, tool_state: store)

    assert File.read!(Path.join(cwd, "new/a.txt")) == "one\n"
    refute Map.has_key?(details, :hash)
    assert [] = :ets.tab2list(store)
    assert {:error, reason} = Sigma.Tools.Write.execute("write", params, cwd: cwd)
    assert reason =~ "File already exists"
  end
end
