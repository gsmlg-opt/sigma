import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import topbar from "topbar"
import * as DuskmoonHooks from "phoenix_duskmoon/hooks"
import { formatElapsedTime, formatRelativeTime } from "./session_time.js"
import { SessionPanels } from "./hooks/session_panels.js"
import { SessionTerminals } from "./hooks/session_terminals.js"
import { SigmaReactChat } from "./hooks/session_chat.js"

import "./duskmoon_elements.js"

// WORKAROUND(upstream): duskmoon-dev/duskmoon-elements#61
// Forces el-dm-markdown-input's `value` property to be a string on mount/update.
// LiveView's diff protocol can deliver the value as an array of template fragments
// instead of a joined string; this hook re-syncs from the HTML attribute, which is
// always a plain string, fixing the "[object Object]..." display bug.
const MarkdownInputHook = {
  mounted() { this._syncValue() },
  updated() { this._syncValue() },
  _syncValue() {
    const val = this.el.getAttribute('value') ?? ''
    if (this.el.value !== val) this.el.value = val
  }
}

// Mirrors phoenix_duskmoon's ThemeSwitcher hook for a radio-button group.
// Reads the active theme from localStorage (or "default") and reflects it on the
// form's radio inputs; on change, applies the theme via `data-theme` on <html>
// and persists the selection. Use: wrap a group of <input type="radio" name="theme"> in
// <form phx-hook="AppearanceThemeHook" id="appearance-theme-form">.
const darkQuery = window.matchMedia("(prefers-color-scheme: dark)")
function resolveAutoTheme() {
  return darkQuery.matches ? "moonlight" : "sunshine"
}

function applyAppearanceTheme(theme) {
  const resolved =
    !theme || theme === "default" ? resolveAutoTheme() : theme

  document.documentElement.setAttribute("data-theme", resolved)
}

// Apply the persisted theme on every page load (survives refresh/navigation),
// not just on the Appearance settings page. Replaces the appbar theme switcher
// which used to run on every page via its hook.
//
// The server renders <html data-theme> from the persisted config, so that value
// is authoritative. We re-apply it here so the theme switches instantly without
// waiting for the radio-group hook (which only mounts on the Appearance page).
// localStorage remains a client-side cache so the value survives round-trips
// while the checkbox state stays in sync.
const serverTheme = document.documentElement.getAttribute("data-theme")
applyAppearanceTheme(serverTheme || localStorage.getItem("theme") || "default")

const AppearanceThemeHook = {
  mounted() {
    this._change = (e) => {
      const theme = e.target.value
      localStorage.setItem("theme", theme)
      applyAppearanceTheme(theme)
      this.pushEvent("theme_changed", { theme })
    }
    this.el.addEventListener("change", this._change)
    this._applyStoredTheme()
    this._mediaListener = () => {
      // Only re-resolve auto mode when the OS color scheme changes
      const current = localStorage.getItem("theme") || "default"
      if (current === "default") this._applyStoredTheme()
    }
    darkQuery.addEventListener("change", this._mediaListener)
  },
  updated() { this._applyStoredTheme() },
  destroyed() {
    this.el.removeEventListener("change", this._change)
    darkQuery.removeEventListener("change", this._mediaListener)
  },
  _applyStoredTheme() {
    const stored = localStorage.getItem("theme") || "default"
    applyAppearanceTheme(stored)
    this.el.querySelectorAll('input[type="radio"][name="theme"]').forEach((input) => {
      input.checked = stored === input.value
    })
  }
}

// Forwards the composed `change` event from el-dm-autocomplete to LiveView.
// Use: phx-hook="AutocompleteHook" data-event="your_lv_event" name="field_name"
const AutocompleteHook = {
  mounted() {
    const eventName = this.el.dataset.event || "autocomplete_change"
    const fieldName = this.el.getAttribute("name") || "value"
    this._handler = (e) => {
      if (e.detail) this.pushEvent(eventName, { [fieldName]: e.detail.value })
    }
    this.el.addEventListener("change", this._handler)
  },
  destroyed() {
    this.el.removeEventListener("change", this._handler)
  }
}

// Polyfill for HTML Interest Invokers (`interestfor` attribute).
// Enables hover/focus triggering for native popovers across browsers that don't
// yet support the experimental Interest Invokers API natively.
function setupInterestInvokers() {
  let activeTarget = null
  let hideTimer = null

  const getTarget = (id) => {
    if (!id) return null
    return document.getElementById(id)
  }

  const supportsAnchor =
    typeof CSS !== 'undefined' &&
    CSS.supports &&
    (CSS.supports('anchor-name', '--foo') || CSS.supports('position-anchor', '--foo'))

  const showInterest = (invoker, targetId) => {
    if (hideTimer) {
      clearTimeout(hideTimer)
      hideTimer = null
    }

    const target = getTarget(targetId)
    if (!target || typeof target.showPopover !== 'function') return

    if (activeTarget && activeTarget !== target) {
      try {
        activeTarget.hidePopover()
      } catch (_) {}
    }

    try {
      if (!target.matches(':popover-open')) {
        target.showPopover()
      }

      if (!supportsAnchor && invoker) {
        const rect = invoker.getBoundingClientRect()
        target.style.position = 'fixed'
        target.style.top = `${rect.bottom + 8}px`
        target.style.left = `${Math.max(8, Math.min(rect.left, window.innerWidth - (target.offsetWidth || 300) - 8))}px`
      }

      activeTarget = target
    } catch (_) {}
  }

  const hideInterest = (targetId) => {
    if (hideTimer) clearTimeout(hideTimer)

    hideTimer = setTimeout(() => {
      const target = getTarget(targetId)
      if (target && typeof target.hidePopover === 'function') {
        try {
          if (target.matches(':popover-open')) {
            target.hidePopover()
          }
        } catch (_) {}
      }
      if (activeTarget === target) {
        activeTarget = null
      }
    }, 120)
  }

  document.addEventListener('mouseover', (e) => {
    const invoker = e.target.closest?.('[interestfor]')
    if (invoker) {
      showInterest(invoker, invoker.getAttribute('interestfor'))
      return
    }

    const popover = e.target.closest?.('[popover]')
    if (popover && popover.matches(':popover-open')) {
      if (hideTimer) {
        clearTimeout(hideTimer)
        hideTimer = null
      }
    }
  })

  document.addEventListener('mouseout', (e) => {
    const invoker = e.target.closest?.('[interestfor]')
    if (invoker) {
      const targetId = invoker.getAttribute('interestfor')
      const target = getTarget(targetId)
      const related = e.relatedTarget

      if (related && (invoker.contains(related) || (target && target.contains(related)))) {
        return
      }

      hideInterest(targetId)
      return
    }

    const popover = e.target.closest?.('[popover]')
    if (popover && popover.matches(':popover-open')) {
      const related = e.relatedTarget
      if (related && popover.contains(related)) {
        return
      }

      hideInterest(popover.id)
    }
  })

  document.addEventListener('focusin', (e) => {
    const invoker = e.target.closest?.('[interestfor]')
    if (invoker) {
      showInterest(invoker, invoker.getAttribute('interestfor'))
    }
  })

  document.addEventListener('focusout', (e) => {
    const invoker = e.target.closest?.('[interestfor]')
    if (invoker) {
      hideInterest(invoker.getAttribute('interestfor'))
    }
  })
}

if (typeof document !== 'undefined') {
  setupInterestInvokers()
}

// Auto-show dialogs when they mount
const ModalHook = {
  mounted() {
    this._show()
  },
  updated() {
    this._show()
  },
  _show() {
    if (typeof this.el.showModal === 'function') {
      if (!this.el.open) {
        this.el.showModal()
      } else if (!this.el.matches?.(':modal')) {
        this.el.close()
        this.el.showModal()
      }
    } else if (typeof this.el.show === 'function') {
      if (!this.el.open) {
        this.el.show()
      }
    } else {
      this.el.setAttribute('open', '')
    }
  }
}

// Drives el-dm-menu open/close from an anchor button and forwards select events to LiveView.
// Use: phx-hook="SessionMenuHook" data-session="session_id" anchor="#btn-id"
const SessionMenuHook = {
  mounted() {
    // Forward menu select events to LiveView
    this._selectHandler = (e) => {
      const session = this.el.dataset.session
      this.pushEvent("session_menu_action", { value: e.detail?.value, session })
    }
    this.el.addEventListener("select", this._selectHandler)

    // Wire anchor button click → menu toggle (el-dm-menu anchor is positioning-only)
    const anchorSel = this.el.getAttribute("anchor")
    this._anchorEl = anchorSel ? document.querySelector(anchorSel) : null
    if (this._anchorEl) {
      this._clickHandler = (e) => { e.stopPropagation(); this.el.toggle() }
      this._anchorEl.addEventListener("click", this._clickHandler)
    }
  },
  destroyed() {
    this.el.removeEventListener("select", this._selectHandler)
    if (this._anchorEl && this._clickHandler) {
      this._anchorEl.removeEventListener("click", this._clickHandler)
    }
  }
}

// Use: phx-hook="LocalTime" data-ts={milliseconds} id="unique-id"
const LocalTime = {
  mounted() { this._format() },
  updated() { this._format() },
  _format() {
    const ts = parseInt(this.el.dataset.ts)
    if (isNaN(ts)) return
    const d = new Date(ts)
    const pad = (n, z = 2) => String(n).padStart(z, '0')
    this.el.textContent = `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}.${pad(d.getMilliseconds(), 3)}`
  }
}

const RelativeTime = {
  mounted() {
    this._render = () => {
      this.el.textContent = formatRelativeTime(this.el.dataset.ts)
    }
    this._render()
    this._timer = window.setInterval(this._render, 1_000)
  },
  updated() { this._render?.() },
  destroyed() { window.clearInterval(this._timer) }
}

const ElapsedTime = {
  mounted() {
    this._render = () => {
      this.el.textContent = formatElapsedTime(this.el.dataset.ts)
    }
    this._render()
    this._timer = window.setInterval(this._render, 1_000)
  },
  updated() { this._render?.() },
  destroyed() { window.clearInterval(this._timer) }
}

// Triggers title rename mode via double-click or long-press on touch devices.
// Use: phx-hook="SessionTitleDblClick" data-session-id="session_id"
const SessionTitleDblClick = {
  mounted() {
    this._pressTimer = null
    const trigger = () => {
      this._clearPressTimer()
      const id = this.el?.dataset?.sessionId
      if (id) {
        this.pushEvent("start_rename_title", { id })
      }
    }
    this._clearPressTimer = () => {
      if (this._pressTimer) {
        clearTimeout(this._pressTimer)
        this._pressTimer = null
      }
    }
    this._dblHandler = (e) => {
      e.stopPropagation()
      e.preventDefault()
      trigger()
    }
    this._touchStart = () => {
      this._clearPressTimer()
      this._pressTimer = setTimeout(trigger, 500)
    }
    this._touchEnd = () => {
      this._clearPressTimer()
    }
    this.el.addEventListener("dblclick", this._dblHandler)
    this.el.addEventListener("touchstart", this._touchStart, { passive: true })
    this.el.addEventListener("touchmove", this._touchEnd, { passive: true })
    this.el.addEventListener("touchend", this._touchEnd)
    this.el.addEventListener("touchcancel", this._touchEnd)
  },
  destroyed() {
    this._clearPressTimer?.()
    this.el.removeEventListener("dblclick", this._dblHandler)
    this.el.removeEventListener("touchstart", this._touchStart)
    this.el.removeEventListener("touchmove", this._touchEnd)
    this.el.removeEventListener("touchend", this._touchEnd)
    this.el.removeEventListener("touchcancel", this._touchEnd)
  }
}

let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")

let liveSocket = new LiveSocket("/live", Socket, {
  params: {_csrf_token: csrfToken},
  hooks: { ...DuskmoonHooks, ModalHook, AutocompleteHook, SessionMenuHook, SigmaReactChat, MarkdownInputHook, AppearanceThemeHook, LocalTime, RelativeTime, ElapsedTime, SessionPanels, SessionTerminals, SessionTitleDblClick }
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket
