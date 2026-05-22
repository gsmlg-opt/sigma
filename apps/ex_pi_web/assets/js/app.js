import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import topbar from "topbar"
import * as DuskmoonHooks from "phoenix_duskmoon/hooks"

import "@duskmoon-dev/elements/register"
import "@duskmoon-dev/el-chat/register"
import "@duskmoon-dev/el-markdown-input/register"

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

// Auto-show dialogs when they mount
const ModalHook = {
  mounted() {
    if (typeof this.el.show === 'function') {
      this.el.show();
    } else {
      this.el.setAttribute('open', '');
    }
  }
};

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

// Adds Cmd+Enter support to el-dm-chat-input (which only handles Ctrl+Enter natively).
// Use: phx-hook="CmdEnterHook" on a wrapper element containing the el-dm-chat-input.
const CmdEnterHook = {
  mounted() {
    this._chatInput = this.el.querySelector('el-dm-chat-input')
    if (!this._chatInput) return
    this._keyHandler = (e) => {
      if (e.key === 'Enter' && e.metaKey && !e.shiftKey) {
        e.preventDefault()
        this._chatInput._send()
      }
    }
    this._chatInput.addEventListener('keydown', this._keyHandler)
  },
  destroyed() {
    if (this._chatInput && this._keyHandler) {
      this._chatInput.removeEventListener('keydown', this._keyHandler)
    }
  }
}

// Scroll to bottom when new stream items arrive, unless the user has scrolled up
const ScrollBottom = {
  mounted() {
    this.atBottom = true
    this.el.addEventListener("scroll", () => {
      const {scrollTop, scrollHeight, clientHeight} = this.el
      this.atBottom = (scrollHeight - scrollTop - clientHeight < 50)
    })

    this.observer = new MutationObserver(() => {
      if (this.atBottom) this.scrollToBottom()
    })
    this.observer.observe(this.el, { childList: true, subtree: true })
    this.scrollToBottom()
  },
  updated() {
    if (this.atBottom) this.scrollToBottom()
  },
  destroyed() {
    if (this.observer) this.observer.disconnect()
  },
  scrollToBottom() {
    this.el.scrollTo({ top: this.el.scrollHeight, behavior: 'auto' })
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

let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")

let liveSocket = new LiveSocket("/live", Socket, {
  params: {_csrf_token: csrfToken},
  hooks: { ...DuskmoonHooks, ModalHook, ScrollBottom, AutocompleteHook, SessionMenuHook, CmdEnterHook, MarkdownInputHook, LocalTime }
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
