defmodule Sigma.ToolsTest do
  use ExUnit.Case, async: true

  defmodule ExtProbe do
    @behaviour Sigma.Coding.Tool

    @impl true
    def name, do: "ext_probe"

    @impl true
    def description, do: "probe"

    @impl true
    def schema, do: %{}

    @impl true
    def execute(_id, _params, _opts), do: {:ok, %{content: [], details: %{}}}
  end

  test "default tools expose oh-my-pi canonical names only" do
    assert Enum.map(Sigma.Tools.default_tools(), &Sigma.Coding.Tool.name/1) == [
             "ask",
             "read",
             "write",
             "bash",
             "edit",
             "search",
             "find",
             "todo",
             "activate_skill"
           ]
  end

  test "extension registry does not alter default_tools/0" do
    before = Enum.map(Sigma.Tools.default_tools(), &Sigma.Coding.Tool.name/1)
    assert {:ok, "ext_probe"} = Sigma.Coding.ExtensionRegistry.register_tool(ExtProbe)
    assert Enum.map(Sigma.Tools.default_tools(), &Sigma.Coding.Tool.name/1) == before
    refute "ext_probe" in before
  after
    Sigma.Coding.ExtensionRegistry.reset!()
  end

  test "catalog includes planned tools without exposing them" do
    planned_names = Sigma.Tools.Catalog.planned() |> Enum.map(& &1.name)
    implemented_names = Sigma.Tools.Catalog.implemented() |> Enum.map(& &1.name)

    assert "job" in planned_names
    assert "todo" in implemented_names
    refute "todo" in planned_names
    assert "task" in planned_names
    assert "lsp" in planned_names
    assert "ast_grep" in planned_names
    assert "ast_edit" in planned_names
    assert "web_search" in planned_names
    assert "github" in planned_names

    exposed_names = Sigma.Tools.default_tools() |> Enum.map(&Sigma.Coding.Tool.name/1)

    assert "todo" in exposed_names
    refute "job" in exposed_names
    refute "lsp" in exposed_names
    refute "ast_grep" in exposed_names
  end

  test "edit tool schema steers models to hashline operations" do
    definition = Sigma.Coding.Tool.ai_definition(Sigma.Tools.Edit)
    input_schema = definition.parameters["properties"]["input"]

    assert definition.description =~ "[path#TAG]"
    assert definition.description =~ "replace N..M:"
    assert input_schema["description"] =~ "Do not send unified diff"
    assert input_schema["description"] =~ "replace N..M:"
  end

  @tag :tmp_dir
  test "activate_skill resolves and prepares an enabled local skill", %{tmp_dir: tmp_dir} do
    skill_dir = Path.join([tmp_dir, ".agents", "skills", "example"])
    File.mkdir_p!(skill_dir)

    File.write!(
      Path.join(skill_dir, "SKILL.md"),
      "---\nname: example\ndescription: Example\n---\nUse $ARGUMENTS."
    )

    assert {:ok, result} =
             Sigma.Tools.ActivateSkill.execute(
               "id",
               %{"reference" => "example", "arguments" => "carefully"},
               cwd: tmp_dir,
               register_skill_resource: register_resource(self())
             )

    assert [%{type: :text, text: "Use carefully."}] = result.content
    assert result.details.digest =~ ~r/^sha256:[0-9a-f]{64}$/
    assert %{files: [_ | _]} = result.details.manifest
    release_registered_resource()
  end

  @tag :tmp_dir
  test "activate_skill deduplicates successful activation within a turn", %{tmp_dir: tmp_dir} do
    skill_dir = Path.join([tmp_dir, ".agents", "skills", "example"])
    File.mkdir_p!(skill_dir)

    File.write!(
      Path.join(skill_dir, "SKILL.md"),
      "---\nname: example\ndescription: Example\n---\nBody"
    )

    table = :ets.new(:skill_activation_test, [:set, :public])

    opts = [
      cwd: tmp_dir,
      tool_state: table,
      turn_id: "turn-1",
      register_skill_resource: register_resource(self())
    ]

    assert {:ok, %{content: [%{text: "Body"}]}} =
             Sigma.Tools.ActivateSkill.execute("id-1", %{"reference" => "example"}, opts)

    assert {:ok, %{details: %{deduplicated?: true}}} =
             Sigma.Tools.ActivateSkill.execute("id-2", %{"reference" => "example"}, opts)

    release_registered_resource()
  end

  @tag :tmp_dir
  test "activate_skill rejects manual-only skills", %{tmp_dir: tmp_dir} do
    skill_dir = Path.join([tmp_dir, ".agents", "skills", "manual"])
    File.mkdir_p!(skill_dir)

    File.write!(
      Path.join(skill_dir, "SKILL.md"),
      "---\nname: manual\ndescription: Manual\ndisable-model-invocation: true\n---\nBody"
    )

    assert {:error, %Sigma.Coding.ToolError{kind: :manual_invocation_required}} =
             Sigma.Tools.ActivateSkill.execute("id", %{"reference" => "manual"}, cwd: tmp_dir)
  end

  @tag :tmp_dir
  test "activate_skill permits model activation when user invocation is disabled", %{
    tmp_dir: tmp_dir
  } do
    skill_dir = Path.join([tmp_dir, ".agents", "skills", "model-only"])
    File.mkdir_p!(skill_dir)

    File.write!(
      Path.join(skill_dir, "SKILL.md"),
      "---\nname: model-only\ndescription: Model only\nuser-invocable: false\n---\nBody"
    )

    assert {:ok, %{content: [%{text: "Body"}]}} =
             Sigma.Tools.ActivateSkill.execute("id", %{"reference" => "model-only"},
               cwd: tmp_dir,
               register_skill_resource: register_resource(self())
             )

    release_registered_resource()
  end

  defp register_resource(owner) do
    fn resource ->
      send(owner, {:prepared_resource, resource})
      :ok
    end
  end

  defp release_registered_resource do
    assert_receive {:prepared_resource, %{root: root, release: release}}
    assert File.dir?(root)
    assert :ok = release.()
    refute File.exists?(root)
  end
end
