defmodule QemuAdminWeb.Components.Vm.List do
  @moduledoc """
  The side panel: the workspace on top (`QemuAdmin.Workspace` — a menu to
  switch to another, open a folder or forget one), then every VM of it, one
  row each — status dot, name, what it is — the selected one highlighted,
  as the Rockwell Viewer's project tree. A filter box narrows it.

  Events: `select_vm` (`id`), `new_vm`, `filter_vms` (`q`),
  `open_workspace` (`path`), `forget_workspace` (`path`), `picker_open`
  (target `workspace`).
  """

  use Surface.Component

  import QemuAdminWeb.CoreComponents, only: [icon: 1]

  alias QemuAdminWeb.Components.Vm.StatusDot

  @doc "`[{vm, runtime}]`."
  prop vms, :list, default: []

  @doc "The selected VM's id."
  prop selected, :any, default: nil

  @doc "The filter text."
  prop filter, :string, default: ""

  @doc "`QemuAdmin.Workspace.list/0`."
  prop workspaces, :list, default: []

  defp current(workspaces), do: Enum.find(workspaces, & &1.current?) || %{name: "—", path: ""}

  defp subtitle(vm) do
    case QemuAdmin.Vm.board(vm) do
      nil -> "#{vm.arch} · #{vm.cpus} vCPU · #{vm.memory} MiB"
      board -> board.name
    end
  end

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
        {#for {vm, rt} <- shown(@vms, @filter)}
          <button
            type="button"
            id={"vm-row-#{vm.id}"}
            phx-click="select_vm"
            phx-value-id={vm.id}
            aria-current={if vm.id == @selected, do: "page"}
            class={
              "flex w-full items-center gap-2.5 rounded-md px-2.5 py-2 text-left transition-colors",
              "bg-primary/15 text-primary": vm.id == @selected,
              "text-base-content/75 hover:bg-base-content/5 hover:text-base-content": vm.id != @selected
            }
          >
            <StatusDot status={rt.status} />
            <span class="min-w-0 flex-1">
              <span class="block truncate text-xs font-semibold">{vm.name}</span>
              <span class="block truncate text-[0.65rem] text-base-content/40">
                {subtitle(vm)}
              </span>
            </span>
          </button>
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
