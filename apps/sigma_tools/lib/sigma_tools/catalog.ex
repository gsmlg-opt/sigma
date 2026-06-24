defmodule Sigma.Tools.Catalog do
  @moduledoc """
  Catalog of the target oh-my-pi-compatible tool surface.
  """

  @tools [
    %{name: "ask", category: :coordination, module: Sigma.Tools.Ask, status: :implemented},
    %{name: "read", category: :file, module: Sigma.Tools.Read, status: :implemented},
    %{name: "write", category: :file, module: Sigma.Tools.Write, status: :implemented},
    %{name: "bash", category: :runtime, module: Sigma.Tools.Bash, status: :implemented},
    %{name: "edit", category: :file, module: Sigma.Tools.Edit, status: :implemented},
    %{name: "search", category: :file, module: Sigma.Tools.Search, status: :implemented},
    %{name: "find", category: :file, module: Sigma.Tools.Find, status: :implemented},
    %{name: "job", category: :runtime, module: Sigma.Tools.Job, status: :planned},
    %{name: "todo", category: :coordination, module: Sigma.Tools.Todo, status: :planned},
    %{name: "task", category: :coordination, module: Sigma.Tools.Task, status: :planned},
    %{name: "lsp", category: :code_intel, module: Sigma.Tools.LSP, status: :planned},
    %{name: "ast_grep", category: :code_intel, module: Sigma.Tools.ASTGrep, status: :planned},
    %{name: "ast_edit", category: :code_intel, module: Sigma.Tools.ASTEdit, status: :planned},
    %{name: "resolve", category: :state, module: Sigma.Tools.Resolve, status: :planned},
    %{name: "web_search", category: :external, module: Sigma.Tools.WebSearch, status: :planned},
    %{name: "github", category: :external, module: Sigma.Tools.GitHub, status: :planned}
  ]

  def all, do: @tools
  def implemented, do: Enum.filter(@tools, &(&1.status == :implemented))
  def planned, do: Enum.filter(@tools, &(&1.status == :planned))
end
