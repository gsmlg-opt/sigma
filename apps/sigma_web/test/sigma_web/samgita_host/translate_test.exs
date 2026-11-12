defmodule Sigma.Web.SamgitaHost.TranslateTest do
  use ExUnit.Case, async: true

  alias Sigma.Protocol.{Envelope, Error}
  alias Sigma.Web.SamgitaHost.Translate

  @tid "thr"

  defp ev(type, payload \\ %{}, turn \\ "t1") do
    {:ok, e} = Envelope.event(type, "s1", payload, turn_id: turn)
    e
  end

  defp ok!(event) do
    assert {:ok, n} = Translate.notification(event, @tid)
    assert {:ok, _} = SamgitaProtocol.Schema.validate(Map.merge(n, %{"stream_id" => "s", "cursor" => 1}))
    assert n["correlation_id"] == "t1"
    n
  end

  test "turn lifecycle" do
    assert %{"method" => "turn/started", "params" => %{"thread_id" => @tid, "turn_id" => "t1"}} =
             ok!(ev("turn.started"))

    for {type, status} <-
          [
            {"turn.completed", "completed"},
            {"turn.failed", "failed"},
            {"turn.cancelled", "interrupted"}
          ] do
      assert %{"method" => "turn/completed", "params" => %{"status" => ^status}} = ok!(ev(type))
    end
  end

  test "messages" do
    msg = %{"id" => "m1", "role" => "assistant", "content" => [%{"type" => "text", "text" => "hi"}]}

    assert %{
             "method" => "item/started",
             "params" => %{
               "item_id" => "m1",
               "item" => %{"type" => "message", "role" => "assistant", "content" => [_]}
             }
           } = ok!(ev("message.started", %{"message" => msg}))

    assert %{"method" => "item/completed", "params" => %{"item_id" => "m1"}} =
             ok!(ev("message.completed", %{"message" => msg}))
  end

  test "text delta only" do
    p = %{"messageId" => "m1", "delta" => "x", "deltaKind" => "text"}

    assert %{"method" => "item/delta", "params" => %{"item_id" => "m1", "delta" => "x"}} =
             ok!(ev("message.delta", p))

    assert :skip = Translate.notification(ev("message.delta", %{p | "deltaKind" => "thinking"}), @tid)
    assert :skip = Translate.notification(ev("message.delta", Map.delete(p, "deltaKind")), @tid)
  end

  test "tools" do
    assert %{
             "method" => "item/started",
             "params" => %{"item_id" => "c1", "item" => %{"type" => "tool", "name" => "ls"}}
           } = ok!(ev("tool.started", %{"toolCallId" => "c1", "name" => "ls", "arguments" => %{}}))

    assert %{
             "method" => "item/completed",
             "params" => %{"item" => %{"is_error" => true, "content" => "boom"}}
           } =
             ok!(
               ev("tool.completed", %{
                 "toolCallId" => "c1",
                 "name" => "ls",
                 "content" => "boom",
                 "isError" => true
               })
             )

    assert :skip = Translate.notification(ev("tool.update", %{"toolCallId" => "c1"}), @tid)
  end

  test "skips unknown events and missing turn id" do
    assert :skip = Translate.notification(ev("session.error"), @tid)
    assert :skip = Translate.notification(ev("turn.started", %{}, nil), @tid)
  end

  test "thread_started" do
    n = Translate.thread_started(@tid)
    assert n["method"] == "thread/started" and n["correlation_id"] == @tid
    assert {:ok, _} = SamgitaProtocol.Schema.validate(Map.merge(n, %{"stream_id" => "s", "cursor" => 1}))
  end

  test "error mapping" do
    code = &Translate.error(&1).code
    assert Translate.error({:prompt_rejected, :turn_active}).details == %{"reason" => "turn_active"}
    assert code.(:not_found) == "not_found"
    assert code.(:session_not_found) == "not_found"
    assert code.({:prompt_rejected, :turn_active}) == "conflict"
    assert code.({:prompt_rejected, :turn_mismatch}) == "conflict"
    assert code.(:turn_mismatch) == "conflict"
    assert code.({:prompt_rejected, :session_busy}) == "conflict"
    assert code.(:session_busy) == "conflict"
    assert code.(:session_not_running) == "conflict"
    assert code.(:model_unavailable) == "invalid_params"
    assert code.(:invalid_admission) == "invalid_params"
    assert code.(:invalid_params) == "invalid_params"
    assert code.({:prompt_rejected, :other}) == "handler_error"
    assert code.(:boom) == "handler_error"
  end

  test "error mapping from session.error envelopes" do
    env = fn c, d ->
      {:ok, e} = Envelope.event("session.error", "s1", %{}, error: Error.new(c, "m", d))
      e
    end

    assert Translate.error(env.("prompt_rejected", %{"reason" => "turn_active"})).code == "conflict"
    assert Translate.error(env.("prompt_rejected", %{"reason" => "x"})).code == "handler_error"
    assert Translate.error(env.("turn_mismatch", %{})).code == "conflict"
    assert Translate.error(env.("session_not_found", %{})).code == "not_found"

    for {c, d, reason} <- [
          {"prompt_rejected", %{"reason" => "turn_active"}, "turn_active"},
          {"prompt_rejected", %{"reason" => "turn_mismatch"}, "turn_mismatch"},
          {"prompt_rejected", %{"reason" => "session_busy"}, "session_busy"},
          {"turn_mismatch", %{}, "turn_mismatch"},
          {"session_busy", %{}, "session_busy"},
          {"session_not_running", %{"input" => "secret"}, "session_not_running"}
        ] do
      assert %{code: "conflict", details: %{"reason" => ^reason} = details} =
               Translate.error(env.(c, d))

      assert map_size(details) == 1
    end
    assert Translate.error(env.("invalid_params", %{"secret" => "s"})).details == %{}
  end
end
