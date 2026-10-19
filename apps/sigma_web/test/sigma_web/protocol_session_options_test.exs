defmodule Sigma.Web.ProtocolSessionOptionsTest do
  use ExUnit.Case, async: false

  alias Sigma.Web.ProtocolSessionOptions

  @tag :tmp_dir
  test "new protocol sessions validate model membership and freeze the resolved default budget",
       %{tmp_dir: tmp} do
    with_config(tmp, fn ->
      assert {:ok, payload} = ProtocolSessionOptions.prepare_create(%{})
      assert payload["providerId"] == "p"
      assert payload["modelId"] == "kept"
      assert payload["metadata"]["context_limit"] == 128_000

      assert {:ok, payload} =
               ProtocolSessionOptions.prepare_create(%{
                 "metadata" => %{"context_limit" => "65536"}
               })

      assert payload["metadata"]["context_limit"] == 65_536

      assert {:error, :model_unavailable} =
               ProtocolSessionOptions.prepare_create(%{
                 "providerId" => "p",
                 "modelId" => "removed"
               })

      assert {:error, :invalid_context_limit} =
               ProtocolSessionOptions.prepare_create(%{"metadata" => %{"context_limit" => 0}})

      assert {:error, :invalid_session_metadata} =
               ProtocolSessionOptions.prepare_create(%{"metadata" => []})
    end)
  end

  @tag :tmp_dir
  test "journal and metadata models require configured membership, even with a valid global default",
       %{tmp_dir: tmp} do
    with_config(tmp, fn ->
      snapshot = %{
        cwd: tmp,
        mcp_server_ids: [],
        provider_id: "p",
        model_id: "removed",
        model_source: :journal
      }

      assert [] == ProtocolSessionOptions.resolve(snapshot, tmp, tmp, "removed")

      File.write!(
        Path.join(tmp, "legacy.meta.json"),
        Jason.encode!(%{"provider_id" => "p", "model_id" => "removed"})
      )

      assert [] ==
               ProtocolSessionOptions.resolve(%{cwd: tmp, mcp_server_ids: []}, tmp, tmp, "legacy")
    end)
  end

  @tag :tmp_dir
  test "protocol budgets preserve existing custom values and legacy default", %{tmp_dir: tmp} do
    with_config(tmp, fn ->
      snapshot = %{
        cwd: tmp,
        mcp_server_ids: [],
        provider_id: "p",
        model_id: "kept",
        model_source: :journal
      }

      opts = ProtocolSessionOptions.resolve(snapshot, tmp, tmp, "legacy")
      assert opts[:context_limit] == 256_000
      File.write!(Path.join(tmp, "custom.meta.json"), Jason.encode!(%{"context_limit" => 65_536}))
      opts = ProtocolSessionOptions.resolve(snapshot, tmp, tmp, "custom")
      assert opts[:context_limit] == 65_536
    end)
  end

  defp with_config(tmp, fun) do
    previous = Application.get_env(:sigma_session, :agent_dir)
    dir = Path.join(tmp, "agent")
    File.mkdir_p!(dir)
    Application.put_env(:sigma_session, :agent_dir, dir)

    File.write!(
      Path.join(dir, "models.json"),
      Jason.encode!(%{
        "providers" => %{
          "p" => %{
            "api" => "openai",
            "baseUrl" => "https://example.com/v1",
            "models" => [%{"id" => "kept", "defaultContextLimit" => 128_000}]
          }
        }
      })
    )

    File.write!(
      Path.join(dir, "settings.json"),
      Jason.encode!(%{"defaultProvider" => "p", "defaultModel" => "kept"})
    )

    try do
      fun.()
    after
      if previous,
        do: Application.put_env(:sigma_session, :agent_dir, previous),
        else: Application.delete_env(:sigma_session, :agent_dir)
    end
  end
end
