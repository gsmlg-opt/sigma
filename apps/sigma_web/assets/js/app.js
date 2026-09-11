import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import topbar from "topbar"
import * as DuskmoonHooks from "phoenix_duskmoon/hooks"
import { encodeImageFiles } from "./chat_attachments.js"
import { shouldClearComposer } from "./chat_submission.js"
import { formatElapsedTime, formatRelativeTime } from "./session_time.js"
import { SessionTerminals } from "./hooks/session_terminals.js"

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

const DEFAULT_SLASH_COMMANDS = [
  { value: '/init', label: '/init', description: 'Create or update AGENTS.md' }
]
const SLASH_COMMAND_MENU_KEYS = ['ArrowDown', 'ArrowUp', 'Enter', 'Tab', 'Escape']

// Adds Cmd/Ctrl+Enter support and slash-command completion to el-dm-chat-input.
// Use: phx-hook="ChatInputHook" on a wrapper element containing the el-dm-chat-input.
const ChatInputHook = {
  mounted() {
    this._chatInput = this.el.querySelector('el-dm-chat-input')
    if (!this._chatInput) return
    this._commands = this._parseCommands()
    this._submitting = false
    this._filteredCommands = []
    this._activeIndex = 0
    this._editorBindings = []
    this._draftKey = `sigma:composer-draft:${window.location.pathname}`
    this._buildMenu()

    this._keyHandler = (e) => {
      if (this._menuOpen && SLASH_COMMAND_MENU_KEYS.includes(e.key)) {
        this._handleMenuKey(e)
        return
      }

      if (e.key === 'Enter' && (e.metaKey || e.ctrlKey) && !e.shiftKey) {
        e.preventDefault()
        this._chatInput._send()
      }
    }
    this._inputHandler = () => {
      this._persistDraft()
      this._syncMenu()
    }
    this._editorKeyHandler = (e) => {
      if (this._menuOpen && SLASH_COMMAND_MENU_KEYS.includes(e.key)) {
        this._handleMenuKey(e)
      }
    }
    this._clickAwayHandler = (e) => {
      if (!this.el.contains(e.target)) this._closeMenu()
    }

    this._chatInput.addEventListener('keydown', this._keyHandler)
    this._sendHandler = (e) => this._handleSend(e)
    this._chatInput.addEventListener('send', this._sendHandler)
    this._chatInput.addEventListener('input', this._inputHandler)
    this._chatInput.addEventListener('keyup', this._inputHandler)
    this._chatInput.addEventListener('change', this._inputHandler)
    this._chatInput.addEventListener('focus', this._inputHandler)
    document.addEventListener('mousedown', this._clickAwayHandler)
    this._bindEditorEvents()
    this._editorObserver = new MutationObserver(() => this._bindEditorEvents())
    if (this._chatInput.shadowRoot) {
      this._editorObserver.observe(this._chatInput.shadowRoot, { childList: true, subtree: true })
    }
    this._editorFrame = window.requestAnimationFrame(() => {
      this._bindEditorEvents()
      this._restoreDraft()
    })
  },
  updated() {
    this._restoreDraft()
  },
  reconnected() {
    window.requestAnimationFrame(() => this._restoreDraft())
  },
  destroyed() {
    if (this._chatInput && this._keyHandler) {
      this._chatInput.removeEventListener('keydown', this._keyHandler)
      this._chatInput.removeEventListener('input', this._inputHandler)
      this._chatInput.removeEventListener('keyup', this._inputHandler)
      this._chatInput.removeEventListener('change', this._inputHandler)
      this._chatInput.removeEventListener('focus', this._inputHandler)
      this._chatInput.removeEventListener('send', this._sendHandler)
    }
    this._editorObserver?.disconnect()
    if (this._editorFrame) window.cancelAnimationFrame(this._editorFrame)
    this._clearEditorBindings()
    document.removeEventListener('mousedown', this._clickAwayHandler)
    this._menu?.remove()
  },
  _parseCommands() {
    try {
      const commands = JSON.parse(this.el.dataset.slashCommands || '[]')
      return Array.isArray(commands) && commands.length ? commands : DEFAULT_SLASH_COMMANDS
    } catch {
      return DEFAULT_SLASH_COMMANDS
    }
  },
  _buildMenu() {
    this._menu = document.createElement('div')
    this._menu.className = 'slash-command-menu hidden'
    this._menu.setAttribute('role', 'listbox')
    this._menu.setAttribute('aria-label', 'Slash commands')
    this.el.appendChild(this._menu)
  },
  _bindEditorEvents() {
    this._clearEditorBindings()

    const markdownInput = this._getMarkdownInput()
    const textarea = markdownInput?.shadowRoot?.querySelector('textarea')
    const targets = [markdownInput, textarea].filter(Boolean)

    targets.forEach((target) => {
      this._addEditorBinding(target, 'keydown', this._editorKeyHandler, { capture: true })
      this._addEditorBinding(target, 'input', this._inputHandler)
      this._addEditorBinding(target, 'change', this._inputHandler)
      this._addEditorBinding(target, 'keyup', this._inputHandler)
      this._addEditorBinding(target, 'focus', this._inputHandler, { capture: true })
    })
  },
  _addEditorBinding(target, event, handler, options = false) {
    target.addEventListener(event, handler, options)
    this._editorBindings.push({ target, event, handler, options })
  },
  _clearEditorBindings() {
    const bindings = this._editorBindings || []
    bindings.forEach(({ target, event, handler, options }) => {
      target.removeEventListener(event, handler, options)
    })
    this._editorBindings = []
  },
  _getMarkdownInput() {
    return this._chatInput?.shadowRoot?.querySelector('el-dm-markdown-input')
  },
  _getValue() {
    return this._chatInput.getValue?.() ?? this._chatInput.value ?? ''
  },
  _setValue(value) {
    if (typeof this._chatInput.setValue === 'function') {
      this._chatInput.setValue(value)
    } else {
      this._chatInput.value = value
    }
    this._chatInput.dispatchEvent(new Event('input', { bubbles: true, composed: true }))
  },
  _draftValue() {
    return this._getMarkdownInput()?.shadowRoot?.querySelector('textarea')?.value ?? this._getValue()
  },
  _persistDraft() {
    const value = this._draftValue()
    if (value) {
      window.sessionStorage.setItem(this._draftKey, value)
    } else {
      window.sessionStorage.removeItem(this._draftKey)
    }
  },
  _restoreDraft() {
    const draft = window.sessionStorage.getItem(this._draftKey)
    if (draft && !this._draftValue()) this._setValue(draft)
  },
  async _handleSend(event) {
    if (this._submitting) return

    const detail = event.detail || {}
    const value = typeof detail.value === 'string' ? detail.value : this._getValue()
    const files = detail.files || this._chatInput.getFiles?.() || []

    if (files.length && value.trim().startsWith('/')) {
      this.pushEvent("attachment_error", { code: "slash_command" })
      return
    }

    this._submitting = true
    const result = await encodeImageFiles(files)

    if (!result.ok) {
      this._submitting = false
      this.pushEvent("attachment_error", { code: result.code })
      return
    }

    this.pushEvent("send_prompt", { value, images: result.images }, (reply) => {
      if (shouldClearComposer(reply)) {
        this._setValue("")
        this._chatInput.clearFiles?.()
      }
      this._submitting = false
    })
  },
  _syncMenu() {
    const value = this._getValue()
    const shouldOpen = value.startsWith('/') && !/\s/.test(value)

    if (!shouldOpen) {
      this._closeMenu()
      return
    }

    const query = value.slice(1).toLowerCase()
    this._filteredCommands = this._commands.filter((command) => {
      return command.value.slice(1).toLowerCase().startsWith(query)
    })
    this._activeIndex = Math.min(this._activeIndex, Math.max(this._filteredCommands.length - 1, 0))

    if (this._filteredCommands.length === 0) {
      this._closeMenu()
      return
    }

    this._renderMenu()
    this._openMenu()
  },
  _renderMenu() {
    this._menu.innerHTML = this._filteredCommands.map((command, index) => {
      const active = index === this._activeIndex
      return `
        <button
          type="button"
          class="slash-command-item ${active ? 'is-active' : ''}"
          role="option"
          aria-selected="${active}"
          data-index="${index}"
        >
          <span class="slash-command-label">${command.label || command.value}</span>
          <span class="slash-command-description">${command.description || ''}</span>
        </button>
      `
    }).join('')

    this._menu.querySelectorAll('.slash-command-item').forEach((item) => {
      item.addEventListener('mousedown', (e) => {
        e.preventDefault()
        this._selectCommand(Number(item.dataset.index))
      })
    })

    this._menu.querySelector('.slash-command-item.is-active')?.scrollIntoView({ block: 'nearest' })
  },
  _handleMenuKey(e) {
    e.stopPropagation()

    if (e.key === 'Escape') {
      e.preventDefault()
      this._closeMenu()
      return
    }

    if (this._filteredCommands.length === 0) {
      e.preventDefault()
      this._closeMenu()
      return
    }

    if (e.key === 'ArrowDown') {
      e.preventDefault()
      this._activeIndex = (this._activeIndex + 1) % this._filteredCommands.length
      this._renderMenu()
      return
    }

    if (e.key === 'ArrowUp') {
      e.preventDefault()
      this._activeIndex =
        (this._activeIndex - 1 + this._filteredCommands.length) % this._filteredCommands.length
      this._renderMenu()
      return
    }

    if (e.key === 'Enter' || e.key === 'Tab') {
      e.preventDefault()
      this._selectCommand(this._activeIndex)
    }
  },
  _selectCommand(index) {
    const command = this._filteredCommands[index]
    if (!command) return
    this._setValue(`${command.value} `)
    this._closeMenu()
    this._focusInput()
    window.requestAnimationFrame(() => this._focusInput())
  },
  _focusInput() {
    this._chatInput.focus?.()
    const editor = this._getMarkdownInput()
    editor?.focus?.()
    editor?.shadowRoot?.querySelector('textarea')?.focus?.()
  },
  _openMenu() {
    this._menuOpen = true
    this._menu.classList.remove('hidden')
  },
  _closeMenu() {
    this._menuOpen = false
    this._menu?.classList.add('hidden')
  }
}

// Scroll to bottom when new stream items arrive, unless the user has scrolled up
const ScrollBottom = {
  mounted() {
    this.atBottom = true
    this.jumpButton = document.createElement('button')
    this.jumpButton.type = 'button'
    this.jumpButton.textContent = 'Jump to latest'
    this.jumpButton.setAttribute('aria-label', 'Jump to latest message')
    this.jumpButton.className = 'sigma-jump-to-latest hidden sticky bottom-3 z-10 mx-auto rounded-md border border-outline-variant bg-surface px-3 py-2 text-xs font-semibold text-on-surface shadow-lg'
    this.jumpButton.addEventListener('click', () => {
      this.atBottom = true
      this.scrollToBottom()
      this._renderJumpButton()
    })
    this._ensureJumpButton()

    this.el.addEventListener("scroll", () => {
      const {scrollTop, scrollHeight, clientHeight} = this.el
      this.atBottom = (scrollHeight - scrollTop - clientHeight < 50)
      this._ensureJumpButton()
      this._renderJumpButton()
    })

    this.observer = new MutationObserver(() => {
      this._ensureJumpButton()
      if (this.atBottom) {
        this.scrollToBottom()
      } else {
        this._renderJumpButton()
      }
    })
    this.observer.observe(this.el, { childList: true, subtree: true })
    this.scrollToBottom()
  },
  updated() {
    this._ensureJumpButton()
    if (this.atBottom) this.scrollToBottom()
  },
  destroyed() {
    if (this.observer) this.observer.disconnect()
    this.jumpButton?.remove()
  },
  scrollToBottom() {
    this.el.scrollTo({ top: this.el.scrollHeight, behavior: 'auto' })
  },
  _ensureJumpButton() {
    if (!this.jumpButton?.isConnected) this.el.appendChild(this.jumpButton)
  },
  _renderJumpButton() {
    this.jumpButton?.classList.toggle('hidden', this.atBottom)
  }
}

// Formats a server UTC millisecond timestamp as the client's local time.
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

let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")

let liveSocket = new LiveSocket("/live", Socket, {
  params: {_csrf_token: csrfToken},
  hooks: { ...DuskmoonHooks, ModalHook, ScrollBottom, AutocompleteHook, SessionMenuHook, ChatInputHook, MarkdownInputHook, AppearanceThemeHook, LocalTime, RelativeTime, ElapsedTime, SessionTerminals }
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
