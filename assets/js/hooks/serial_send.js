// The send bar under a board's serial terminal (`Vm.SerialConsole`): a line of
// text and what ends it, sent to the UART as `serial_input` — the same event the
// terminal's own keystrokes use, so the server has one way in.
//
//   form  [data-vm-id]            the hook's element
//   input [name=text]             the line; Enter sends, ↑ / ↓ walk the history
//   select[name=eol]              "" (nothing) | "\n" | "\r" | "\r\n", as JSON-free
//                                 names: none, lf, cr, crlf
//
// What was sent (per VM) and the chosen ending are kept in localStorage; the
// page works without it. Nothing is echoed here: the firmware answers on the
// UART, and the terminal above shows that.

const EOL = {none: "", lf: "\n", cr: "\r", crlf: "\r\n"}
const KEEP = 100

const load = (key, fallback) => {
  try {
    return JSON.parse(localStorage.getItem(key)) ?? fallback
  } catch (_) {
    return fallback
  }
}

const save = (key, value) => {
  try {
    localStorage.setItem(key, JSON.stringify(value))
  } catch (_) {}
}

export const SerialSend = {
  mounted() {
    this.vmId = this.el.dataset.vmId
    this.input = this.el.querySelector("[name=text]")
    this.eol = this.el.querySelector("[name=eol]")
    this.histKey = `qa:serial-history:${this.vmId}`
    this.history = load(this.histKey, [])
    this.pos = this.history.length

    const stored = load("qa:serial-eol", null)
    if (stored && stored in EOL) this.eol.value = stored
    this.eol.addEventListener("change", () => save("qa:serial-eol", this.eol.value))

    this.el.addEventListener("submit", (e) => {
      e.preventDefault()
      this.send()
    })

    this.input.addEventListener("keydown", (e) => {
      if (e.key === "ArrowUp" && this.pos > 0) {
        e.preventDefault()
        this.input.value = this.history[--this.pos]
      } else if (e.key === "ArrowDown" && this.pos < this.history.length) {
        e.preventDefault()
        this.pos++
        this.input.value = this.history[this.pos] ?? ""
      }
    })
  },

  send() {
    const text = this.input.value
    const data = text + (EOL[this.eol.value] ?? "")
    if (data === "") return

    this.pushEvent("serial_input", {id: this.vmId, data})

    if (text !== "" && this.history[this.history.length - 1] !== text) {
      this.history.push(text)
      this.history = this.history.slice(-KEEP)
      save(this.histKey, this.history)
    }
    this.pos = this.history.length
    this.input.value = ""
  },
}
