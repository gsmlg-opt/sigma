import { describe, expect, test } from "bun:test"

import {
  SessionTerminals,
  applyPresentationAction,
  canResize,
  canSendInput,
  commandFence,
  decodeTerminalBytes,
  encodeTerminalBytes,
  presentationStorageKey,
  presentationControlState,
  readPresentation,
  terminalKey,
  writePresentation
} from "./session_terminals.js"

const storage = () => {
  const values = new Map()
  return { getItem: (key) => values.get(key) || null, setItem: (key, value) => values.set(key, value) }
}

const presentation = (overrides = {}) => ({
  selectedId: "terminal-1",
  panelOpen: true,
  height: null,
  maximized: false,
  scroll: {},
  unread: {},
  ...overrides
})

describe("session terminal presentation storage", () => {
  test("keys browser presentation by repository session incarnation without output, authority, or server-owned visibility", () => {
    const local = storage()
    const identity = "repo:session:incarnation"
    writePresentation(identity, { selectedId: "terminal-1", panelOpen: false, height: 360, maximized: true, scroll: { "terminal-1": 20 }, unread: { "terminal-2": true }, output: "secret", controllerToken: "secret" }, local)

    expect(presentationStorageKey(identity)).toBe("sigma:terminal-presentation:repo:session:incarnation")
    expect(readPresentation(identity, local, true)).toEqual({ selectedId: "terminal-1", panelOpen: true, height: 360, maximized: true, scroll: { "terminal-1": 20 }, unread: { "terminal-2": true } })
    expect(local.getItem(presentationStorageKey(identity))).not.toContain("secret")
    expect(local.getItem(presentationStorageKey(identity))).not.toContain("panelOpen")
  })

  test("server-declared reopen wins after a persisted collapse while keeping local preferences", () => {
    const local = storage()
    const identity = "repo:session:incarnation"
    writePresentation(identity, presentation({ panelOpen: false, height: 480, maximized: true, unread: { "terminal-2": true } }), local)

    expect(readPresentation(identity, local, true)).toEqual(presentation({ height: 480, maximized: true, unread: { "terminal-2": true } }))
  })

  test("fails closed when browser storage is unavailable or corrupt", () => {
    const unavailable = { getItem: () => { throw new Error("denied") }, setItem: () => { throw new Error("full") } }
    const corrupt = { getItem: () => "not json" }

    expect(readPresentation("identity", unavailable, false)).toEqual(presentation({ selectedId: null, panelOpen: false }))
    expect(readPresentation("identity", corrupt)).toEqual(presentation({ selectedId: null }))
    expect(writePresentation("identity", presentation(), unavailable)).toBe(false)
  })
})

describe("session terminal authority and rendering", () => {
  test("round trips arbitrary PTY bytes through base64 without UTF-8 coercion", () => {
    const bytes = new Uint8Array([0, 27, 128, 255, 10])
    expect(decodeTerminalBytes(encodeTerminalBytes(bytes))).toEqual(bytes)
    expect(decodeTerminalBytes("not base64!")).toBeNull()
  })
  test("keys xterm instances by terminal and run generation", () => {
    expect(terminalKey("terminal-1", 4)).toBe("terminal-1:4")
    expect(terminalKey("terminal-1", 5)).not.toBe(terminalKey("terminal-1", 4))
  })

  test("builds the complete typed command fence from the mounted scope", () => {
    const root = { dataset: { terminalRepository: "repo", terminalSession: "session", terminalIncarnation: "incarnation", terminalCatalogRevision: "8" } }
    const panel = { dataset: { terminalId: "terminal-1", terminalGeneration: "3", terminalAttachment: "attachment-1", terminalControlEpoch: "5" } }

    expect(commandFence(panel, root)).toEqual({
      repository_id: "repo",
      session_id: "session",
      incarnation_id: "incarnation",
      terminal_id: "terminal-1",
      generation: 3,
      catalog_revision: 8,
      attachment_id: "attachment-1",
      control_epoch: 5
    })
  })

  test("cycles an accessible height value and toggles maximize to Restore and back", () => {
    const state = presentation({ height: null, maximized: false })

    expect(presentationControlState(state)).toMatchObject({
      heightLabel: "Adjust terminal height, current automatic",
      heightValue: "automatic",
      maximizeLabel: "Maximize terminal",
      maximizeValue: "restored"
    })

    expect(applyPresentationAction(state, "height")).toBe(true)
    expect(presentationControlState(state)).toMatchObject({
      heightLabel: "Adjust terminal height, current 240px",
      heightValue: "240px"
    })

    expect(applyPresentationAction(state, "maximize")).toBe(true)
    expect(presentationControlState(state)).toMatchObject({
      maximizeLabel: "Restore terminal",
      maximizeValue: "maximized"
    })

    applyPresentationAction(state, "maximize")
    expect(presentationControlState(state)).toMatchObject({
      maximizeLabel: "Maximize terminal",
      maximizeValue: "restored"
    })
  })

  test("publishes height and maximize state on the rendered controls", () => {
    const control = () => {
      const attributes = new Map()
      const label = { textContent: "" }
      return {
        attributes,
        dataset: {},
        label,
        setAttribute: (name, value) => attributes.set(name, value),
        querySelector: () => label
      }
    }
    const height = control()
    const maximize = control()
    const context = {
      presentation: presentation({ height: 360, maximized: true }),
      el: {
        querySelector: (selector) => selector.includes("height") ? height : maximize
      },
      updateActionControl: SessionTerminals.updateActionControl
    }

    SessionTerminals.updatePresentationControls.call(context)

    expect(height.attributes.get("aria-label")).toBe("Adjust terminal height, current 360px")
    expect(height.dataset.terminalActionValue).toBe("360px")
    expect(height.label.textContent).toBe("Adjust terminal height, current 360px")
    expect(maximize.attributes.get("aria-label")).toBe("Restore terminal")
    expect(maximize.attributes.get("aria-pressed")).toBe("true")
    expect(maximize.label.textContent).toBe("Restore terminal")

    context.presentation.maximized = false
    SessionTerminals.updatePresentationControls.call(context)
    expect(maximize.attributes.get("aria-label")).toBe("Maximize terminal")
    expect(maximize.attributes.get("aria-pressed")).toBe("false")
  })

  test("gates input and resize on controller, resync, visibility, and measured host", () => {
    const instance = {
      controller: true,
      resynced: false,
      disposed: false,
      host: { getBoundingClientRect: () => ({ width: 800, height: 320 }) }
    }

    expect(canSendInput(instance)).toBe(false)
    expect(canResize({ hidden: false }, instance)).toBe(false)
    instance.resynced = true
    expect(canSendInput(instance)).toBe(true)
    expect(canResize({ hidden: true }, instance)).toBe(false)
    expect(canResize({ hidden: false }, instance)).toBe(true)
    instance.host.getBoundingClientRect = () => ({ width: 0, height: 320 })
    expect(canResize({ hidden: false }, instance)).toBe(false)
  })

  test("acknowledges output only after xterm completes rendering and tracks hidden output as unread", () => {
    let rendered
    const events = []
    const instance = {
      terminalId: "terminal-1",
      panel: { hidden: true },
      terminal: { write: (_data, callback) => { rendered = callback } }
    }
    const context = {
      instances: new Map([[terminalKey("terminal-1", 1), instance]]),
      presentation: presentation(),
      persistPresentation() {},
      applyPresentation() {},
      pushEvent: (event, payload) => events.push([event, payload])
    }

    SessionTerminals.write.call(context, { terminal_id: "terminal-1", generation: 1, sequence: 9, data: "output" })
    expect(events).toEqual([])
    expect(context.presentation.unread["terminal-1"]).toBe(true)

    rendered()
    expect(events).toEqual([["terminal_rendered", { terminal_id: "terminal-1", generation: 1, sequence: 9 }]])
    expect(context.presentation.unread["terminal-1"]).toBe(true)
  })

  test("resets xterm for a snapshot and clears unread only after the visible screen renders", () => {
    let rendered
    let resets = 0
    const instance = {
      terminalId: "terminal-1",
      panel: { hidden: false },
      terminal: {
        reset: () => { resets += 1 },
        write: (_data, callback) => { rendered = callback }
      }
    }
    const context = {
      instances: new Map([[terminalKey("terminal-1", 2), instance]]),
      presentation: presentation({ unread: { "terminal-1": true } }),
      persistPresentation() {},
      applyPresentation() {},
      pushEvent() {}
    }

    SessionTerminals.write.call(context, { terminal_id: "terminal-1", generation: 2, sequence: 3, data: new Uint8Array([65]) }, { reset: true })
    expect(resets).toBe(1)
    expect(context.presentation.unread["terminal-1"]).toBe(true)
    rendered()
    expect(context.presentation.unread["terminal-1"]).toBe(false)
  })

  test("sends only changed controller dimensions and never emits create or close", () => {
    const events = []
    const panel = { hidden: false, dataset: { terminalId: "terminal-1", terminalGeneration: "3" } }
    const instance = {
      controller: true,
      resynced: true,
      disposed: false,
      lastSize: null,
      fence: { terminal_id: "terminal-1", generation: 3, catalog_revision: 8, attachment_id: "attachment-1", control_epoch: 5 },
      host: { getBoundingClientRect: () => ({ width: 800, height: 320 }) },
      fit: { fit() {} },
      terminal: { cols: 100, rows: 30 }
    }
    const context = { pushEvent: (event, payload) => events.push([event, payload]) }

    SessionTerminals.fit.call(context, panel, instance)
    SessionTerminals.fit.call(context, panel, instance)

    expect(events).toEqual([["terminal_resize", { terminal_id: "terminal-1", generation: 3, catalog_revision: 8, attachment_id: "attachment-1", control_epoch: 5, cols: 100, rows: 30 }]])
    expect(events.flat()).not.toContain("terminal_create")
    expect(events.flat()).not.toContain("terminal_close")
  })

  test("disposes browser resources without requesting backend close", () => {
    let terminalDisposals = 0
    let subscriptionDisposals = 0
    const instance = {
      disposed: false,
      subscriptions: [{ dispose: () => { subscriptionDisposals += 1 } }],
      fit: {},
      terminal: { dispose: () => { terminalDisposals += 1 } }
    }

    SessionTerminals.disposeInstance(instance)
    SessionTerminals.disposeInstance(instance)

    expect({ terminalDisposals, subscriptionDisposals }).toEqual({ terminalDisposals: 1, subscriptionDisposals: 1 })
  })

  test("does not replay unconfirmed input after disconnect or before control resync", () => {
    const events = []
    const disconnected = {
      controller: true,
      resynced: true,
      disposed: false,
      subscriptions: [{ dispose() {} }],
      terminal: { dispose() {} }
    }

    SessionTerminals.disposeInstance(disconnected)
    if (canSendInput(disconnected)) events.push("terminal_input")

    const reconnected = { controller: false, resynced: false, disposed: false }
    if (canSendInput(reconnected)) events.push("terminal_input")
    reconnected.controller = true
    if (canSendInput(reconnected)) events.push("terminal_input")

    expect(events).toEqual([])
  })
})
