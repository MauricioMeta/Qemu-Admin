defmodule QemuAdminWeb.Components.Vm.List do
  @moduledoc """
  The side panel: the workspace on top (`QemuAdmin.Workspace` — a menu to
  switch to another, open a folder or forget one), then every VM of it, one
  row each — status dot, name, what it is — the selected one highlighted,
  as the Rockwell Viewer's project tree. A filter box narrows it.

  The VMs are grouped by engine (QEMU, Renode). A board that runs a program (an
  Arduino, a Cortex-M board, a Renode board) opens like a tree node onto its
  **firmwares** (`QemuAdmin.Firmwares`): clicking one makes it the VM's program,
  the play button next to it starts the VM with it, and "adicionar firmware…" copies
  a file into the VM's `firmware/` folder.

  Events: `tree_toggle` (`id`), `pick_firmware` and `run_firmware` (`id`, `file`),
  `select_vm` (`id`), `new_vm`, `filter_vms` (`q`),
  `open_workspace` (`path`), `forget_workspace` (`path`), `picker_open`
  (target `workspace`).
  """

  use Surface.Component

  import QemuAdminWeb.CoreComponents, only: [icon: 1]

  alias QemuAdmin.Firmwares
  alias QemuAdminWeb.Components.Vm.StatusDot

  @doc "`[{vm, runtime}]`."
  prop vms, :list, default: []

  @doc "The selected VM's id."
  prop selected, :any, default: nil

  @doc "The filter text."
  prop filter, :string, default: ""

  @doc "Ids of the VMs whose firmwares are listed (the tree's open nodes)."
  prop open, :list, default: []

  @doc "`QemuAdmin.Workspace.list/0`."
  prop workspaces, :list, default: []

  defp current(workspaces), do: Enum.find(workspaces, & &1.current?) || %{name: "—", path: ""}

  defp subtitle(vm) do
    case QemuAdmin.Vm.board(vm) do
      nil -> "#{vm.arch} · #{vm.cpus} vCPU · #{vm.memory} MiB"
      board -> board.name
    end
  end

  # the engines, in tree order: QEMU's VMs, then Renode's
  defp groups(vms) do
    {renode, qemu} = Enum.split_with(vms, fn {vm, _} -> QemuAdmin.Vm.kind(vm) == :renode end)
    [{"qemu", "QEMU", qemu}, {"renode", "Renode", renode}]
  end

  # each VM with its firmwares and whether its node is open
  defp nodes(group, open) do
    for {vm, rt} <- group do
      {vm, rt, Firmwares.list(vm), vm.id in open and Firmwares.supported?(vm)}
    end
  end

  defp size_label(bytes) when bytes >= 1_048_576, do: "#{Float.round(bytes / 1_048_576, 1)} MiB"
  defp size_label(bytes) when bytes >= 1024, do: "#{Float.round(bytes / 1024, 1)} KiB"
  defp size_label(bytes), do: "#{bytes} B"

  defp shown(vms, ""), do: vms

  defp shown(vms, q) do
    q = String.downcase(q)
    Enum.filter(vms, fn {vm, _} -> String.contains?(String.downcase(vm.name), q) end)
  end

  def render(assigns) do
    ~F"""
    <div class="flex h-full min-h-0 flex-col">
      <div class="flex h-[var(--qa-bar)] shrink-0 items-center gap-2 border-b border-primary/20 px-3">
        <div class="dropdown min-w-0 flex-1">
          <div
            tabindex="0"
            role="button"
            id="workspace-menu"
            title={current(@workspaces).path}
            class="flex min-w-0 items-center gap-2 rounded px-1 py-0.5 hover:bg-base-300"
          >
            <.icon name="hero-folder" class="size-4 shrink-0 text-primary" />
            <span class="truncate text-sm font-semibold text-primary">{current(@workspaces).name}</span>
            <.icon name="hero-chevron-down" class="size-3 shrink-0 text-base-content/50" />
          </div>
          <ul
            tabindex="0"
            class="dropdown-content menu menu-sm z-50 mt-1 w-72 rounded-lg border border-primary/20 bg-base-200 p-1 shadow-xl"
          >
            <li class="menu-title text-[0.65rem]">Workspaces</li>
            <li :for={w <- @workspaces}>
              <div class="flex items-center gap-2 pr-1">
                <button
                  type="button"
                  phx-click="open_workspace"
                  phx-value-path={w.path}
                  disabled={not w.exists?}
                  title={w.path}
                  class={
                    "flex min-w-0 flex-1 items-center gap-2 text-left text-xs",
                    "font-semibold text-primary": w.current?,
                    "opacity-40": not w.exists?
                  }
                >
                  <.icon name={if w.current?, do: "hero-check", else: "hero-folder"} class="size-3.5 shrink-0" />
                  <span class="min-w-0 flex-1">
                    <span class="block truncate">{w.name}</span>
                    <span class="block truncate text-[0.6rem] font-normal text-base-content/40">{w.path}</span>
                  </span>
                  <span class="text-[0.6rem] text-base-content/40">{w.vms} VM</span>
                </button>
                <button
                  :if={not w.current?}
                  type="button"
                  phx-click="forget_workspace"
                  phx-value-path={w.path}
                  title="Tirar da lista (a pasta fica)"
                  class="grid size-5 place-items-center rounded text-base-content/40 hover:text-error"
                >
                  <.icon name="hero-x-mark" class="size-3" />
                </button>
              </div>
            </li>
            <li class="mt-1 border-t border-base-content/10 pt-1">
              <button
                type="button"
                id="workspace-open"
                phx-click="picker_open"
                phx-value-target="workspace"
                class="text-xs"
              >
                <.icon name="hero-folder-plus" class="size-3.5" /> Abrir ou criar pasta…
              </button>
            </li>
          </ul>
        </div>
        <button
          type="button"
          id="reveal-workspace"
          phx-click="reveal_workspace"
          title="Abrir a pasta do workspace no Explorer"
          class="grid size-6 place-items-center rounded text-base-content/55 hover:bg-base-300 hover:text-primary"
        >
          <.icon name="hero-folder-open" class="size-4" />
        </button>
        <button
          type="button"
          id="new-vm"
          phx-click="new_vm"
          title="Nova VM"
          class="grid size-6 place-items-center rounded text-base-content/55 hover:bg-base-300 hover:text-primary"
        >
          <.icon name="hero-plus" class="size-4" />
        </button>
      </div>
      <form
        id="vm-filter"
        phx-change="filter_vms"
        class="shrink-0 border-b border-primary/10 p-2"
        onsubmit="return false"
      >
        <label class="flex items-center gap-2 rounded border border-base-content/10 bg-base-100/60 px-2 py-1 focus-within:border-primary/50">
          <.icon name="hero-magnifying-glass" class="size-3.5 text-base-content/40" />
          <input
            type="text"
            name="q"
            value={@filter}
            placeholder="Filtrar"
            autocomplete="off"
            phx-debounce="150"
            class="w-full bg-transparent text-xs outline-none"
          />
        </label>
      </form>
      <nav id="vm-list" class="min-h-0 flex-1 space-y-0.5 overflow-y-auto p-1.5" aria-label="VMs">
        {#for {engine, label, group} <- groups(shown(@vms, @filter))}
          <div
            :if={group != []}
            id={"engine-#{engine}"}
            class="flex items-center gap-1.5 px-2 pt-2 pb-0.5 text-[0.6rem] font-semibold uppercase tracking-wider text-base-content/40"
          >
            <.icon name={if engine == "renode", do: "hero-bolt", else: "hero-server-stack"} class="size-3" />
            {label}
            <span class="font-mono font-normal">{length(group)}</span>
          </div>
          {#for {vm, rt, fws, open?} <- nodes(group, @open)}
              <div id={"vm-node-#{vm.id}"}>
                <div class={
                  "flex w-full items-center rounded-md transition-colors",
                  "bg-primary/15 text-primary": vm.id == @selected,
                  "text-base-content/75 hover:bg-base-content/5 hover:text-base-content": vm.id != @selected
                }>
                  <button
                    :if={Firmwares.supported?(vm)}
                    type="button"
                    id={"vm-toggle-#{vm.id}"}
                    phx-click="tree_toggle"
                    phx-value-id={vm.id}
                    title={if open?, do: "Recolher os firmwares", else: "Mostrar os firmwares (#{length(fws)})"}
                    class="grid size-6 shrink-0 place-items-center rounded text-base-content/45 hover:text-primary"
                  >
                    <.icon name={if open?, do: "hero-chevron-down", else: "hero-chevron-right"} class="size-3" />
                  </button>
                  <span :if={not Firmwares.supported?(vm)} class="size-6 shrink-0" />
                  <button
                    type="button"
                    id={"vm-row-#{vm.id}"}
                    phx-click="select_vm"
                    phx-value-id={vm.id}
                    aria-current={if vm.id == @selected, do: "page"}
                    class="flex min-w-0 flex-1 items-center gap-2.5 py-2 pr-2.5 text-left"
                  >
                    <StatusDot status={rt.status} />
                    <span class="min-w-0 flex-1">
                      <span class="block truncate text-xs font-semibold">{vm.name}</span>
                      <span class="block truncate text-[0.65rem] text-base-content/40">
                        {subtitle(vm)}
                      </span>
                    </span>
                  </button>
                </div>
                <ul :if={open?} id={"fw-list-#{vm.id}"} class="mb-1 ml-6 border-l border-base-content/10 pl-1">
                  <li :for={fw <- fws} id={"fw-#{vm.id}-#{fw.name}"} class="group flex items-center">
                    <button
                      type="button"
                      phx-click="pick_firmware"
                      phx-value-id={vm.id}
                      phx-value-file={fw.file}
                      title={"Usar #{fw.file} nesta VM"}
                      class={
                        "flex min-w-0 flex-1 items-center gap-1.5 rounded px-2 py-1 text-left text-[0.7rem] hover:bg-base-content/5",
                        "font-semibold text-primary": fw.active?,
                        "text-base-content/65": not fw.active?
                      }
                    >
                      <.icon name={if fw.active?, do: "hero-check-circle", else: "hero-document"} class="size-3 shrink-0" />
                      <span class="min-w-0 flex-1 truncate">{fw.name}</span>
                      <span class="shrink-0 font-mono text-[0.58rem] text-base-content/35">{size_label(fw.size)}</span>
                    </button>
                    <button
                      type="button"
                      phx-click="run_firmware"
                      phx-value-id={vm.id}
                      phx-value-file={fw.file}
                      title={"Simular #{vm.name} com #{fw.name}"}
                      class="grid size-5 shrink-0 place-items-center rounded text-success/70 hover:bg-success/15 hover:text-success"
                    >
                      <.icon name="hero-play" class="size-3" />
                    </button>
                  </li>
                  <li :if={fws == []} class="px-2 py-1 text-[0.65rem] italic text-base-content/35">nenhum firmware</li>
                  <li>
                    <button
                      type="button"
                      id={"fw-add-#{vm.id}"}
                      phx-click="picker_open"
                      phx-value-target={"tree_fw:#{vm.id}"}
                      phx-value-exts={Enum.join(Firmwares.extensions(vm), ",")}
                      class="flex w-full items-center gap-1.5 rounded px-2 py-1 text-left text-[0.65rem] text-base-content/45 hover:text-primary"
                    >
                      <.icon name="hero-plus" class="size-3" /> adicionar firmware…
                    </button>
                  </li>
                </ul>
              </div>
          {/for}
        {/for}
        <div :if={@vms == []} class="px-3 py-8 text-center text-xs text-base-content/40">
          Nenhuma VM neste workspace.
          <button type="button" phx-click="new_vm" class="mt-2 block w-full text-primary hover:underline">
            Criar a primeira
          </button>
        </div>
      </nav>
    </div>
    """
  end
end
