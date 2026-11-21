import { FitAddon } from "@xterm/addon-fit"
import { Terminal } from "@xterm/xterm"

const storagePrefix = "sigma:terminal-presentation:"
const inputFrameBytes = 16 * 1024
const maxWriteBatchBytes = 64 * 1024
const heightSteps = [240, 360, 480]

const emptyPresentation = (panelOpen = true) => ({
  selectedId: null,
  panelOpen,
  height: null,
  maximized: false,
  scroll: {},
  unread: {}
})

export function presentationStorageKey(identity) {
  return `${storagePrefix}${identity}`
}

export function readPresentation(identity, storage = globalThis.window?.sessionStorage, panelOpen = true) {
  const fallback = emptyPresentation(panelOpen)

  try {
    const value = JSON.parse(storage.getItem(presentationStorageKey(identity)) || "{}")
    return {
      selectedId: typeof value.selectedId === "string" ? value.selectedId : null,
      panelOpen: value.panelOpen === true || (value.panelOpen !== false && panelOpen),
      height: Number.isFinite(value.height) ? value.height : null,
      maximized: value.maximized === true,
      scroll: value.scroll && typeof value.scroll === "object" ? value.scroll : {},
      unread: value.unread && typeof value.unread === "object" ? value.unread : {}
    }
  } catch (_) {
    return fallback
  }
}

export function writePresentation(identity, presentation, storage = globalThis.window?.sessionStorage) {
  const safe = {
    panelOpen: presentation.panelOpen === true,
    selectedId: typeof presentation.selectedId === "string" ? presentation.selectedId : null,
    height: Number.isFinite(presentation.height) ? presentation.height : null,
    maximized: presentation.maximized === true,
    scroll: presentation.scroll && typeof presentation.scroll === "object" ? presentation.scroll : {},
    unread: presentation.unread && typeof presentation.unread === "object" ? presentation.unread : {}
  }

  try {
    if (!storage) return false
    storage.setItem(presentationStorageKey(identity), JSON.stringify(safe))
    return true
  } catch (_) {
    return false
  }
}

export function terminalKey(id, generation) {
  return `${id}:${generation}`
}

function instanceIdentity(panel, root) {
  return {
    repository_id: root?.dataset.terminalRepository,
    session_id: root?.dataset.terminalSession,
    incarnation_id: root?.dataset.terminalIncarnation,
    terminal_id: panel?.dataset.terminalId,
    generation: integer(panel?.dataset.terminalGeneration)
  }
}

function matchesServerFrame(instance, frame) {
  const identity = instance?.identity
  return Boolean(identity && frame &&
    frame.repository_id === identity.repository_id &&
    frame.session_id === identity.session_id &&
    frame.incarnation_id === identity.incarnation_id &&
    frame.terminal_id === identity.terminal_id &&
    integer(frame.generation) === identity.generation &&
    frame.attachment_id === instance.fence?.attachment_id &&
    frame.recovery_id === instance.recoveryId)
}

export function encodeTerminalBytes(value) {
  const bytes = value instanceof Uint8Array ? value : new TextEncoder().encode(value)
  let binary = ""
  for (const byte of bytes) binary += String.fromCharCode(byte)
  return globalThis.btoa(binary)
}

export function decodeTerminalBytes(value) {
  if (typeof value !== "string") return null

  try {
    const binary = globalThis.atob(value)
    return Uint8Array.from(binary, (character) => character.charCodeAt(0))
  } catch (_) {
    return null
  }
}

function createInstance(host) {
  const terminal = new Terminal({ convertEol: false, cursorBlink: true, scrollback: 5000, fontFamily: "ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace", fontSize: 13, lineHeight: 1.25 })
  const fit = new FitAddon()
  terminal.loadAddon(fit)
  suppressDeviceReplies(terminal)
  terminal.open(host)
  return {
    terminal,
    fit,
    host,
    panel: null,
    terminalId: null,
    generation: null,
    lastSize: null,
    canonicalSize: null,
    renderedSequence: 0,
    receivedSequence: 0,
    snapshotEpoch: 0,
    recoveryId: null,
    frameQueue: [],
    rendering: false,
    controller: false,
    resynced: false,
    disposed: false,
    subscriptions: []
  }
}

export function suppressDeviceReplies(terminal) {
  terminal.parser.registerCsiHandler({ final: "n" }, ([status]) => status === 5 || status === 6)
  terminal.parser.registerCsiHandler({ final: "c" }, ([device]) => device === 0)
  terminal.parser.registerCsiHandler({ prefix: "?", final: "n" }, ([status]) => status === 6)
  terminal.parser.registerCsiHandler({ prefix: ">", final: "c" }, ([device]) => device === 0)
}

export const SessionTerminalRestore = {
  mounted() {
    this.onTerminalPush = ({ detail: { event, payload, onReply } }) => {
      this.pushEvent(event, payload).then(
        (reply) => onReply?.(reply),
        () => onReply?.(null)
      )
    }
    this.el.addEventListener("sigma:terminal-push", this.onTerminalPush)
    this.restoreTerminalView()
  },
  destroyed() { this.el.removeEventListener("sigma:terminal-push", this.onTerminalPush) },
  updated() { this.restoreTerminalView() },
  reconnected() {
    this.restoreAttempt = null
    this.restoreTerminalView()
  },
  restoreTerminalView() {
    const data = this.el.dataset
    const key = data.terminalStorageKey
    if (data.terminalAvailable !== "true" || data.terminalRetained === "0") return

    const { panelOpen, selectedId } = readPresentation(key, globalThis.window?.sessionStorage, false)
    const trigger = this.el.ownerDocument?.getElementById("session-terminal-open-btn")
    if (selectedId) trigger?.setAttribute("phx-value-terminal_id", selectedId)
    else trigger?.removeAttribute("phx-value-terminal_id")

    if (!panelOpen || data.terminalPanelOpen === "true" || this.restoreAttempt === key) return
    this.restoreAttempt = key
    pushTerminalEvent(this, "terminal_restore", {
      incarnation_id: data.terminalIncarnation,
      terminal_id: selectedId
    })
  }
}

function pushTerminalEvent(hook, event, payload, onReply) {
  // Phoenix locks the element that pushes an event until its reply. Use a leaf
  // outside the terminal panel so a recovery patch can precede its output.
  const transport = hook.el?.ownerDocument?.getElementById("session-terminal-transport")
  if (transport) {
    transport.dispatchEvent(new CustomEvent("sigma:terminal-push", { detail: { event, payload, onReply } }))
  } else {
    hook.pushEvent(event, payload, onReply)
  }
}

export function canSendInput(instance) {
  return instance?.controller === true && instance?.resynced === true && instance?.disposed !== true
}

export function canResize(panel, instance) {
  return canSendInput(instance) && canFit(panel, instance)
}

function canFit(panel, instance) {
  if (!instance || instance.disposed || panel?.hidden) return false
  const rect = instance.host?.getBoundingClientRect()
  return Boolean(rect && rect.width > 0 && rect.height > 0)
}

function integer(value) {
  const parsed = Number.parseInt(value, 10)
  return Number.isInteger(parsed) ? parsed : undefined
}

export function commandFence(panel, root) {
  return {
    repository_id: root?.dataset.terminalRepository,
    session_id: root?.dataset.terminalSession,
    incarnation_id: root?.dataset.terminalIncarnation,
    terminal_id: panel?.dataset.terminalId,
    generation: integer(panel?.dataset.terminalGeneration),
    catalog_revision: integer(root?.dataset.terminalCatalogRevision),
    attachment_id: panel?.dataset.terminalAttachment,
    control_epoch: integer(panel?.dataset.terminalControlEpoch),
    recovery_id: panel?.dataset.terminalRecovery
  }
}

function nextHeight(height) {
  const index = heightSteps.indexOf(height)
  return heightSteps[(index + 1) % heightSteps.length]
}

export function applyPresentationAction(presentation, action) {
  if (action === "height") {
    presentation.height = nextHeight(presentation.height)
  } else if (action === "maximize") {
    presentation.maximized = !presentation.maximized
  } else if (action === "collapse") {
    presentation.panelOpen = false
  } else {
    return false
  }

  return true
}

export function presentationControlState(presentation) {
  const heightValue = Number.isFinite(presentation.height) ? `${presentation.height}px` : "automatic"
  return {
    heightLabel: `Adjust terminal height, current ${heightValue}`,
    heightValue,
    maximizeLabel: presentation.maximized ? "Restore terminal" : "Maximize terminal",
    maximizeValue: presentation.maximized ? "maximized" : "restored"
  }
}

function afterPaint(callback) {
  const request = globalThis.window?.requestAnimationFrame
  if (typeof request === "function") request(() => callback())
  else callback()
}

export const SessionTerminals = {
  mounted() {
    this.instances = new Map()
    this.storageIdentity = this.el.dataset.terminalStorageKey
    this.presentation = readPresentation(
      this.storageIdentity,
      globalThis.window?.sessionStorage,
      this.el.dataset.terminalPanelOpen === "true"
    )
    this.presentation.panelOpen = true
    this.persistPresentation()
    this.installEvents()
    this.installKeyboardNavigation()
    this.installPresentationControls()
    this.installResizeTracking()
    this.installHeartbeat()
    this.applyPresentation()
    this.syncHosts()
    this.synchronizeSelection()
  },
  updated() {
    this.applyPresentation()
    this.syncHosts()
    this.synchronizeSelection()
  },
  disconnected() {
    this.disconnectedFromServer = true
    this.instances.forEach((instance) => { instance.inputBatch = null })
  },
  reconnected() { this.disconnectedFromServer = false },
  destroyed() {
    this.resizeObserver?.disconnect()
    globalThis.window?.removeEventListener?.("resize", this.onResize)
    globalThis.window?.clearInterval?.(this.heartbeatTimer)
    this.el.removeEventListener("keydown", this.onTabKeydown)
    this.el.removeEventListener("click", this.onPresentationClick)
    this.eventRefs?.forEach((ref) => this.removeHandleEvent?.(ref))
    this.instances.forEach((instance) => this.disposeInstance(instance))
    this.instances.clear()
  },
  installEvents() {
    this.eventRefs = [
      this.handleEvent("terminal_output", (frame) => this.write(frame)),
      this.handleEvent("terminal_snapshot", (frame) => this.write(frame, { reset: true })),
      this.handleEvent("terminal_resize", (frame) => this.write(frame)),
      this.handleEvent("terminal_selection", (frame) => this.selectFromServer(frame)),
      this.handleEvent("terminal_control", (frame) => this.setControl(frame)),
      this.handleEvent("terminal_resync", (frame) => this.setResynced(frame))
    ]
  },
  installKeyboardNavigation() {
    this.onTabKeydown = (event) => {
      const tab = event.target.closest('[role="tab"]')
      if (!tab || !["ArrowLeft", "ArrowRight", "Home", "End"].includes(event.key)) return
      const tabs = [...this.el.querySelectorAll('[role="tab"]')]
      const index = tabs.indexOf(tab)
      const next = event.key === "Home" ? 0 : event.key === "End" ? tabs.length - 1 : (index + (event.key === "ArrowRight" ? 1 : -1) + tabs.length) % tabs.length
      event.preventDefault()
      tabs[next]?.focus()
      tabs[next]?.click()
    }
    this.el.addEventListener("keydown", this.onTabKeydown)
  },
  installPresentationControls() {
    this.onPresentationClick = (event) => {
      const tab = event.target.closest?.('[role="tab"][data-terminal-id]')
      if (tab) {
        this.presentation.selectedId = tab.dataset.terminalId
        this.presentation.unread[tab.dataset.terminalId] = false
        this.persistPresentation()
        this.applyPresentation()
        this.syncHosts()
        SessionTerminals.requestSelection.call(this, tab.dataset.terminalId, true)
      }

      const action = event.target.closest?.("[data-terminal-action]")?.dataset.terminalAction
      if (!applyPresentationAction(this.presentation, action)) return

      this.persistPresentation()
      this.applyPresentation()
      this.syncHosts()
    }
    this.el.addEventListener("click", this.onPresentationClick)
  },
  installResizeTracking() {
    this.onResize = () => this.syncHosts()
    if (typeof globalThis.ResizeObserver === "function") {
      this.resizeObserver = new globalThis.ResizeObserver(this.onResize)
      this.resizeObserver.observe(this.el)
    }
    globalThis.window?.addEventListener?.("resize", this.onResize)
  },
  installHeartbeat() {
    this.heartbeatTimer = globalThis.window?.setInterval?.(() => {
      this.instances.forEach((instance) => {
        if (!instance.disposed && instance.fence?.attachment_id) {
          pushTerminalEvent(this, "terminal_heartbeat", instance.fence)
        }
      })
    }, 10_000)
  },
  persistPresentation() {
    writePresentation(this.storageIdentity, this.presentation)
  },
  requestSelection(terminalId, explicit = false) {
    if (typeof this.el.querySelectorAll !== "function") return
    const tab = [...this.el.querySelectorAll('[role="tab"][data-terminal-id]')]
      .find((candidate) => candidate.dataset.terminalId === terminalId)
    if (!tab) return
    const generation = integer(tab.dataset.terminalGeneration)
    const instance = this.instances.get(terminalKey(terminalId, generation))
    this.selectionRequest = `${terminalId}:${generation}`
    pushTerminalEvent(this, "terminal_select", {
      terminal_id: terminalId,
      generation,
      ...(explicit ? { acquire_control: true } : {}),
      rendered_sequence: Number.isInteger(instance?.renderedSequence) ? instance.renderedSequence : 0
    })
  },
  synchronizeSelection() {
    const terminalId = this.presentation.selectedId
    if (!terminalId || terminalId === this.el.dataset.terminalSelected) return
    const tab = [...this.el.querySelectorAll('[role="tab"][data-terminal-id]')]
      .find((candidate) => candidate.dataset.terminalId === terminalId)
    if (!tab) return
    const generation = integer(tab.dataset.terminalGeneration)
    const signature = `${terminalId}:${generation}`
    if (this.selectionRequest === signature) return
    SessionTerminals.requestSelection.call(this, terminalId)
  },
  selectFromServer(frame) {
    if (typeof frame?.terminal_id !== "string") return
    this.forcedSelection = { terminal_id: frame.terminal_id, generation: integer(frame.generation) }
    this.presentation.selectedId = frame.terminal_id
    this.presentation.unread[frame.terminal_id] = false
    this.selectionRequest = `${frame.terminal_id}:${integer(frame.generation)}`
    this.persistPresentation()
    this.applyPresentation()
    this.syncHosts()
  },
  applyPresentation() {
    const tabs = [...this.el.querySelectorAll('[role="tab"][data-terminal-id]')]
    const forcedSelection = tabs.find((tab) =>
      tab.dataset.terminalId === this.forcedSelection?.terminal_id &&
      integer(tab.dataset.terminalGeneration) === this.forcedSelection?.generation
    )
    const validSelection = forcedSelection || tabs.find((tab) => tab.dataset.terminalId === this.presentation.selectedId)
    this.presentation.selectedId = validSelection?.dataset.terminalId || tabs[0]?.dataset.terminalId || null
    if (forcedSelection) this.forcedSelection = null

    this.el.classList.toggle("is-collapsed", !this.presentation.panelOpen)
    this.el.classList.toggle("is-maximized", this.presentation.maximized)
    if (Number.isFinite(this.presentation.height)) this.el.style.setProperty("--sigma-terminal-height", `${Math.min(900, Math.max(192, this.presentation.height))}px`)
    else this.el.style.removeProperty("--sigma-terminal-height")

    this.updatePresentationControls()

    tabs.forEach((tab) => {
      const selected = tab.dataset.terminalId === this.presentation.selectedId
      tab.setAttribute("aria-selected", String(selected))
      tab.tabIndex = selected ? 0 : -1
      tab.classList.toggle("is-selected", selected)
      tab.classList.toggle("has-unread", this.presentation.unread[tab.dataset.terminalId] === true)
    })

    SessionTerminals.revealSelectedTab.call(this, validSelection || tabs[0])

    this.el.querySelectorAll("[role=tabpanel][data-terminal-id]").forEach((panel) => {
      panel.hidden = panel.dataset.terminalId !== this.presentation.selectedId
    })
  },
  revealSelectedTab(tab) {
    if (!this.presentation.panelOpen || !tab) return

    const tabbar = tab.closest?.(".sigma-terminal-tabbar")
    const tabRect = tab.getBoundingClientRect?.()
    const tabbarRect = tabbar?.getBoundingClientRect?.()
    if (!tabbar || !tabRect || !tabbarRect || tabbarRect.width <= 0) return

    if (tabRect.width >= tabbarRect.width || tabRect.left < tabbarRect.left) {
      tabbar.scrollLeft = Math.max(0, tabbar.scrollLeft + tabRect.left - tabbarRect.left)
    } else if (tabRect.right > tabbarRect.right) {
      tabbar.scrollLeft += tabRect.right - tabbarRect.right
    }
  },
  updatePresentationControls() {
    const state = presentationControlState(this.presentation)
    this.updateActionControl("height", state.heightLabel, state.heightValue)
    this.updateActionControl("maximize", state.maximizeLabel, state.maximizeValue, this.presentation.maximized)
  },
  updateActionControl(action, label, value, pressed) {
    const control = this.el.querySelector(`[data-terminal-action="${action}"]`)
    if (!control) return

    control.setAttribute("aria-label", label)
    control.setAttribute("title", label)
    control.dataset.terminalActionValue = value
    if (typeof pressed === "boolean") control.setAttribute("aria-pressed", String(pressed))
    const accessibleLabel = control.querySelector("[data-terminal-action-label]")
    if (accessibleLabel) accessibleLabel.textContent = label
  },
  syncHosts() {
    const seen = new Set()
    this.el.querySelectorAll("[data-terminal-host]").forEach((host) => {
      const panel = host.closest("[data-terminal-id]")
      const key = terminalKey(panel.dataset.terminalId, panel.dataset.terminalGeneration)
      seen.add(key)
      let instance = this.instances.get(key)
      const identity = instanceIdentity(panel, this.el)
      if (instance && instance.identity &&
          JSON.stringify(instance.identity) !== JSON.stringify(identity)) {
        this.disposeInstance(instance)
        this.instances.delete(key)
        instance = null
      }
      if (instance && instance.host !== host) {
        this.disposeInstance(instance)
        this.instances.delete(key)
        instance = null
      }
      if (!instance) {
        instance = createInstance(host)
        this.instances.set(key, instance)
        instance.subscriptions.push(instance.terminal.onData((data) =>
          SessionTerminals.sendInput.call(this, instance, data)
        ))
        instance.subscriptions.push(instance.terminal.onScroll((position) => {
          this.presentation.scroll[instance.terminalId] = position
          this.persistPresentation()
        }))
      }
      instance.panel = panel
      instance.identity = identity
      instance.terminalId = panel.dataset.terminalId
      instance.generation = panel.dataset.terminalGeneration
      instance.fence = commandFence(panel, this.el)
      instance.controller = panel.dataset.terminalController === "true"
      instance.resynced = panel.dataset.terminalResynced === "true"
      instance.recoveryId = panel.dataset.terminalRecovery || instance.recoveryId
      const canonicalSize = {
        cols: integer(panel.dataset.terminalColumns),
        rows: integer(panel.dataset.terminalRows)
      }
      if (!instance.fence.attachment_id || !instance.canonicalSize) {
        SessionTerminals.applyCanonicalSize.call(this, instance, canonicalSize)
      }
      const scrollPosition = this.presentation.scroll[instance.terminalId]
      if (Number.isInteger(scrollPosition)) instance.terminal.scrollToLine(scrollPosition)
      afterPaint(() => this.fit(instance.panel, instance))
    })
    this.instances.forEach((instance, key) => {
      if (!seen.has(key)) {
        this.disposeInstance(instance)
        this.instances.delete(key)
      }
    })
  },
  sendInput(instance, data) {
    if (this.disconnectedFromServer || !canSendInput(instance)) return

    const bytes = new TextEncoder().encode(data)
    const fence = instance.fence
    const send = (chunk, reply) => pushTerminalEvent(this, "terminal_input", {
      ...instance.fence,
      data_base64: encodeTerminalBytes(chunk),
      ...(reply ? { input_batch: true } : {})
    }, reply)

    if (bytes.length <= inputFrameBytes && !instance.inputBatch) {
      send(bytes)
      return
    }

    let batch = instance.inputBatch
    if (batch && batch.fence.attachment_id === fence.attachment_id &&
        batch.fence.control_epoch === fence.control_epoch && batch.fence.recovery_id === fence.recovery_id) {
      batch.pending.push(bytes)
      return
    }

    batch = { fence, pending: [bytes], offset: 0 }
    instance.inputBatch = batch
    const next = () => {
      if (instance.inputBatch !== batch) return
      const current = instance.fence
      if (this.disconnectedFromServer || !canSendInput(instance) ||
          fence.attachment_id !== current.attachment_id || fence.control_epoch !== current.control_epoch ||
          fence.recovery_id !== current.recovery_id || batch.pending.length === 0) {
        instance.inputBatch = null
        return
      }
      const input = batch.pending[0]
      const end = Math.min(batch.offset + inputFrameBytes, input.length)
      const chunk = input.subarray(batch.offset, end)
      batch.offset = end
      if (end === input.length) {
        batch.pending.shift()
        batch.offset = 0
      }
      send(chunk, (reply) => {
        if (reply?.accepted) next()
        else if (instance.inputBatch === batch) instance.inputBatch = null
      })
    }
    next()
  },
  write(frame, options = {}) {
    const instance = this.instances.get(terminalKey(frame.terminal_id, frame.generation))
    if (!matchesServerFrame(instance, frame) || instance.disposed) return

    instance.frameQueue ||= []
    instance.renderedSequence ||= 0
    instance.receivedSequence ||= 0
    if (options.reset) {
      instance.snapshotEpoch = (instance.snapshotEpoch || 0) + 1
      instance.frameQueue = []
      instance.renderedSequence = 0
      instance.receivedSequence = 0
    }
    const sequence = integer(frame.sequence)
    if (!Number.isInteger(sequence)) return
    if (!options.reset && instance.receivedSequence > 0 && sequence > instance.receivedSequence + 1) {
      pushTerminalEvent(this, "terminal_resync_request", {
        ...instance.fence,
        recovery_id: instance.recoveryId,
        rendered_sequence: instance.renderedSequence
      })
      return
    }
    const delivery = instance.delivery
    const sameDelivery = !options.reset &&
      delivery?.attachmentId === frame.attachment_id && delivery?.recoveryId === frame.recovery_id
    instance.delivery = {
      attachmentId: frame.attachment_id,
      recoveryId: frame.recovery_id,
      sequence: sameDelivery ? Math.max(delivery.sequence, sequence) : sequence
    }
    if (!options.reset && sequence <= instance.receivedSequence) {
      // Recovery may replay bytes already rendered before its new acknowledgement arrived.
      if (sequence <= instance.renderedSequence) {
        pushTerminalEvent(this, "terminal_rendered", {
          terminal_id: frame.terminal_id,
          generation: frame.generation,
          ...instance.fence,
          recovery_id: instance.recoveryId,
          sequence
        })
      }
      return
    }
    instance.receivedSequence = Math.max(instance.receivedSequence, sequence)
    instance.frameQueue.push({ frame, options })
    SessionTerminals.drainFrames.call(this, instance)
  },
  drainFrames(instance) {
    if (instance.rendering || instance.disposed) return
    const queued = instance.frameQueue.shift()
    if (!queued) return

    instance.rendering = true
    const { frame, options } = queued
    let lastSequence = integer(frame.sequence)
    let data = frame.data_base64 ? decodeTerminalBytes(frame.data_base64) : frame.data

    if (!options.reset && data instanceof Uint8Array) {
      const chunks = [data]
      let length = data.length
      let consumed = 0
      for (const next of instance.frameQueue) {
        const pending = next.frame
        if (next.options.reset || pending.attachment_id !== frame.attachment_id ||
            pending.recovery_id !== frame.recovery_id || integer(pending.sequence) !== lastSequence + 1 ||
            pending.columns !== frame.columns || pending.rows !== frame.rows) break

        const bytes = pending.data_base64 ? decodeTerminalBytes(pending.data_base64) : pending.data
        if (!(bytes instanceof Uint8Array) || length + bytes.length > maxWriteBatchBytes) break
        chunks.push(bytes)
        length += bytes.length
        lastSequence += 1
        consumed += 1
      }
      if (consumed > 0) {
        instance.frameQueue.splice(0, consumed)
        data = new Uint8Array(length)
        let offset = 0
        for (const chunk of chunks) {
          data.set(chunk, offset)
          offset += chunk.length
        }
      }
    }

    const snapshotEpoch = instance.snapshotEpoch || 0
    const visible = this.presentation.panelOpen && !instance.panel?.hidden
    if (!visible && !this.presentation.unread[instance.terminalId]) {
      this.presentation.unread[instance.terminalId] = true
      this.persistPresentation()
      this.applyPresentation()
    }

    SessionTerminals.applyCanonicalSize.call(this, instance, { cols: integer(frame.columns), rows: integer(frame.rows) })
    if (options.reset) instance.terminal.reset()

    const rendered = () => {
      instance.rendering = false
      if (instance.disposed) return
      if ((instance.snapshotEpoch || 0) !== snapshotEpoch) {
        SessionTerminals.drainFrames.call(this, instance)
        return
      }

      instance.renderedSequence = Math.max(instance.renderedSequence, lastSequence)
      if (this.presentation.panelOpen && !instance.panel?.hidden && this.presentation.unread[instance.terminalId]) {
        this.presentation.unread[instance.terminalId] = false
        this.persistPresentation()
        this.applyPresentation()
      }

      const delivery = instance.delivery
      if (delivery?.attachmentId === instance.fence?.attachment_id &&
          delivery?.recoveryId === instance.recoveryId) {
        const sequence = Math.min(lastSequence, delivery.sequence)
        if (sequence >= integer(frame.sequence)) {
          pushTerminalEvent(this, "terminal_rendered", {
            terminal_id: frame.terminal_id,
            generation: frame.generation,
            ...instance.fence,
            recovery_id: instance.recoveryId,
            sequence
          })
        }
      }
      SessionTerminals.drainFrames.call(this, instance)
    }

    if (typeof data === "string" || data instanceof Uint8Array) instance.terminal.write(data, rendered)
    else rendered()
  },
  setControl(frame) {
    const instance = this.instances.get(terminalKey(frame.terminal_id, frame.generation))
    if (matchesServerFrame(instance, frame)) {
      instance.controller = frame.controller === true
      instance.fence = {
        ...instance.fence,
        attachment_id: frame.attachment_id,
        control_epoch: frame.control_epoch
      }
    }
  },
  setResynced(frame) {
    const instance = this.instances.get(terminalKey(frame.terminal_id, frame.generation))
    if (matchesServerFrame(instance, frame)) {
      instance.resynced = frame.resynced === true
      instance.recoveryId = frame.recovery_id || instance.recoveryId
    }
  },
  fit(panel, instance) {
    if (!canResize(panel, instance)) return
    const proposed = instance.fit.proposeDimensions?.()
    const size = proposed && { cols: proposed.cols, rows: proposed.rows }
    if (!size) return
    if (size.cols <= 0 || size.rows <= 0 || (instance.lastSize && size.cols === instance.lastSize.cols && size.rows === instance.lastSize.rows)) return
    instance.lastSize = size
    pushTerminalEvent(this, "terminal_resize", { ...instance.fence, ...size })
  },
  applyCanonicalSize(instance, size) {
    if (!Number.isInteger(size?.cols) || !Number.isInteger(size?.rows) || size.cols <= 0 || size.rows <= 0) return
    if (instance.canonicalSize?.cols === size.cols && instance.canonicalSize?.rows === size.rows &&
        instance.terminal.cols === size.cols && instance.terminal.rows === size.rows) return
    instance.canonicalSize = size
    instance.terminal.resize(size.cols, size.rows)
  },
  disposeInstance(instance) {
    if (instance.disposed) return
    instance.disposed = true
    instance.subscriptions.forEach((subscription) => subscription.dispose())
    instance.terminal.dispose()
  }
}
