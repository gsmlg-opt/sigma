defmodule PiWeb.SlashCommands do
  @moduledoc """
  Expands chat slash commands into agent prompts.
  """

  @init_command "init"

  @spec expand(String.t()) :: :not_command | {:ok, String.t()} | {:error, String.t()}
  def expand(text) when is_binary(text) do
    text
    |> String.trim()
    |> do_expand()
  end

  defp do_expand(""), do: :not_command
  defp do_expand("/" <> command), do: expand_command(command)
  defp do_expand(_text), do: :not_command

  defp expand_command(command) do
    case String.split(command, ~r/\s+/, trim: true) do
      [@init_command | args] -> {:ok, init_prompt(Enum.join(args, " "))}
      [unknown | _args] -> {:error, "Unknown slash command: /#{unknown}"}
      [] -> {:error, "Unknown slash command: /"}
    end
  end

  defp init_prompt(args) do
    extra =
      case args do
        "" -> ""
        _ -> "\n\nCommand arguments: #{args}"
      end

    """
    You are running the `/init` slash command.

    Create or update `AGENTS.md` for the current repository or worktree.

    Requirements:
    - Inspect the current repository before editing.
    - If `AGENTS.md` already exists, update it in place and preserve useful existing instructions.
    - Keep the result concise and repo-specific.
    - Include the project shape, important commands, architecture notes, testing or validation expectations, and collaboration conventions that future agents need.
    - Prefer `AGENTS.md`; do not create a competing `CLAUDE.md` unless the user explicitly asks for it.
    - Avoid generic boilerplate that is not grounded in this repository.
    #{extra}
    """
    |> String.trim()
  end
end
