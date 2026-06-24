defmodule Sigma.Ai.Message do
  @type role :: :system | :user | :assistant | :tool_result

  @type text_content :: %{
          type: :text,
          text: String.t(),
          text_signature: String.t() | nil
        }

  @type thinking_content :: %{
          type: :thinking,
          thinking: String.t(),
          thinking_signature: String.t() | nil,
          redacted: boolean()
        }

  @type image_content :: %{
          type: :image,
          data: String.t(),
          mime_type: String.t()
        }

  @type tool_call :: %{
          type: :tool_call,
          id: String.t(),
          name: String.t(),
          arguments: map(),
          thought_signature: String.t() | nil
        }

  @type content :: text_content() | thinking_content() | image_content() | tool_call()

  @type usage :: %{
          input: integer(),
          output: integer(),
          cache_read: integer(),
          cache_write: integer(),
          total_tokens: integer(),
          cost: %{
            input: float(),
            output: float(),
            cache_read: float(),
            cache_write: float(),
            total: float()
          }
        }

  @type stop_reason :: :stop | :length | :tool_use | :error | :aborted

  @type assistant_message :: %{
          role: :assistant,
          content: [content()],
          api: String.t(),
          provider: String.t(),
          model: String.t(),
          response_model: String.t() | nil,
          response_id: String.t() | nil,
          usage: usage(),
          stop_reason: stop_reason() | nil,
          error_message: String.t() | nil,
          timestamp: integer()
        }

  @type user_message :: %{
          role: :user,
          content: String.t() | [text_content() | image_content()],
          timestamp: integer()
        }

  @type tool_result_message :: %{
          role: :tool_result,
          tool_call_id: String.t(),
          tool_name: String.t(),
          content: [text_content() | image_content()],
          is_error: boolean(),
          timestamp: integer()
        }

  @type t :: user_message() | assistant_message() | tool_result_message()

  @type stream_event ::
          {:start, assistant_message()}
          | {:text_start, integer(), assistant_message()}
          | {:text_delta, integer(), String.t(), assistant_message()}
          | {:text_end, integer(), String.t(), assistant_message()}
          | {:thinking_start, integer(), assistant_message()}
          | {:thinking_delta, integer(), String.t(), assistant_message()}
          | {:thinking_end, integer(), String.t(), assistant_message()}
          | {:toolcall_start, integer(), assistant_message()}
          | {:toolcall_delta, integer(), String.t(), assistant_message()}
          | {:toolcall_end, integer(), tool_call(), assistant_message()}
          | {:done, stop_reason(), assistant_message()}
          | {:error, stop_reason(), assistant_message()}
end
