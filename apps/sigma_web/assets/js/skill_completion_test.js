import { describe, expect, test } from "bun:test"

import { filterSkillCandidates, insertSkillCandidate, searchableRemoteSources } from "./skill_completion.js"

const candidates = [
  { kind: "skill", reference: "repo:review", name: "review", description: "Review code", source: "Project" },
  { kind: "skill", reference: "remote:deploy", name: "deploy", description: "Deploy service", source: "Backplane" }
]

describe("Skill completion", () => {
  test("filters source-aware local and remote metadata without side effects", () => {
    expect(filterSkillCandidates(candidates, "/skill back")).toEqual([candidates[1]])
    expect(filterSkillCandidates(candidates, "/skill rev")).toEqual([candidates[0]])
  })

  test("selection preserves arguments and only rewrites the candidate token", () => {
    expect(insertSkillCandidate("/skill old check src/lib.ex", candidates[0]))
      .toBe("/skill repo:review check src/lib.ex")
    expect(insertSkillCandidate("/skill dep", candidates[1]))
      .toBe("/skill remote:deploy ")
  })

  test("only online configured sources participate in explicit search", () => {
    const sources = [
      { source_id: "online", status: "configured", "enabled?": true },
      { source_id: "offline", status: "offline", "enabled?": true },
      { source_id: "disabled", status: "configured", "enabled?": false },
      { source_id: "invalid", status: "invalid_configuration", "enabled?": true }
    ]

    expect(searchableRemoteSources(sources)).toEqual([sources[0]])
  })

})
