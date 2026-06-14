defmodule PiTools.Result do
  @moduledoc false

  def text(text, details \\ %{}) do
    %{
      content: [%{type: :text, text: text, text_signature: nil}],
      details: details
    }
  end
end
