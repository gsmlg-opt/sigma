import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import topbar from "topbar"
import * as DuskmoonHooks from "phoenix_duskmoon/hooks"
import { marked } from "marked"
import DOMPurify from "dompurify"

import "@duskmoon-dev/el-button/register"
import "@duskmoon-dev/el-card/register"
import "@duskmoon-dev/el-dialog/register"
import "@duskmoon-dev/el-input/register"
import "@duskmoon-dev/el-menu/register"
import "@duskmoon-dev/el-badge/register"
import "@duskmoon-dev/el-chip/register"

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

// Scroll to bottom when new stream items arrive, unless the user has scrolled up
const ScrollBottom = {
  mounted() {
    this.scrollToBottom()
    this.observer = new MutationObserver(() => {
      if (this.isNearBottom()) this.scrollToBottom()
    })
    this.observer.observe(this.el, { childList: true, subtree: true })
  },
  destroyed() {
    if (this.observer) this.observer.disconnect()
  },
  scrollToBottom() {
    this.el.scrollTop = this.el.scrollHeight
  },
  isNearBottom() {
    return this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight < 300
  }
}

// Multi-line markdown-friendly chat input.
// Enter submits the form. Shift+Enter inserts a newline.
// Auto-resizes vertically as the user types, up to a max height.
const ChatInput = {
  mounted() {
    this.autoresize()
    this.el.addEventListener("input", () => this.autoresize())
    this.el.addEventListener("keydown", (e) => {
      if (e.key === "Enter" && !e.shiftKey && !e.isComposing) {
        e.preventDefault()
        const form = this.el.form
        if (form) form.requestSubmit()
      }
    })
  },
  updated() { this.autoresize() },
  autoresize() {
    this.el.style.height = "auto"
    const max = 200
    this.el.style.height = Math.min(this.el.scrollHeight, max) + "px"
  }
}

// Parse markdown from data-content and render sanitized HTML.
const MarkdownContent = {
  mounted() { this.render() },
  updated() { this.render() },
  render() {
    const raw = this.el.dataset.content
    if (raw) {
      const html = DOMPurify.sanitize(marked.parse(raw))
      this.el.innerHTML = html
    }
  }
}

let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")

let liveSocket = new LiveSocket("/live", Socket, {
  params: {_csrf_token: csrfToken},
  hooks: { ...DuskmoonHooks, ModalHook, ScrollBottom, MarkdownContent, ChatInput }
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
