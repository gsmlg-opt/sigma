defmodule Sigma.Web.HostedCitations do
  @moduledoc false

  def sources(%{role: :assistant, metadata: metadata}) when is_map(metadata) do
    case metadata["openai_responses_hosted"] do
      %{"version" => 1, "items" => items} when is_list(items) ->
        items
        |> Enum.flat_map(&item_sources/1)
        |> Enum.uniq_by(& &1.url)

      _ ->
        []
    end
  end

  def sources(_), do: []

  defp item_sources(%{"item" => %{"type" => "message", "content" => content}})
       when is_list(content) do
    Enum.flat_map(content, fn
      %{"type" => "output_text", "annotations" => annotations} when is_list(annotations) ->
        Enum.flat_map(annotations, &source/1)

      _ ->
        []
    end)
  end

  defp item_sources(_), do: []

  defp source(%{"type" => "url_citation", "url" => url, "title" => title})
       when is_binary(url) and is_binary(title) do
    uri = URI.parse(url)

    if String.valid?(url) and String.valid?(title) and
         not String.match?(url, ~r/[\x00-\x20\x7f]/u) and
         uri.scheme in ["https", "http"] and is_binary(uri.host) and uri.host != "" and
         is_nil(uri.userinfo) do
      [%{url: url, title: if(String.trim(title) == "", do: uri.host, else: title)}]
    else
      []
    end
  end

  defp source(_), do: []
end
