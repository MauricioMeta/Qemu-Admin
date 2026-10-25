// The open VMs' tab bar (`App.Tabs`): a middle click closes a tab, as in a
// browser or Obsidian.

export const TabBar = {
  mounted() {
    this.el.addEventListener("auxclick", (e) => {
      if (e.button !== 1) return
      const tab = e.target.closest("[data-tab-id]")
      if (!tab) return
      e.preventDefault()
      this.pushEvent("close_tab", {id: tab.dataset.tabId})
    })
    // no autoscroll cursor on middle press
    this.el.addEventListener("mousedown", (e) => e.button === 1 && e.preventDefault())
  },
}
