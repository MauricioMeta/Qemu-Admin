defmodule QemuAdminWeb.Components.Pages.Images do
  @moduledoc """
  The workspace's image library (`QemuAdmin.Images`): the files in its
  `images/` folder — ISOs, disk and SD card images, Arduino firmware,
  AtomVM apps — each with what it can start (a new VM of the right kind, a
  PC's CD), and the catalog of images to download into it.

  Events: `new_vm_from_image` (`path`), `insert_iso` (`id`, `path`),
  `image_download` (`id`), `refresh_images`, `picker_open` (`import_image`).
  """

  use Surface.Component

  import QemuAdminWeb.CoreComponents, only: [icon: 1]

  alias QemuAdmin.Qemu.Img

  @doc "`QemuAdmin.Images.list/0`."
  prop images, :list, default: []

  @doc "The library folder."
  prop dir, :string, required: true

  @doc "`[{vm, runtime}]`, for the CD menu."
  prop vms, :list, default: []

  @doc "`QemuAdmin.Images.state/0`."
  prop download, :map, required: true

  defp action(:iso), do: "Nova VM (PC)"
  defp action(:disk), do: "Nova VM com este disco"
  defp action(:sd), do: "Nova VM Raspberry Pi"
  defp action(:avr), do: "Nova VM Arduino"
  defp action(:avm), do: "Nova VM ESP32"
  defp action(_), do: nil

  defp icon_for(:iso), do: "hero-square-3-stack-3d"
  defp icon_for(:avr), do: "hero-cpu-chip"
  defp icon_for(:avm), do: "hero-cube"
  defp icon_for(_), do: "hero-circle-stack"

  defp busy?(job), do: job.phase in [:resolve, :download, :verify]

  defp progress(%{phase: :resolve}), do: "procurando a versão mais nova…"
  defp progress(%{phase: :verify}), do: "conferindo o SHA-256…"
  defp progress(%{phase: :done, file: f}), do: "#{f} baixado"
  defp progress(%{phase: :error, error: e}), do: e

  defp progress(%{phase: :download, received: r, total: t}) when is_integer(t) and t > 0,
    do: "#{Img.human(r)} de #{Img.human(t)} (#{trunc(r * 100 / t)}%)"

  defp progress(%{phase: :download, received: r}), do: Img.human(r)
  defp progress(_), do: nil

  def render(assigns) do
    ~F"""
    <div id="images-page" class="min-h-0 flex-1 overflow-y-auto p-5">
      <section class="qa-card mb-4 flex items-center gap-3 p-4 text-xs">
        <.icon name="hero-photo" class="size-8 shrink-0 text-primary/70" />
        <div class="min-w-0 flex-1">
          <p class="font-semibold">Imagens do workspace</p>
          <p class="truncate text-base-content/50" title={@dir}>
            Copie arquivos para <code class="text-primary/80">{@dir}</code> ou baixe do catálogo abaixo.
          </p>
        </div>
        <button
          type="button"
          phx-click="picker_open"
          phx-value-target="import_image"
          phx-value-exts={Enum.join(QemuAdmin.Images.extensions(), ",")}
          class="rounded border border-primary/30 px-3 py-1.5 text-primary hover:bg-primary/10"
        >
          Copiar para cá…
        </button>
        <button
          type="button"
          phx-click="refresh_images"
          title="Atualizar"
          class="grid size-7 place-items-center rounded hover:bg-base-300 hover:text-primary"
        >
          <.icon name="hero-arrow-path" class="size-4" />
        </button>
      </section>

      <section class="qa-card p-4">
        <table class="data-table">
          <thead>
            <tr><th class="fill">Imagem</th><th class="hidden lg:table-cell">Tipo</th><th>Tamanho</th><th /></tr>
          </thead>
          <tbody>
            {#for {img, i} <- Enum.with_index(@images)}
              <tr id={"image-#{i}"}>
                <td class="fill">
                  <span class="flex items-center gap-2">
                    <.icon name={icon_for(img.kind)} class="size-4 shrink-0 text-base-content/40" />
                    <span class="clip font-semibold" title={img.path}>{img.name}</span>
                  </span>
                </td>
                <td class="hidden text-base-content/60 lg:table-cell">{img.kind_label}</td>
                <td>{Img.human(img.size)}</td>
                <td>
                  <div class="flex items-center justify-end gap-1">
                    <div :if={img.kind == :iso and @vms != []} class="dropdown dropdown-end">
                      <div
                        tabindex="0"
                        role="button"
                        class="rounded border border-base-content/15 px-2 py-1 text-[0.68rem] hover:text-primary"
                      >
                        Colocar no CD de…
                      </div>
                      <ul
                        tabindex="0"
                        class="dropdown-content menu menu-sm z-50 mt-1 w-56 rounded-lg border border-primary/20 bg-base-200 p-1 shadow-xl"
                      >
                        <li :for={{vm, _} <- @vms} :if={QemuAdmin.Vm.kind(vm) == :pc}>
                          <button
                            type="button"
                            phx-click="insert_iso"
                            phx-value-id={vm.id}
                            phx-value-path={img.path}
                            class="text-xs"
                          >{vm.name}</button>
                        </li>
                      </ul>
                    </div>
                    <button
                      :if={action(img.kind)}
                      type="button"
                      phx-click="new_vm_from_image"
                      phx-value-path={img.path}
                      class="rounded border border-primary/30 px-2 py-1 text-[0.68rem] text-primary hover:bg-primary/10"
                    >
                      {action(img.kind)}
                    </button>
                  </div>
                </td>
              </tr>
            {/for}
            <tr :if={@images == []}>
              <td colspan="4" class="py-6 text-center text-base-content/40">Nenhuma imagem neste workspace ainda.</td>
            </tr>
          </tbody>
        </table>
      </section>

      <section class="qa-card mt-4 p-4">
        <div class="mb-2 flex items-center gap-2">
          <h3 class="qa-label mb-0 flex-1">Baixar</h3>
          <span
            :if={progress(@download)}
            id="image-download-progress"
            class={
              "text-xs",
              "text-error": @download.phase == :error,
              "text-success": @download.phase == :done,
              "text-base-content/60": busy?(@download)
            }
          >{progress(@download)}</span>
        </div>
        <div class="grid gap-2 md:grid-cols-2">
          {#for e <- QemuAdmin.Images.catalog()}
            <div class="flex items-center gap-3 rounded-md border border-base-content/10 p-3 text-xs">
              <div class="min-w-0 flex-1">
                <p class="font-semibold">{e.name}</p>
                <p class="text-base-content/50">{e.desc}</p>
              </div>
              <button
                type="button"
                id={"download-#{e.id}"}
                phx-click="image_download"
                phx-value-id={e.id}
                disabled={busy?(@download)}
                class="shrink-0 rounded border border-primary/30 px-2 py-1 text-[0.68rem] text-primary hover:bg-primary/10 disabled:opacity-40"
              >
                {if busy?(@download) and @download.id == e.id, do: "Baixando…", else: "Baixar"}
              </button>
            </div>
          {/for}
        </div>
      </section>
    </div>
    """
  end
end
