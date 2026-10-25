// The side panel's right edge (`#side-panel-resizer`): drag to resize the
// panel, double-click to bring back the default width.
//
// The width lives in `--side-panel-w` on <html>, not on the panel: LiveView
// never patches <html>, so a re-render cannot undo it, and the panel (drawn
// again when it switches between VMs and Configurações) picks it up as it
// is. Kept in localStorage; root.html.heex applies it before the first paint.

export const PANEL_WIDTH_KEY = "qa:side-panel-w"
const MIN = 200
const MAX = 720

const clamp = (w) => Math.round(Math.min(Math.max(w, MIN), Math.min(MAX, window.innerWidth * 0.6)))

function setWidth(px) {
  document.documentElement.style.setProperty("--side-panel-w", `${px}px`)
}

export const PanelResizer = {
  mounted() {
    this.el.addEventListener("pointerdown", (e) => {
      if (e.button !== 0) return
      e.preventDefault()
      const panel = this.el.parentElement
      const left = panel.getBoundingClientRect().left
      this.el.setPointerCapture(e.pointerId)
      document.body.classList.add("qa-resizing")

      const move = (ev) => setWidth(clamp(ev.clientX - left))
      const up = () => {
        this.el.removeEventListener("pointermove", move)
        this.el.removeEventListener("pointerup", up)
        this.el.removeEventListener("pointercancel", up)
        document.body.classList.remove("qa-resizing")
        try {
          localStorage.setItem(PANEL_WIDTH_KEY, String(Math.round(panel.getBoundingClientRect().width)))
        } catch (_e) {}
      }

      this.el.addEventListener("pointermove", move)
      this.el.addEventListener("pointerup", up)
      this.el.addEventListener("pointercancel", up)
    })

    this.el.addEventListener("dblclick", () => {
      document.documentElement.style.removeProperty("--side-panel-w")
      try {
        localStorage.removeItem(PANEL_WIDTH_KEY)
      } catch (_e) {}
    })
  },
}
