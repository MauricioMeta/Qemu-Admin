// The app-drawn title bar's buttons (`App.TitleBar`), as in Eleuther.IO:
// minimize and maximize go straight to the window over Tauri's IPC.
//
// Close does not: it asks the page first (`window_close`), which confirms
// when VMs are running and answers `qa:close-window` once the window may go.
// The shell sends the same question when the window is closed from outside
// the bar (Alt+F4, the taskbar): `src-tauri/src/main.rs` dispatches
// `qa:close-requested` on the page instead of closing.

// The global comes from a script Tauri injects, which does not reliably beat
// this one (tauri-apps/tauri#12990) — so it is read per call.
const tauriWindow = () => window.__TAURI__?.window?.getCurrentWindow?.()

export const WindowControls = {
  mounted() {
    this.onClick = (event) => {
      const action = event.target.closest("[data-action]")?.dataset.action
      const appWindow = tauriWindow()
      if (!action || !appWindow) return

      if (action === "minimize") appWindow.minimize()
      if (action === "maximize") appWindow.toggleMaximize().then(() => this.sync())
      if (action === "close") this.askClose()
    }

    this.onResize = () => this.sync()
    this.onCloseRequested = () => this.askClose()

    this.el.addEventListener("click", this.onClick)
    window.addEventListener("resize", this.onResize)
    window.addEventListener("qa:close-requested", this.onCloseRequested)

    // `destroy` skips the CloseRequested the shell intercepts.
    this.handleEvent("qa:close-window", () => tauriWindow()?.destroy())
    this.settle()
  },

  destroyed() {
    window.removeEventListener("resize", this.onResize)
    window.removeEventListener("qa:close-requested", this.onCloseRequested)
  },

  // The server decides; but a page that cannot ask it (disconnected — the
  // server died — or no answer in 5 s) must not leave the window stuck open.
  askClose() {
    const destroy = () => tauriWindow()?.destroy()
    if (!this.liveSocket.isConnected()) return destroy()

    const timer = setTimeout(destroy, 5000)
    this.pushEvent("window_close", {}, () => clearTimeout(timer))
  },

  async sync() {
    const appWindow = tauriWindow()
    if (!appWindow) return false
    this.el.toggleAttribute("data-maximized", await appWindow.isMaximized())
    return true
  },

  // The first read can land before the global exists.
  async settle() {
    for (let attempt = 0; attempt < 10; attempt++) {
      if (await this.sync()) return
      await new Promise((resolve) => setTimeout(resolve, 150))
    }
  },
}
