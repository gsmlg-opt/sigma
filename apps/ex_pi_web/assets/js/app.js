import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import topbar from "topbar"
import * as DuskmoonHooks from "phoenix_duskmoon/hooks"

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

let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")

let liveSocket = new LiveSocket("/live", Socket, {
  params: {_csrf_token: csrfToken},
  hooks: { ...DuskmoonHooks, ModalHook }
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
