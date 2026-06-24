defmodule Sigma.Coding.Tools.UrlFetch do
  @behaviour Sigma.Coding.Tool

  @max_chars 50_000
  @timeout 30_000

  @impl true
  def name, do: "url_fetch"

  @impl true
  def description do
    "Fetch the text content of a URL. Returns HTML stripped to plain text. Use for reading documentation, GitHub issues, API references, or any web resource."
  end

  @impl true
  def schema do
    %{
      "type" => "object",
      "properties" => %{
        "url" => %{
          "type" => "string",
          "description" => "The URL to fetch (must be http:// or https://)"
        },
        "max_length" => %{
          "type" => "integer",
          "description" => "Maximum characters to return (default: #{@max_chars})",
          "minimum" => 1
        }
      },
      "required" => ["url"]
    }
  end

  @impl true
  def execute(_tool_call_id, params, _opts) do
    url = Map.get(params, "url")
    max_length = Map.get(params, "max_length", @max_chars)

    unless String.starts_with?(url, ["http://", "https://"]) do
      {:error, "Only http:// and https:// URLs are supported"}
    else
      do_fetch(url, max_length)
    end
  end

  defp do_fetch(url, max_length) do
    case Req.get(url,
           receive_timeout: @timeout,
           headers: [{"user-agent", "sigma/1.0 (Elixir bot)"}],
           redirect: true
         ) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        text =
          body
          |> strip_html()
          |> collapse_whitespace()

        truncated = String.length(text) > max_length
        text = String.slice(text, 0, max_length)
        text = if truncated, do: text <> "\n(truncated)", else: text

        {:ok,
         %{
           content: [%{type: :text, text: text, text_signature: nil}],
           details: %{url: url, status: status, truncated: truncated}
         }}

      {:ok, %{status: status}} ->
        {:error, "HTTP #{status} from #{url}"}

      {:error, reason} ->
        {:error, "Fetch failed: #{Exception.message(reason)}"}
    end
  end

  defp strip_html(html) when is_binary(html) do
    html
    |> String.replace(~r/<style[^>]*>.*?<\/style>/si, " ")
    |> String.replace(~r/<script[^>]*>.*?<\/script>/si, " ")
    |> String.replace(~r/<[^>]+>/, " ")
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&nbsp;", " ")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
  end

  defp strip_html(body), do: inspect(body)

  defp collapse_whitespace(text) do
    text
    |> String.replace(~r/[ \t]+/, " ")
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
  end
end
