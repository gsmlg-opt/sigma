defmodule Sigma.Session.SkillExpander do
  @moduledoc "Unified local and configured-remote Skill expansion boundary."

  alias Sigma.Session.SlashCommands
  alias Sigma.Session.Skills.RemoteAdapter

  @spec expand(binary(), keyword()) ::
          :not_command | {:ok, binary() | map()} | {:error, binary()}
  def expand(text, opts \\ []) when is_binary(text) and is_list(opts) do
    SlashCommands.expand(
      text,
      Keyword.put(opts, :remote_preparer, fn reference, arguments, prepare_opts ->
        case RemoteAdapter.prepare(reference, arguments, prepare_opts) do
          {:ok, expansion} -> {:ok, expansion}
          {:error, error} -> {:error, error.message}
        end
      end)
    )
  end
end
