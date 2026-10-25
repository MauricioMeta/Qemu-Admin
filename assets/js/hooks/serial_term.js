// An ESP32's UART in the page (`Vm.SerialConsole`): xterm.js fed by the
// VmServer, which holds QEMU's serial socket (see `QemuAdmin.Vm.Args`).
//
// On mount it asks for what was printed so far (`serial_init` → the bytes
// and the run's byte count), then follows `qa:serial` events, each carrying
// where its bytes start in the run's output — a chunk that overlaps what the
// buffer already had is trimmed, so nothing shows twice. Bytes travel as
// base64: the UART is not UTF-8 by contract, and a multi-byte character may
// be split across chunks (xterm reassembles it).
//
// Typing goes back as `serial_input` while the VM runs (`data-live`). The
// element id carries the run, so a restart mounts a fresh terminal.
//   qa:serial-clear → clears the screen

import {Terminal} from "@xterm/xterm"
import {FitAddon} from "@xterm/addon-fit"

const decode = (b64) => Uint8Array.from(atob(b64), (c) => c.charCodeAt(0))

const css = (name, fallback) =>
  getComputedStyle(document.documentElement).getPropertyValue(name).trim() || fallback

export const SerialTerm = {
  mounted() {
    this.vmId = this.el.dataset.vmId
    this.offset = null
    this.pending = []

    this.term = new Terminal({
      convertEol: true,
      cursorBlink: true,
      fontFamily: 'ui-monospace, "Cascadia Mono", Consolas, monospace',
      fontSize: 13,
      scrollback: 10000,
      theme: {
        background: "#0c0a09",
        foreground: "#e7e5e4",
        cursor: css("--color-primary", "#f97316"),
        selectionBackground: "#f9731655",
      },
    })
    this.fit = new FitAddon()
    this.term.loadAddon(this.fit)
    this.term.open(this.el.querySelector("[data-term]"))
    this.refit()

    this.resizer = new ResizeObserver(() => this.refit())
    this.resizer.observe(this.el)

    this.term.onData((data) => {
      if (this.el.dataset.live === "1") this.pushEvent("serial_input", {id: this.vmId, data})
    })

    this.onClear = () => this.term.clear()
    window.addEventListener("qa:serial-clear", this.onClear)

    this.handleEvent("qa:serial", ({id, offset, data}) => {
      if (id !== this.vmId) return
      if (this.offset === null) this.pending.push({offset, data})
      else this.append(offset, decode(data))
    })

    this.pushEvent("serial_init", {id: this.vmId}, ({data, total}) => {
      const bytes = decode(data)
      this.term.write(bytes)
      this.offset = total
      this.pending.forEach(({offset, data}) => this.append(offset, decode(data)))
      this.pending = []
      if (this.el.dataset.live === "1") this.term.focus()
    })
  },

  append(offset, bytes) {
    const skip = this.offset - offset
    if (skip >= bytes.length) return
    this.term.write(skip > 0 ? bytes.subarray(skip) : bytes)
    this.offset = offset + bytes.length
  },

  refit() {
    try {
      this.fit.fit()
    } catch (_e) {}
  },

  destroyed() {
    window.removeEventListener("qa:serial-clear", this.onClear)
    this.resizer?.disconnect()
    this.term?.dispose()
  },
}
