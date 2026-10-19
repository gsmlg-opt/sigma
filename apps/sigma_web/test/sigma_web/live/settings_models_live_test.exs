defmodule Sigma.Web.SettingsModelsLiveTest do
  use Sigma.Web.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Sigma.Session.{ConfigManager, Models}

  @moduletag :tmp_dir
  setup %{tmp_dir: tmp_dir} do
    previous = Application.get_env(:sigma_session, :agent_dir)
    Application.put_env(:sigma_session, :agent_dir, Path.join(tmp_dir, "agent"))

    on_exit(fn ->
      if previous,
        do: Application.put_env(:sigma_session, :agent_dir, previous),
        else: Application.delete_env(:sigma_session, :agent_dir)

      Application.delete_env(:sigma_web, :model_discovery_options)
    end)

    {:ok, config} =
      ConfigManager.add_provider(%{
        "name" => "Model connection",
        "api_type" => "openai",
        "base_url" => "https://example.test/v1"
      })

    [provider_id] = Map.keys(config["providers"])
    %{provider_id: provider_id}
  end

  test "manual models validate budgets, edit, set default and confirm removal", %{
    conn: conn,
    provider_id: pid
  } do
    {:ok, view, _} = live(conn, "/settings/models")
    assert render(view) =~ "No configured models"
    view |> form("#models-provider-filter", %{"provider_id" => pid}) |> render_change()

    view
    |> form("#model-manual-form", %{
      "model" => %{"id" => "manual", "name" => "Manual", "defaultContextLimit" => "-1"}
    })
    |> render_submit()

    assert render(view) =~ "positive integer"
    assert Models.list() == []

    view
    |> form("#model-manual-form", %{
      "model" => %{"id" => "manual", "name" => "Manual", "defaultContextLimit" => "32000"}
    })
    |> render_submit()

    assert [%{default_context_limit: 32000}] = Models.list()
    view |> element("[phx-click='default_model']") |> render_click()
    config = ConfigManager.get_config()
    assert config["active_provider_id"] == pid
    assert config["default_model_id"] == "manual"
    view |> element("[phx-click='edit_model']") |> render_click()

    view
    |> form("#model-edit-form", %{"model" => %{"name" => "Renamed", "defaultContextLimit" => ""}})
    |> render_submit()

    assert [%{name: "Renamed", default_context_limit: nil}] = Models.list()
    view |> element("[phx-click='confirm_remove_model']") |> render_click()
    assert length(Models.list()) == 1
    view |> element("#model-confirm-remove") |> render_click()
    assert Models.list() == []
    assert ConfigManager.get_config()["default_model_id"] in [nil, ""]
  end

  test "discovery is explicit, selective and selection survives search", %{
    conn: conn,
    provider_id: pid
  } do
    owner = self()

    Application.put_env(:sigma_web, :model_discovery_options,
      plug: fn conn ->
        send(owner, :discovery_requested)

        Req.Test.json(conn, %{
          "data" => [%{"id" => "alpha"}, %{"id" => "beta"}, %{"id" => "gamma"}]
        })
      end
    )

    {:ok, view, _} = live(conn, "/settings/models")
    refute_receive :discovery_requested
    view |> form("#models-provider-filter", %{"provider_id" => pid}) |> render_change()
    view |> element("#models-discover") |> render_click()
    html = render_async(view)
    assert_receive :discovery_requested
    assert html =~ "alpha"
    assert Models.list() == []
    view |> element("#candidate-alpha") |> render_click()
    view |> form("#model-candidate-search", %{"query" => "beta"}) |> render_change()
    view |> element("#candidate-beta") |> render_click()
    view |> element("#models-add-selected") |> render_click()
    assert Models.list() |> Enum.map(& &1.model_id) |> Enum.sort() == ["alpha", "beta"]
    view |> form("#model-candidate-search", %{"query" => "gamma"}) |> render_change()
    view |> element("#candidate-gamma") |> render_click()
    view |> element("#models-add-selected") |> render_click()
    assert length(Models.list()) == 3
    view |> form("#model-candidate-search", %{"query" => "alpha"}) |> render_change()
    assert render(view) =~ "Already configured"
  end

  test "discovery errors preserve configured models and hide response details", %{
    conn: conn,
    provider_id: pid
  } do
    {:ok, _} = Models.add(pid, [%{"id" => "kept"}])

    Application.put_env(:sigma_web, :model_discovery_options,
      plug: fn conn -> Plug.Conn.send_resp(conn, 401, "secret-token") end
    )

    {:ok, view, _} = live(conn, "/settings/models")
    view |> form("#models-provider-filter", %{"provider_id" => pid}) |> render_change()
    view |> element("#models-discover") |> render_click()
    html = render_async(view)
    assert html =~ "authentication"
    refute html =~ "secret-token"
    assert [%{model_id: "kept"}] = Models.list()
  end

  test "connection changes discard an in-flight discovery result", %{conn: conn, provider_id: pid} do
    owner = self()

    Application.put_env(:sigma_web, :model_discovery_options,
      plug: fn conn ->
        send(owner, {:discovery_started, self()})

        receive do
          :finish -> Req.Test.json(conn, %{"data" => [%{"id" => "stale"}]})
        end
      end
    )

    {:ok, view, _} = live(conn, "/settings/models")
    view |> form("#models-provider-filter", %{"provider_id" => pid}) |> render_change()
    view |> element("#models-discover") |> render_click()
    assert_receive {:discovery_started, task}
    {:ok, _} = ConfigManager.update_provider(pid, %{"base_url" => "https://changed.test/v1"})
    send(task, :finish)
    html = render_async(view, 1000)
    assert html =~ "connection changed"
    refute html =~ "candidate-stale"
    assert Models.list() == []
  end

  test "open model pages refresh when another page changes configured membership", %{
    conn: conn,
    provider_id: pid
  } do
    {:ok, first, _} = live(conn, "/settings/models")
    {:ok, second, _} = live(conn, "/settings/models")
    first |> form("#models-provider-filter", %{"provider_id" => pid}) |> render_change()

    first
    |> form("#model-manual-form", %{"model" => %{"id" => "shared-model"}})
    |> render_submit()

    assert render(second) =~ "shared-model"
  end
end
