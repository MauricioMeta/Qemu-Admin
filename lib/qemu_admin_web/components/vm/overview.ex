defmodule QemuAdminWeb.Components.Vm.Overview do
  @moduledoc """
  A VM's "Visão geral": its screen (the last screenshot, a click opens the
  console), what it is made of — hardware, disks, CD, network — and the
  command line QEMU runs with. When the last run failed, its exit code and
  last lines lead the page. An ESP32 shows its last serial lines where a PC
  shows its screen, and its flash where a PC has a CD.

  Events: `vm_view` (`view`), `picker_open` (for the CD), `eject_cdrom`,
  `qa:copy` (the command line, client side).
  """

  use Surface.Component

  import QemuAdminWeb.CoreComponents, only: [icon: 1]
  import QemuAdminWeb.VmHelpers

  alias Phoenix.LiveView.JS
  alias QemuAdmin.Vm
  alias QemuAdmin.Qemu.Img
  alias QemuAdminWeb.Components.App.Logo

  prop vm, :struct, required: true
  prop rt, :map, required: true

  @doc "`qemu-img info` of each disk, by path (`%{path => {:ok, info} | {:error, msg}}`)."
  prop disk_info, :map, default: %{}

  @doc "The command line (running: the real one; stopped: what it would be)."
  prop command, :any, default: nil

  @doc "An ESP32's last lines of serial output."
  prop serial_tail, :list, default: []
  defp row(assigns) do
    ~F"""
    <div class="flex items-baseline justify-between gap-4 border-t border-base-content/5 py-1.5 first:border-t-0">
      <span class="shrink-0 text-[0.65rem] uppercase tracking-wider text-base-content/40">{@label}</span>
      <span class="min-w-0 truncate text-right text-xs" title={@value}>{@value}</span>
    </div>
    """
  end

  def render(assigns) do
    ~F"""
    <div id="vm-overview" class="min-h-0 flex-1 overflow-y-auto p-5">
      <div
        :if={stopped?(@rt) and Map.get(@rt, :exit_code, 0) not in [0, nil]}
        id="vm-last-error"
        class="mb-4 rounded-lg border border-error/40 bg-error/10 p-3 text-xs"
      >
        <p class="mb-2 flex items-center gap-2 font-semibold text-error">
          <.icon name="hero-exclamation-triangle" class="size-4" />
          A última execução terminou com erro (código {@rt.exit_code})
        </p>
        <pre class="max-h-40 overflow-auto whitespace-pre-wrap font-mono text-[0.68rem] text-base-content/70">{Enum.join(Map.get(@rt, :tail, []), "\n")}</pre>
      </div>

      <div class="grid gap-4 xl:grid-cols-[minmax(0,var(--overview-split,1.3fr))_1rem_minmax(0,1fr)] xl:gap-x-0">
        <section class="qa-card overflow-hidden">
          <button
            type="button"
            phx-click="vm_view"
            phx-value-view="console"
            class="relative block aspect-video w-full"
            title="Abrir o console"
          >
            {#if Vm.mcu?(@vm)}
              <pre class={
                "size-full overflow-hidden bg-[#0c0a09] p-3 text-left font-mono text-[0.65rem] leading-snug text-stone-300",
                "opacity-50": stopped?(@rt)
              }>{Enum.join(@serial_tail, "\n")}</pre>
            {#elseif screen_url(@vm, @rt)}
              <img
                src={screen_url(@vm, @rt)}
                alt=""
                class={"qa-screen size-full", "opacity-40 grayscale": stopped?(@rt)}
              />
            {#else}
              <div class="qa-screen grid size-full place-items-center">
                <Logo class="size-20 text-base-content/10" />
              </div>
            {/if}
            <span
              :if={stopped?(@rt) and not Vm.mcu?(@vm)}
              class="absolute inset-0 grid place-items-center text-xs uppercase tracking-widest text-base-content/50"
            >
              Desligada
            </span>
          </button>
          <div class="flex items-center gap-4 border-t border-primary/10 px-4 py-2 text-[0.68rem] text-base-content/50">
            <span :if={running?(@rt)}>Ligada há {uptime(@rt)}</span>
            <span :if={running?(@rt) and @vm.display == "vnc" and @rt[:ports]}>
              VNC 127.0.0.1:{@rt.ports.vnc}
            </span>
            <span :if={stopped?(@rt) and not Vm.mcu?(@vm)}>{Vm.display_label(@vm.display)}</span>
            <span :if={Vm.mcu?(@vm)}>Serial (UART0){if stopped?(@rt), do: " · última execução"}</span>
          </div>
        </section>

        {!-- between the two columns (wide windows): drag to resize, double click for the default --}
        <div
          id="overview-resizer"
          phx-hook="SplitResizer"
          data-var="--overview-split"
          data-key="qa:overview-split"
          class="split-resizer hidden xl:block"
          title="Arraste para redimensionar · duplo clique volta ao padrão"
        />

        <section :if={Vm.kind(@vm) == :esp32} class="qa-card p-4">
          <h3 class="qa-label mb-2">Placa</h3>
          {row(%{label: "Placa", value: Vm.board(@vm).name})}
          {row(%{label: "Chip", value: Vm.board(@vm).chip})}
          {row(%{label: "PSRAM", value: if(@vm.memory > 0, do: memory_label(@vm.memory), else: "nenhuma")})}
          {row(%{label: "Firmware", value: if(@vm.firmware in [nil, ""], do: "—", else: @vm.firmware)})}
          {row(%{label: "App", value: if(@vm.app in [nil, ""], do: "—", else: Path.basename(@vm.app))})}
          {row(%{label: "Emulador", value: "QEMU da Espressif (TCG)"})}
          {row(%{
            label: "Rede",
            value: if(@vm.net_mode == "none", do: "sem rede", else: "NAT (OpenCores Ethernet)")
          })}
          {row(%{
            label: "Portas",
            value: if(@vm.forwards == [], do: "—", else: Enum.join(@vm.forwards, ", "))
          })}
          {row(%{label: "MAC", value: Vm.mac(@vm)})}
        </section>

        <section :if={Vm.kind(@vm) == :avr} class="qa-card p-4">
          <h3 class="qa-label mb-2">Placa</h3>
          {row(%{label: "Placa", value: Vm.board(@vm).name})}
          {row(%{label: "Chip", value: Vm.board(@vm).chip})}
          {row(%{
            label: "Programa",
            value: if(@vm.firmware in [nil, ""], do: "flash vazia", else: @vm.firmware)
          })}
          {row(%{label: "Emulador", value: "qemu-system-avr (TCG)"})}
          {row(%{label: "Serial", value: "USART0 → aba Serial"})}
        </section>

        <section :if={Vm.kind(@vm) == :cortexm} class="qa-card p-4">
          <h3 class="qa-label mb-2">Placa</h3>
          {row(%{label: "Placa", value: Vm.board(@vm).name})}
          {row(%{label: "Chip", value: Vm.board(@vm).chip})}
          {row(%{
            label: "Programa",
            value: if(@vm.firmware in [nil, ""], do: "flash vazia", else: @vm.firmware)
          })}
          {row(%{label: "Emulador", value: "qemu-system-arm · #{@vm.machine} (TCG)"})}
          {row(%{label: "Serial", value: "USART1 → aba Serial"})}
        </section>

        <section :if={Vm.kind(@vm) == :renode} class="qa-card p-4">
          <h3 class="qa-label mb-2">Placa</h3>
          {row(%{label: "Placa", value: @vm.machine})}
          {row(%{label: "Emulador", value: "Renode #{QemuAdmin.Renode.info().version}"})}
          {row(%{label: "Programa", value: QemuAdmin.Firmwares.active(@vm) || "nenhum (escolha na árvore da lateral)"})}
          {row(%{label: "Serial", value: "#{QemuAdmin.Renode.uart(@vm) || "—"} → aba Serial"})}
        </section>

        <section :if={Vm.kind(@vm) == :raspi} class="qa-card p-4">
          <h3 class="qa-label mb-2">Placa</h3>
          {row(%{label: "Placa", value: Vm.board(@vm).name})}
          {row(%{label: "Chip", value: Vm.board(@vm).chip})}
          {row(%{label: "Memória", value: memory_label(@vm.memory)})}
          {row(%{label: "Cartão SD", value: if(@vm.firmware in [nil, ""], do: "—", else: @vm.firmware)})}
          {row(%{label: "Kernel", value: if(@vm.kernel == "", do: "—", else: "#{@vm.kernel} · #{@vm.dtb}")})}
          {row(%{label: "Tela", value: Vm.display_label(@vm.display)})}
          {row(%{
            label: "Rede",
            value:
              if(@vm.net_mode == "none" or not Vm.board(@vm).usb?,
                do: "sem rede",
                else: "NAT (USB Ethernet)"
              )
          })}
          {row(%{
            label: "Portas",
            value: if(@vm.forwards == [], do: "—", else: Enum.join(@vm.forwards, ", "))
          })}
        </section>

        <section :if={Vm.kind(@vm) == :pc} class="qa-card p-4">
          <h3 class="qa-label mb-2">Hardware</h3>
          {row(%{label: "Arquitetura", value: "#{@vm.arch} · #{@vm.machine}"})}
          {row(%{label: "CPU", value: "#{@vm.cpus} × #{if @vm.cpu == "", do: "padrão", else: @vm.cpu}"})}
          {row(%{label: "Memória", value: memory_label(@vm.memory)})}
          {row(%{label: "Aceleração", value: accel_label(@vm.accel)})}
          {row(%{label: "Firmware", value: if(@vm.uefi, do: "UEFI (edk2)", else: "BIOS (SeaBIOS)")})}
          {row(%{label: "Vídeo", value: if(@vm.arch == "aarch64", do: "virtio-gpu", else: @vm.vga)})}
          {row(%{label: "Tela", value: Vm.display_label(@vm.display)})}
          {row(%{
            label: "Rede",
            value: if(@vm.net_mode == "none", do: "sem rede", else: "NAT (#{@vm.net_model})")
          })}
          {row(%{
            label: "Portas",
            value: if(@vm.forwards == [], do: "—", else: Enum.join(@vm.forwards, ", "))
          })}
          {row(%{label: "MAC", value: Vm.mac(@vm)})}
        </section>
      </div>

      <section :if={Vm.kind(@vm) not in [:avr, :cortexm, :renode]} class="qa-card mt-4 p-4">
        <h3 class="qa-label mb-2">{case Vm.kind(@vm) do
            :esp32 -> "Flash SPI"
            :raspi -> "Cartão SD"
            _ -> "Discos"
          end}</h3>
        <table class="data-table">
          <thead>
            <tr><th>#</th><th class="fill">Arquivo</th><th>Formato</th><th>Interface</th><th>Tamanho</th><th>Ocupado</th></tr>
          </thead>
          <tbody>
            {#for {d, i} <- Enum.with_index(@vm.disks)}
              <tr>
                <td class="text-base-content/40">{i}</td>
                <td class="fill"><span class="clip" title={Vm.resolve(@vm, d["path"])}>{d["path"]}</span></td>
                <td>{d["format"]}</td>
                <td>{d["interface"]}</td>
                {#case Map.get(@disk_info, Vm.resolve(@vm, d["path"]))}
                  {#match {:ok, info}}
                    <td>{Img.human(info.virtual_size)}</td>
                    <td>{Img.human(info.actual_size)}</td>
                  {#match {:error, msg}}
                    <td colspan="2" class="text-error" title={msg}>indisponível</td>
                  {#match _}
                    <td>—</td><td>—</td>
                {/case}
              </tr>
            {/for}
            <tr :if={@vm.disks == []}>
              <td colspan="6" class="py-3 text-center text-base-content/40">
                {if Vm.kind(@vm) == :raspi,
                  do: "Sem cartão — importe uma imagem na aba Cartão SD.",
                  else: "Sem discos — boot só pelo CD."}
              </td>
            </tr>
          </tbody>
        </table>

        <h3 :if={Vm.kind(@vm) == :pc} class="qa-label mb-2 mt-4">CD-ROM</h3>
        <div :if={Vm.kind(@vm) == :pc} class="flex items-center gap-2 text-xs">
          <span class="hero-disc size-4 shrink-0 text-base-content/40" />
          <span class="min-w-0 flex-1 truncate" title={@vm.cdrom}>
            {if @vm.cdrom in [nil, ""], do: "vazio", else: @vm.cdrom}
          </span>
          <button
            type="button"
            id="cdrom-change"
            phx-click="picker_open"
            phx-value-target="cdrom_live"
            phx-value-exts=".iso,.img"
            class="rounded border border-primary/30 px-2 py-1 text-primary hover:bg-primary/10"
          >
            {if running?(@rt), do: "Trocar mídia", else: "Escolher ISO"}
          </button>
          <button
            :if={@vm.cdrom not in [nil, ""]}
            type="button"
            id="cdrom-eject"
            phx-click="eject_cdrom"
            class="rounded border border-base-content/15 px-2 py-1 text-base-content/60 hover:bg-base-300"
          >
            Ejetar
          </button>
        </div>
      </section>

      <section :if={@command} class="qa-card mt-4 p-4">
        <div class="mb-2 flex items-center justify-between">
          <h3 class="qa-label mb-0">Linha de comando {if stopped?(@rt), do: "(próxima execução)"}</h3>
          <button
            type="button"
            id="copy-command"
            data-copy={@command}
            phx-click={JS.dispatch("qa:copy")}
            class="flex items-center gap-1 rounded px-2 py-1 text-[0.68rem] text-base-content/50 hover:bg-base-300 hover:text-primary"
          >
            <.icon name="hero-clipboard-document" class="size-3.5" /> Copiar
          </button>
        </div>
        <pre class="max-h-48 overflow-auto whitespace-pre-wrap break-all rounded bg-base-300/60 p-3 font-mono text-[0.68rem] text-base-content/70">{@command}</pre>
      </section>

      <section :if={@vm.notes not in [nil, ""]} class="qa-card mt-4 p-4">
        <h3 class="qa-label mb-2">Notas</h3>
        <p class="whitespace-pre-wrap text-xs text-base-content/70">{@vm.notes}</p>
      </section>
    </div>
    """
  end
end
