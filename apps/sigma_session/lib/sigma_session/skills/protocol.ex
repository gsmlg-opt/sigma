defmodule Sigma.Session.Skills.Protocol do
  @moduledoc "Package-backed Skill document parsing at the Sigma Session boundary."

  alias Backplane.SkillProtocol.{Diagnostic, Document, Error, Parser, Validator}

  @parser_options [:max_document_bytes, :max_frontmatter_bytes, :max_nesting_depth]
  @validator_options [:supported_capabilities]

  @spec parse(binary(), keyword()) :: {:ok, map()} | {:error, map()}
  def parse(bytes, opts \\ []) when is_binary(bytes) and is_list(opts) do
    with {:ok, document} <- parse_document(bytes, opts) do
      {:ok, document_map(document)}
    end
  end

  @doc false
  @spec parse_document(binary(), keyword()) :: {:ok, Document.t()} | {:error, map()}
  def parse_document(bytes, opts \\ []) when is_binary(bytes) and is_list(opts) do
    with {:ok, document} <- Parser.parse(bytes, Keyword.take(opts, @parser_options)),
         {:ok, document} <- Validator.validate(document, Keyword.take(opts, @validator_options)) do
      {:ok, document}
    else
      {:error, %Error{} = error} -> {:error, error_map(error)}
    end
  end

  @spec error_map(Error.t()) :: map()
  def error_map(%Error{} = error) do
    code = public_code(error)

    %{
      code: code,
      message: public_message(code),
      phase: error.phase,
      retryable?: error.retryable,
      diagnostics: diagnostics(error.context)
    }
  end

  @doc false
  @spec primary_diagnostic_message(map()) :: binary()
  def primary_diagnostic_message(%{diagnostics: [%{message: message} | _]})
      when is_binary(message),
      do: message

  def primary_diagnostic_message(%{message: message}) when is_binary(message), do: message
  def primary_diagnostic_message(_error), do: "Skill metadata is invalid"

  @doc false
  @spec discovery_diagnostic(Diagnostic.t()) :: %{path: binary(), message: binary()}
  def discovery_diagnostic(%Diagnostic{} = diagnostic) do
    %{
      path: diagnostic_path(diagnostic.context),
      message: diagnostic_message(diagnostic.code)
    }
  end

  @doc false
  @spec discovery_error(Error.t()) :: %{path: binary(), message: binary()}
  def discovery_error(%Error{code: :limit_exceeded, phase: :discovery}),
    do: %{path: ".", message: "local skill scan limit exceeded"}

  def discovery_error(%Error{code: :invalid_request, phase: :discovery}),
    do: %{path: ".", message: "local skill root is invalid"}

  def discovery_error(%Error{}), do: %{path: ".", message: "local skill discovery failed"}

  defp document_map(%Document{} = document) do
    %{
      name: document.name,
      description: document.description,
      metadata: document.metadata,
      argument_hint: document.metadata["argument-hint"],
      disable_model_invocation?: document.metadata["disable-model-invocation"] == true,
      user_invocable?: Map.get(document.metadata, "user-invocable", true)
    }
  end

  defp diagnostics(%{diagnostics: diagnostics}) when is_list(diagnostics) do
    Enum.flat_map(diagnostics, fn
      %Diagnostic{} = diagnostic -> [diagnostic_map(diagnostic)]
      _ -> []
    end)
  end

  defp diagnostics(_context), do: []

  defp diagnostic_path(%{path: path}) when is_binary(path) do
    if Path.type(path) == :relative and path != ".." and not String.starts_with?(path, "../"),
      do: path,
      else: "."
  end

  defp diagnostic_path(_context), do: "."

  defp diagnostic_map(%Diagnostic{} = diagnostic) do
    %{
      code: diagnostic.code,
      phase: diagnostic.phase,
      severity: diagnostic.severity,
      message: diagnostic_message(diagnostic.code)
    }
  end

  defp public_code(%Error{code: :not_found, phase: :resource}), do: :resource_denied
  defp public_code(%Error{code: :not_found}), do: :skill_not_found
  defp public_code(%Error{code: :ambiguous_skill}), do: :ambiguous_skill

  defp public_code(%Error{code: code}) when code in [:host_disabled, :explicit_disabled],
    do: :skill_disabled

  defp public_code(%Error{code: :manual_only}), do: :manual_invocation_required

  defp public_code(%Error{code: code})
       when code in [:unsupported_capability, :not_user_invocable],
       do: :unsupported_skill_kind

  defp public_code(%Error{code: code, phase: phase})
       when phase in [:transport, :wire] and
              code in [
                :cancelled,
                :forbidden,
                :invalid_request,
                :limit_exceeded,
                :temporarily_unavailable,
                :timeout,
                :unauthorized,
                :unsupported_protocol
              ],
       do: :remote_unavailable

  defp public_code(%Error{code: :revision_unavailable}), do: :artifact_unavailable
  defp public_code(%Error{code: :integrity_mismatch}), do: :digest_mismatch

  defp public_code(%Error{code: code, phase: :bundle})
       when code in [:invalid_bundle, :invalid_request, :limit_exceeded],
       do: :unsafe_archive

  defp public_code(%Error{code: :cancelled, phase: :bundle}), do: :artifact_unavailable

  defp public_code(%Error{code: code, phase: :resource})
       when code in [:invalid_request, :limit_exceeded],
       do: :resource_denied

  defp public_code(%Error{code: :capacity_exceeded}), do: :queue_full
  defp public_code(%Error{code: :source_changed}), do: :source_changed
  defp public_code(%Error{code: :digest_mismatch}), do: :digest_mismatch
  defp public_code(%Error{}), do: :invalid_skill_metadata

  defp public_message(:skill_not_found), do: "Skill not found"
  defp public_message(:ambiguous_skill), do: "Skill reference is ambiguous"
  defp public_message(:skill_disabled), do: "Skill is disabled"
  defp public_message(:manual_invocation_required), do: "Skill requires explicit invocation"
  defp public_message(:unsupported_skill_kind), do: "Skill is not supported"
  defp public_message(:remote_unavailable), do: "Skill source is unavailable"
  defp public_message(:artifact_unavailable), do: "Skill artifact is unavailable"
  defp public_message(:unsafe_archive), do: "Skill artifact is unsafe"
  defp public_message(:source_changed), do: "Skill source changed"
  defp public_message(:digest_mismatch), do: "Skill digest does not match"
  defp public_message(:resource_denied), do: "Skill resource is unavailable"
  defp public_message(:queue_full), do: "Skill queue is full"
  defp public_message(:invalid_skill_metadata), do: "Skill metadata is invalid"

  defp diagnostic_message(:missing_name), do: "name is required"
  defp diagnostic_message(:invalid_name), do: "name must be lowercase kebab-case"
  defp diagnostic_message(:missing_description), do: "description is required"
  defp diagnostic_message(:invalid_invocation_flag), do: "invocation flag is invalid"
  defp diagnostic_message(:invalid_backplane_extension), do: "backplane metadata is invalid"
  defp diagnostic_message(:invalid_required_capabilities), do: "required capabilities are invalid"
  defp diagnostic_message(:unsupported_capability), do: "a required capability is unsupported"
  defp diagnostic_message(_code), do: "Skill metadata is invalid"
end
