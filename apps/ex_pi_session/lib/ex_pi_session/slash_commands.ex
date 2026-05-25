defmodule PiSession.SlashCommands do
  @moduledoc """
  Expands chat slash commands into agent prompts.
  """

  @init_command "init"
  @init_prompt """
  Set up a minimal AGENTS.md, and optionally Pi Agent skills and supported hooks, for this repo. AGENTS.md instructions are loaded into Pi Agent sessions, so the file must stay concise: only include what Pi Agent would get wrong without it.

  ## Phase 0: Check for an existing project AGENTS.md

  Before asking anything, check whether AGENTS.md already exists at the project root. Read only `./AGENTS.md` for this phase; do not explore the tree yet. This branches Phase 1.

  ## Phase 1: Ask what to set up

  Ask the user concise questions in chat. If Pi Agent exposes a structured user-question tool, use it; otherwise ask normally. Ask only Q1 first. Ask Q2 only after the Q1 answer, because "Let Pi Agent decide" skips Q2.

  Before the first question, print this primer as normal assistant text:

  > Quick context:
  > - Project AGENTS.md gives Pi Agent persistent, team-shared instructions for this repository. Pi Agent reads it when working in this repo.
  > - User AGENTS.md at `~/.pi/agent/AGENTS.md` gives Pi Agent personal/global instructions outside source control.
  > - Skills are packaged instructions Pi Agent can discover from `.agents/skills` or `~/.agents/skills` and inject when a task matches, or that the user can trigger by name.
  > - Hooks are deterministic commands on lifecycle events. Only set them up when this repo already has Pi Agent hook support, or when the user explicitly asks to design that support.

  If project AGENTS.md already exists, ask:
  - "I found an existing AGENTS.md. What would you like to do?"
    Options: "Review and improve it" | "Leave it, set up other things" | "Start fresh (replace it)"
    Description for improve: "Explore what changed in the codebase and propose targeted edits to the existing file."
    Description for leave it: "Skip project AGENTS.md. Go straight to skills and supported hooks."
    Description for start fresh: "Discard it and write new file(s)."
    Routing:
    - "Review and improve it" -> skip Q1/Q2; explore in Phase 2, ask the single Phase 3-lite question, then go to Phase 4's diff proposal and Phase 8.
    - "Leave it, set up other things" -> skip Q1, ask Q2. If they pick "Neither - skip setup", jump to Phase 8 with: "Nothing to set up - your AGENTS.md is unchanged." Otherwise continue through Phase 2, Phase 3 proposal, and Phases 6/7 for the approved queue.
    - "Start fresh (replace it)" -> continue to Q1 as if no file existed.

  If no project AGENTS.md exists, or the user picked "Start fresh (replace it)", ask:
  - Q1: "Which AGENTS.md files should /init set up?"
    Options: "Project AGENTS.md" | "User AGENTS.md" | "Both project + user" | "Let Pi Agent decide"
    Description for project: "Team-shared instructions checked into source control: architecture, coding standards, common workflows."
    Description for user: "Your private/global Pi Agent instructions in `~/.pi/agent/AGENTS.md`: role, preferences, sandbox URLs, workflow quirks."
    Description for Let Pi Agent decide: "Fastest path: project AGENTS.md plus whatever skills or supported hooks fit this repo. No follow-on setup-scope questions; you will approve everything before it is written."
    If the user picks "Let Pi Agent decide", skip Q2 and treat it as project AGENTS.md with no hard skills/hooks constraint.

  - Q2: "Also set up skills or supported hooks?"
    Options: "Skills + supported hooks" | "Skills only" | "Supported hooks only" | "Neither, just AGENTS.md"
    Description for skills: "Packaged instructions Pi Agent can discover and inject for repeatable workflows and reference knowledge."
    Description for hooks: "Deterministic shell commands that run on tool events. Only create hook config if this repo already supports Pi Agent hooks or the user explicitly asks to add support."
    Q2 is a hint, not a hard filter. Phase 3 proposes what fits the repo and notes any deviation.

  ## Phase 2: Explore the codebase

  Survey the codebase. If Pi Agent has parallel subagents available, use one for the survey; otherwise inspect directly. Read key files that explain the project: manifest files (`mix.exs`, `package.json`, `Cargo.toml`, `pyproject.toml`, `go.mod`, `pom.xml`, etc.), README, Makefile/build configs, CI config, existing AGENTS.md, `.agents/skills/`, existing hook config, other agent instructions, and MCP config.

  Detect:
  - Build, test, and lint commands, especially non-standard ones.
  - Languages, frameworks, and package manager.
  - Project structure: monorepo/workspaces, umbrella/multi-module, or single project.
  - Code style rules that differ from language defaults.
  - Non-obvious gotchas, required env vars, or workflow quirks.
  - Existing `.agents/skills/` and `~/.agents/skills/` patterns that should be preserved.
  - Formatter configuration or a unified format command such as `mix format`, `npm run format`, or `make fmt`.
  - Git worktree usage with `git worktree list` when it affects where project instructions should live.

  Note what you could not figure out from code alone. Those become interview questions.

  ## Phase 3: Fill in the gaps

  Ask only questions the code cannot answer.

  If the user chose project AGENTS.md, both, or "Let Pi Agent decide", ask about codebase practices: non-obvious commands, gotchas, branch/PR conventions, required env setup, and testing quirks. Skip anything already in README or obvious from manifest files. Do not mark any option as recommended; this is about how their team works.

  If the user chose user AGENTS.md or both, ask about personal/global preferences rather than repo facts. Do not mark any option as recommended. Examples:
  - What is their role on the team?
  - How familiar are they with this codebase and its languages/frameworks?
  - Do they have personal sandbox URLs, test accounts, API key paths, or local setup details Pi Agent should know?
  - Any communication preferences, such as "be terse" or "always explain tradeoffs"?

  If the user picked "Review and improve it" in Phase 0, ask just one question: "Has anything changed about how the team works since this AGENTS.md was written?" with options "No, nothing changed" | "Yes, let me describe". If they pick Yes, ask what changed before continuing. Then skip to Phase 4.

  Synthesize a proposal from Phase 2 findings and the gap-fill answers. For each item, pick the artifact type that fits the evidence:
  - Hook: deterministic, fast, per-edit or lifecycle shell command, only when Pi Agent hook support exists or is explicitly requested.
  - Skill: on-demand multi-step workflow such as `/verify`, `/deploy-staging`, or session reports.
  - AGENTS.md note: guidance that shapes behavior but is not mechanically enforced.

  Include the AGENTS.md file(s) implied by Q1 as the first proposal bullet(s), with a one-line summary of what each will cover. Then list skills, hooks, and notes. On the "Leave it" path, omit project AGENTS.md file bullets and project notes. On a personal-only path after "Start fresh", say the existing project AGENTS.md will be left untouched.

  Propose what fits. If the user gave a Q2 hint and your proposal deviates from it, say so in one line and propose the better-fitting artifacts.

  Print the proposal as normal assistant text, one bullet per item:

  Here's what I would set up:
  - **[Artifact type: file/hook/skill/note]** - [one-line description]

  Then ask: "Does this look right?" with short options such as "Looks good - proceed", "Drop the hook", or "Drop the skill". Include a free-form path for custom tweaks if the interface supports it.

  Build the preference queue from the accepted proposal. Each entry should include: type (`hook`, `skill`, or `note`), description, target file, and any Phase-2-sourced details such as actual test or format commands.

  ## Phase 4: Write project AGENTS.md if approved

  Write a minimal AGENTS.md at the project root. Every line must pass this test: "Would removing this cause Pi Agent to make mistakes?" If no, cut it.

  If the user picked "Review and improve it" in Phase 0, do not write fresh. Read the existing file, compare it against Phase 2 findings and the Phase 3-lite answer, and propose specific additions/removals as diffs with a one-line reason for each. Ask before applying the edits.

  Consume approved `note` entries whose target is project AGENTS.md. Add each as a concise line in the most relevant section.

  Include:
  - Build/test/lint commands Pi Agent cannot reliably guess.
  - Code style rules that differ from language defaults.
  - Testing instructions and quirks.
  - Repo etiquette such as branch, PR, and commit conventions.
  - Required env vars or setup steps.
  - Non-obvious gotchas or architectural decisions.
  - Important content from existing AI coding tool configs when it applies to Pi Agent.

  Exclude:
  - File-by-file structure or component lists that Pi Agent can discover by reading the codebase.
  - Standard language conventions Pi Agent already knows.
  - Generic advice such as "write clean code" or "handle errors".
  - Detailed API docs or long references. Use `@path/to/import` syntax if this repo supports it, or reference the source file path.
  - Information that changes frequently. Reference the source file instead.
  - Long tutorials or walkthroughs. Move them to a separate doc or skill.
  - Commands obvious from manifest files.

  Be specific. Do not repeat yourself and do not invent broad sections like "Common Development Tasks" unless the files you read justify them.

  Prefix the file with:

  ```markdown
  # AGENTS.md

  This file provides guidance to Pi Agent when working with code in this repository.
  ```

  For projects with distinct subdirectories or modules, mention that subdirectory AGENTS.md files can be added for module-specific instructions. Offer to create them only if useful.

  ## Phase 5: Write user AGENTS.md if approved

  Write a minimal user AGENTS.md at `~/.pi/agent/AGENTS.md`. This file is outside source control and applies globally to Pi Agent sessions.

  Consume approved `note` entries whose target is user AGENTS.md. Include only what would make Pi Agent's responses noticeably better for this user:
  - Role and familiarity with the codebase.
  - Personal sandbox URLs, test accounts, API key paths, or local setup details.
  - Personal workflow or communication preferences.

  If the file already exists, read it, propose specific additions, and do not silently overwrite it.

  ## Phase 6: Suggest and create skills if approved

  Skills add capabilities Pi Agent can use on demand without bloating every session.

  First, consume approved `skill` entries from the Phase 3 preference queue. Each queued skill becomes a SKILL.md tailored to what the user described:
  - Name it from the preference, such as `verify-deep`, `session-report`, or `deploy-sandbox`.
  - Write the body using the user's words from the interview plus Phase 2 facts such as test commands, report format, or deploy target.
  - Ask a quick follow-up if the preference is underspecified.

  Then suggest additional skills when you find:
  - Reference knowledge for specific tasks, conventions, patterns, or subsystems.
  - Repeatable workflows the user would want to trigger directly.

  For each suggested skill, provide name, one-line purpose, and why it fits this repo.

  If `.agents/skills/` already exists, review it first. Do not overwrite existing skills; only propose complementary skills.

  Create project skills at `.agents/skills/<skill-name>/SKILL.md` and user skills at `~/.agents/skills/<skill-name>/SKILL.md`, based on the approved scope:

  ```yaml
  ---
  name: <skill-name>
  description: <what the skill does and when to use it>
  ---

  <Instructions for Pi Agent>
  ```

  For workflows with side effects, add `disable-model-invocation: true` so only the user can trigger them. Use `$ARGUMENTS` when the skill accepts input.

  ## Phase 7: Suggest additional optimizations

  After AGENTS.md and skills are in place, suggest a few additional optimizations that are relevant to this repo:
  - GitHub CLI: run `which gh` when the project uses GitHub. If missing, ask whether the user wants to install it.
  - Linting: if Phase 2 found no lint config for the project's language, ask whether the user wants Pi Agent to set one up.
  - Supported hooks: only consume approved hook entries when this repo already has Pi Agent hook support or the user explicitly approved adding it. Do not create hook config for another agent runtime.
  - Missing or sparse tests: suggest a focused test setup so Pi Agent can verify its own changes.
  - Useful project skills: suggest verify, release, deploy, review, or issue-fix skills when they fit this repo.

  Act on each accepted optimization before moving on.

  ## Phase 8: Summary and next steps

  Recap what was set up, which files were written, and the key points included in each. Remind the user these files are a starting point they can review and tune, and that `/init` can be run again to rescan the repo.

  Then present a short to-do list with only relevant follow-ups, ordered by impact.
  """

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

    [@init_prompt, extra]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("")
    |> String.trim()
  end
end
