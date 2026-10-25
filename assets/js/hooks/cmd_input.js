// The Terminal's prompt (`Vm.Terminal`).
//
//  * History: with no suggestions open, ↑/↓ walk through what was sent before
//    (`data-history`, oldest first) so it can be edited and sent again.
//  * Suggestions: as you type, the commands of QEMU (priv/terminal/commands.json,
//    served at /terminal/commands.json) that fit, each with its usage and
//    description — monitor commands (`info registers`), QMP commands (picked in
//    the plain prompt they become `{"execute": "..."}`), the saved commands (the
//    names in terminal.json, `data-saved`, listed first), the QEMU tools that need
//    no VM running (qemu-img, qemu-io, qemu-system-* -machine help…) and, inside a QMP
//    message, the command's names and arguments. ↑/↓ choose, Tab accepts, Esc
//    closes, Enter sends what is typed (or accepts, once an item was chosen
//    with the arrows); a click accepts too.

const MAX_ROWS = 100 // `info ` alone has 70
const MAX_LOOSE = 5 // QMP names that only contain what is typed

let catalogPromise = null

function loadCatalog() {
  catalogPromise ||= fetch("/terminal/commands.json")
    .then((r) => (r.ok ? r.json() : null))
    .then((c) => (c ? prepare(c) : null))
    .catch(() => null)
  return catalogPromise
}

function prepare(c) {
  const hmp = c.hmp.map((e) => ({
    kind: "hmp",
    name: e.name,
    usage: e.usage || "",
    description: e.description || "",
    aliases: e.aliases || [],
  }))
  const qmp = c.qmp.map((e) => ({
    kind: "qmp",
    name: e.name,
    description: e.description || "",
    args: e.arguments || [],
    since: e.since,
    returns: e.returns,
  }))
  const tools = (c.tools || []).map((e) => ({
    kind: "tool",
    name: e.name,
    usage: e.usage || "",
    description: e.description || "",
    aliases: [],
  }))
  // every way of calling a monitor command or a tool, longest first, for the usage hint
  const hmpNames = [...hmp, ...tools]
    .flatMap((e) => [e.name, ...e.aliases].map((n) => [n.toLowerCase(), e]))
    .sort((a, b) => b[0].length - a[0].length)
  return {hmp, tools, qmp, hmpNames, byQmp: new Map(qmp.map((e) => [e.name, e]))}
}

// ------------------------------------------------------------- suggestions

function qmpSkeleton(entry) {
  const required = entry.args.filter((a) => a.required)
  if (required.length === 0) return `{"execute": "${entry.name}"}`
  const args = required.map((a) => `"${a.name}": ${placeholder(a)}`).join(", ")
  return `{"execute": "${entry.name}", "arguments": {${args}}}`
}

function placeholder(arg) {
  if (arg.type === "int" || arg.type === "number" || arg.type === "size") return "0"
  if (arg.type === "bool") return "true"
  return '""'
}

// what to offer for `text` (the caret at its end): {items, hint}
//   item: {entry, apply: {text, caret}}, hint: an entry to describe even with no list
function suggest(cat, text, saved) {
  const trimmed = text.trimStart()
  if (trimmed === "") return {items: [], hint: null}

  if (trimmed.startsWith("{")) return suggestJson(cat, text)

  const p = trimmed.toLowerCase()
  const items = []
  const seen = new Set()

  // the user's own saved commands: by their name, before everything else
  for (const c of saved) {
    if (c.name.toLowerCase().startsWith(p)) {
      items.push({entry: {kind: "saved", ...c}, apply: {text: c.name, caret: c.name.length}})
    }
  }
  const exact = saved.find((c) => c.name.toLowerCase() === p)

  // monitor commands whose name (or alias) starts with what is typed
  for (const e of cat.hmp) {
    const names = [e.name, ...e.aliases]
    if (names.some((n) => n.toLowerCase().startsWith(p)) && !seen.has(e.name)) {
      seen.add(e.name)
      items.push({entry: e, apply: applyHmp(e)})
    }
  }
  items.sort((a, b) => rank(a.entry, p) - rank(b.entry, p) || a.entry.name.localeCompare(b.entry.name))

  // the QEMU tools, which run with the VM off
  for (const e of cat.tools) {
    if (e.name.toLowerCase().startsWith(p)) items.push({entry: e, apply: applyHmp(e)})
  }

  // QMP commands, for a single word: names that start with it, then that contain it
  if (!/\s/.test(p) && p.length >= 2) {
    const starts = cat.qmp.filter((e) => e.name.toLowerCase().startsWith(p))
    const has = cat.qmp.filter((e) => !e.name.toLowerCase().startsWith(p) && e.name.toLowerCase().includes(p))
    for (const e of [...starts, ...has.slice(0, MAX_LOOSE)]) {
      items.push({entry: e, apply: {text: qmpSkeleton(e), caret: null}})
    }
  }

  // a monitor command already complete and followed by its arguments: describe it
  let hint = exact ? {kind: "saved", ...exact} : null
  if (items.length === 0) {
    const hit = cat.hmpNames.find(([n]) => p === n || p.startsWith(n + " "))
    if (hit) hint = hit[1]
  }
  return {items: items.slice(0, MAX_ROWS), hint}
}

function rank(entry, p) {
  const names = [entry.name, ...entry.aliases].map((n) => n.toLowerCase())
  if (names.includes(p)) return 0
  return 1
}

function applyHmp(e) {
  const text = e.name + (e.usage ? " " : "")
  return {text, caret: text.length}
}

function suggestJson(cat, text) {
  // inside the command's name: "execute": "que|
  const m = /"execute"\s*:\s*"([^"]*)$/.exec(text)
  if (m) {
    const p = m[1].toLowerCase()
    const starts = cat.qmp.filter((e) => e.name.toLowerCase().startsWith(p))
    const has = cat.qmp.filter((e) => !e.name.toLowerCase().startsWith(p) && e.name.toLowerCase().includes(p))
    const items = [...starts, ...has].slice(0, MAX_ROWS).map((e) => {
      const next = text.slice(0, text.length - m[1].length) + e.name + '"'
      return {entry: e, apply: {text: next, caret: next.length}}
    })
    return {items, hint: null}
  }

  const cmdName = /"execute"\s*:\s*"([\w-]+)"/.exec(text)
  const cmd = cmdName ? cat.byQmp.get(cmdName[1]) : null
  if (!cmd) return {items: [], hint: null}

  // inside "arguments": {"fi|  → the command's arguments not yet given
  const a = /"arguments"\s*:\s*\{(?:[^{}]*,)?\s*"([\w-]*)$/.exec(text)
  if (a) {
    const p = a[1].toLowerCase()
    const items = cmd.args
      .filter((x) => x.name.toLowerCase().startsWith(p) && !text.includes(`"${x.name}"`))
      .map((x) => {
        const next = text.slice(0, text.length - a[1].length) + x.name + '": '
        return {entry: {kind: "arg", name: x.name, command: cmd.name, arg: x}, apply: {text: next, caret: next.length}}
      })
    if (items.length > 0) return {items, hint: cmd}
  }
  return {items: [], hint: cmd}
}

// ------------------------------------------------------------------ view

const el = (tag, cls, text) => {
  const node = document.createElement(tag)
  if (cls) node.className = cls
  if (text !== undefined) node.textContent = text
  return node
}

function describe(entry) {
  const box = el("div", "space-y-1")
  if (entry.kind === "arg") {
    const a = entry.arg
    const head = el("div", "font-mono text-primary", `${a.name}`)
    head.append(el("span", "ml-2 text-base-content/50", `${argType(a)} · ${a.required ? "obrigatório" : "opcional"}`))
    box.append(head, el("div", "", a.description || "sem descrição"))
    box.append(el("div", "text-base-content/40", `argumento de ${entry.command}`))
    return box
  }

  if (entry.kind === "saved") {
    const box = el("div", "space-y-1")
    box.append(el("div", "font-mono text-primary", entry.name))
    box.append(el("div", "", entry.description || "comando salvo"))
    box.append(el("div", "text-base-content/40", "executa, em ordem:"))
    entry.steps.forEach((step, i) => box.append(el("div", "pl-2 font-mono", `${i + 1}. ${step}`)))
    return box
  }

  const head = el("div", "font-mono text-primary", entry.name)
  if ((entry.kind === "hmp" || entry.kind === "tool") && entry.usage)
    head.append(el("span", "ml-2 text-base-content/60", entry.usage))
  box.append(head)
  box.append(el("div", "", entry.description || "sem descrição na documentação do QEMU"))

  if (entry.kind === "hmp" && entry.aliases.length > 0)
    box.append(el("div", "text-base-content/40", `apelido: ${entry.aliases.join(", ")}`))

  if (entry.kind === "qmp") {
    const meta = []
    if (entry.since) meta.push(`desde o QEMU ${entry.since}`)
    if (entry.returns) meta.push(`devolve ${entry.returns}`)
    if (meta.length) box.append(el("div", "text-base-content/40", meta.join(" · ")))
    if (entry.args.length === 0) box.append(el("div", "text-base-content/40", "sem argumentos"))
    for (const a of entry.args) {
      const line = el("div", "pl-2")
      line.append(el("span", "font-mono text-primary/80", a.name))
      line.append(el("span", "text-base-content/50", ` (${argType(a)}, ${a.required ? "obrigatório" : "opcional"})`))
      if (a.description) line.append(el("span", "text-base-content/70", ` — ${a.description}`))
      box.append(line)
    }
  }
  return box
}

function argType(a) {
  return a.values ? `${a.type}: ${a.values.join(" | ")}` : a.type
}

// ------------------------------------------------------------------ hook

export const CmdInput = {
  mounted() {
    this.pos = null // index in the history while browsing, null when typing
    this.draft = ""
    this.items = []
    this.hint = null
    this.sel = 0
    this.explicit = false // the user chose an item with the arrows
    this.box = document.getElementById("cmd-suggest")
    this.cat = null
    loadCatalog().then((c) => (this.cat = c))

    this.el.addEventListener("input", () => {
      this.pos = null
      this.refresh()
    })
    this.el.addEventListener("keydown", (e) => this.onKey(e))
    this.el.addEventListener("blur", () => setTimeout(() => this.close(), 150))
    this.el.addEventListener("focus", () => this.refresh())

    this.el.form.addEventListener("submit", () => {
      // the value has been read by the time the event reaches the server
      setTimeout(() => {
        this.el.value = ""
        this.pos = null
        this.close()
      }, 0)
    })
  },

  saved() {
    try {
      return JSON.parse(this.el.dataset.saved || "[]")
    } catch (_) {
      return []
    }
  },

  history() {
    try {
      return JSON.parse(this.el.dataset.history || "[]")
    } catch (_) {
      return []
    }
  },

  open() {
    return this.items.length > 0
  },

  onKey(e) {
    if (this.open()) {
      if (e.key === "ArrowDown" || e.key === "ArrowUp") {
        e.preventDefault()
        const n = this.items.length
        this.sel = (this.sel + (e.key === "ArrowDown" ? 1 : n - 1)) % n
        this.explicit = true
        return this.render()
      }
      if (e.key === "Tab") {
        e.preventDefault()
        return this.accept(this.sel)
      }
      if (e.key === "Enter" && this.explicit) {
        e.preventDefault()
        return this.accept(this.sel)
      }
      if (e.key === "Escape") {
        e.preventDefault()
        return this.close()
      }
    }

    // history, when no suggestions are open
    const history = this.history()
    if (e.key === "ArrowUp" && history.length > 0) {
      e.preventDefault()
      if (this.pos === null) {
        this.draft = this.el.value
        this.pos = history.length
      }
      this.pos = Math.max(0, this.pos - 1)
      this.el.value = history[this.pos]
      this.close()
    } else if (e.key === "ArrowDown" && this.pos !== null) {
      e.preventDefault()
      this.pos += 1
      if (this.pos >= history.length) {
        this.pos = null
        this.el.value = this.draft
      } else {
        this.el.value = history[this.pos]
      }
      this.close()
    }
  },

  refresh() {
    if (!this.cat || document.activeElement !== this.el || this.el.disabled) return this.close()
    const {items, hint} = suggest(this.cat, this.el.value, this.saved())
    this.items = items
    this.hint = hint
    this.sel = 0
    this.explicit = false
    this.render()
  },

  accept(i) {
    const item = this.items[i]
    if (!item) return
    this.el.value = item.apply.text
    const caret = item.apply.caret ?? item.apply.text.length
    this.el.setSelectionRange(caret, caret)
    this.el.focus()
    this.refresh()
  },

  close() {
    this.items = []
    this.hint = null
    this.render()
  },

  render() {
    const box = this.box
    if (!box) return
    box.replaceChildren()
    const current = this.items[this.sel]?.entry || this.hint
    if (this.items.length === 0 && !this.hint) return box.classList.add("hidden")
    box.classList.remove("hidden")

    if (this.items.length > 0) {
      const list = el("div", "max-h-44 overflow-y-auto")
      this.items.forEach((item, i) => {
        const e = item.entry
        const row = el(
          "div",
          "flex cursor-pointer items-baseline gap-2 px-2 py-1 " +
            (i === this.sel ? "bg-primary/15" : "hover:bg-base-300"),
        )
        row.append(el("span", "shrink-0 font-mono text-primary", e.name))
        row.append(
          el(
            "span",
            "shrink-0 rounded px-1 text-[0.58rem] uppercase " +
              (e.kind === "qmp"
                ? "bg-info/15 text-info"
                : e.kind === "arg"
                  ? "bg-warning/15 text-warning"
                  : e.kind === "tool"
                    ? "bg-secondary/15 text-secondary"
                    : e.kind === "saved"
                      ? "bg-primary/20 text-primary"
                      : "bg-success/15 text-success"),
            e.kind === "qmp"
              ? "QMP"
              : e.kind === "arg"
                ? "arg"
                : e.kind === "tool"
                  ? "ferramenta"
                  : e.kind === "saved"
                    ? "salvo"
                    : "monitor",
          ),
        )
        const desc = e.kind === "arg" ? e.arg.description || "" : e.description
        const steps = e.kind === "saved" ? `${e.steps.length} passo(s)  ` : ""
        const usage = (e.kind === "hmp" || e.kind === "tool") && e.usage ? e.usage + "  " : ""
        row.append(el("span", "min-w-0 flex-1 truncate text-base-content/55", steps + usage + desc))
        // mousedown, not click: the input must keep the focus
        row.addEventListener("mousedown", (ev) => {
          ev.preventDefault()
          this.accept(i)
        })
        list.append(row)
        if (i === this.sel) requestAnimationFrame(() => row.scrollIntoView({block: "nearest"}))
      })
      box.append(list)
    }

    if (current) {
      const detail = el("div", "max-h-40 overflow-y-auto border-t border-primary/15 px-2 py-1.5 text-[0.68rem] leading-snug")
      detail.append(describe(current))
      box.append(detail)
    }

    const keys = el(
      "div",
      "border-t border-primary/10 px-2 py-0.5 text-[0.58rem] text-base-content/35",
      this.items.length > 0
        ? "↑↓ escolher · Tab aceita · Esc fecha · Enter envia o que está digitado"
        : "uso do comando · ↑ recupera o anterior",
    )
    box.append(keys)
  },
}
