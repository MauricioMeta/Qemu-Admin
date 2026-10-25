// The Terminal's top edge (`#terminal-resizer`): drag up or down to resize it,
// double-click to bring back the default height.
//
// Like the side panel's width (`PanelResizer`), the height lives in
// `--terminal-h` on <html>, which a LiveView re-render never touches; it is kept
// in localStorage and root.html.heex applies it before the first paint.

export const TERMINAL_HEIGHT_KEY = "qa:terminal-h"
const MIN = 120

const clamp = (h) => Math.round(Math.min(Math.max(h, MIN), window.innerHeight * 0.8))

function setHeight(px) {
  document.documentElement.style.setProperty("--terminal-h", `${px}px`)
}

export const DockResizer = {
  mounted() {
    this.el.addEventListener("pointerdown", (e) => {
      if (e.button !== 0) return
      e.preventDefault()
      const dock = this.el.parentElement
      const startY = e.clientY
      const startH = dock.getBoundingClientRect().height
      this.el.setPointerCapture(e.pointerId)
      document.body.classList.add("qa-resizing-row")

      const move = (ev) => setHeight(clamp(startH + (startY - ev.clientY)))
      const up = () => {
        this.el.removeEventListener("pointermove", move)
        this.el.removeEventListener("pointerup", up)
        this.el.removeEventListener("pointercancel", up)
        document.body.classList.remove("qa-resizing-row")
        try {
          localStorage.setItem(TERMINAL_HEIGHT_KEY, String(Math.round(dock.getBoundingClientRect().height)))
        } catch (_e) {}
      }

      this.el.addEventListener("pointermove", move)
      this.el.addEventListener("pointerup", up)
      this.el.addEventListener("pointercancel", up)
    })

    this.el.addEventListener("dblclick", () => {
      document.documentElement.style.removeProperty("--terminal-h")
      try {
        localStorage.removeItem(TERMINAL_HEIGHT_KEY)
      } catch (_e) {}
    })
  },
}
