defmodule QemuAdminWeb.Components.Vm.SerialConsole do
  @moduledoc """
  An ESP32's console: its UART in a terminal (the `SerialTerm` hook,
  xterm.js). While the chip runs, what it prints streams in and what is
  typed goes to it; with it off, the last run's output (`serial.log`) stays
  readable.

  Under it, a **send bar** (`SerialSend` hook): a line of text, what ends it
  (nada, LF, CR, CR+LF) and Enter or *Enviar*; ↑ / ↓ walk what was sent. It goes
  out as `serial_input`, like the terminal's own keystrokes. On top, a button
  shows or hides the **side panel** (`split`): the board drawn, or the VM's summary,
  next to the terminal (`toggle_split`).

  The element id carries the run (its start time), so a restart mounts a
  fresh terminal. Events: `serial_init`, `serial_input` (from the hooks),
  `start_vm`, `toggle_split`.
  """

  use Surface.Component

  import QemuAdminWeb.CoreComponents, only: [icon: 1]
  import QemuAdminWeb.VmHelpers

  prop vm, :struct, required: true
  prop rt, :map, required: true

  @doc "Whether the side panel is open."
  prop split, :boolean, default: false

  @doc "What the side panel shows, for the button: `\"a placa\"` or `\"o resumo\"`."
  prop side_label, :string, default: "a placa"

  defp run_id(%{started_at: %DateTime{} = t}), do: DateTime.to_unix(t, :millisecond)
  defp run_id(_), do: "off"

  def render(assigns) do
    ~F"""
    <div class="relative flex min-h-0 min-w-0 flex-1 flex-col bg-[#0c0a09]">
      <div class="flex items-center gap-2 border-b border-primary/15 bg-base-200/60 px-3 py-1 text-[0.68rem] text-base-content/55">
        <span class="font-mono">UART</span>
        <span :if={stopped?(@rt)} class="text-base-content/40">· última execução</span>
        <button
          type="button"
          id="serial-split"
          phx-click="toggle_split"
          aria-pressed={to_string(@split)}
          class={
            "ml-auto inline-flex items-center gap-1.5 rounded border px-2 py-0.5 hover:bg-base-300",
            "border-primary/50 bg-primary/10 text-primary": @split,
            "border-base-content/20": not @split
          }
        >
          <.icon name="hero-view-columns" class="size-3.5" />
          {if @split, do: "Ocultar #{@side_label}", else: "Mostrar #{@side_label} ao lado"}
        </button>
      </div>
      <div
        id={"serial-#{@vm.id}-#{run_id(@rt)}"}
        phx-hook="SerialTerm"
        phx-update="ignore"
        data-vm-id={@vm.id}
        data-live={if running?(@rt), do: "1", else: "0"}
        class="min-h-0 flex-1 p-2"
      >
        <div data-term class="size-full" />
      </div>
      <form
        id={"serial-send-#{@vm.id}"}
        phx-hook="SerialSend"
        data-vm-id={@vm.id}
        autocomplete="off"
        class="flex shrink-0 items-center gap-2 border-t border-primary/15 bg-base-200/80 px-2 py-1.5"
      >
        <.icon name="hero-chevron-right" class="size-3.5 shrink-0 text-primary/70" />
        <input
          type="text"
          name="text"
          spellcheck="false"
          disabled={stopped?(@rt)}
          placeholder={if stopped?(@rt), do: "Ligue a placa para enviar", else: "Texto para a UART — Enter envia, ↑ ↓ repetem"}
          class="min-w-0 flex-1 rounded border border-base-content/15 bg-base-100 px-2 py-1 font-mono text-xs outline-none focus:border-primary disabled:opacity-50"
        />
        <select
          name="eol"
          title="O que termina a linha enviada"
          class="rounded border border-base-content/15 bg-base-100 px-1.5 py-1 text-xs"
        >
          <option value="cr">+ CR</option>
          <option value="lf">+ LF</option>
          <option value="crlf">+ CR LF</option>
          <option value="none">sem fim</option>
        </select>
        <button
          type="submit"
          disabled={stopped?(@rt)}
          class="rounded bg-primary px-3 py-1 text-xs font-semibold text-primary-content hover:brightness-110 disabled:opacity-40"
        >
          Enviar
        </button>
      </form>
    </div>
    """
  end
end
