defmodule QemuAdminWeb.Components.Vm.SdCard do
  @moduledoc """
  A Raspberry Pi's "Cartão SD": the card image and what QEMU boots from it
  — kernel, device tree, command line (`QemuAdmin.Raspi.Image`). Importing
  an image (Raspberry Pi OS, `.img` or `.img.xz`) replaces the card.

  The first-boot user (`userconf.txt`) and SSH go in with the image: the
  `sd_user` form (`user`, `password`, `ssh`).

  Events: `picker_open` (target `sd_image`), `sd_user`, `sd_append`.
  """

  use Surface.Component

  import QemuAdminWeb.CoreComponents, only: [icon: 1]
  import QemuAdminWeb.VmHelpers

  alias QemuAdmin.Vm
  alias QemuAdmin.Qemu.Img
  alias QemuAdmin.Raspi.Image

  prop vm, :struct, required: true
  prop rt, :map, required: true
  prop board, :map, required: true

  @doc "`%{busy:, error:}` of an import running."
  prop import, :map, default: %{busy: false, error: nil}

  @doc "`%{\"user\" =>, \"password\" =>, \"ssh\" =>}` for the next import."
  prop user, :map, required: true

  defp size(vm, path) do
    case File.stat(Vm.resolve(vm, path)) do
      {:ok, %{size: s}} -> Img.human(s)
      _ -> "ausente"
    end
  end

  def render(assigns) do
    ~F"""
    <div id="vm-sd" class="min-h-0 flex-1 overflow-y-auto p-5">
      <div
        :if={not stopped?(@rt)}
        class="mb-4 flex items-center gap-2 rounded-lg border border-info/40 bg-info/10 px-3 py-2 text-xs text-info"
      >
        <.icon name="hero-information-circle" class="size-4 shrink-0" />
        A placa está ligada: desligue-a para trocar o cartão.
      </div>
      <div class="grid gap-4 xl:grid-cols-2">
        <section class="qa-card p-4">
          <h3 class="qa-label mb-1 text-primary">Imagem do cartão</h3>
          <p class="mb-3 text-xs text-base-content/55">
            Uma imagem do Raspberry Pi OS ({Enum.join(Image.extensions(), ", ")}). Ela é copiada para a pasta da VM,
            aumentada para uma potência de 2 e o kernel e o device tree saem da partição de boot — o QEMU não emula
            o firmware de boot do Pi.
          </p>
          <div class="flex items-center gap-2 text-xs">
            <.icon name="hero-circle-stack" class="size-4 text-base-content/40" />
            {#case @vm.disks}
              {#match [d | _]}
                <span class="min-w-0 flex-1 truncate font-semibold" title={Vm.resolve(@vm, d["path"])}>{if @vm.firmware in [nil, ""], do: d["path"], else: @vm.firmware}</span>
                <span class="text-base-content/45">{size(@vm, d["path"])}</span>
              {#match _}
                <span class="flex-1 text-base-content/45">sem cartão</span>
            {/case}
          </div>
          <form
            id="sd-user-form"
            phx-change="sd_user"
            class="mt-3 grid grid-cols-2 gap-2"
            onsubmit="return false"
          >
            <div>
              <label class="qa-label" for="sd_user">Usuário</label>
              <input id="sd_user" name="user" value={@user["user"]} class="qa-field" autocomplete="off">
            </div>
            <div>
              <label class="qa-label" for="sd_password">Senha</label>
              <input
                id="sd_password"
                name="password"
                value={@user["password"]}
                class="qa-field"
                autocomplete="off"
              />
            </div>
            <label class="col-span-2 flex items-center gap-2 text-xs">
              <input type="hidden" name="ssh" value="false">
              <input
                type="checkbox"
                name="ssh"
                value="true"
                checked={@user["ssh"] == "true"}
                class="checkbox checkbox-xs checkbox-primary"
              />
              Ligar o SSH (redirecione uma porta em Configuração › Rede, ex. tcp:2222:22)
            </label>
            <p class="col-span-2 text-[0.65rem] text-base-content/45">
              Criados no primeiro boot (como o Raspberry Pi Imager faz). Vazio: o sistema pergunta no teclado da aba Tela.
            </p>
          </form>
          <button
            type="button"
            id="sd-import"
            phx-click="picker_open"
            phx-value-target="sd_image"
            phx-value-exts={Enum.join(Image.extensions(), ",")}
            disabled={not stopped?(@rt) or @import.busy}
            class="mt-3 rounded-md bg-primary px-3 py-1.5 text-xs font-semibold text-primary-content hover:brightness-110 disabled:opacity-40"
          >
            {if @import.busy, do: "Importando… (pode levar alguns minutos)", else: "Importar imagem…"}
          </button>
          <p :if={@import.error} class="mt-2 text-xs text-error">{@import.error}</p>
          <p :if={not @board.usb?} class="mt-3 text-[0.68rem] text-warning">
            O {@board.name} do QEMU não tem USB: sem teclado, mouse nem rede — use a aba Serial.
          </p>
        </section>

        <section class="qa-card p-4">
          <h3 class="qa-label mb-2">Boot</h3>
          <dl class="grid grid-cols-[7rem_1fr] gap-y-1.5 text-xs">
            <dt class="text-base-content/45">Kernel</dt>
            <dd class="font-mono">{if @vm.kernel == "", do: "—", else: @vm.kernel}</dd>
            <dt class="text-base-content/45">Device tree</dt>
            <dd class="font-mono">{if @vm.dtb == "", do: "—", else: @vm.dtb}</dd>
          </dl>
          <form id="sd-append-form" phx-submit="sd_append" class="mt-3">
            <label class="qa-label" for="sd_append">Linha de comando do kernel</label>
            <textarea id="sd_append" name="append" rows="4" class="qa-field font-mono text-[0.68rem]">{@vm.append}</textarea>
            <button
              type="submit"
              class="mt-2 rounded border border-primary/30 px-3 py-1 text-xs text-primary hover:bg-primary/10"
            >Salvar</button>
          </form>
        </section>
      </div>
    </div>
    """
  end
end
