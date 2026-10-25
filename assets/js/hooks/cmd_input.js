// The command panel's prompt (`Vm.Commands`): the arrow keys walk through what
// was sent before (`data-history`, oldest first) so it can be edited and sent
// again; the field is cleared once a command is submitted.

export const CmdInput = {
  mounted() {
    this.pos = null // index in the history while browsing, null when typing
    this.draft = ""

    this.el.addEventListener("keydown", (e) => {
      const history = this.history()
      if (e.key === "ArrowUp" && history.length > 0) {
        e.preventDefault()
        if (this.pos === null) {
          this.draft = this.el.value
          this.pos = history.length
        }
        this.pos = Math.max(0, this.pos - 1)
        this.el.value = history[this.pos]
      } else if (e.key === "ArrowDown" && this.pos !== null) {
        e.preventDefault()
        this.pos += 1
        if (this.pos >= history.length) {
          this.pos = null
          this.el.value = this.draft
        } else {
          this.el.value = history[this.pos]
        }
      } else if (e.key !== "ArrowUp" && e.key !== "ArrowDown") {
        this.pos = null
      }
    })

    this.el.form.addEventListener("submit", () => {
      // the value has been read by the time the event reaches the server
      setTimeout(() => {
        this.el.value = ""
        this.pos = null
      }, 0)
    })
  },

  history() {
    try {
      return JSON.parse(this.el.dataset.history || "[]")
    } catch (_) {
      return []
    }
  },
}
