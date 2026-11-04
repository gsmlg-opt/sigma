defmodule Sigma.Agent.BackplaneCodexResultsTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.Error
  alias Sigma.Agent.Backplane.Provider
  alias Sigma.Session.{EntryDecoder, EntryEncoder}

  test "content projection keeps the complete structured result for durable replay" do
    result = %{
      content: [%{type: :text, text: "done"}],
      structured: %{exit_code: 0, session_id: 42},
      artifacts: [%{path: "output.txt"}],
      progress: %{completed: 3},
      details: %{revision: 4},
      is_error: false
    }

    message = normalize("exec_command", result)
    assert message.content == result.content
    assert message.metadata.structured_result == json_value(result)

    assert {:ok, entry} = EntryEncoder.encode({:message_end, message}, nil, true)
    assert {:ok, restored} = entry |> json_value() |> EntryDecoder.message()
    assert restored.metadata["structured_result"] == json_value(result)
  end

  test "native view_image bytes become actual image content and serializable metadata" do
    data = <<137, 80, 78, 71, 13, 10, 26, 10, 255, 0>>
    encoded = Base.encode64(data)

    result = %{
      path: "plot.png",
      detail: "original",
      mime_type: "image/png",
      data: data,
      bytes: byte_size(data),
      image_url: "data:image/png;base64,#{encoded}"
    }

    message = normalize("view_image", result)
    refute message.is_error
    assert [%{type: :image, data: ^encoded, mime_type: "image/png"}] = message.content
    assert message.metadata.structured_result == json_value(Map.delete(result, :data))

    assert {:ok, entry} = EntryEncoder.encode({:message_end, message}, nil, true)
    assert {:ok, restored} = entry |> json_value() |> EntryDecoder.message()
    assert restored.content == message.content
    assert restored.metadata["structured_result"]["image_url"] == result.image_url
  end

  test "runtime errors remain structured without persisting their private cause" do
    error =
      Error.new(:forbidden, "outside workspace", details: %{path: "../secret"}, cause: self())

    message = normalize("apply_patch", %{is_error: true, error: error})
    assert message.is_error
    assert [%{type: :text, text: text}] = message.content
    assert text =~ "outside workspace"
    assert message.metadata.structured_result["error"] == json_value(Error.to_map(error))
    refute text =~ inspect(self())
    assert {:ok, _} = Jason.encode(message.metadata)
  end

  test "nonserializable sibling metadata cannot leak process handles" do
    message = normalize("exec_command", %{content: [%{type: :text, text: "ok"}], owner: self()})
    assert message.is_error
    assert message.content == [%{type: :text, text: "Error: malformed tool result"}]
    assert message.metadata == %{}
  end

  test "malformed projected blocks or error flags cannot create unreplayable journal entries" do
    for result <- [
          %{content: [1]},
          %{content: 1},
          %{content: [%{type: :text, text: "ok"}], is_error: "false"},
          %{content: [%{type: :image, data: "image", mime_type: nil}]}
        ] do
      message = normalize("exec_command", result)
      assert message.is_error
      assert message.content == [%{type: :text, text: "Error: malformed tool result"}]
      assert {:ok, entry} = EntryEncoder.encode({:message_end, message}, nil, true)
      assert {:ok, _} = entry |> json_value() |> EntryDecoder.message()
    end
  end

  defp normalize(name, result) do
    [message] =
      Provider.normalize_messages([
        %{role: :tool, name: name, tool_call_id: "native-call", result: result}
      ])

    message
  end

  defp json_value(value), do: value |> Jason.encode!() |> Jason.decode!()
end
