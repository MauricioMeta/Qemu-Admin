// The command panel's history (`Vm.Commands`): follows the end as entries
// arrive, like the log (`LogTail`), and shows each entry's time (sent as UTC
// in `data-utc`) in the user's own time zone.

export const CmdLog = {
  mounted() {
    this.follow = true
    this.el.addEventListener("scroll", () => {
      this.follow = this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight < 24
    })
    this.localize()
    this.el.scrollTop = this.el.scrollHeight
  },

  updated() {
    this.localize()
    if (this.follow) this.el.scrollTop = this.el.scrollHeight
  },

  localize() {
    this.el.querySelectorAll("[data-utc]").forEach((span) => {
      const t = new Date(span.dataset.utc)
      if (!isNaN(t)) {
        span.textContent = t.toLocaleTimeString([], {hour12: false})
        span.title = t.toLocaleString()
      }
    })
  },
}
