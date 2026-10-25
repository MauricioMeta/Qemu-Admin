defmodule QemuAdminWeb.Components.Vm.Form do
  @moduledoc """
  The VM's "Configuração" — and the Nova VM page, the same form with a
  first disk to create (`new`).

  It draws what the page keeps in `params` (string keys, as `QemuAdmin.Vm`
  casts them) and `errors` (`%{field => message}`); every change goes back
  as `validate_vm`, so dependent fields follow (the machine types of the
  chosen architecture), and the submit as `save_vm`. Disks are rows
  (`add_disk_row`, `remove_disk_row`); a path can be typed or picked
  (`picker_open` with `target` `disk:<i>` or `cdrom`).

  A development board (`QemuAdmin.Vm.kind/1`) shrinks it to what the board
  has: an ESP32's PSRAM and flash size (written in the Flash view); an
  Arduino nothing but its name and board (the program goes in the Firmware
  view); a Raspberry Pi its screen, network and, when creating it, the SD
  card image to import (`sd_image`). Creating, a row of boards fills
  architecture and board at once (`vm_preset`, `machine`).
  """

  use Surface.Component

  import QemuAdminWeb.CoreComponents, only: [icon: 1]

  alias QemuAdmin.{Qemu, Vm}
  alias QemuAdmin.Qemu.Img

  prop params, :map, required: true
  prop errors, :map, default: %{}

  @doc "Creating a VM (shows the first-disk fields) rather than editing one."
  prop new, :boolean, default: false

  @doc "The VM is running: changes apply on its next boot."
  prop running, :boolean, default: false

  @doc "The emulators this QEMU has (others are listed, marked)."
  prop emulators, :list, default: []

  defp v(params, key), do: Map.get(params, key, "")

  defp kind(params), do: Vm.kind(v(params, "arch"), v(params, "machine"))
  defp pc?(params), do: kind(params) == :pc

  # the New VM's shortcuts: {machine (nil: a PC), label, icon}
  @presets [
    {nil, "PC", "hero-computer-desktop"},
    {"esp32", "ESP32", "hero-cpu-chip"},
    {"esp32s3", "ESP32-S3", "hero-cpu-chip"},
    {"arduino-uno", "Arduino Uno", "hero-cpu-chip"},
    {"arduino-mega-2560-v3", "Arduino Mega", "hero-cpu-chip"},
    {"netduinoplus2", "Netduino Plus 2 (STM32)", "hero-cpu-chip"},
    {"raspi3b", "Raspberry Pi 3", "hero-server"},
    {"raspi4b", "Raspberry Pi 4", "hero-server"},
    {"raspi0", "Raspberry Pi Zero", "hero-server"}
  ]

  defp presets, do: @presets

  defp preset_active?(params, nil), do: pc?(params)
  defp preset_active?(params, machine), do: v(params, "machine") == machine

  defp preset_available?(_emulators, nil), do: true
  defp preset_available?([], _machine), do: true

  defp preset_available?(emulators, machine),
    do: QemuAdmin.Board.for_machine(machine).arch in emulators

  defp checked?(params, key), do: v(params, key) in [true, "true", "on"]

  defp disks(params) do
    params
    |> Map.get("disks", %{})
    |> Enum.sort_by(fn {i, _} -> String.to_integer(i) end)
  end

  defp field_class(errors, key), do: ["qa-field", Map.has_key?(errors, key) && "!border-error"]

  defp error(assigns) do
    ~F"""
    <p :if={@errors[@key]} class="mt-1 text-[0.65rem] text-error">{@errors[@key]}</p>
    """
  end

  @cpu_models ~w(max host qemu64 Skylake-Client-v4 EPYC-v4 Nehalem-v2 cortex-a72 cortex-a57 neoverse-n1)

  defp cpu_models, do: @cpu_models

  def render(assigns) do
    ~F"""
    <form
      id="vm-form"
      phx-change="validate_vm"
      phx-submit="save_vm"
      class="min-h-0 flex-1 overflow-y-auto p-5"
      autocomplete="off"
    >
      <div
        :if={@running}
        class="mb-4 flex items-center gap-2 rounded-lg border border-info/40 bg-info/10 px-3 py-2 text-xs text-info"
      >
        <.icon name="hero-information-circle" class="size-4 shrink-0" />
        A VM está ligada: as mudanças valem a partir do próximo boot.
      </div>

      <section :if={@new} class="qa-card mb-4 p-3">
        <h3 class="qa-label mb-2 text-primary">O que vai ser</h3>
        <div class="flex flex-wrap gap-1.5">
          {#for {machine, label, icon} <- presets()}
            <button
              type="button"
              id={"preset-#{machine || "pc"}"}
              phx-click="vm_preset"
              phx-value-machine={machine || ""}
              disabled={not preset_available?(@emulators, machine)}
              class={
                "flex items-center gap-1.5 rounded-md border px-2.5 py-1.5 text-xs transition-colors disabled:opacity-35",
                "border-primary bg-primary/15 font-semibold text-primary": preset_active?(@params, machine),
                "border-base-content/15 hover:border-primary/50 hover:text-primary":
                  not preset_active?(@params, machine)
              }
            >
              <.icon name={icon} class="size-4" /> {label}
            </button>
          {/for}
        </div>
      </section>

      <div class="grid gap-4 xl:grid-cols-2">
        <!-- Geral -->
        <section class="qa-card space-y-3 p-4">
          <h3 class="qa-label text-primary">Geral</h3>
          <div>
            <label class="qa-label" for="vm_name">Nome</label>
            <input
              id="vm_name"
              name="vm[name]"
              value={v(@params, "name")}
              class={field_class(@errors, :name)}
              placeholder="Ex.: Debian 13"
              phx-debounce="300"
            />
            {error(%{errors: @errors, key: :name})}
          </div>
          <div>
            <label class="qa-label" for="vm_notes">Notas</label>
            <textarea id="vm_notes" name="vm[notes]" rows="3" class="qa-field" phx-debounce="500">{v(@params, "notes")}</textarea>
          </div>
        </section>

        <!-- Sistema -->
        <section class="qa-card space-y-3 p-4">
          <h3 class="qa-label text-primary">Sistema</h3>
          <div class="grid grid-cols-2 gap-3">
            <div>
              <label class="qa-label" for="vm_arch">Arquitetura</label>
              <select id="vm_arch" name="vm[arch]" class="qa-field">
                {#for a <- Qemu.arches()}
                  <option value={a} selected={v(@params, "arch") == a}>
                    {a}{if @emulators != [] and a not in @emulators, do: " (indisponível)"}
                  </option>
                {/for}
              </select>
            </div>
            <div>
              <label class="qa-label" for="vm_machine">Placa</label>
              <select id="vm_machine" name="vm[machine]" class="qa-field">
                {#for m <- Vm.machines(v(@params, "arch"))}
                  <option value={m} selected={v(@params, "machine") == m}>{Vm.machine_label(m)}</option>
                {/for}
              </select>
            </div>
            {#if kind(@params) == :esp32}
              <div>
                <label class="qa-label" for="vm_memory">PSRAM (MiB)</label>
                <select id="vm_memory" name="vm[memory]" class={field_class(@errors, :memory)}>
                  <option :for={m <- [0, 2, 4, 8]} value={m} selected={v(@params, "memory") == to_string(m)}>
                    {if m == 0, do: "nenhuma", else: "#{m} MiB"}
                  </option>
                </select>
                {error(%{errors: @errors, key: :memory})}
              </div>
              <div :if={@new}>
                <label class="qa-label" for="vm_flash_size">Flash SPI</label>
                <select id="vm_flash_size" name="vm[flash_size]" class={field_class(@errors, :flash_size)}>
                  <option
                    :for={m <- QemuAdmin.Esp32.Flash.sizes()}
                    value={m}
                    selected={v(@params, "flash_size") == to_string(m)}
                  >{m} MiB</option>
                </select>
                {error(%{errors: @errors, key: :flash_size})}
              </div>
            {/if}
            <div :if={kind(@params) == :raspi}>
              <span class="qa-label">Memória</span>
              <p class="py-1.5 text-xs">{QemuAdminWeb.VmHelpers.memory_label(QemuAdmin.Board.for_machine(v(@params, "machine")).memory)} (a da placa)</p>
            </div>
            <div :if={pc?(@params)}>
              <label class="qa-label" for="vm_cpus">vCPUs</label>
              <input
                id="vm_cpus"
                name="vm[cpus]"
                type="number"
                min="1"
                max="256"
                value={v(@params, "cpus")}
                class={field_class(@errors, :cpus)}
              />
              {error(%{errors: @errors, key: :cpus})}
            </div>
            <div :if={pc?(@params)}>
              <label class="qa-label" for="vm_memory">Memória (MiB)</label>
              <input
                id="vm_memory"
                name="vm[memory]"
                type="number"
                min="16"
                step="1"
                list="memory-presets"
                value={v(@params, "memory")}
                class={field_class(@errors, :memory)}
              />
              <datalist id="memory-presets">
                <option :for={m <- [512, 1024, 2048, 4096, 8192, 16384]} value={m} />
              </datalist>
              {error(%{errors: @errors, key: :memory})}
            </div>
            <div :if={pc?(@params)}>
              <label class="qa-label" for="vm_cpu">Modelo de CPU</label>
              <input
                id="vm_cpu"
                name="vm[cpu]"
                list="cpu-models"
                value={v(@params, "cpu")}
                class="qa-field"
                placeholder="padrão do QEMU"
                phx-debounce="300"
              />
              <datalist id="cpu-models">
                <option :for={c <- cpu_models()} value={c} />
              </datalist>
            </div>
            <div :if={pc?(@params)}>
              <label class="qa-label" for="vm_accel">Aceleração</label>
              <select id="vm_accel" name="vm[accel]" class="qa-field">
                {#for a <- Vm.accels()}
                  <option value={a} selected={v(@params, "accel") == a}>{QemuAdminWeb.VmHelpers.accel_label(a)}</option>
                {/for}
              </select>
            </div>
          </div>
          <p :if={kind(@params) == :esp32} class="text-[0.68rem] text-base-content/50">
            Emulado pelo QEMU da Espressif (sempre TCG). O AtomVM e o seu app vão para a flash na aba Flash, depois de criar.
          </p>
          <p :if={kind(@params) == :avr} class="text-[0.68rem] text-base-content/50">
            Emulado pelo qemu-system-avr. O sketch compilado (.hex) vai para a flash na aba Firmware, depois de criar.
          </p>
          <p :if={kind(@params) == :cortexm} class="text-[0.68rem] text-base-content/50">
            Emulado pelo qemu-system-arm (sempre TCG). O firmware (.elf, .bin ou .hex) vai para a flash na aba Firmware, depois de criar.
          </p>
          <p :if={kind(@params) == :raspi} class="text-[0.68rem] text-base-content/50">
            Emulado pelo QEMU (sempre TCG): o kernel e o device tree saem da imagem do cartão SD.
          </p>
          <div :if={kind(@params) == :raspi and @new}>
            <label class="qa-label" for="vm_sd_image">Imagem do cartão SD (pode ficar para depois)</label>
            <div class="flex gap-1">
              <input
                id="vm_sd_image"
                name="vm[sd_image]"
                value={v(@params, "sd_image")}
                class="qa-field"
                placeholder="Raspberry Pi OS (.img, .img.xz)"
                phx-debounce="400"
              />
              <button
                type="button"
                phx-click="picker_open"
                phx-value-target="new_sd_image"
                phx-value-exts={Enum.join(QemuAdmin.Raspi.Image.extensions(), ",")}
                title="Procurar"
                class="grid size-7 shrink-0 place-items-center rounded border border-base-content/15 text-base-content/55 hover:text-primary"
              >
                <.icon name="hero-folder-open" class="size-4" />
              </button>
            </div>
            <div class="mt-2 grid grid-cols-2 gap-2">
              <div>
                <label class="qa-label" for="vm_sd_user">Usuário (primeiro boot)</label>
                <input
                  id="vm_sd_user"
                  name="vm[sd_user]"
                  value={Map.get(@params, "sd_user", "pi")}
                  class="qa-field"
                />
              </div>
              <div>
                <label class="qa-label" for="vm_sd_password">Senha</label>
                <input
                  id="vm_sd_password"
                  name="vm[sd_password]"
                  value={Map.get(@params, "sd_password", "raspberry")}
                  class="qa-field"
                />
              </div>
            </div>
          </div>
          <div :if={pc?(@params)} class="flex flex-wrap gap-x-6 gap-y-2 pt-1 text-xs">
            <label class="flex items-center gap-2">
              <input type="hidden" name="vm[uefi]" value="false">
              <input
                type="checkbox"
                name="vm[uefi]"
                value="true"
                checked={checked?(@params, "uefi") or v(@params, "arch") == "aarch64"}
                disabled={v(@params, "arch") == "aarch64"}
                class="checkbox checkbox-xs checkbox-primary"
              />
              UEFI {if v(@params, "arch") == "aarch64", do: "(obrigatório no aarch64)"}
            </label>
            <label class="flex items-center gap-2">
              <input type="hidden" name="vm[localtime]" value="false">
              <input
                type="checkbox"
                name="vm[localtime]"
                value="true"
                checked={checked?(@params, "localtime")}
                class="checkbox checkbox-xs checkbox-primary"
              />
              Relógio em hora local (Windows)
            </label>
          </div>
        </section>

        <!-- Armazenamento -->
        <section :if={pc?(@params)} class="qa-card space-y-3 p-4 xl:col-span-2">
          <h3 class="qa-label text-primary">Armazenamento</h3>

          <div
            :if={@new}
            class="grid grid-cols-[1fr_1fr_2fr] items-end gap-3 rounded-md border border-primary/15 bg-primary/5 p-3"
          >
            <div>
              <label class="qa-label" for="vm_disk_size">Novo disco</label>
              <input
                id="vm_disk_size"
                name="vm[disk_size]"
                value={v(@params, "disk_size")}
                class={field_class(@errors, :disk_size)}
                placeholder="Ex.: 40G (vazio: nenhum)"
              />
            </div>
            <div>
              <label class="qa-label" for="vm_disk_format">Formato</label>
              <select id="vm_disk_format" name="vm[disk_format]" class="qa-field">
                <option :for={f <- ~w(qcow2 raw)} value={f} selected={v(@params, "disk_format") == f}>{f}</option>
              </select>
            </div>
            <p class="pb-1.5 text-[0.65rem] text-base-content/45">
              Criado vazio na pasta da VM (qcow2 só ocupa o que for usado). {error(%{errors: @errors, key: :disk_size})}
            </p>
          </div>

          <table class="data-table">
            <thead>
              <tr><th>#</th><th class="fill">Arquivo do disco</th><th>Formato</th><th>Interface</th><th /></tr>
            </thead>
            <tbody>
              {#for {i, d} <- disks(@params)}
                <tr>
                  <td class="text-base-content/40">{i}</td>
                  <td class="fill">
                    <div class="flex gap-1">
                      <input
                        name={"vm[disks][#{i}][path]"}
                        value={d["path"]}
                        class="qa-field"
                        placeholder="caminho (relativo: dentro da pasta da VM)"
                        phx-debounce="400"
                      />
                      <button
                        type="button"
                        phx-click="picker_open"
                        phx-value-target={"disk:#{i}"}
                        phx-value-exts={Enum.join(Img.extensions(), ",")}
                        title="Procurar"
                        class="grid size-7 shrink-0 place-items-center rounded border border-base-content/15 text-base-content/55 hover:text-primary"
                      >
                        <.icon name="hero-folder-open" class="size-4" />
                      </button>
                    </div>
                  </td>
                  <td>
                    <select name={"vm[disks][#{i}][format]"} class="qa-field">
                      <option :for={f <- Img.formats()} value={f} selected={d["format"] == f}>{f}</option>
                    </select>
                  </td>
                  <td>
                    <select
                      name={"vm[disks][#{i}][interface]"}
                      class="qa-field"
                      title={Vm.interface_label(d["interface"])}
                    >
                      <option :for={x <- Vm.interfaces()} value={x} selected={d["interface"] == x}>{x}</option>
                    </select>
                  </td>
                  <td>
                    <button
                      type="button"
                      phx-click="remove_disk_row"
                      phx-value-index={i}
                      title="Remover da VM (o arquivo fica)"
                      class="grid size-7 place-items-center rounded text-base-content/45 hover:bg-error/15 hover:text-error"
                    >
                      <.icon name="hero-trash" class="size-4" />
                    </button>
                  </td>
                </tr>
              {/for}
            </tbody>
          </table>
          {error(%{errors: @errors, key: :disks})}
          <button
            type="button"
            id="add-disk-row"
            phx-click="add_disk_row"
            class="flex items-center gap-1 rounded px-2 py-1 text-xs text-primary hover:bg-primary/10"
          >
            <.icon name="hero-plus" class="size-3.5" /> Anexar disco existente
          </button>

          <div class="grid grid-cols-[3fr_1fr] gap-3 pt-2">
            <div>
              <label class="qa-label" for="vm_cdrom">CD-ROM (ISO)</label>
              <div class="flex gap-1">
                <input
                  id="vm_cdrom"
                  name="vm[cdrom]"
                  value={v(@params, "cdrom")}
                  class="qa-field"
                  placeholder="vazio"
                  phx-debounce="400"
                />
                <button
                  type="button"
                  phx-click="picker_open"
                  phx-value-target="cdrom"
                  phx-value-exts=".iso,.img"
                  title="Procurar"
                  class="grid size-7 shrink-0 place-items-center rounded border border-base-content/15 text-base-content/55 hover:text-primary"
                >
                  <.icon name="hero-folder-open" class="size-4" />
                </button>
              </div>
            </div>
            <div>
              <label class="qa-label" for="vm_boot">Boot por</label>
              <select id="vm_boot" name="vm[boot]" class="qa-field">
                <option value="disk" selected={v(@params, "boot") == "disk"}>Disco</option>
                <option value="cdrom" selected={v(@params, "boot") == "cdrom"}>CD-ROM</option>
              </select>
            </div>
          </div>
        </section>

        <!-- Tela -->
        <section :if={pc?(@params) or kind(@params) == :raspi} class="qa-card space-y-3 p-4">
          <h3 class="qa-label text-primary">Tela e entrada</h3>
          <div class="grid grid-cols-2 gap-3">
            <div>
              <label class="qa-label" for="vm_display">Tela</label>
              <select id="vm_display" name="vm[display]" class="qa-field">
                <option :for={d <- Vm.displays()} value={d} selected={v(@params, "display") == d}>{Vm.display_label(d)}</option>
              </select>
            </div>
            <div :if={pc?(@params)}>
              <label class="qa-label" for="vm_vga">Placa de vídeo</label>
              <select id="vm_vga" name="vm[vga]" class="qa-field" disabled={v(@params, "arch") == "aarch64"}>
                <option :for={g <- Vm.vgas()} value={g} selected={v(@params, "vga") == g}>{g}</option>
              </select>
            </div>
          </div>
          <label :if={pc?(@params)} class="flex items-center gap-2 text-xs">
            <input type="hidden" name="vm[usb_tablet]" value="false">
            <input
              type="checkbox"
              name="vm[usb_tablet]"
              value="true"
              checked={checked?(@params, "usb_tablet")}
              class="checkbox checkbox-xs checkbox-primary"
            />
            Tablet USB (o ponteiro acompanha o mouse no console)
          </label>
        </section>

        <!-- Rede -->
        <section :if={kind(@params) not in [:avr, :cortexm]} class="qa-card space-y-3 p-4">
          <h3 class="qa-label text-primary">Rede</h3>
          <div class="grid grid-cols-2 gap-3">
            <div>
              <label class="qa-label" for="vm_net_mode">Modo</label>
              <select id="vm_net_mode" name="vm[net_mode]" class="qa-field">
                <option value="user" selected={v(@params, "net_mode") == "user"}>NAT (usuário)</option>
                <option value="none" selected={v(@params, "net_mode") == "none"}>Sem rede</option>
              </select>
            </div>
            <div :if={pc?(@params)}>
              <label class="qa-label" for="vm_net_model">Placa</label>
              <select id="vm_net_model" name="vm[net_model]" class="qa-field">
                <option :for={m <- Vm.net_models()} value={m} selected={v(@params, "net_model") == m}>{m}</option>
              </select>
            </div>
          </div>
          <div>
            <label class="qa-label" for="vm_forwards">Portas redirecionadas (host → VM)</label>
            <textarea
              id="vm_forwards"
              name="vm[forwards]"
              rows="2"
              class={field_class(@errors, :forwards)}
              placeholder="tcp:2222:22&#10;tcp:3389:3389"
              phx-debounce="500"
            >{v(@params, "forwards")}</textarea>
            {error(%{errors: @errors, key: :forwards})}
          </div>
        </section>

        <!-- Avançado -->
        <section class="qa-card space-y-3 p-4 xl:col-span-2">
          <h3 class="qa-label text-primary">Avançado</h3>
          <div>
            <label class="qa-label" for="vm_extra_args">Argumentos extras do QEMU</label>
            <textarea
              id="vm_extra_args"
              name="vm[extra_args]"
              rows="2"
              class={field_class(@errors, :extra_args)}
              placeholder="-device intel-hda -device hda-duplex"
              phx-debounce="500"
            >{v(@params, "extra_args")}</textarea>
            {error(%{errors: @errors, key: :extra_args})}
          </div>
        </section>
      </div>

      <div class="sticky bottom-0 mt-5 flex justify-end gap-2 border-t border-primary/15 bg-base-100/90 py-3 backdrop-blur">
        <button
          type="button"
          phx-click="cancel_form"
          class="rounded-md border border-base-content/15 px-4 py-1.5 text-xs hover:bg-base-300"
        >
          Cancelar
        </button>
        <button
          type="submit"
          id="save-vm"
          phx-disable-with="Salvando…"
          class="rounded-md bg-primary px-4 py-1.5 text-xs font-semibold text-primary-content hover:brightness-110"
        >
          {if @new, do: "Criar VM", else: "Salvar"}
        </button>
      </div>
    </form>
    """
  end
end
