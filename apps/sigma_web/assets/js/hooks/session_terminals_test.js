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

const serverIdentity = {
  repository_id: "repo",
  session_id: "session",
  incarnation_id: "incarnation",
  terminal_id: "terminal-1",
  generation: 1
}

const serverFrame = (overrides = {}) => ({
  ...serverIdentity,
  attachment_id: "attachment-1",
  recovery_id: "recovery-1",
  ...overrides
})

const fencedInstance = (overrides = {}) => ({
  identity: serverIdentity,
  terminalId: "terminal-1",
  fence: { attachment_id: "attachment-1", control_epoch: 1 },
  recoveryId: "recovery-1",
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
  test("ignores control, resync, and output from an old incarnation with reused terminal ids", () => {
    let writes = 0
    const identity = {
      repository_id: "repo",
      session_id: "session",
      incarnation_id: "new-incarnation",
      terminal_id: "terminal-1",
      generation: 1
    }
    const instance = {
      identity,
      terminalId: "terminal-1",
      controller: false,
      resynced: false,
      recoveryId: "recovery-new",
      fence: { attachment_id: "attachment-new" },
      terminal: { write: () => { writes += 1 } }
    }
    const context = {
      instances: new Map([[terminalKey("terminal-1", 1), instance]]),
      presentation: presentation(),
      pushEvent() {},
      persistPresentation() {},
      applyPresentation() {}
    }
    const stale = {
      ...identity,
      incarnation_id: "old-incarnation",
      attachment_id: "attachment-new",
      recovery_id: "recovery-new"
    }

    SessionTerminals.setControl.call(context, { ...stale, controller: true, control_epoch: 9 })
    SessionTerminals.setResynced.call(context, { ...stale, resynced: true })
    SessionTerminals.write.call(context, { ...stale, sequence: 1, data: "stale" })

    expect({ controller: instance.controller, resynced: instance.resynced, writes }).toEqual({
      controller: false,
      resynced: false,
      writes: 0
    })
  })

  test("tab activation refits the newly visible terminal", () => {
    let listener
    const selections = []
    const context = {
      presentation: presentation(),
      el: { addEventListener: (_event, callback) => { listener = callback } },
      persistPresentation() {},
      applyPresentation() {},
      syncHosts() { selections.push(this.presentation.selectedId) }
    }
    SessionTerminals.installPresentationControls.call(context)
    listener({ target: { closest: (selector) => selector.includes('role="tab"') ? { dataset: { terminalId: "terminal-2" } } : null } })
    expect(selections).toEqual(["terminal-2"])
  })

  test("renders a visible observer at confirmed canonical dimensions without fitting its viewport", () => {
    let fits = 0
    const sizes = []
    const events = []
    const instance = {
      controller: false, resynced: true, disposed: false,
      host: { getBoundingClientRect: () => ({ width: 800, height: 320 }) },
      fit: { fit() { fits += 1 } },
      terminal: { cols: 100, rows: 30, resize: (cols, rows) => sizes.push([cols, rows]) },
      canonicalSize: { cols: 120, rows: 24 }
    }
    const context = { pushEvent: (event) => events.push(event) }
    SessionTerminals.fit.call(context, { hidden: false }, instance)
    SessionTerminals.applyCanonicalSize.call(context, instance, instance.canonicalSize)
    expect(fits).toBe(0)
    expect(sizes).toEqual([[120, 24]])
    expect(events).toEqual([])
    SessionTerminals.fit.call(context, { hidden: true }, instance)
    instance.disposed = true
    SessionTerminals.fit.call(context, { hidden: false }, instance)
    expect(fits).toBe(0)
  })

  test("height and maximize/restore controls synchronize hosts after applying layout", () => {
    let listener
    const layouts = []
    let applied
    const context = {
      presentation: presentation(),
      el: { addEventListener: (_event, callback) => { listener = callback } },
      persistPresentation() {},
      applyPresentation() { applied = { height: this.presentation.height, maximized: this.presentation.maximized } },
      syncHosts() { layouts.push(applied) }
    }
    SessionTerminals.installPresentationControls.call(context)
    for (const action of ["height", "maximize", "maximize"]) {
      listener({ target: { closest: (selector) => selector === "[data-terminal-action]" ? { dataset: { terminalAction: action } } : null } })
    }
    expect(layouts).toEqual([
      { height: 240, maximized: false },
      { height: 240, maximized: true },
      { height: 240, maximized: false }
    ])
  })

  test("host synchronization fits after layout settles without replacing the instance", () => {
    const originalWindow = globalThis.window
    const frames = []
    const fits = []
    const panel = { dataset: { terminalId: "terminal-1", terminalGeneration: "1" } }
    const host = { closest: () => panel }
    const instance = { host, terminal: {} }
    const context = {
      el: { dataset: {}, querySelectorAll: () => [host] },
      instances: new Map([["terminal-1:1", instance]]),
      presentation: presentation(),
      fit: (_panel, value) => fits.push(value)
    }
    globalThis.window = { requestAnimationFrame: (callback) => frames.push(callback) }
    try {
      SessionTerminals.syncHosts.call(context)
      expect(fits).toEqual([])
      frames.forEach((callback) => callback())
      expect(fits).toEqual([instance])
      expect(context.instances.get("terminal-1:1")).toBe(instance)
    } finally {
      globalThis.window = originalWindow
    }
  })

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
    const panel = { dataset: { terminalId: "terminal-1", terminalGeneration: "3", terminalAttachment: "attachment-1", terminalControlEpoch: "5", terminalRecovery: "recovery-1" } }

    expect(commandFence(panel, root)).toEqual({
      repository_id: "repo",
      session_id: "session",
      incarnation_id: "incarnation",
      terminal_id: "terminal-1",
      generation: 3,
      catalog_revision: 8,
      attachment_id: "attachment-1",
      control_epoch: 5,
      recovery_id: "recovery-1"
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
    const instance = fencedInstance({
      terminalId: "terminal-1",
      panel: { hidden: true },
      terminal: { write: (_data, callback) => { rendered = callback } }
    })
    const context = {
      instances: new Map([[terminalKey("terminal-1", 1), instance]]),
      presentation: presentation(),
      persistPresentation() {},
      applyPresentation() {},
      pushEvent: (event, payload) => events.push([event, payload])
    }

    SessionTerminals.write.call(context, serverFrame({ sequence: 9, data: "output" }))
    expect(events).toEqual([])
    expect(context.presentation.unread["terminal-1"]).toBe(true)

    rendered()
    expect(events).toEqual([["terminal_rendered", expect.objectContaining({ terminal_id: "terminal-1", generation: 1, sequence: 9 })]])
    expect(context.presentation.unread["terminal-1"]).toBe(true)
  })

  test("captures attachment and recovery identity before an asynchronous render callback", () => {
    let rendered
    const events = []
    const instance = fencedInstance({
      terminalId: "terminal-1",
      panel: { hidden: false },
      fence: { attachment_id: "attachment-old", control_epoch: 1 },
      recoveryId: "recovery-old",
      terminal: { write: (_data, callback) => { rendered = callback } }
    })
    const context = {
      instances: new Map([[terminalKey("terminal-1", 1), instance]]),
      presentation: presentation(),
      persistPresentation() {},
      applyPresentation() {},
      pushEvent: (event, payload) => events.push([event, payload])
    }

    SessionTerminals.write.call(context, serverFrame({
      sequence: 4,
      attachment_id: "attachment-old",
      recovery_id: "recovery-old",
      data: "old"
    }))
    instance.fence = { attachment_id: "attachment-new", control_epoch: 2 }
    instance.recoveryId = "recovery-new"
    rendered()

    expect(events).toEqual([])
  })

  test("a stale callback cannot discard a newer attachment recovery queued behind it", () => {
    const callbacks = []
    const writes = []
    const events = []
    const instance = fencedInstance({
      terminalId: "terminal-1",
      panel: { hidden: false },
      fence: { attachment_id: "attachment-old", control_epoch: 1 },
      recoveryId: "recovery-old",
      terminal: {
        reset() {},
        write: (data, callback) => { writes.push(data); callbacks.push(callback) }
      }
    })
    const context = {
      instances: new Map([[terminalKey("terminal-1", 1), instance]]),
      presentation: presentation(),
      persistPresentation() {},
      applyPresentation() {},
      pushEvent: (event, payload) => events.push([event, payload])
    }

    SessionTerminals.write.call(context, serverFrame({ sequence: 1,
      attachment_id: "attachment-old", recovery_id: "recovery-old", data: "old"
    }))
    instance.fence = { attachment_id: "attachment-new", control_epoch: 2 }
    instance.recoveryId = "recovery-new"
    SessionTerminals.write.call(context, serverFrame({ sequence: 2,
      attachment_id: "attachment-new", recovery_id: "recovery-new", data: "new"
    }), { reset: true })

    callbacks.shift()()
    expect(writes).toEqual(["old", "new"])
    callbacks.shift()()
    expect(events).toEqual([["terminal_rendered", expect.objectContaining({
      attachment_id: "attachment-new",
      recovery_id: "recovery-new",
      sequence: 2
    })]])
  })

  test("applies snapshot dimensions before resetting and rendering bytes", () => {
    const order = []
    const instance = fencedInstance({
      terminalId: "terminal-1",
      panel: { hidden: false },
      fence: { attachment_id: "attachment-1" },
      recoveryId: "recovery-1",
      terminal: {
        resize: (cols, rows) => order.push(["resize", cols, rows]),
        reset: () => order.push(["reset"]),
        write: (_data, callback) => { order.push(["write"]); callback() }
      }
    })
    const context = {
      instances: new Map([[terminalKey("terminal-1", 1), instance]]),
      presentation: presentation(),
      persistPresentation() {},
      applyPresentation() {},
      pushEvent() {},
      applyCanonicalSize: SessionTerminals.applyCanonicalSize
    }

    SessionTerminals.write.call(context, serverFrame({
      sequence: 7,
      attachment_id: "attachment-1",
      recovery_id: "recovery-1",
      columns: 90,
      rows: 31,
      data: "screen"
    }), { reset: true })

    expect(order).toEqual([["resize", 90, 31], ["reset"], ["write"]])
  })

  test("deduplicates a frame queued during rendering", () => {
    const callbacks = []
    const writes = []
    const instance = fencedInstance({
      terminalId: "terminal-1",
      panel: { hidden: false },
      fence: { attachment_id: "attachment-1" },
      recoveryId: "recovery-1",
      terminal: { write: (data, callback) => { writes.push(data); callbacks.push(callback) } }
    })
    const context = {
      instances: new Map([[terminalKey("terminal-1", 1), instance]]),
      presentation: presentation(),
      persistPresentation() {},
      applyPresentation() {},
      pushEvent() {}
    }
    const frame = serverFrame({ sequence: 1, data: "once" })

    SessionTerminals.write.call(context, frame)
    SessionTerminals.write.call(context, frame)
    callbacks.shift()()

    expect(writes).toEqual(["once"])
  })

  test("a coherent snapshot replaces an unreliable cursor even when its sequence is older", () => {
    const order = []
    const instance = fencedInstance({
      terminalId: "terminal-1",
      panel: { hidden: false },
      fence: { attachment_id: "attachment-1" },
      recoveryId: "recovery-2",
      renderedSequence: 12,
      receivedSequence: 12,
      terminal: {
        reset: () => order.push("reset"),
        write: (_data, callback) => { order.push("snapshot"); callback() }
      }
    })
    const context = {
      instances: new Map([[terminalKey("terminal-1", 1), instance]]),
      presentation: presentation(),
      persistPresentation() {},
      applyPresentation() {},
      pushEvent() {}
    }

    SessionTerminals.write.call(context, serverFrame({
      sequence: 8,
      recovery_id: "recovery-2",
      data: "baseline"
    }), { reset: true })

    expect(order).toEqual(["reset", "snapshot"])
    expect(instance.renderedSequence).toBe(8)
  })

  test("restores a valid local selection with its confirmed same-run render cursor", () => {
    const events = []
    const context = {
      presentation: presentation({ selectedId: "terminal-2" }),
      el: {
        dataset: { terminalSelected: "terminal-1" },
        querySelectorAll: (selector) => selector.includes('role="tab"') ? [
          { dataset: { terminalId: "terminal-1", terminalGeneration: "1" } },
          { dataset: { terminalId: "terminal-2", terminalGeneration: "3" } }
        ] : []
      },
      instances: new Map([["terminal-2:3", { renderedSequence: 42 }]]),
      pushEvent: (event, payload) => events.push([event, payload])
    }

    SessionTerminals.synchronizeSelection.call(context)

    expect(events).toEqual([["terminal_select", {
      terminal_id: "terminal-2",
      generation: 3,
      rendered_sequence: 42
    }]])
  })

  test("keeps a creator selection pending until the new tab arrives in the DOM", () => {
    const context = {
      presentation: presentation({ selectedId: "terminal-1" }),
      persistPresentation() {},
      applyPresentation() {},
      syncHosts() {}
    }

    SessionTerminals.selectFromServer.call(context, { terminal_id: "terminal-2", generation: 1 })

    expect(context.forcedSelection).toEqual({ terminal_id: "terminal-2", generation: 1 })
  })

  test("resets xterm for a snapshot and clears unread only after the visible screen renders", () => {
    let rendered
    let resets = 0
    const instance = fencedInstance({
      identity: { ...serverIdentity, generation: 2 },
      terminalId: "terminal-1",
      panel: { hidden: false },
      terminal: {
        reset: () => { resets += 1 },
        write: (_data, callback) => { rendered = callback }
      }
    })
    const context = {
      instances: new Map([[terminalKey("terminal-1", 2), instance]]),
      presentation: presentation({ unread: { "terminal-1": true } }),
      persistPresentation() {},
      applyPresentation() {},
      pushEvent() {}
    }

    SessionTerminals.write.call(context, serverFrame({ generation: 2, sequence: 3, data: new Uint8Array([65]) }), { reset: true })
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
      fit: { proposeDimensions: () => ({ cols: 100, rows: 30 }) },
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
