defmodule Sigma.Agent.BackplaneHostedToolsTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.Codex
  alias Sigma.Agent.Backplane.{CodexResources, HostedTools, NativeTools, ToolCatalog}
  alias Sigma.Agent.{Message, MessageTransformer}
  alias Sigma.Ai.Providers.{Anthropic, OpenAI, OpenAIResponses}

  @model %{id: "hosted", provider: "configured", api: "configured"}
  @enabled %{supported: true, enabled: true, mode: :cached}

  test "hosted capabilities require explicit support and enablement on Responses" do
    assert {:ok, nil} = HostedTools.configuration(OpenAIResponses, @model, [])

    for config <- [%{supported: true}, %{enabled: true}, %{supported: true, enabled: false}] do
      assert {:ok, nil} =
               HostedTools.configuration(OpenAIResponses, @model, hosted_web_search: config)
    end

    for provider <- [Anthropic, OpenAI] do
      assert {:error, %{class: :unsupported_capability}} =
               HostedTools.configuration(provider, @model, hosted_web_search: @enabled)
    end

    assert {:error, %{class: :validation}} =
             HostedTools.configuration(OpenAIResponses, @model,
               hosted_web_search: %{@enabled | mode: :automatic}
             )
  end

  test "model hosted metadata replaces provider defaults as one configuration" do
    provider = %{
      "model" => "hosted",
      "hostedTools" => %{
        "webSearch" => %{"supported" => true, "enabled" => true, "mode" => "live"}
      },
      "models" => [%{"id" => "hosted"}]
    }

    assert %{supported: true, enabled: true, mode: :live} = HostedTools.from_config(provider)

    disabled = put_in(provider, ["models"], [%{"id" => "hosted", "hostedTools" => %{}}])
    assert is_nil(HostedTools.from_config(disabled))

    override =
      put_in(provider, ["models"], [
        %{
          "id" => "hosted",
          "hostedTools" => %{"webSearch" => %{"enabled" => true, "mode" => "cached"}}
        }
      ])

    assert %{enabled: true, mode: :cached} = config = HostedTools.from_config(override)
    refute Map.has_key?(config, :supported)

    assert {:ok, nil} =
             HostedTools.configuration(OpenAIResponses, @model, hosted_web_search: config)
  end

  test "public Hosted negotiation produces exact configured access modes" do
    for {mode, access} <- [
          cached: %{external_web_access: false},
          live: %{external_web_access: true},
          indexed: %{external_web_access: true, indexed_web_access: true}
        ] do
      assert {:ok, context} =
               HostedTools.configuration(OpenAIResponses, @model,
                 hosted_web_search: %{@enabled | mode: mode}
               )

      assert {:ok, [declaration]} = Codex.Hosted.declarations(%{provider_hosted: context})
      assert declaration == Map.put(access, :type, "web_search")
    end
  end

  @tag :tmp_dir
  test "hosted profile declarations never become local grants or registry descriptors", ctx do
    authority = %{
      caller: "root",
      run_id: "hosted-run",
      grants: ["clock::curr_time"],
      tool_revision: 1
    }

    resources = start_supervised!({CodexResources, workspace: ctx.tmp_dir, owner_pid: self()})
    assert {:ok, binding} = CodexResources.bind(resources, authority)
    assert {:ok, context} = CodexResources.context(resources, binding)

    assert {:ok, hosted} =
             HostedTools.configuration(OpenAIResponses, @model, hosted_web_search: @enabled)

    assert {:ok, profile} =
             NativeTools.profile(Map.put(context, :provider_hosted, hosted), authority, %{},
               tools: ["clock::curr_time"]
             )

    assert {:ok, bundle} =
             ToolCatalog.admit([], authority, fn _ -> flunk("no local hosted dispatch") end,
               profiles: [profile]
             )

    assert bundle.hosted_tools == [%{type: "web_search", external_web_access: false}]
    assert Enum.map(bundle.tools, & &1.name) == ["clock::curr_time"]
    assert Map.keys(bundle.registry.tools) == ["clock::curr_time"]
    assert bundle.authority.grants == ["clock::curr_time"]

    assert {:error, %{class: :validation}} =
             ToolCatalog.admit([], authority, fn _ -> :unused end,
               profiles: [%{profile | hosted_tools: hd(profile.hosted_tools)}]
             )

    assert {:error, %{class: :validation}} =
             ToolCatalog.admit([], authority, fn _ -> :unused end,
               profiles: [profile, %{profile | registry: %{profile.registry | tools: %{}}}]
             )
  end

  test "canonical assistant provider metadata survives model-context conversion" do
    metadata = %{
      "openai_responses_hosted" => %{
        "version" => 1,
        "origin" => %{"model" => "hosted", "endpoint_sha256" => String.duplicate("a", 64)},
        "items" => [
          %{"output_index" => 0, "item" => %{"type" => "web_search_call", "id" => "ws1"}}
        ]
      }
    }

    message =
      Message.assistant("assistant", %{
        content: [%{type: :text, text: "A sourced answer"}],
        metadata: metadata
      })

    assert [%{metadata: ^metadata}] = MessageTransformer.convert_to_llm([message])
  end
end
