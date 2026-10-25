// The VM's log (`Vm.Log`): follows the end as lines arrive, unless the user
// scrolled up to read — then it stays put until they come back down.

export const LogTail = {
  mounted() {
    this.follow = true
    this.el.addEventListener("scroll", () => {
      this.follow = this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight < 24
    })
    this.el.scrollTop = this.el.scrollHeight
  },

  updated() {
    if (this.follow) this.el.scrollTop = this.el.scrollHeight
  },
}
