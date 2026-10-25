// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import topbar from "../vendor/topbar"
import {PanelResizer} from "./hooks/panel_resizer"
import {VncConsole} from "./hooks/vnc_console"
import {WindowControls} from "./hooks/window_controls"
import {TabBar} from "./hooks/tab_bar"
import {LogTail} from "./hooks/log_tail"
import {SerialTerm} from "./hooks/serial_term"
import {CmdInput} from "./hooks/cmd_input"
import {CmdLog} from "./hooks/cmd_log"

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
// WebSocket only, no long-poll fallback: the app runs on localhost, where
// the socket is always there (the Rockwell Viewer's reasoning). Forget any
// fallback memorized before.
try {
  sessionStorage.removeItem("phx:fallback:LongPoll")
} catch (_e) {}

const liveSocket = new LiveSocket("/live", Socket, {
  params: {_csrf_token: csrfToken},
  hooks: {PanelResizer, VncConsole, WindowControls, TabBar, LogTail, SerialTerm, CmdInput, CmdLog},
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#f97316"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", (_info) => topbar.show(300))
window.addEventListener("phx:page-loading-stop", (_info) => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// A menu item gives up focus after acting, so a CSS (focus) dropdown closes.
window.addEventListener("qa:blur", (e) => e.target.blur())

// Copy a text to the clipboard (the command line on the overview).
window.addEventListener("qa:copy", (e) => {
  const text = e.target.dataset.copy
  if (text) navigator.clipboard?.writeText(text)
})

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
window.liveSocket = liveSocket

if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    reloader.enableServerLogs()
    window.liveReloader = reloader
  })
}
