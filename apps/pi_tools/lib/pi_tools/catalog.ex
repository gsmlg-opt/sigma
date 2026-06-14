defmodule PiTools.Catalog do
  @moduledoc """
  Catalog of the target oh-my-pi-compatible tool surface.
  """

  @tools [
    %{name: "ask", category: :coordination, module: PiTools.Ask, status: :implemented},
    %{name: "read", category: :file, module: PiTools.Read, status: :implemented},
    %{name: "write", category: :file, module: PiTools.Write, status: :implemented},
    %{name: "bash", category: :runtime, module: PiTools.Bash, status: :implemented},
    %{name: "edit", category: :file, module: PiTools.Edit, status: :implemented},
    %{name: "search", category: :file, module: PiTools.Search, status: :implemented},
    %{name: "find", category: :file, module: PiTools.Find, status: :implemented},
    %{name: "job", category: :runtime, module: PiTools.Job, status: :planned},
    %{name: "todo", category: :coordination, module: PiTools.Todo, status: :planned},
    %{name: "task", category: :coordination, module: PiTools.Task, status: :planned},
    %{name: "lsp", category: :code_intel, module: PiTools.LSP, status: :planned},
    %{name: "ast_grep", category: :code_intel, module: PiTools.ASTGrep, status: :planned},
    %{name: "ast_edit", category: :code_intel, module: PiTools.ASTEdit, status: :planned},
    %{name: "resolve", category: :state, module: PiTools.Resolve, status: :planned},
    %{name: "web_search", category: :external, module: PiTools.WebSearch, status: :planned},
    %{name: "github", category: :external, module: PiTools.GitHub, status: :planned}
  ]

  def all, do: @tools
  def implemented, do: Enum.filter(@tools, &(&1.status == :implemented))
  def planned, do: Enum.filter(@tools, &(&1.status == :planned))
end
