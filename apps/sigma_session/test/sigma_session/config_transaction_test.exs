defmodule Sigma.Session.ConfigTransactionTest do
  use ExUnit.Case, async: false
  alias Sigma.Session.{ConfigManager, Models}

  @moduletag :tmp_dir
  setup %{tmp_dir: dir} do
    previous = Application.get_env(:sigma_session, :agent_dir)
    Application.put_env(:sigma_session, :agent_dir, dir)

    File.write!(
      Path.join(dir, "models.json"),
      Jason.encode!(%{
        "providers" => %{"p" => %{"name" => "Original", "models" => [%{"id" => "keep"}]}}
      })
    )

    on_exit(fn ->
      if previous,
        do: Application.put_env(:sigma_session, :agent_dir, previous),
        else: Application.delete_env(:sigma_session, :agent_dir)
    end)

    :ok
  end

  test "concurrent explicit adds retain every model" do
    owner = self()

    tasks =
      for index <- 1..12 do
        Task.async(fn ->
          send(owner, {:ready, self()})

          receive do
            :add -> Models.add("p", [%{"id" => "new-#{index}"}])
          end
        end)
      end

    Enum.each(tasks, fn task -> assert_receive {:ready, pid} when pid == task.pid end)
    Enum.each(tasks, &send(&1.pid, :add))
    assert Enum.all?(Enum.map(tasks, &Task.await(&1, 15_000)), &match?({:ok, _}, &1))

    assert MapSet.new(Enum.map(Models.list(), & &1.model_id)) ==
             MapSet.new(["keep" | Enum.map(1..12, &"new-#{&1}")])
  end

  test "cached model read and nested add exclude a concurrent removal until completion" do
    {added, removed} =
      interleave(
        fn ->
          assert Enum.any?(Models.list(), &(&1.model_id == "keep"))
          assert {:ok, _} = Models.add("p", [%{"id" => "new"}])
        end,
        fn -> Models.remove("p", "keep") end
      )

    assert {:ok, _} = added
    assert {:ok, _} = removed
    assert Enum.map(Models.list(), & &1.model_id) == ["new"]
  end

  test "default removal cannot leave a stale pair after a nested default write" do
    {_set, removed} =
      interleave(fn -> assert {:ok, _} = Models.set_default("p", "keep") end, fn ->
        Models.remove("p", "keep")
      end)

    assert {:ok, _} = removed
    assert ConfigManager.get_config()["active_provider_id"] == ""
    assert ConfigManager.get_config()["default_model_id"] == ""
  end

  test "provider reference checks share the model transaction lock" do
    assert {:ok, _} = Models.remove("p", "keep")

    {_added, deleted} =
      interleave(fn -> assert {:ok, _} = Models.add("p", [%{"id" => "new"}]) end, fn ->
        ConfigManager.delete_provider("p")
      end)

    assert {:error, {:provider_in_use, [{:model, "new"}]}} = deleted
  end

  test "provider edits and model edits share the same transaction" do
    {_updated, added} =
      interleave(
        fn -> assert {:ok, _} = ConfigManager.update_provider("p", %{"name" => "Changed"}) end,
        fn -> Models.add("p", [%{"id" => "new"}]) end
      )

    assert {:ok, _} = added
    assert ConfigManager.get_config()["providers"]["p"]["name"] == "Changed"
    assert Enum.map(Models.list(), & &1.model_id) == ["keep", "new"]
  end

  defp interleave(first_operation, second_operation) do
    owner = self()

    first =
      Task.async(fn ->
        ConfigManager.transaction(fn ->
          result = first_operation.()
          send(owner, {:holding_transaction, self()})

          receive do
            :release -> result
          end
        end)
      end)

    assert_receive {:holding_transaction, pid} when pid == first.pid

    second =
      Task.async(fn ->
        send(owner, {:attempting_operation, self()})
        second_operation.()
      end)

    assert_receive {:attempting_operation, pid} when pid == second.pid

    try do
      assert Task.yield(second, 100) == nil
      send(first.pid, :release)
      {Task.await(first, 15_000), Task.await(second, 15_000)}
    after
      send(first.pid, :release)
      Task.shutdown(first, :brutal_kill)
      Task.shutdown(second, :brutal_kill)
    end
  end
end
