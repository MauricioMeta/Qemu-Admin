defmodule QemuAdminWeb.Components.Pages.Qemu do
  @moduledoc """
  The QEMU in use and where else one was looked for: the folder, its
  origin (embedded in the app, downloaded, PATH…), version, emulators and
  accelerators — and the button that downloads the portable build
  (`QemuAdmin.Qemu.InstallJob`), with its progress. Below, Espressif's QEMU
  (the ESP32, `QemuAdmin.Qemu.Esp`), found or downloaded the same way.

  Events: `install_qemu` (`kind`: none or `esp`), `refresh_qemu`, `nav`
  (to Configurações).
  """

  use Surface.Component

  import QemuAdminWeb.CoreComponents, only: [icon: 1]

  alias QemuAdmin.Qemu
  alias QemuAdmin.Qemu.{Esp, Img}

  @doc "`QemuAdmin.Qemu.info/0`."
  prop qemu, :map, required: true

  @doc "`QemuAdmin.Qemu.InstallJob.state/1` of the portable QEMU."
  prop install, :map, required: true

  @doc "`QemuAdmin.Qemu.InstallJob.state/1` of Espressif's."
  prop install_esp, :map, required: true

  defp busy?(%{phase: p}), do: p in [:resolve, :download, :verify, :extract]

  defp phase_label(:resolve), do: "procurando a versão mais nova…"
  defp phase_label(:download), do: "baixando…"
  defp phase_label(:verify), do: "verificando o checksum…"
  defp phase_label(:extract), do: "descompactando…"
  defp phase_label(:done), do: "instalado"
  defp phase_label(:error), do: "falhou"
  defp phase_label(_), do: ""

  defp pct(%{received: r, total: t}) when is_integer(t) and t > 0, do: div(r * 100, t)
  defp pct(_), do: nil

  defp candidate_ok?(dir) when is_binary(dir) and dir != "" do
    File.regular?(Path.join(dir, "qemu-img.exe")) or File.regular?(Path.join(dir, "qemu-img"))
  end

  defp candidate_ok?(_), do: false

  def render(assigns) do
    ~F"""
    <div id="qemu-page" class="min-h-0 flex-1 overflow-y-auto p-5">
      <section class={"qa-card mb-4 p-5", "!border-warning/50": is_nil(@qemu.dir)}>
        {#if @qemu.dir}
          <div class="flex items-start gap-4">
            <.icon name="hero-check-badge" class="size-10 shrink-0 text-success" />
            <div class="min-w-0 flex-1">
              <p class="text-lg font-bold">QEMU {@qemu.version || "?"}</p>
              <p class="text-xs text-base-content/55">{Qemu.source_label(@qemu.source)}</p>
              <p class="mt-1 truncate font-mono text-[0.68rem] text-base-content/45" title={@qemu.dir}>{@qemu.dir}</p>
            </div>
            <button
              type="button"
              id="refresh-qemu"
              phx-click="refresh_qemu"
              class="flex items-center gap-1 rounded px-2 py-1 text-xs text-base-content/55 hover:bg-base-300 hover:text-primary"
            >
              <.icon name="hero-arrow-path" class="size-3.5" /> Procurar de novo
            </button>
          </div>
          <div class="mt-4 grid gap-4 md:grid-cols-2">
            <div>
              <p class="qa-label">Emuladores</p>
              <div class="flex flex-wrap gap-1.5">
                {#for a <- Qemu.arches() -- ["xtensa"]}
                  <span class={
                    "rounded border px-2 py-0.5 font-mono text-[0.68rem]",
                    "border-success/40 text-success": a in @qemu.emulators,
                    "border-base-content/10 text-base-content/30 line-through": a not in @qemu.emulators
                  }>qemu-system-{a}</span>
                {/for}
              </div>
            </div>
            <div>
              <p class="qa-label">Aceleradores</p>
              <div class="flex flex-wrap gap-1.5">
                <span
                  :for={a <- @qemu.accels}
                  class={
                    "rounded border px-2 py-0.5 font-mono text-[0.68rem]",
                    "border-primary/40 text-primary": a != "tcg",
                    "border-base-content/20 text-base-content/60": a == "tcg"
                  }
                >{a}</span>
              </div>
              <p :if={"whpx" in @qemu.accels} class="mt-1.5 text-[0.65rem] text-base-content/45">
                WHPX precisa do recurso "Plataforma do Hipervisor do Windows" ativado. Sem ele, as VMs caem para TCG (mais lento).
              </p>
            </div>
          </div>
        {#else}
          <div class="flex items-start gap-4">
            <.icon name="hero-exclamation-triangle" class="size-10 shrink-0 text-warning" />
            <div>
              <p class="text-lg font-bold">QEMU não encontrado</p>
              <p class="text-xs text-base-content/55">
                Baixe a versão portátil abaixo (sem instalar nada no sistema) ou aponte uma pasta em Configurações.
              </p>
            </div>
          </div>
        {/if}
      </section>

      <section class="qa-card mb-4 p-5">
        <div class="flex items-start gap-4">
          <.icon name="hero-arrow-down-tray" class="size-8 shrink-0 text-primary/70" />
          <div class="min-w-0 flex-1">
            <p class="font-semibold">QEMU portátil para Windows</p>
            <p class="text-xs text-base-content/55">
              A build de Stefan Weil (a indicada em qemu.org), verificada por SHA-512 e descompactada na pasta de dados do app —
              sem permissão de administrador. Ficam só os emuladores x86_64, i386, aarch64, arm (Raspberry Pi) e avr (Arduino) (~420 MB).
            </p>
            {#if busy?(@install)}
              <div class="mt-3">
                <div class="mb-1 flex justify-between text-[0.68rem] text-base-content/60">
                  <span>{phase_label(@install.phase)}</span>
                  <span :if={@install.phase == :download}>
                    {Img.human(@install.received)}{if @install.total, do: " / #{Img.human(@install.total)}"}
                  </span>
                </div>
                <progress class="progress progress-primary w-full" value={pct(@install)} max="100" />
              </div>
            {/if}
            <p :if={@install.phase == :error} class="mt-2 text-xs text-error">{@install.error}</p>
            <p :if={@install.phase == :done} class="mt-2 text-xs text-success">QEMU instalado.</p>
          </div>
          <button
            type="button"
            id="install-qemu"
            phx-click="install_qemu"
            disabled={busy?(@install)}
            class="shrink-0 rounded-md bg-primary px-4 py-1.5 text-xs font-semibold text-primary-content hover:brightness-110 disabled:opacity-40"
          >
            {if @qemu.source == :downloaded, do: "Atualizar", else: "Baixar QEMU"}
          </button>
        </div>
      </section>

      <section id="qemu-esp" class="qa-card mb-4 p-5">
        <div class="flex items-start gap-4">
          <.icon
            name="hero-cpu-chip"
            class={"size-8 shrink-0", "text-success": Esp.available?(), "text-primary/70": not Esp.available?()}
          />
          <div class="min-w-0 flex-1">
            <p class="font-semibold">QEMU da Espressif — ESP32</p>
            {#if Esp.available?()}
              <p class="text-xs text-base-content/55">
                {Esp.info().version} · {Esp.source_label(Esp.info().source)} · placas {Enum.join(Esp.machines(), ", ")}
              </p>
              <p class="mt-1 truncate font-mono text-[0.68rem] text-base-content/45" title={Esp.info().dir}>{Esp.info().dir}</p>
            {#else}
              <p class="text-xs text-base-content/55">
                O QEMU oficial não emula o ESP32: a Espressif mantém um fork com os chips ESP32 e ESP32-S3,
                a flash SPI e a serial. Baixado do GitHub da Espressif, verificado por SHA-256 (~35 MB).
              </p>
            {/if}
            {#if busy?(@install_esp)}
              <div class="mt-3">
                <div class="mb-1 flex justify-between text-[0.68rem] text-base-content/60">
                  <span>{phase_label(@install_esp.phase)}</span>
                  <span :if={@install_esp.phase == :download}>
                    {Img.human(@install_esp.received)}{if @install_esp.total, do: " / #{Img.human(@install_esp.total)}"}
                  </span>
                </div>
                <progress class="progress progress-primary w-full" value={pct(@install_esp)} max="100" />
              </div>
            {/if}
            <p :if={@install_esp.phase == :error} class="mt-2 text-xs text-error">{@install_esp.error}</p>
            <p :if={@install_esp.phase == :done} class="mt-2 text-xs text-success">QEMU da Espressif instalado.</p>
          </div>
          <button
            type="button"
            id="install-qemu-esp"
            phx-click="install_qemu"
            phx-value-kind="esp"
            disabled={busy?(@install_esp)}
            class="shrink-0 rounded-md bg-primary px-4 py-1.5 text-xs font-semibold text-primary-content hover:brightness-110 disabled:opacity-40"
          >
            {if Esp.available?(), do: "Atualizar", else: "Baixar"}
          </button>
        </div>
      </section>

      <section class="qa-card p-5">
        <div class="mb-2 flex items-center justify-between">
          <h3 class="qa-label mb-0">Onde o QEMU é procurado (nesta ordem)</h3>
          <button
            type="button"
            phx-click="nav"
            phx-value-view="settings"
            class="text-[0.68rem] text-primary hover:underline"
          >
            Escolher uma pasta…
          </button>
        </div>
        <table class="data-table">
          <thead><tr><th /><th>Origem</th><th class="fill">Pasta</th></tr></thead>
          <tbody>
            {#for {source, dir} <- Qemu.candidates()}
              <tr>
                <td>
                  {#if @qemu.dir && dir == @qemu.dir}
                    <.icon name="hero-arrow-right-circle-solid" class="size-4 text-primary" />
                  {#elseif candidate_ok?(dir)}
                    <.icon name="hero-check-circle" class="size-4 text-success/70" />
                  {#else}
                    <.icon name="hero-minus-circle" class="size-4 text-base-content/20" />
                  {/if}
                </td>
                <td>{Qemu.source_label(source)}</td>
                <td class="fill"><span class="clip font-mono text-[0.68rem]" title={dir}>{dir || "—"}</span></td>
              </tr>
            {/for}
          </tbody>
        </table>
      </section>
    </div>
    """
  end
end
