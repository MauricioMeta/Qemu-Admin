defmodule QemuAdminWeb.Components.Vm.Firmware do
  @moduledoc """
  An Arduino's "Firmware": the program in its flash
  (`QemuAdmin.Avr.Firmware`) — pick the `.hex` the Arduino IDE exports
  (Sketch › Exportar binário compilado) or `arduino-cli compile
  --output-dir` writes, an `.elf` or a raw `.bin`. Only with the board off.

  Events: `picker_open` (target `avr_firmware`), `avr_erase`.
  """

  use Surface.Component

  import QemuAdminWeb.CoreComponents, only: [icon: 1]
  import QemuAdminWeb.VmHelpers

  alias QemuAdmin.Avr.Firmware, as: Fw
  alias QemuAdmin.Qemu.Img

  prop vm, :struct, required: true
  prop rt, :map, required: true

  @doc "The program file in the VM's folder (`Vm.Args.avr_firmware/1`), or nil."
  prop file, :string, default: nil

  def render(assigns) do
    ~F"""
    <div id="vm-firmware" class="min-h-0 flex-1 overflow-y-auto p-5">
      <div
        :if={not stopped?(@rt)}
        class="mb-4 flex items-center gap-2 rounded-lg border border-info/40 bg-info/10 px-3 py-2 text-xs text-info"
      >
        <.icon name="hero-information-circle" class="size-4 shrink-0" />
        A placa está ligada: desligue-a para gravar outro programa.
      </div>
      <div class="grid gap-4 xl:grid-cols-2">
        <section class="qa-card p-4">
          <h3 class="qa-label mb-1 text-primary">Programa na flash</h3>
          <p class="mb-3 text-xs text-base-content/55">
            O sketch compilado: no Arduino IDE, <em>Sketch › Exportar binário compilado</em>; na linha de comando,
            <code class="text-primary/80">arduino-cli compile -b arduino:avr:uno --output-dir out</code>.
            Use o <code>.hex</code> (ou o <code>.elf</code>) — não o <code>with_bootloader</code>.
          </p>
          <div class="flex items-center gap-2 text-xs">
            <.icon name="hero-cpu-chip" class="size-4 text-base-content/40" />
            <span class="min-w-0 flex-1 truncate font-semibold" title={@vm.app}>
              {cond do
                is_nil(@file) -> "flash vazia"
                @vm.firmware in [nil, ""] -> Path.basename(@file)
                true -> @vm.firmware
              end}
            </span>
            <span :if={@file} class="text-base-content/45">{Img.human(File.stat!(@file).size)}</span>
          </div>
          <div class="mt-3 flex gap-2">
            <button
              type="button"
              id="avr-firmware"
              phx-click="picker_open"
              phx-value-target="avr_firmware"
              phx-value-exts={Enum.join(Fw.extensions(), ",")}
              disabled={not stopped?(@rt)}
              class="rounded-md bg-primary px-3 py-1.5 text-xs font-semibold text-primary-content hover:brightness-110 disabled:opacity-40"
            >
              Gravar programa…
            </button>
            <button
              :if={@file}
              type="button"
              id="avr-erase"
              phx-click="avr_erase"
              data-confirm="Apagar o programa da flash?"
              disabled={not stopped?(@rt)}
              class="rounded-md border border-error/40 px-3 py-1.5 text-xs text-error hover:bg-error/10 disabled:opacity-40"
            >
              Apagar
            </button>
          </div>
        </section>
        <section class="qa-card p-4 text-xs text-base-content/60">
          <h3 class="qa-label mb-2">Como a placa é emulada</h3>
          <ul class="list-disc space-y-1.5 pl-4">
            <li>O ATmega roda no QEMU (<code>qemu-system-avr</code>); a <code>Serial</code> sai na aba Serial.</li>
            <li>
              Os pinos aparecem na aba Placa: o app segue cada acesso às portas pelo gdbstub do QEMU, e as entradas
              (botões) se acionam clicando no pino.
            </li>
            <li>
              O QEMU não tem o Timer0: o app faz o papel dele, então <code>millis()</code> e <code>delay()</code>
              andam no ritmo aproximado do relógio. PWM (<code>analogWrite</code>) e o ADC
              (<code>analogRead</code>) não são emulados.
            </li>
          </ul>
        </section>
      </div>
    </div>
    """
  end
end
