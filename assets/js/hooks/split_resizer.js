// A strip between two columns (`.split-resizer`, a grid track of its own): drag
// to give one column more width than the other, double-click for the default.
//
//   data-var  the CSS variable the grid reads, on <html>: the left column's share
//             as `fr` (the right one is 1fr) — `--overview-split`
//   data-key  the localStorage key it is kept under (root.html.heex applies it
//             before the first paint, as the side panel's width)
//
// The share lives on <html>, which a LiveView re-render never touches.

const MIN_SHARE = 0.4 // each column keeps at least 1/3.5 of the width
const MAX_SHARE = 2.5

export const SplitResizer = {
  mounted() {
    const {var: cssVar, key} = this.el.dataset

    this.el.addEventListener("pointerdown", (e) => {
      if (e.button !== 0) return
      const left = this.el.previousElementSibling
      const right = this.el.nextElementSibling
      if (!left || !right) return
      e.preventDefault()

      const startX = e.clientX
      const leftW = left.getBoundingClientRect().width
      const total = leftW + right.getBoundingClientRect().width
      this.el.setPointerCapture(e.pointerId)
      document.body.classList.add("qa-resizing")

      let share = leftW / (total - leftW)
      const move = (ev) => {
        const w = Math.min(Math.max(leftW + (ev.clientX - startX), total * 0.22), total * 0.78)
        share = Math.min(Math.max(w / (total - w), MIN_SHARE), MAX_SHARE)
        document.documentElement.style.setProperty(cssVar, `${share.toFixed(3)}fr`)
      }
      const up = () => {
        this.el.removeEventListener("pointermove", move)
        this.el.removeEventListener("pointerup", up)
        this.el.removeEventListener("pointercancel", up)
        document.body.classList.remove("qa-resizing")
        try {
          localStorage.setItem(key, `${share.toFixed(3)}fr`)
        } catch (_e) {}
      }

      this.el.addEventListener("pointermove", move)
      this.el.addEventListener("pointerup", up)
      this.el.addEventListener("pointercancel", up)
    })

    this.el.addEventListener("dblclick", () => {
      document.documentElement.style.removeProperty(cssVar)
      try {
        localStorage.removeItem(key)
      } catch (_e) {}
    })
  },
}
