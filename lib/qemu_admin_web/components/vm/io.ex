defmodule QemuAdminWeb.Components.Vm.Io do
  @moduledoc """
  A board's "Placa" view: the board drawn with its pins live
  (`QemuAdminWeb.Components.Vm.Board`), a legend, and the GPIOs in use as
  a table — direction, level, and for an input a button to flip it.

  Events: `gpio_toggle` (`gpio`).
  """

  use Surface.Component

  import QemuAdminWeb.CoreComponents, only: [icon: 1]
  import QemuAdminWeb.VmHelpers

  alias QemuAdmin.Board
  alias QemuAdminWeb.Components.Vm.Board, as: BoardSvg

  prop vm, :struct, required: true
  prop rt, :map, required: true
  prop board, :map, required: true

  @doc "`QemuAdmin.Gpio.snapshot/1` (nil when off)."
  prop gpio, :map, default: nil

  defp label(board, g) do
    pin = Enum.find(Board.pins(board), &(&1.ref == g))
    name = if pin, do: pin.label, else: "?"
    if board.kind == :avr, do: "#{name} · #{Board.avr_name(g)}", else: "#{name} · GPIO#{g}"
  end

  # outputs, inputs driven from here or pulled up, alternate functions
  defp in_use(nil), do: []

  defp in_use(gpio) do
    driven = Map.get(gpio, :driven, %{})

    gpio.pins
    |> Enum.filter(fn {g, p} ->
      p.dir in [:out, :alt] or p.level == 1 or Map.has_key?(driven, g)
    end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp status(nil, rt),
    do: if(stopped?(rt), do: "Desligada — ligue a placa para ver os pinos.", else: "Conectando…")

  defp status(%{status: :attaching}, _rt), do: "Conectando ao gdbstub do QEMU…"
  defp status(%{status: :running}, _rt), do: "Seguindo os pinos pelo gdbstub do QEMU."
  defp status(%{status: :polling}, _rt), do: "Lendo os registradores do GPIO (BCM2835) pelo QMP."
  defp status(%{status: :paused}, _rt), do: "Pausada."
  defp status(%{status: :error, error: e}, _rt), do: "IO indisponível: #{e}"
  defp status(_, _rt), do: ""

  def render(assigns) do
    ~F"""
    <div id="vm-io" class="min-h-0 flex-1 overflow-y-auto p-5">
      <div class="grid gap-4 2xl:grid-cols-[minmax(0,1.6fr)_minmax(0,1fr)]">
        <section class="qa-card p-4">
          <div class="mb-3 flex items-center gap-2 text-xs">
            <.icon name="hero-cpu-chip" class="size-4 text-primary" />
            <span class="font-semibold">{@board.name}</span>
            <span class="text-base-content/45">{@board.chip}</span>
            <span class="flex-1" />
            <span class={"text-base-content/50", "text-error": match?(%{status: :error}, @gpio)}>{status(@gpio, @rt)}</span>
          </div>
          <div class="mx-auto max-w-3xl">
            <BoardSvg board={@board} gpio={@gpio} on={running?(@rt)} />
          </div>
          <div class="mt-3 flex flex-wrap items-center gap-x-4 gap-y-1 text-[0.68rem] text-base-content/60">
            <span class="flex items-center gap-1.5"><span class="size-2.5 rounded-full bg-[#ef4444]" /> saída alta</span>
            <span class="flex items-center gap-1.5"><span class="size-2.5 rounded-full bg-[#4c0d0d]" /> saída baixa</span>
            <span class="flex items-center gap-1.5"><span class="size-2.5 rounded-full bg-[#60a5fa]" /> entrada alta</span>
            <span class="flex items-center gap-1.5"><span class="size-2.5 rounded-full bg-[#1e3a8a]" /> entrada baixa</span>
            <span class="flex items-center gap-1.5"><span class="size-2.5 rounded-full bg-[#a855f7]" /> outra função</span>
            <span class="flex items-center gap-1.5"><span class="size-2.5 rounded-full bg-[#f97316]" /> alimentação</span>
          </div>
          <p class="mt-2 text-[0.68rem] text-base-content/45">
            {#if @gpio && @gpio.inputs?}
              Clique numa entrada (borda azul) para inverter o nível que chega nela — um botão, uma chave.
            {#elseif @board.io == :raspi}
              No Raspberry Pi os pinos são lidos dos registradores do chip; as entradas não podem ser acionadas de fora.
            {/if}
          </p>
        </section>

        <section class="qa-card p-4">
          <h3 class="qa-label mb-2">Pinos em uso</h3>
          <table class="data-table">
            <thead><tr><th class="fill">Pino</th><th>Direção</th><th>Nível</th><th /></tr></thead>
            <tbody>
              <tr :for={{g, p} <- in_use(@gpio)} id={"gpio-row-#{g}"}>
                <td class="fill font-mono">{label(@board, g)}</td>
                <td>{case p.dir do
                    :out -> "saída"
                    :in -> if Map.get(p, :pullup), do: "entrada (pull-up)", else: "entrada"
                    :alt -> "outra função"
                  end}</td>
                <td class={
                  "font-semibold",
                  "text-error": p.dir == :out and p.level == 1,
                  "text-info": p.dir == :in and p.level == 1
                }>
                  {if p.level == 1, do: "ALTO", else: "baixo"}
                </td>
                <td>
                  <button
                    :if={p.dir == :in and @gpio.inputs?}
                    type="button"
                    phx-click="gpio_toggle"
                    phx-value-gpio={g}
                    class="rounded border border-info/40 px-2 py-0.5 text-[0.68rem] text-info hover:bg-info/10"
                  >inverter</button>
                </td>
              </tr>
              <tr :if={in_use(@gpio) == []}>
                <td colspan="4" class="py-4 text-center text-base-content/40">
                  {if @gpio, do: "Nenhum pino configurado ainda.", else: "—"}
                </td>
              </tr>
            </tbody>
          </table>
        </section>
      </div>
    </div>
    """
  end
end
