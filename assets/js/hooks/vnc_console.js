// The VM's screen in the page (`Vm.Console`): noVNC talking to QEMU's own
// VNC WebSocket listener (`-vnc …,websocket=127.0.0.1:PORT`, see
// `QemuAdmin.Vm.Args`). Nothing in between — the page's origin and QEMU are
// both on loopback.
//
// The element carries `data-ws-port`; a new port (the VM restarted) means a
// new connection. Window events drive the toolbar buttons:
//   qa:vnc-cad        → Ctrl+Alt+Del
//   qa:vnc-fullscreen → the console fills the screen
//   qa:vnc-scale      → fit the window / native size
//
// noVNC fits the screen to its container when it connects and when the *window*
// resizes, but not when the container alone changes size (the Terminal folded or
// dragged, a view opened beside it): the screen then stays at the old scale, bigger
// than the room it has, and its top and left rows end up cut off and out of the
// pointer's reach. A ResizeObserver on the container sets `scaleViewport` again, which
// makes noVNC fit it anew.

import RFB from "@novnc/novnc"

const SCALE_KEY = "qa:vnc-scale"

export const VncConsole = {
  mounted() {
    this.screen = this.el.querySelector("[data-screen]")
    this.statusEl = this.el.querySelector("[data-status]")

    this.onCad = () => this.rfb?.sendCtrlAltDel()
    this.onFullscreen = () => this.el.requestFullscreen?.()
    this.onScale = () => {
      const scale = !(this.rfb?.scaleViewport ?? true)
      try {
        localStorage.setItem(SCALE_KEY, scale ? "1" : "0")
      } catch (_e) {}
      if (this.rfb) this.rfb.scaleViewport = scale
    }

    window.addEventListener("qa:vnc-cad", this.onCad)
    window.addEventListener("qa:vnc-fullscreen", this.onFullscreen)
    window.addEventListener("qa:vnc-scale", this.onScale)

    // (a timer, not requestAnimationFrame: a hidden window does not run those)
    this.refit = () => {
      clearTimeout(this.fitTimer)
      this.fitTimer = setTimeout(() => {
        if (this.rfb) this.rfb.scaleViewport = this.rfb.scaleViewport
      }, 30)
    }
    this.observer = new ResizeObserver(this.refit)
    this.observer.observe(this.screen)
    // and a look every so often, for where an observer is not delivered (a hidden or
    // embedded window): cheap, a size read
    this.lastSize = ""
    this.sizeTimer = setInterval(() => {
      const r = this.screen.getBoundingClientRect()
      const size = `${Math.round(r.width)}x${Math.round(r.height)}`
      if (size !== this.lastSize) {
        this.lastSize = size
        this.refit()
      }
    }, 400)
    this.connect()
  },

  updated() {
    if (this.el.dataset.wsPort !== this.port) this.connect()
  },

  destroyed() {
    window.removeEventListener("qa:vnc-cad", this.onCad)
    window.removeEventListener("qa:vnc-fullscreen", this.onFullscreen)
    window.removeEventListener("qa:vnc-scale", this.onScale)
    this.observer?.disconnect()
    clearInterval(this.sizeTimer)
    clearTimeout(this.fitTimer)
    this.disconnect()
  },

  connect() {
    this.disconnect()
    this.port = this.el.dataset.wsPort
    if (!this.port) return

    this.status("conectando…")
    const rfb = new RFB(this.screen, `ws://127.0.0.1:${this.port}`, {shared: true})
    let scale = true
    try {
      scale = localStorage.getItem(SCALE_KEY) !== "0"
    } catch (_e) {}
    rfb.scaleViewport = scale
    rfb.resizeSession = false
    rfb.focusOnClick = true
    rfb.background = "transparent"

    rfb.addEventListener("connect", () => {
      this.status("")
      this.retries = 0
      rfb.focus()
      this.refit()
    })
    // the guest changed its resolution: the screen is another size, fit it again
    rfb.addEventListener("desktopresize", () => this.refit?.())
    rfb.addEventListener("disconnect", (e) => {
      if (this.rfb !== rfb) return
      this.rfb = null
      // QEMU opens the listener a moment after it starts: try again a few
      // times before giving up.
      if (!e.detail.clean && (this.retries = (this.retries || 0) + 1) <= 20) {
        this.status("aguardando a VM…")
        this.timer = setTimeout(() => this.connect(), 500)
      } else {
        this.status("desconectado")
      }
    })
    rfb.addEventListener("desktopname", (e) => this.pushEvent("vnc_title", {title: e.detail.name}))
    this.rfb = rfb
  },

  disconnect() {
    clearTimeout(this.timer)
    const rfb = this.rfb
    this.rfb = null
    if (rfb) {
      try {
        rfb.disconnect()
      } catch (_e) {}
    }
    if (this.screen) this.screen.innerHTML = ""
  },

  status(text) {
    if (!this.statusEl) return
    this.statusEl.textContent = text
    this.statusEl.hidden = !text
  },
}
