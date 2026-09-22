defmodule Sigma.Session.Skills.ProtocolTest do
  use ExUnit.Case, async: true

  alias Backplane.SkillProtocol.{Diagnostic, Error}
  alias Sigma.Session.Skills.Protocol

  test "parses standard package documents into Sigma-owned maps" do
    document =
      "\uFEFF---\r\n" <>
        "name: protocol-skill\r\n" <>
        "description: Uses the Backplane protocol\r\n" <>
        "disable-model-invocation: true\r\n" <>
        "user-invocable: false\r\n" <>
        "argument-hint: FILE\r\n" <>
        "metadata:\r\n" <>
        "  owner: sigma\r\n" <>
        "backplane:\r\n" <>
        "  required-capabilities: [resource.read]\r\n" <>
        "---\r\n" <>
        "Use the protocol.\r\n"

    assert {:ok, skill} = Protocol.parse(document, supported_capabilities: ["resource.read"])

    assert %{
             name: "protocol-skill",
             description: "Uses the Backplane protocol",
             metadata: %{
               "disable-model-invocation" => true,
               "user-invocable" => false,
               "argument-hint" => "FILE",
               "metadata" => %{"owner" => "sigma"},
               "backplane" => %{"required-capabilities" => ["resource.read"]}
             },
             argument_hint: "FILE",
             disable_model_invocation?: true,
             user_invocable?: false
           } = skill
  end

  test "rejects duplicate frontmatter keys" do
    assert {:error, %{code: :invalid_skill_metadata, phase: :parse, diagnostics: []}} =
             Protocol.parse(
               "---\nname: protocol-skill\nname: duplicate\ndescription: Duplicate name\n---\nBody"
             )
  end

  test "rejects unsupported required capabilities" do
    document = """
    ---
    name: protocol-skill
    description: Uses unsupported capabilities
    backplane:
      required-capabilities: [resource.write]
    ---
    Body
    """

    assert {:error, %{code: :invalid_skill_metadata, diagnostics: diagnostics}} =
             Protocol.parse(document, supported_capabilities: ["resource.read"])

    assert [%{code: :unsupported_capability, phase: :validate, severity: :error}] = diagnostics
  end

  test "rejects a document without an explicit name" do
    assert {:error, %{code: :invalid_skill_metadata, diagnostics: diagnostics}} =
             Protocol.parse("---\ndescription: Missing name\n---\nBody")

    assert [%{code: :missing_name, phase: :validate, severity: :error}] = diagnostics
  end

  test "rejects a non-kebab-case name" do
    assert {:error, %{code: :invalid_skill_metadata, diagnostics: diagnostics}} =
             Protocol.parse("---\nname: Not Kebab\ndescription: Invalid name\n---\nBody")

    assert [%{code: :invalid_name, phase: :validate, severity: :error}] = diagnostics
  end

  test "does not expose paths or raw documents through public errors" do
    path = "/private/tmp/skills/protocol-skill/SKILL.md"
    raw_document = "---\nname: protocol-skill\ndescription: secret document\n---\nsecret body"

    error =
      Error.new(:invalid_document, :validate, "invalid #{path}: #{raw_document}",
        context: %{
          path: path,
          raw: raw_document,
          diagnostics: [
            Diagnostic.new(:missing_name, :validate, :error, "#{path}: #{raw_document}")
          ]
        }
      )

    assert %{code: :invalid_skill_metadata, diagnostics: [%{code: :missing_name}]} =
             public_error = Protocol.error_map(error)

    refute inspect(public_error) =~ path
    refute inspect(public_error) =~ raw_document
  end

  test "maps package errors to the closed Sigma error set" do
    mappings = [
      {:not_found, :resolve, :skill_not_found},
      {:not_found, :resource, :resource_denied},
      {:ambiguous_skill, :resolve, :ambiguous_skill},
      {:host_disabled, :eligibility, :skill_disabled},
      {:explicit_disabled, :eligibility, :skill_disabled},
      {:manual_only, :eligibility, :manual_invocation_required},
      {:not_user_invocable, :eligibility, :unsupported_skill_kind},
      {:unsupported_capability, :wire, :unsupported_skill_kind},
      {:revision_unavailable, :transport, :artifact_unavailable},
      {:integrity_mismatch, :transport, :digest_mismatch},
      {:invalid_bundle, :bundle, :unsafe_archive},
      {:invalid_request, :bundle, :unsafe_archive},
      {:limit_exceeded, :bundle, :unsafe_archive},
      {:cancelled, :bundle, :artifact_unavailable},
      {:invalid_request, :resource, :resource_denied},
      {:limit_exceeded, :resource, :resource_denied},
      {:capacity_exceeded, :transport, :queue_full},
      {:invalid_request, :transport, :remote_unavailable},
      {:invalid_request, :wire, :remote_unavailable},
      {:unsupported_protocol, :transport, :remote_unavailable},
      {:unsupported_protocol, :wire, :remote_unavailable},
      {:unauthorized, :transport, :remote_unavailable},
      {:forbidden, :transport, :remote_unavailable},
      {:timeout, :transport, :remote_unavailable},
      {:cancelled, :transport, :remote_unavailable},
      {:temporarily_unavailable, :transport, :remote_unavailable},
      {:limit_exceeded, :transport, :remote_unavailable},
      {:invalid_document, :validate, :invalid_skill_metadata},
      {:invalid_encoding, :parse, :invalid_skill_metadata},
      {:missing_frontmatter, :parse, :invalid_skill_metadata},
      {:malformed_frontmatter, :parse, :invalid_skill_metadata},
      {:duplicate_key, :parse, :invalid_skill_metadata},
      {:limit_exceeded, :parse, :invalid_skill_metadata}
    ]

    for {package_code, phase, public_code} <- mappings do
      error = Error.new(package_code, phase, "private package message", retryable: true)

      assert %{code: ^public_code, phase: ^phase, retryable?: true} = Protocol.error_map(error)
    end
  end
end
