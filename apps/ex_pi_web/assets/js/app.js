import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import topbar from "topbar"
import * as DuskmoonHooks from "phoenix_duskmoon/hooks"

import "@duskmoon-dev/el-button/register"
import "@duskmoon-dev/el-card/register"
import "@duskmoon-dev/el-chat/register"
import "@duskmoon-dev/el-dialog/register"
import "@duskmoon-dev/el-input/register"
import "@duskmoon-dev/el-menu/register"
import "@duskmoon-dev/el-badge/register"
import "@duskmoon-dev/el-chip/register"
import "@duskmoon-dev/el-autocomplete/register"

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

let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")

let liveSocket = new LiveSocket("/live", Socket, {
  params: {_csrf_token: csrfToken},
  hooks: { ...DuskmoonHooks, ModalHook, ScrollBottom, AutocompleteHook }
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
