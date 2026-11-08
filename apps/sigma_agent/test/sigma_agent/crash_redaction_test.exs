defmodule Sigma.Agent.CrashRedactionTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  require Logger

  alias Sigma.Agent.CrashRedaction

  @moduletag :tmp_dir
  @secret "sk-crash-redaction-secret-0123456789"

  defmodule IdleProvider do
    @behaviour Sigma.Ai.Provider
    @impl true
    def stream(_params), do: []
  end

  test "redacts credential keys at any depth without changing shape" do
    state = %{
      provider_options: [api_key: @secret, base_url: "https://example.test"],
      nested: {%{"resolved_key" => @secret, "name" => "p"}, [authorization: @secret]},
      empty: [api_key: ""],
      date: ~D[2026-11-09]
    }

    redacted = CrashRedaction.redact(state)

    refute inspect(redacted, limit: :infinity) =~ @secret
    assert redacted.provider_options == [api_key: "[REDACTED]", base_url: "https://example.test"]

    assert {%{"resolved_key" => "[REDACTED]", "name" => "p"}, [authorization: "[REDACTED]"]} =
             redacted.nested

    assert redacted.empty == [api_key: ""]
    assert redacted.date == ~D[2026-11-09]
  end

  test "a live Agent hides provider keys from status and crash reports", %{tmp_dir: tmp_dir} do
    Process.flag(:trap_exit, true)

    {:ok, agent} =
      Sigma.Agent.start_link(
        model: %{id: "mock-model", api: "mock-api", provider: "mock-provider"},
        provider: IdleProvider,
        options: [api_key: @secret, base_url: "https://example.test"],
        backplane_runtime_path: Path.join(tmp_dir, "runtime")
      )

    assert {:status, ^agent, _module, status_items} = :sys.get_status(agent)
    refute inspect(status_items, limit: :infinity, printable_limit: :infinity) =~ @secret

    # Sanity: the real state still carries the key for provider requests.
    assert inspect(:sys.get_state(agent), limit: :infinity, printable_limit: :infinity) =~
             @secret

    log =
      capture_log(fn ->
        catch_exit(GenServer.call(agent, {:crash_redaction_test_unhandled_call}))
        assert_receive {:EXIT, ^agent, _reason}, 5_000
        Logger.flush()
      end)

    assert log =~ "terminating"
    refute log =~ @secret
  end
end
