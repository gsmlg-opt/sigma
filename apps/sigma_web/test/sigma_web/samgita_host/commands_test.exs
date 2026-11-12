defmodule Sigma.Web.SamgitaHost.CommandsTest do
  use ExUnit.Case, async: true

  alias Sigma.Web.SamgitaHost.Commands

  setup do
    {:ok, pid} = Commands.start_link(name: nil, max: 3)
    %{s: pid}
  end

  test "new, complete, done", %{s: s} do
    assert :new = Commands.reserve(s, "c1", {"m", %{}})
    assert :ok = Commands.complete(s, "c1", :r)
    assert {:done, :r} = Commands.reserve(s, "c1", {"m", %{}})
  end

  test "different fingerprint conflicts", %{s: s} do
    :new = Commands.reserve(s, "c1", {"m", %{}})
    Commands.complete(s, "c1", :r)
    assert :conflict = Commands.reserve(s, "c1", {"m", %{"a" => 1}})
  end

  test "in-flight reentry conflicts", %{s: s} do
    :new = Commands.reserve(s, "c1", {"m", %{}})
    assert :conflict = Commands.reserve(s, "c1", {"m", %{}})
  end

  test "release allows retry", %{s: s} do
    :new = Commands.reserve(s, "c1", {"m", %{}})
    assert :ok = Commands.release(s, "c1")
    assert :new = Commands.reserve(s, "c1", {"m", %{}})
  end

  test "oldest entry is evicted past the bound", %{s: s} do
    for id <- ~w(a b c d), do: :new = Commands.reserve(s, id, {"m", id})
    assert :new = Commands.reserve(s, "a", {"m", "a"})
    assert :conflict = Commands.reserve(s, "d", {"m", "d"})
  end
end
