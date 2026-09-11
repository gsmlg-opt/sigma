import { FitAddon } from "@xterm/addon-fit"
import { Terminal } from "@xterm/xterm"

const storagePrefix = "sigma:terminal-presentation:"
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
      panelOpen,
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
  terminal.open(host)
  return {
    terminal,
    fit,
    host,
    panel: null,
    terminalId: null,
    generation: null,
    lastSize: null,
    controller: false,
    resynced: false,
    disposed: false,
    subscriptions: []
  }
}

export function canSendInput(instance) {
  return instance?.controller === true && instance?.resynced === true && instance?.disposed !== true
}

export function canResize(panel, instance) {
  if (!canSendInput(instance) || panel?.hidden) return false
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
    control_epoch: integer(panel?.dataset.terminalControlEpoch)
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
    this.installEvents()
    this.installKeyboardNavigation()
    this.installPresentationControls()
    this.installResizeTracking()
    this.installHeartbeat()
    this.applyPresentation()
    this.syncHosts()
  },
  updated() {
    this.applyPresentation()
    this.syncHosts()
  },
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
          this.pushEvent("terminal_heartbeat", instance.fence)
        }
      })
    }, 10_000)
  },
  persistPresentation() {
    writePresentation(this.storageIdentity, this.presentation)
  },
  applyPresentation() {
    const tabs = [...this.el.querySelectorAll('[role="tab"][data-terminal-id]')]
    const validSelection = tabs.find((tab) => tab.dataset.terminalId === this.presentation.selectedId)
    this.presentation.selectedId = validSelection?.dataset.terminalId || tabs[0]?.dataset.terminalId || null

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

    this.el.querySelectorAll("[role=tabpanel][data-terminal-id]").forEach((panel) => {
      panel.hidden = panel.dataset.terminalId !== this.presentation.selectedId
    })
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
      if (instance && instance.host !== host) {
        this.disposeInstance(instance)
        this.instances.delete(key)
        instance = null
      }
      if (!instance) {
        instance = createInstance(host)
        this.instances.set(key, instance)
        instance.subscriptions.push(instance.terminal.onData((data) => {
          if (canSendInput(instance)) {
            this.pushEvent("terminal_input", {
              ...instance.fence,
              data_base64: encodeTerminalBytes(data)
            })
          }
        }))
        instance.subscriptions.push(instance.terminal.onScroll((position) => {
          this.presentation.scroll[instance.terminalId] = position
          this.persistPresentation()
        }))
      }
      instance.panel = panel
      instance.terminalId = panel.dataset.terminalId
      instance.generation = panel.dataset.terminalGeneration
      instance.fence = commandFence(panel, this.el)
      instance.controller = panel.dataset.terminalController === "true"
      instance.resynced = panel.dataset.terminalResynced === "true"
      const scrollPosition = this.presentation.scroll[instance.terminalId]
      if (Number.isInteger(scrollPosition)) instance.terminal.scrollToLine(scrollPosition)
      this.fit(panel, instance)
    })
    this.instances.forEach((instance, key) => {
      if (!seen.has(key)) {
        this.disposeInstance(instance)
        this.instances.delete(key)
      }
    })
  },
  write(frame, options = {}) {
    const instance = this.instances.get(terminalKey(frame.terminal_id, frame.generation))
    const data = frame.data_base64 ? decodeTerminalBytes(frame.data_base64) : frame.data
    const validData = typeof data === "string" || data instanceof Uint8Array
    if (!instance || !validData) return

    const visible = this.presentation.panelOpen && !instance.panel?.hidden
    if (!visible) {
      this.presentation.unread[instance.terminalId] = true
      this.persistPresentation()
      this.applyPresentation()
    }

    if (options.reset) instance.terminal.reset()
    instance.terminal.write(data, () => afterPaint(() => {
      if (this.presentation.panelOpen && !instance.panel?.hidden) {
        this.presentation.unread[instance.terminalId] = false
        this.persistPresentation()
        this.applyPresentation()
      }
      this.pushEvent("terminal_rendered", {
        terminal_id: frame.terminal_id,
        generation: frame.generation,
        ...instance.fence,
        sequence: frame.sequence
      })
    }))
  },
  setControl(frame) {
    const instance = this.instances.get(terminalKey(frame.terminal_id, frame.generation))
    if (instance) {
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
    if (instance) instance.resynced = frame.resynced === true
  },
  fit(panel, instance) {
    if (!canResize(panel, instance)) return
    instance.fit.fit()
    const size = { cols: instance.terminal.cols, rows: instance.terminal.rows }
    if (size.cols <= 0 || size.rows <= 0 || (instance.lastSize && size.cols === instance.lastSize.cols && size.rows === instance.lastSize.rows)) return
    instance.lastSize = size
    this.pushEvent("terminal_resize", { ...instance.fence, ...size })
  },
  disposeInstance(instance) {
    if (instance.disposed) return
    instance.disposed = true
    instance.subscriptions.forEach((subscription) => subscription.dispose())
    instance.terminal.dispose()
  }
}
