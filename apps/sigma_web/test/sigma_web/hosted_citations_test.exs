defmodule Sigma.Web.HostedCitationsTest do
  use ExUnit.Case, async: true

  alias Sigma.Web.HostedCitations

  test "native message citations retain output order and deduplicate links" do
    message =
      message([
        citation("https://example.com/a", "A"),
        citation("https://example.com/b", "B"),
        citation("https://example.com/a", "Again")
      ])

    assert HostedCitations.sources(message) == [
             %{url: "https://example.com/a", title: "A"},
             %{url: "https://example.com/b", title: "B"}
           ]

    assert HostedCitations.sources(%{message | role: :user}) == []
  end

  test "corrupt history and unsafe URLs never become active links" do
    citations =
      for url <- [
            "javascript:alert(1)",
            "data:text/html,x",
            "https://u:p@example.com/",
            "https://example.com/\npath",
            "https:///",
            "//example.com/"
          ],
          do: citation(url, "bad")

    assert HostedCitations.sources(
             message(citations ++ [nil, %{}, citation("https://example.com/", "")])
           ) == [%{url: "https://example.com/", title: "example.com"}]

    for metadata <- [
          nil,
          %{},
          %{
            "openai_responses_hosted" => %{
              "version" => 1,
              "items" => [nil, %{"item" => %{"type" => "message", "content" => [nil]}}]
            }
          }
        ] do
      assert HostedCitations.sources(%{role: :assistant, metadata: metadata}) == []
    end
  end

  defp message(annotations),
    do: %{
      role: :assistant,
      metadata: %{
        "openai_responses_hosted" => %{
          "version" => 1,
          "items" => [
            %{
              "output_index" => 0,
              "item" => %{
                "type" => "message",
                "content" => [
                  %{"type" => "output_text", "text" => "Sourced", "annotations" => annotations}
                ]
              }
            }
          ]
        }
      }
    }

  defp citation(url, title),
    do: %{
      "type" => "url_citation",
      "url" => url,
      "title" => title,
      "start_index" => 0,
      "end_index" => 7
    }
end
