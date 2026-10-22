tmp = Path.join(System.tmp_dir!(), "sigma-skills-smoke-#{System.unique_integer([:positive])}")
skill_dir = Path.join([tmp, ".agents", "skills", "smoke"])
File.mkdir_p!(skill_dir)

try do
  File.write!(
    Path.join(skill_dir, "SKILL.md"),
    "---\nname: smoke\ndescription: Local smoke skill\n---\nUse $ARGUMENTS."
  )

  catalog = Sigma.Session.Skills.Catalog.build(tmp)
  {:ok, skill} = Sigma.Session.Skills.Catalog.resolve(catalog, "smoke")
  {:ok, snapshot} = Sigma.Session.Skills.Snapshot.prepare(skill)
  {:ok, expanded} = Sigma.Session.SlashCommands.expand("/skill smoke verify", cwd: tmp)

  true = String.starts_with?(snapshot.digest, "sha256:")
  true = expanded.content == "Use verify."
  true = expanded.skill.digest == hd(expanded.prepared_resources).digest
  [resource] = expanded.prepared_resources
  true = File.regular?(Path.join(resource.root, "SKILL.md"))
  true = resource.digest =~ ~r/^sha256:[0-9a-f]{64}$/

  :ok = Sigma.Session.Skills.Snapshot.release(snapshot)
  Enum.each(expanded.prepared_resources, & &1.release.())
  false = File.exists?(resource.root)

  record = %{
    "invocationId" => "smoke-invocation",
    "requestKey" => "smoke-key",
    "fingerprint" => "smoke-fingerprint",
    "state" => "running"
  }

  {:ok, _} = Sigma.Session.SkillInvocationStore.reserve(tmp, "session-smoke", record)
  {:ok, [_interrupted]} = Sigma.Session.SkillInvocationStore.recover(tmp, "session-smoke")

  IO.puts("skills local smoke: passed")
after
  File.rm_rf!(tmp)
end
