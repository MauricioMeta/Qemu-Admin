defmodule QemuAdminWeb.Components.Vm.SerialConsole do
  @moduledoc """
  An ESP32's console: its UART in a terminal (the `SerialTerm` hook,
  xterm.js). While the chip runs, what it prints streams in and what is
  typed goes to it; with it off, the last run's output (`serial.log`) stays
  readable.

  The element id carries the run (its start time), so a restart mounts a
  fresh terminal. Events: `serial_init`, `serial_input` (from the hook),
  `start_vm`.
  """

  use Surface.Component

  import QemuAdminWeb.CoreComponents, only: [icon: 1]
  import QemuAdminWeb.VmHelpers

  prop vm, :struct, required: true
  prop rt, :map, required: true

  defp run_id(%{started_at: %DateTime{} = t}), do: DateTime.to_unix(t, :millisecond)
  defp run_id(_), do: "off"

  def render(assigns) do
    ~F"""
    <div class="relative flex min-h-0 flex-1 flex-col bg-[#0c0a09]">
      <div
        :if={stopped?(@rt)}
        class="flex items-center gap-3 border-b border-primary/15 bg-base-200/80 px-4 py-2 text-xs text-base-content/60"
      >
        <.icon name="hero-power" class="size-4 text-base-content/35" />
        <span class="flex-1">O chip está desligado — abaixo, a saída da última execução.</span>
        <button
          type="button"
          phx-click="start_vm"
          phx-value-id={@vm.id}
          class="inline-flex items-center gap-1.5 rounded-md border border-success/40 px-2.5 py-1 text-success hover:bg-success/10"
        >
          <.icon name="hero-play-solid" class="size-3.5" /> Ligar
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
    </div>
    """
  end
end
