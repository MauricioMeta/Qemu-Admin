defmodule QemuAdminWeb.Components.Vm.Grid do
  @moduledoc """
  The VMs page with no VM selected: one card per VM — its last screenshot,
  status, specs and the start/stop button — and a card to create one.

  Events: `select_vm`, `start_vm`, `powerdown_vm` (`id`), `new_vm`.
  """

  use Surface.Component

  import QemuAdminWeb.CoreComponents, only: [icon: 1]
  import QemuAdminWeb.VmHelpers

  alias QemuAdmin.Vm
  alias QemuAdminWeb.Components.App.Logo
  alias QemuAdminWeb.Components.Vm.StatusDot

  @doc "`[{vm, runtime}]`."
  prop vms, :list, default: []

  @doc "Whether QEMU was found (no start buttons otherwise)."
  prop qemu?, :boolean, default: true

  def render(assigns) do
    ~F"""
    <div id="vm-grid" class="min-h-0 flex-1 overflow-y-auto p-5">
      <div
        :if={not @qemu?}
        class="mb-5 flex items-center gap-3 rounded-lg border border-warning/40 bg-warning/10 px-4 py-3 text-xs text-warning"
      >
        <.icon name="hero-exclamation-triangle" class="size-5 shrink-0" />
        <span class="flex-1">QEMU não encontrado. Baixe a versão portátil ou aponte uma instalação existente.</span>
        <button
          type="button"
          phx-click="nav"
          phx-value-view="qemu"
          class="rounded border border-warning/50 px-2 py-1 hover:bg-warning/15"
        >
          Configurar QEMU
        </button>
      </div>

      <div class="grid gap-4 [grid-template-columns:repeat(auto-fill,minmax(16rem,1fr))]">
        {#for {vm, rt} <- @vms}
          <article id={"vm-card-#{vm.id}"} class="qa-card group flex flex-col overflow-hidden">
            <button
              type="button"
              phx-click="select_vm"
              phx-value-id={vm.id}
              class="relative block aspect-[4/3] w-full overflow-hidden border-b border-primary/10"
              title={"Abrir #{vm.name}"}
            >
              {#if Vm.kind(vm) in [:esp32, :avr] or (Vm.kind(vm) == :raspi and is_nil(screen_url(vm, rt)))}
                <div class={"qa-screen grid size-full place-items-center bg-base-300/40 p-3", "opacity-50": stopped?(rt)}>
                  <QemuAdminWeb.Components.Vm.Board board={Vm.board(vm)} compact on={not stopped?(rt)} />
                </div>
              {#elseif screen_url(vm, rt)}
                <img
                  src={screen_url(vm, rt)}
                  alt=""
                  class={"qa-screen size-full", "opacity-40 grayscale": stopped?(rt)}
                />
              {#else}
                <div class="qa-screen grid size-full place-items-center">
                  <Logo class="size-14 text-base-content/15" />
                </div>
              {/if}
              <span class="absolute left-2 top-2 rounded bg-base-100/80 px-1.5 py-0.5 backdrop-blur">
                <StatusDot status={rt.status} label />
              </span>
            </button>
            <div class="flex items-center gap-2 px-3 py-2.5">
              <div class="min-w-0 flex-1">
                <h3 class="truncate text-sm font-semibold">{vm.name}</h3>
                <p class="truncate text-[0.65rem] text-base-content/45">
                  {#if Vm.board(vm)}
                    {Vm.board(vm).name} · {if vm.firmware in [nil, ""], do: "vazio", else: vm.firmware}
                  {#else}
                    {vm.arch} · {vm.cpus} vCPU · {memory_label(vm.memory)} · {length(vm.disks)} disco(s)
                  {/if}
                </p>
              </div>
              {#if stopped?(rt)}
                <button
                  type="button"
                  phx-click="start_vm"
                  phx-value-id={vm.id}
                  disabled={not @qemu?}
                  title="Ligar"
                  class="grid size-8 place-items-center rounded-full border border-success/40 text-success hover:bg-success/15 disabled:opacity-30"
                >
                  <.icon name="hero-play-solid" class="size-4" />
                </button>
              {#else}
                <button
                  type="button"
                  phx-click="powerdown_vm"
                  phx-value-id={vm.id}
                  title="Desligar (ACPI)"
                  class="grid size-8 place-items-center rounded-full border border-warning/40 text-warning hover:bg-warning/15"
                >
                  <.icon name="hero-power" class="size-4" />
                </button>
              {/if}
            </div>
          </article>
        {/for}

        <button
          type="button"
          id="vm-card-new"
          phx-click="new_vm"
          class="flex min-h-48 flex-col items-center justify-center gap-2 rounded-lg border border-dashed border-primary/30 text-base-content/45 transition-colors hover:border-primary/60 hover:bg-primary/5 hover:text-primary"
        >
          <.icon name="hero-plus-circle" class="size-8" />
          <span class="text-xs font-semibold uppercase tracking-wider">Nova VM</span>
        </button>
      </div>
    </div>
    """
  end
end
