defmodule QemuAdminWeb.Components.Pages.Disks do
  @moduledoc """
  Every disk of every VM, with what `qemu-img info` says of it (size,
  occupied, format), plus the forms to create a new disk for a VM and to
  grow one.

  Events: `create_disk` (form: `vm`, `size`, `format`, `interface`),
  `resize_disk` (form: `path`, `size`), `refresh_disks`, `select_vm`.
  """

  use Surface.Component

  import QemuAdminWeb.CoreComponents, only: [icon: 1]
  import QemuAdminWeb.VmHelpers, only: [running?: 1]

  alias QemuAdmin.Vm
  alias QemuAdmin.Qemu.Img

  @doc "`[{vm, runtime}]`."
  prop vms, :list, default: []

  @doc "`%{path => {:ok, info} | {:error, msg}}`."
  prop disk_info, :map, default: %{}

  @doc "Whether qemu-img is there."
  prop qemu?, :boolean, default: true

  defp rows(vms) do
    for {vm, rt} <- vms, {d, i} <- Enum.with_index(vm.disks) do
      %{vm: vm, rt: rt, index: i, disk: d, path: Vm.resolve(vm, d["path"])}
    end
  end

  defp total(disk_info, key) do
    disk_info
    |> Map.values()
    |> Enum.reduce(0, fn
      {:ok, info}, acc -> acc + (Map.get(info, key) || 0)
      _, acc -> acc
    end)
  end

  def render(assigns) do
    ~F"""
    <div id="disks-page" class="min-h-0 flex-1 overflow-y-auto p-5">
      <div class="mb-4 grid gap-4 md:grid-cols-3">
        <div class="qa-card p-4">
          <p class="qa-label">Discos</p>
          <p class="text-2xl font-bold text-primary">{length(rows(@vms))}</p>
        </div>
        <div class="qa-card p-4">
          <p class="qa-label">Capacidade total</p>
          <p class="text-2xl font-bold">{Img.human(total(@disk_info, :virtual_size))}</p>
        </div>
        <div class="qa-card p-4">
          <p class="qa-label">Ocupado no host</p>
          <p class="text-2xl font-bold">{Img.human(total(@disk_info, :actual_size))}</p>
        </div>
      </div>

      <section class="qa-card mb-4 p-4">
        <div class="mb-2 flex items-center justify-between">
          <h3 class="qa-label mb-0">Imagens de disco</h3>
          <button
            type="button"
            phx-click="refresh_disks"
            class="flex items-center gap-1 rounded px-2 py-1 text-[0.68rem] text-base-content/50 hover:bg-base-300 hover:text-primary"
          >
            <.icon name="hero-arrow-path" class="size-3.5" /> Atualizar
          </button>
        </div>
        <table class="data-table">
          <thead>
            <tr><th>VM</th><th class="fill">Arquivo</th><th>Formato</th><th>Interface</th><th>Tamanho</th><th>Ocupado</th><th>Aumentar</th></tr>
          </thead>
          <tbody>
            {#for r <- rows(@vms)}
              <tr id={"disk-#{r.vm.id}-#{r.index}"}>
                <td>
                  <button
                    type="button"
                    phx-click="select_vm"
                    phx-value-id={r.vm.id}
                    class="text-primary hover:underline"
                  >{r.vm.name}</button>
                </td>
                <td class="fill"><span class="clip" title={r.path}>{r.disk["path"]}</span></td>
                {#case Map.get(@disk_info, r.path)}
                  {#match {:ok, info}}
                    <td>{info.format}</td>
                    <td>{r.disk["interface"]}</td>
                    <td>{Img.human(info.virtual_size)}</td>
                    <td>{Img.human(info.actual_size)}</td>
                  {#match {:error, msg}}
                    <td>{r.disk["format"]}</td>
                    <td>{r.disk["interface"]}</td>
                    <td colspan="2" class="text-error"><span class="clip" title={msg}>{msg}</span></td>
                  {#match _}
                    <td>{r.disk["format"]}</td><td>{r.disk["interface"]}</td><td>—</td><td>—</td>
                {/case}
                <td>
                  <form phx-submit="resize_disk" class="flex gap-1">
                    <input type="hidden" name="path" value={r.path}>
                    <input name="size" placeholder="+10G" class="qa-field !w-20 !py-1" disabled={running?(r.rt)}>
                    <button
                      type="submit"
                      disabled={running?(r.rt)}
                      title={if running?(r.rt), do: "Desligue a VM para redimensionar", else: "Aumentar"}
                      class="grid size-7 place-items-center rounded border border-base-content/15 hover:text-primary disabled:opacity-30"
                    >
                      <.icon name="hero-arrows-pointing-out" class="size-3.5" />
                    </button>
                  </form>
                </td>
              </tr>
            {/for}
            <tr :if={rows(@vms) == []}>
              <td colspan="7" class="py-4 text-center text-base-content/40">Nenhuma VM tem discos ainda.</td>
            </tr>
          </tbody>
        </table>
        <p class="mt-2 text-[0.65rem] text-base-content/40">
          Depois de aumentar um disco, estenda a partição dentro do sistema convidado.
        </p>
      </section>

      <section class="qa-card p-4">
        <h3 class="qa-label">Novo disco</h3>
        <form
          id="create-disk"
          phx-submit="create_disk"
          class="grid items-end gap-3 md:grid-cols-[2fr_1fr_1fr_1fr_auto]"
        >
          <div>
            <label class="qa-label" for="disk_vm">Anexar à VM</label>
            <select id="disk_vm" name="vm" class="qa-field" required>
              <option :for={{vm, _} <- @vms} value={vm.id}>{vm.name}</option>
            </select>
          </div>
          <div>
            <label class="qa-label" for="disk_size">Tamanho</label>
            <input id="disk_size" name="size" placeholder="40G" class="qa-field" required>
          </div>
          <div>
            <label class="qa-label" for="disk_format">Formato</label>
            <select id="disk_format" name="format" class="qa-field">
              <option :for={f <- ~w(qcow2 raw vhdx vmdk)} value={f}>{f}</option>
            </select>
          </div>
          <div>
            <label class="qa-label" for="disk_interface">Interface</label>
            <select id="disk_interface" name="interface" class="qa-field">
              <option :for={x <- Vm.interfaces()} value={x}>{x}</option>
            </select>
          </div>
          <button
            type="submit"
            disabled={not @qemu? or @vms == []}
            class="h-[1.95rem] rounded-md bg-primary px-4 text-xs font-semibold text-primary-content hover:brightness-110 disabled:opacity-30"
          >
            Criar
          </button>
        </form>
      </section>
    </div>
    """
  end
end
