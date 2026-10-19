defmodule Sigma.Session.ModelsTest do
  use ExUnit.Case, async: false
  alias Sigma.Session.{ConfigEvents, ConfigManager, Models}

  @moduletag :tmp_dir
  setup %{tmp_dir: dir} do
    previous = Application.get_env(:sigma_session, :agent_dir)
    Application.put_env(:sigma_session, :agent_dir, dir)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:sigma_session, :agent_dir, previous),
        else: Application.delete_env(:sigma_session, :agent_dir)
    end)

    File.write!(
      Path.join(dir, "models.json"),
      Jason.encode!(%{
        "extra" => true,
        "providers" => %{
          "p" => %{
            "name" => "Provider",
            "api" => "openai-responses",
            "vendor" => %{"keep" => true},
            "models" => ["legacy", %{"id" => "known", "contextWindow" => 1000, "vendor" => true}]
          }
        }
      })
    )

    :ok
  end

  test "only explicit collection operations add models and preserve metadata" do
    File.write!(
      Path.join(ConfigManager.agent_dir(), "settings.json"),
      Jason.encode!(%{"defaultProvider" => "p", "defaultModel" => "ghost"})
    )

    assert ConfigManager.get_config()["providers"]["p"]["model"] == ""
    assert {:error, :model_unavailable} = Models.resolve("p", "ghost")

    assert {:ok, _} =
             ConfigManager.update_provider("p", %{
               "model" => "ghost",
               "models" => [%{"id" => "ghost"}],
               "name" => "Renamed"
             })

    assert Enum.map(Models.list(), & &1.model_id) == ["legacy", "known"]

    assert {:ok, _} =
             Models.add("p", [
               %{"id" => " known ", "vendor" => false},
               %{"id" => " new ", "defaultContextLimit" => "131072"},
               %{"id" => "new"}
             ])

    assert Enum.map(Models.list(), & &1.model_id) == ["legacy", "known", "new"]
    assert Enum.find(Models.list(), &(&1.model_id == "known")).metadata["vendor"]
    assert {:ok, provider} = Models.resolve("p", "new")
    assert provider["model"] == "new"
    assert Enum.find(Models.list(), &(&1.model_id == "new")).default_context_limit == 131_072

    assert {:ok, _} =
             Models.update("p", "known", %{"name" => "Named", "defaultContextLimit" => "512"})

    assert Enum.find(Models.list(), &(&1.model_id == "known")).metadata["contextWindow"] == 1000
    assert {:ok, _} = Models.set_default("p", "new")
    assert {:ok, _} = Models.remove("p", "new")
    assert ConfigManager.get_config()["active_provider_id"] == ""
    assert {:error, :model_unavailable} = ConfigManager.set_active_provider("p")
    saved = Path.join(ConfigManager.agent_dir(), "models.json") |> File.read!() |> Jason.decode!()
    assert saved["providers"]["p"]["vendor"] == %{"keep" => true}
    assert saved["extra"]
  end

  test "positive strict budgets and IDs are validated without side effects" do
    for value <- [0, -1, "1x", "1.5", 1.5] do
      assert {:error, :invalid_context_limit} =
               Models.add("p", [%{"id" => "new", "defaultContextLimit" => value}])
    end

    assert {:error, :invalid_model_id} = Models.add("p", [%{"id" => " "}])
    assert {:error, :provider_unavailable} = Models.add("missing", [%{"id" => "ok"}])
    assert {:ok, _} = Models.update("p", "known", %{"defaultContextLimit" => " "})
    assert Enum.find(Models.list(), &(&1.model_id == "known")).default_context_limit == nil
  end

  test "events are isolated by agent directory and reads do not notify" do
    unless Process.whereis(ConfigEvents),
      do: start_supervised!(%{id: ConfigEvents, start: {:pg, :start_link, [ConfigEvents]}})

    assert :ok = ConfigEvents.subscribe()
    ConfigManager.get_config()
    refute_receive {:models_changed, _}
    original_dir = ConfigManager.agent_dir()
    Application.put_env(:sigma_session, :agent_dir, Path.join(original_dir, "other"))
    assert :ok = ConfigEvents.broadcast()
    refute_receive {:models_changed, _}
    Application.put_env(:sigma_session, :agent_dir, original_dir)
    assert {:ok, _} = Models.add("p", [%{"id" => "added"}])
    assert_receive {:models_changed, dir}
    assert dir == ConfigManager.agent_dir()
  end
end
