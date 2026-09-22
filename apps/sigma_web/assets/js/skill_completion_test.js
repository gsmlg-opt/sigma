import { describe, expect, test } from "bun:test"

import { filterSkillCandidates, insertSkillCandidate, searchableRemoteSources } from "./skill_completion.js"

async function loadChatInputHook() {
  const source = await Bun.file(new URL("./app.js", import.meta.url)).text()
  const start = source.indexOf("const DEFAULT_SLASH_COMMANDS")
  const end = source.indexOf("// Scroll to bottom", start)

  if (start === -1 || end === -1) throw new Error("ChatInputHook source not found")

  return Function(
    "filterSkillCandidates",
    "insertSkillCandidate",
    "searchableRemoteSources",
    `${source.slice(start, end)}; return ChatInputHook`
  )(filterSkillCandidates, insertSkillCandidate, searchableRemoteSources)
}

function fakeElement(tagName = "div") {
  const classes = new Set()

  return {
    tagName,
    children: [],
    dataset: {},
    parentNode: null,
    set className(value) {
      classes.clear()
      value.split(/\s+/).filter(Boolean).forEach((name) => classes.add(name))
    },
    classList: {
      add(name) { classes.add(name) },
      remove(name) { classes.delete(name) },
      contains(name) { return classes.has(name) }
    },
    setAttribute() {},
    addEventListener() {},
    removeEventListener() {},
    appendChild(child) {
      child.parentNode?.removeChild(child)
      this.children.push(child)
      child.parentNode = this
      return child
    },
    removeChild(child) {
      this.children = this.children.filter((candidate) => candidate !== child)
      child.parentNode = null
    },
    remove() { this.parentNode?.removeChild(this) },
    replaceChildren() {
      this.children.forEach((child) => { child.parentNode = null })
      this.children = []
    },
    querySelector() { return null },
    querySelectorAll(selector) {
      return selector === ".slash-command-menu"
        ? this.children.filter((child) => child.classList.contains("slash-command-menu"))
        : []
    }
  }
}

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

  test("restores one menu after LiveView removes hook-owned children", async () => {
    const ChatInputHook = await loadChatInputHook()
    const originalDocument = globalThis.document
    const originalWindow = globalThis.window
    const originalMutationObserver = globalThis.MutationObserver
    const documentListeners = { added: 0, removed: 0 }
    const inputListeners = { added: 0, removed: 0 }
    const chatInput = {
      shadowRoot: null,
      getValue() { return "" },
      addEventListener() { inputListeners.added += 1 },
      removeEventListener() { inputListeners.removed += 1 }
    }
    const host = fakeElement()
    host.querySelector = (selector) => selector === "el-dm-chat-input" ? chatInput : null

    globalThis.document = {
      createElement: (tagName) => fakeElement(tagName),
      addEventListener() { documentListeners.added += 1 },
      removeEventListener() { documentListeners.removed += 1 }
    }
    globalThis.window = {
      location: { pathname: "/sessions/test" },
      sessionStorage: { getItem() { return null }, setItem() {}, removeItem() {} },
      requestAnimationFrame() { return 1 },
      cancelAnimationFrame() {},
      clearTimeout() {}
    }
    globalThis.MutationObserver = class {
      observe() {}
      disconnect() {}
    }

    try {
      const hook = { ...ChatInputHook, el: host }
      hook.mounted()
      const menu = hook._menu
      const mountedInputListeners = inputListeners.added

      expect(host.querySelectorAll(".slash-command-menu")).toEqual([menu])
      menu.remove()
      expect(host.querySelectorAll(".slash-command-menu")).toHaveLength(0)

      hook.updated()
      hook.updated()

      expect(host.querySelectorAll(".slash-command-menu")).toEqual([menu])
      expect(inputListeners.added).toBe(mountedInputListeners)
      expect(documentListeners.added).toBe(1)

      menu.remove()
      expect(() => hook.destroyed()).not.toThrow()
      expect(documentListeners.removed).toBe(1)
      expect(inputListeners.removed).toBe(mountedInputListeners)
    } finally {
      globalThis.document = originalDocument
      globalThis.window = originalWindow
      globalThis.MutationObserver = originalMutationObserver
    }
  })
})
