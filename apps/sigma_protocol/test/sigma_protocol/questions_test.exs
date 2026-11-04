defmodule Sigma.Protocol.QuestionsTest do
  use ExUnit.Case, async: true

  alias Sigma.Protocol.{Codec, Envelope, Questions}

  test "questions capability and additive envelopes round trip" do
    assert "questions.v1" in Envelope.capabilities()

    for {kind, type, payload} <- [
          {:command, "question.resolve",
           %{"requestId" => "ask-1", "action" => "answer", "answer" => "原文\n"}},
          {:command, "question.resolve", %{"requestId" => "ask-1", "action" => "cancel"}},
          {:event, "question.required",
           %{"requestId" => "ask-1", "request" => %{"question" => "Pick?"}}},
          {:event, "question.resolved", %{"requestId" => "ask-1"}}
        ] do
      assert {:ok, envelope} = apply(Envelope, kind, [type, "session", payload])
      assert {:ok, encoded} = Codec.encode(envelope)
      assert {:ok, ^envelope} = Codec.decode(encoded)
    end
  end

  test "question projection whitelists display fields without serializing private terms" do
    request = %{
      question: "[选择] 下一步？",
      options: [%{label: "继续", value: "continue", description: "原说明", secret: "hidden"}],
      allow_freeform: true,
      placeholder: "请输入",
      tool_call_id: "call-1",
      source: %{agent_id: "child", incarnation: 1, token: "hidden"},
      secret: "hidden",
      reply_to: self(),
      callback: fn -> :secret end
    }

    assert {:ok, projected} = Questions.request("ask-1", request)
    assert projected["requestId"] == "ask-1"
    assert projected["request"]["question"] == "[选择] 下一步？"
    assert projected["request"]["allowFreeform"]

    assert projected["request"]["options"] == [
             %{"label" => "继续", "value" => "continue", "description" => "原说明"}
           ]

    assert projected["request"]["source"] == %{"agent_id" => "child", "incarnation" => 1}
    assert {:ok, envelope} = Envelope.event("question.required", "session", projected)
    assert {:ok, json} = Codec.encode(envelope)
    refute json =~ "hidden"
    refute json =~ "callback"
    refute json =~ "reply_to"
  end

  test "malformed display fields fail rather than dropping or altering a choice" do
    for request <- [
          %{question: ""},
          %{question: self()},
          %{question: "Pick?", options: [%{label: "A", value: self()}]},
          %{question: "Pick?", allow_freeform: "true"},
          %{question: "Pick?", options: "A"},
          %{question: String.duplicate("x", 40_000)}
        ] do
      assert {:error, _} = Questions.request("ask-1", request)
    end
  end

  test "reply preserves accepted text and enforces the actual host choices" do
    request = %{
      id: "ask-1",
      question: "Pick?",
      options: [%{label: "A", value: "a"}],
      allow_freeform: false
    }

    payload = %{"requestId" => "ask-1", "action" => "answer", "answer" => "a"}
    assert {:ok, {:ok, "a"}} = Questions.reply(payload, request)
    assert {:error, _} = Questions.reply(Map.put(payload, "answer", "A"), request)
    assert {:error, _} = Questions.reply(Map.put(payload, "answer", "custom"), request)

    freeform = %{request | allow_freeform: true}

    assert {:ok, {:ok, "  中文\n"}} =
             Questions.reply(Map.put(payload, "answer", "  中文\n"), freeform)

    assert {:ok, {:error, :cancelled}} =
             Questions.reply(%{"requestId" => "ask-1", "action" => "cancel"}, request)
  end

  test "malformed, mismatched and permission replies are rejected" do
    request = %{id: "ask-1", question: "Pick?", allow_freeform: true}

    for payload <- [
          %{},
          %{"requestId" => "other", "action" => "answer", "answer" => "A"},
          %{"requestId" => "ask-1", "action" => "answer", "answer" => " "},
          %{"requestId" => "ask-1", "action" => "answer", "answer" => ["A"]},
          %{"requestId" => "ask-1", "action" => "answer", "answer" => <<255>>},
          %{
            "requestId" => "ask-1",
            "action" => "answer",
            "answer" => String.duplicate("x", 40_000)
          },
          %{"requestId" => "ask-1", "action" => "cancel", "answer" => "A"},
          %{"requestId" => "ask-1", "action" => "answer", "answer" => "A", "decision" => "allow"}
        ] do
      assert {:error, _} = Questions.reply(payload, request)
    end

    assert {:error, _} =
             Questions.reply(
               %{"requestId" => "ask-1", "action" => "answer", "answer" => "allow_once"},
               Map.put(request, :kind, :permission)
             )
  end
end
