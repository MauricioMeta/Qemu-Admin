#!/usr/bin/env python3
"""Builds priv/terminal/commands.json: every command of the QEMU in use.

What the installed QEMU tells about itself, for each emulator found:
  * the monitor (HMP) commands, with usage and description, from `help` and `help info`;
  * the QMP commands and events, with their arguments, types and results, from `query-qmp-schema`;
  * the tools that need no VM (what the Terminal runs with the VM off): the commands of `qemu-img`
    (usage and description from its own `--help`), `qemu-io`, and the introspection of each
    `qemu-system-*` (`-machine help`, `-cpu help`, `-version`…).
What it does not tell, the descriptions of the QMP commands, arguments and events, comes from
the doc comments of QEMU's own QAPI schema (qapi/*.json, same version, from the official repository).

    python tools/gen_qemu_catalog.py [--qemu DIR] [--esp DIR] [--qapi DIR] [--out FILE]

--qapi is where the qapi/*.json files are (downloaded there when missing).
"""
import argparse, datetime, json, os, re, subprocess, sys
from concurrent.futures import ThreadPoolExecutor

EMULATORS = ["x86_64", "i386", "aarch64", "arm", "avr"]

# ----------------------------------------------------------------- talking to QEMU


def qmp_session(exe, commands):
    """Runs `exe` with QMP on stdio and returns (version, {index: reply})."""
    p = subprocess.Popen(
        [exe, "-machine", "none", "-nodefaults", "-display", "none", "-qmp", "stdio"],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        text=True, encoding="utf-8", errors="replace")
    greeting = json.loads(p.stdout.readline())

    def send(msg):
        p.stdin.write(json.dumps(msg) + "\n")
        p.stdin.flush()

    def wait(ident):
        while True:
            line = p.stdout.readline()
            if not line:
                return None
            m = json.loads(line)
            if m.get("id") == ident:
                return m

    send({"execute": "qmp_capabilities", "id": "caps"})
    wait("caps")
    replies = {}
    for i, c in enumerate(commands):
        send({**c, "id": i})
        replies[i] = wait(i)
    try:
        send({"execute": "quit"})
        p.wait(timeout=5)
    except Exception:
        p.kill()
    v = greeting["QMP"]["version"]["qemu"]
    return f"{v['major']}.{v['minor']}.{v['micro']}", replies


def hmp(line):
    return {"execute": "human-monitor-command", "arguments": {"command-line": line}}


def parse_hmp(text, group=None):
    """`name usage -- description`, the description's lines continued by indented ones.

    `help info` lists `info <sub> usage -- description`: the group is the first word.
    A few usages go over several lines that start with `[` or `<`; `cont|c` names an alias.
    """
    entries, current = [], None
    for raw in text.splitlines():
        if not raw.strip():
            continue
        if current is not None and (raw[0] in " \t" or raw[0] in "[<"):
            if raw[0] in "[<" and " -- " in raw:
                usage, _, desc = raw.partition(" -- ")
                current["usage"] = (current["usage"] + " " + usage.strip()).strip()
                current["description"] = desc.strip()
            elif raw[0] in "[<":
                current["usage"] = (current["usage"] + " " + raw.strip()).strip()
            else:
                current["description"] = (current["description"] + " " + raw.strip()).strip()
            continue
        head, sep, desc = raw.partition(" -- ")
        parts = head.split(None, 2 if group else 1)
        if not parts:
            continue
        if group and parts[0] == group and len(parts) > 1:
            name = f"{group} {parts[1]}"
            usage = parts[2].strip() if len(parts) > 2 else ""
        else:
            name = parts[0]
            usage = parts[1].strip() if len(parts) > 1 else ""
        names = name.split("|") if "|" in name else [name]
        current = {"name": names[0], "usage": usage, "description": desc.strip(), "aliases": names[1:]}
        entries.append(current)
    return entries


# --------------------------------------------------------------------- the schema


def resolve_schema(schema):
    by_name = {e["name"]: e for e in schema}

    def type_of(name):
        """(rendered type, enum values or None)"""
        if name.startswith("[") and name.endswith("]"):
            inner, values = type_of(name[1:-1])
            return f"[{inner}]", values
        e = by_name.get(name)
        if e is None:
            return name, None
        meta = e["meta-type"]
        if meta == "builtin":
            return name, None
        if meta == "enum":
            return "enum", [m["name"] if isinstance(m, dict) else m for m in e.get("members", [])]
        # the schema's names for arrays are opaque ("[123]"), the objects' too
        if meta == "array":
            inner, values = type_of(e["element-type"])
            return f"[{inner}]", values
        return meta, None  # object, alternate, ...

    def members(type_name):
        e = by_name.get(type_name)
        if not e or e["meta-type"] != "object":
            return []
        out = []
        for m in e.get("members", []):
            t, values = type_of(m["type"])
            arg = {"name": m["name"], "type": t, "required": "default" not in m}
            if values:
                arg["values"] = values
            out.append(arg)
        return out

    commands, events = {}, {}
    for e in schema:
        if e["meta-type"] == "command":
            ret, _ = type_of(e["ret-type"]) if e.get("ret-type") else (None, None)
            commands[e["name"]] = {
                "arguments": members(e["arg-type"]) if e.get("arg-type") else [],
                "returns": ret,
            }
        elif e["meta-type"] == "event":
            events[e["name"]] = {"data": members(e["arg-type"]) if e.get("arg-type") else []}
    return commands, events


# ------------------------------------------------------------------------- the tools

# What `qemu-system-* <option>` lists, in the words of the page.
SYSTEM_HELPS = [
    ("-machine help", "Lista as máquinas (placas) que este emulador sabe emular."),
    ("-cpu help", "Lista os modelos de CPU que este emulador sabe emular."),
    ("-device help", "Lista os dispositivos que se pode ligar à máquina (-device nome,help mostra as propriedades de um)."),
    ("-accel help", "Lista os aceleradores disponíveis (tcg, whpx, kvm…)."),
    ("-display help", "Lista as formas de mostrar a tela (sdl, gtk, vnc, none…)."),
    ("-netdev help", "Lista os tipos de rede (user, tap, socket…)."),
    ("-object help", "Lista os objetos que se pode criar (memória, segredos, backends…)."),
    ("-version", "Mostra a versão do emulador."),
]


def probe_tools(qemu_dir, exes):
    """qemu-img's commands (usage and description from `--help`), qemu-io and the qemu-system-* helps."""
    tools = []
    img = next((os.path.join(qemu_dir, f) for f in ("qemu-img.exe", "qemu-img")
                if os.path.isfile(os.path.join(qemu_dir, f))), None)
    if img:
        def run(*args):
            return subprocess.run([img, *args], capture_output=True, text=True, encoding="utf-8",
                                  errors="replace").stdout

        help_text = run("--help")
        section = help_text.split("Recognized commands", 1)[-1].split("Supported image formats")[0]
        for name, desc in re.findall(r"^\s+([\w-]+) - (.+)$", section, re.M):
            usage = run(name, "--help").split("Usage:", 1)[-1].split("\n\n", 1)[0]
            usage = re.sub(r"\s+", " ", usage).strip()
            usage = re.sub(r"^qemu-img " + re.escape(name) + r"\s*", "", usage)
            tools.append({"name": f"qemu-img {name}", "usage": usage, "description": desc.strip(),
                          "emulators": []})
        tools.append({"name": "qemu-img", "usage": "COMMAND [opções]",
                      "description": "Utilitário de imagens de disco do QEMU: criar, inspecionar, converter, redimensionar, "
                                     "tirar snapshots… (qemu-img COMMAND --help mostra a ajuda de um comando).",
                      "emulators": []})
    io = any(os.path.isfile(os.path.join(qemu_dir, f)) for f in ("qemu-io.exe", "qemu-io"))
    if io:
        tools.append({"name": "qemu-io", "usage": "[-f FMT] -c COMANDO [-c COMANDO]... ARQUIVO",
                      "description": "Exercita uma imagem de disco: lê, escreve e consulta blocos (use -c; "
                                     "sem -c ele seria interativo).",
                      "emulators": []})
    for arch in exes:
        for opt, desc in SYSTEM_HELPS:
            tools.append({"name": f"qemu-system-{arch} {opt}", "usage": "", "description": desc, "emulators": [arch]})
    return sorted(tools, key=lambda t: t["name"])


# ------------------------------------------------------------ the docs (QAPI sources)

QAPI_BASE = "https://gitlab.com/qemu-project/qemu/-/raw/v{version}/qapi/"


def load_qapi(directory, version):
    os.makedirs(directory, exist_ok=True)

    def get(name):
        path = os.path.join(directory, name)
        if not os.path.exists(path) or os.path.getsize(path) == 0:
            subprocess.run(["curl", "-sfL", "-o", path, QAPI_BASE.format(version=version) + name], check=True)
        return open(path, encoding="utf-8").read()

    seen, queue, texts = set(), ["qapi-schema.json"], {}
    while queue:
        name = queue.pop(0)
        if name in seen:
            continue
        seen.add(name)
        texts[name] = get(name)
        queue += re.findall(r"\{\s*'include':\s*'([^']+)'", texts[name])
    return texts


def clean(lines):
    text = " ".join(l.strip() for l in lines).strip()
    return re.sub(r"\s+", " ", text)


def parse_docs(texts):
    """{kind: {name: {description, since, args: {arg: text}}}} for the commands and events.

    A command whose arguments are a named type (`'data': 'Type'`, `'base': 'Type'`) takes
    their descriptions from that type's own doc comment.
    """
    docs = {"command": {}, "event": {}, "type": {}}
    pattern = re.compile(r"^##\n((?:#.*\n)+?)##\n(\{(?:[^\n]*\n)*?)(?=\{|##|\Z)", re.M)
    refs = {}
    for text in texts.values():
        for block, definition in pattern.findall(text):
            m = re.match(r"\{\s*'(command|event|struct|union|alternate)':\s*'([\w.-]+)'", definition)
            if not m:
                continue
            kind, name = m.groups()
            kind = kind if kind in ("command", "event") else "type"
            lines = [l[2:] if l.startswith("# ") else l[1:] for l in block.splitlines()]
            description, since, args = [], None, {}
            section, arg = "desc", None
            for line in lines:
                a = re.match(r"@([\w.-]+):\s*(.*)$", line)
                if a and a.group(1) == name and section == "desc" and not description:
                    if a.group(2):
                        description.append(a.group(2))
                    continue
                if a and section != "since" and a.group(1) != name:
                    section, arg = "args", a.group(1)
                    args[arg] = [a.group(2)]
                    continue
                sn = re.match(r"Since:\s*(.*)$", line)
                if sn:
                    since, section = sn.group(1).strip(), "since"
                    continue
                if not line.strip():
                    if section == "desc" and description:
                        section = "after"  # the first paragraph is the description
                    elif section == "args":
                        section, arg = "after", None
                    continue
                if section == "desc":
                    description.append(line)
                elif section == "args" and arg is not None and line.startswith(" "):
                    args[arg].append(line)
            docs[kind][name] = {
                "description": clean(description),
                "since": since,
                "args": {k: clean(v) for k, v in args.items()},
            }
            refs[(kind, name)] = re.findall(r"'(?:data|base)':\s*'([\w.-]+)'", definition)

    def inherited(names, seen=()):
        out = {}
        for t in names:
            if t in seen or t not in docs["type"]:
                continue
            out.update(inherited(refs.get(("type", t), []), seen + (t,)))
            out.update({k: v for k, v in docs["type"][t]["args"].items() if v})
        return out

    for kind in ("command", "event"):
        for name, d in docs[kind].items():
            extra = inherited(refs.get((kind, name), []))
            for k, v in extra.items():
                d["args"].setdefault(k, v)
    return docs


# -------------------------------------------------------------------------- main


def main():
    ap = argparse.ArgumentParser()
    here = os.path.dirname(os.path.abspath(__file__))
    root = os.path.dirname(here)
    ap.add_argument("--qemu", default=os.path.join(root, "qemu"))
    ap.add_argument("--esp", default=os.path.join(root, "qemu-esp", "bin"))
    ap.add_argument("--qapi", default=os.path.join(root, "tmp", "qapi"))
    ap.add_argument("--out", default=os.path.join(root, "priv", "terminal", "commands.json"))
    args = ap.parse_args()

    exes = {}
    for arch in EMULATORS:
        for ext in (".exe", ""):
            path = os.path.join(args.qemu, f"qemu-system-{arch}{ext}")
            if os.path.isfile(path):
                exes[arch] = path
    for ext in (".exe", ""):
        path = os.path.join(args.esp, f"qemu-system-xtensa{ext}")
        if os.path.isfile(path):
            exes["xtensa"] = path
    if not exes:
        sys.exit("nenhum qemu-system-* encontrado")

    def probe(item):
        arch, exe = item
        return arch, qmp_session(exe, [
            hmp("help"), hmp("help info"), {"execute": "query-qmp-schema"}])

    with ThreadPoolExecutor(max_workers=4) as pool:
        results = dict(pool.map(probe, exes.items()))

    versions = {arch: v for arch, (v, _) in results.items()}
    main_version = versions.get("x86_64") or next(iter(versions.values()))
    print("emuladores:", versions)

    hmp_all, qmp_all, ev_all = {}, {}, {}
    for arch, (version, r) in results.items():
        for entry in parse_hmp(r[0]["return"]) + parse_hmp(r[1]["return"], group="info"):
            e = hmp_all.setdefault(entry["name"], {**entry, "emulators": []})
            e["aliases"] = sorted(set(e["aliases"]) | set(entry["aliases"]))
            e["emulators"].append(arch)
            if len(entry["description"]) > len(e["description"]):
                e["description"] = entry["description"]
        cmds, events = resolve_schema(r[2]["return"])
        for name, c in cmds.items():
            e = qmp_all.setdefault(name, {**c, "emulators": []})
            e["emulators"].append(arch)
            if len(c["arguments"]) > len(e["arguments"]):
                e["arguments"] = c["arguments"]
        for name, c in events.items():
            e = ev_all.setdefault(name, {**c, "emulators": []})
            e["emulators"].append(arch)

    docs = parse_docs(load_qapi(args.qapi, main_version))
    order = {a: i for i, a in enumerate(EMULATORS + ["xtensa"])}

    qmp = []
    for name in sorted(qmp_all):
        c, d = qmp_all[name], docs["command"].get(name, {})
        arguments = []
        for a in c["arguments"]:
            a = dict(a)
            text = d.get("args", {}).get(a["name"])
            if text:
                a["description"] = text
            arguments.append(a)
        qmp.append({
            "name": name,
            "description": d.get("description", ""),
            "since": d.get("since"),
            "arguments": arguments,
            "returns": c["returns"],
            "emulators": sorted(c["emulators"], key=order.get),
        })

    events = []
    for name in sorted(ev_all):
        c, d = ev_all[name], docs["event"].get(name, {})
        data = []
        for a in c["data"]:
            a = dict(a)
            text = d.get("args", {}).get(a["name"])
            if text:
                a["description"] = text
            data.append(a)
        events.append({
            "name": name,
            "description": d.get("description", ""),
            "since": d.get("since"),
            "data": data,
            "emulators": sorted(c["emulators"], key=order.get),
        })

    hmp_list = []
    for name in sorted(hmp_all):
        e = hmp_all[name]
        hmp_list.append({
            "name": name,
            "usage": e["usage"],
            "description": e["description"],
            "aliases": e["aliases"],
            "emulators": sorted(e["emulators"], key=order.get),
        })

    catalog = {
        "version": 1,
        "qemu": main_version,
        "emulator_versions": versions,
        "generated": datetime.date.today().isoformat(),
        "about": (
            "Todos os comandos do QEMU: 'tools' são as ferramentas que não precisam da VM ligada "
            "(qemu-img, qemu-io, qemu-system-* -machine help…); 'hmp' são os comandos do monitor (digitados como estão, "
            "ex.: info registers); 'qmp' são os comandos do protocolo de máquina, enviados como "
            "JSON {\"execute\": nome, \"arguments\": {...}}; 'qmp_events' são os eventos que o QEMU envia. "
            "Gerado por tools/gen_qemu_catalog.py a partir do QEMU instalado e dos comentários do QAPI."
        ),
        "tools": probe_tools(args.qemu, exes),
        "hmp": hmp_list,
        "qmp": qmp,
        "qmp_events": events,
    }

    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with open(args.out, "w", encoding="utf-8", newline="\n") as f:
        json.dump(catalog, f, ensure_ascii=False, indent=1)
        f.write("\n")

    no_desc = [c["name"] for c in qmp if not c["description"]]
    print(f"hmp: {len(hmp_list)}  qmp: {len(qmp)}  eventos: {len(events)}")
    print(f"qmp sem descrição: {len(no_desc)}", no_desc[:15])
    print("hmp sem descrição:", [c["name"] for c in hmp_list if not c["description"]][:15])
    print("escrito:", args.out, os.path.getsize(args.out), "bytes")


if __name__ == "__main__":
    main()
