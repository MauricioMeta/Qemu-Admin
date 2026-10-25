defmodule QemuAdminWeb.Components.Vm.Flash do
  @moduledoc """
  An ESP32's "Flash" — `esptool.py write_flash`, done to the VM's
  `flash.bin` (`QemuAdmin.Esp32.Flash`):

    * **AtomVM** — a release's image for the chip, downloaded, checked and
      written over an erased flash;
    * **App** — an `.avm` (`mix atomvm.packbeam`) into one of AtomVM's app
      partitions (`main.avm`);
    * **Avançado** — any binary at an offset (an ESP-IDF build merged with
      `esptool merge_bin`), or the whole flash erased.

  Only with the chip off — QEMU holds the file while it runs.

  Events: `atomvm_install` (`tag`, `flavor`), `picker_open` (targets
  `flash_app:<partition>` and `flash_bin`), `flash_offset`, `flash_erase`.
  """

  use Surface.Component

  import QemuAdminWeb.CoreComponents, only: [icon: 1]
  import QemuAdminWeb.VmHelpers

  alias QemuAdmin.Esp32.Flash, as: F
  alias QemuAdmin.Qemu.Img

  prop vm, :struct, required: true
  prop rt, :map, required: true

  @doc "`%{path:, size:, partitions:, error:}` of the VM's flash."
  prop flash, :map, required: true

  @doc "`%{releases: [%{tag:, prerelease:}] | nil, error:, busy:}` — the AtomVM card."
  prop atomvm, :map, required: true

  @doc "The offset typed in Avançado."
  prop offset, :string, default: "0x0"

  defp hex(n), do: "0x" <> String.pad_leading(F.hex(n), 6, "0")

  defp type_label(%{type: :app}), do: "app"
  defp type_label(%{name: name}) when name in ["nvs", "phy_init"], do: "dados (ESP-IDF)"
  defp type_label(_), do: "dados"

  # the newest release that is not a beta: what to flash unless asked otherwise
  defp stable(releases), do: Enum.find_value(releases, &(not &1.prerelease && &1.tag))

  defp avm_parts(%{partitions: parts}) do
    Enum.filter(
      parts,
      &(&1.type == :data and String.ends_with?(&1.name, ".avm") and &1.name != "boot.avm")
    )
  end

  def render(assigns) do
    ~F"""
    <div id="vm-flash" class="min-h-0 flex-1 overflow-y-auto p-5">
      <div
        :if={not stopped?(@rt)}
        class="mb-4 flex items-center gap-2 rounded-lg border border-info/40 bg-info/10 px-3 py-2 text-xs text-info"
      >
        <.icon name="hero-information-circle" class="size-4 shrink-0" />
        O chip está ligado: desligue-o para gravar a flash.
      </div>
      <div
        :if={@flash.error}
        class="mb-4 flex items-center gap-2 rounded-lg border border-error/40 bg-error/10 px-3 py-2 text-xs text-error"
      >
        <.icon name="hero-exclamation-triangle" class="size-4 shrink-0" />
        {@flash.error}
      </div>

      <div class="grid gap-4 xl:grid-cols-2">
        <section class="qa-card p-4">
          <h3 class="qa-label mb-1 text-primary">AtomVM</h3>
          <p class="mb-3 text-xs text-base-content/55">
            A máquina virtual BEAM para microcontroladores. Baixa a imagem da versão escolhida
            ({@vm.machine}), confere o SHA-256, apaga a flash e grava em {hex(F.bootloader_offset(@vm.machine))}.
          </p>
          <form
            id="atomvm-form"
            phx-submit="atomvm_install"
            class="grid grid-cols-[1fr_1fr_auto] items-end gap-2"
          >
            <div>
              <label class="qa-label" for="atomvm_tag">Versão</label>
              <select id="atomvm_tag" name="tag" class="qa-field" disabled={is_nil(@atomvm.releases)}>
                {#if is_nil(@atomvm.releases)}
                  <option>{if @atomvm.error, do: "indisponível", else: "carregando…"}</option>
                {#else}
                  <option :for={r <- @atomvm.releases} value={r.tag} selected={r.tag == stable(@atomvm.releases)}>
                    {r.tag}{if r.prerelease, do: " (pré-lançamento)"}
                  </option>
                {/if}
              </select>
            </div>
            <div>
              <label class="qa-label" for="atomvm_flavor">Bibliotecas</label>
              <select id="atomvm_flavor" name="flavor" class="qa-field">
                <option value="elixir">Elixir + Erlang</option>
                <option value="erlang">Só Erlang</option>
              </select>
            </div>
            <button
              type="submit"
              id="atomvm-install"
              disabled={not stopped?(@rt) or @atomvm.busy or is_nil(@atomvm.releases)}
              data-confirm="Apagar a flash e gravar o AtomVM?"
              class="h-[1.875rem] rounded-md bg-primary px-3 text-xs font-semibold text-primary-content hover:brightness-110 disabled:opacity-40"
            >
              {if @atomvm.busy, do: "Gravando…", else: "Baixar e gravar"}
            </button>
          </form>
          <p :if={@atomvm.error} class="mt-2 text-xs text-error">{@atomvm.error}</p>
          <p class="mt-3 flex items-center gap-2 text-xs">
            <.icon name="hero-cpu-chip" class="size-4 text-base-content/40" />
            <span class="text-base-content/50">Na flash:</span>
            <span class="font-semibold">{if @vm.firmware in [nil, ""], do: "—", else: @vm.firmware}</span>
          </p>
        </section>

        <section class="qa-card p-4">
          <h3 class="qa-label mb-1 text-primary">App (.avm)</h3>
          <p class="mb-3 text-xs text-base-content/55">
            O seu programa, empacotado com <code class="text-primary/80">mix atomvm.packbeam</code>
            ou <code class="text-primary/80">rebar3 atomvm packbeam</code>. O AtomVM o inicia no boot.
          </p>
          {#if avm_parts(@flash) == []}
            <p class="text-xs text-base-content/45">A flash não tem partição de app — grave o AtomVM primeiro.</p>
          {#else}
            {#for p <- avm_parts(@flash)}
              <div class="flex items-center gap-3 border-t border-base-content/5 py-2 text-xs first:border-t-0">
                <span class="font-mono font-semibold">{p.name}</span>
                <span class="text-base-content/45">{hex(p.offset)} · {Img.human(p.size)}</span>
                <span class={"flex-1", "text-success": p.used, "text-base-content/35": not p.used}>
                  {if p.used, do: "gravada", else: "vazia"}
                </span>
                <button
                  type="button"
                  id={"flash-app-#{p.name}"}
                  phx-click="picker_open"
                  phx-value-target={"flash_app:#{p.name}"}
                  phx-value-exts=".avm"
                  disabled={not stopped?(@rt)}
                  class="rounded border border-primary/30 px-2 py-1 text-primary hover:bg-primary/10 disabled:opacity-40"
                >
                  Gravar .avm…
                </button>
              </div>
            {/for}
          {/if}
          <p class="mt-3 flex items-center gap-2 text-xs">
            <.icon name="hero-cube" class="size-4 text-base-content/40" />
            <span class="text-base-content/50">App:</span>
            <span class="min-w-0 truncate font-semibold" title={@vm.app}>{if @vm.app in [nil, ""], do: "—", else: Path.basename(@vm.app)}</span>
          </p>
        </section>
      </div>

      <section class="qa-card mt-4 p-4">
        <div class="mb-2 flex items-center justify-between">
          <h3 class="qa-label mb-0">Partições</h3>
          <span class="font-mono text-[0.68rem] text-base-content/45" title={@flash.path}>
            flash.bin · {if @flash.size, do: Img.human(@flash.size), else: "?"}
          </span>
        </div>
        <table class="data-table">
          <thead>
            <tr><th class="fill">Nome</th><th>Tipo</th><th>Início</th><th>Tamanho</th><th>Conteúdo</th></tr>
          </thead>
          <tbody>
            <tr :for={p <- @flash.partitions}>
              <td class="fill font-mono">{p.name}</td>
              <td>{type_label(p)}</td>
              <td class="font-mono">{hex(p.offset)}</td>
              <td>{Img.human(p.size)}</td>
              <td class={if p.used, do: "text-success", else: "text-base-content/35"}>{if p.used, do: "gravada", else: "vazia"}</td>
            </tr>
            <tr :if={@flash.partitions == []}>
              <td colspan="5" class="py-3 text-center text-base-content/40">
                Sem tabela de partições — a flash está vazia (ou não é do ESP-IDF).
              </td>
            </tr>
          </tbody>
        </table>
      </section>

      <section class="qa-card mt-4 p-4">
        <h3 class="qa-label mb-1">Avançado</h3>
        <p class="mb-3 text-xs text-base-content/55">
          Qualquer binário num endereço, como o <code>esptool write_flash</code> — por exemplo uma build do ESP-IDF
          juntada com <code>esptool merge_bin</code> (em 0x0).
        </p>
        <div class="flex flex-wrap items-end gap-2">
          <form id="flash-offset-form" phx-change="flash_offset" onsubmit="return false">
            <label class="qa-label" for="flash_offset">Endereço (hex)</label>
            <input id="flash_offset" name="offset" value={@offset} class="qa-field w-32 font-mono">
          </form>
          <button
            type="button"
            id="flash-bin"
            phx-click="picker_open"
            phx-value-target="flash_bin"
            phx-value-exts=".bin,.img"
            disabled={not stopped?(@rt)}
            class="h-[1.875rem] rounded border border-primary/30 px-3 text-xs text-primary hover:bg-primary/10 disabled:opacity-40"
          >
            Gravar binário…
          </button>
          <span class="flex-1" />
          <button
            type="button"
            id="flash-erase"
            phx-click="flash_erase"
            data-confirm="Apagar a flash inteira? O AtomVM e o app vão junto."
            disabled={not stopped?(@rt)}
            class="h-[1.875rem] rounded border border-error/40 px-3 text-xs text-error hover:bg-error/10 disabled:opacity-40"
          >
            Apagar flash
          </button>
        </div>
      </section>
    </div>
    """
  end
end
