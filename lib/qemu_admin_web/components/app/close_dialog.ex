defmodule QemuAdminWeb.Components.App.CloseDialog do
  @moduledoc """
  Asked when the desktop window is closed with VMs running: closing the app
  stops them. "Desligar e sair" presses each VM's power button (ACPI) and
  waits for the guests (`stop_timeout`), "Forçar" ends QEMU at once.
  While the VMs go down it shows that instead of the buttons.

  Events: `close_confirm` with `how` = `shutdown`, `force` or `cancel`.
  """

  use Surface.Component

  import QemuAdminWeb.CoreComponents, only: [icon: 1]

  @doc "nil (hidden), `:ask` or `:closing`."
  prop state, :atom, default: nil

  @doc "Names of the running VMs."
  prop names, :list, default: []

  prop timeout, :integer, default: 30

  def render(assigns) do
    ~F"""
    <div
      :if={@state}
      id="close-dialog"
      class="fixed inset-0 z-50 grid place-items-center bg-black/55 p-6"
    >
      <div class="w-full max-w-md rounded-lg border border-warning/40 bg-base-200 p-5 shadow-2xl">
        {#if @state == :closing}
          <p class="flex items-center gap-2 text-sm font-semibold">
            <span class="loading loading-spinner loading-sm text-warning" />
            Desligando as VMs…
          </p>
          <p class="mt-2 text-xs text-base-content/55">
            Esperando até {@timeout}s pelos sistemas convidados; depois o QEMU é encerrado.
          </p>
        {#else}
          <p class="flex items-center gap-2 text-sm font-semibold text-warning">
            <.icon name="hero-exclamation-triangle" class="size-5" />
            {length(@names)} VM(s) em execução
          </p>
          <p class="mt-2 text-xs text-base-content/65">
            Fechar o QEMU Admin desliga: <span class="font-semibold">{Enum.join(@names, ", ")}</span>.
          </p>
          <div class="mt-5 flex justify-end gap-2">
            <button
              type="button"
              id="close-cancel"
              phx-click="close_confirm"
              phx-value-how="cancel"
              class="rounded-md border border-base-content/15 px-3 py-1.5 text-xs hover:bg-base-300"
            >
              Cancelar
            </button>
            <button
              type="button"
              id="close-force"
              phx-click="close_confirm"
              phx-value-how="force"
              class="rounded-md border border-error/40 px-3 py-1.5 text-xs text-error hover:bg-error/10"
            >
              Forçar
            </button>
            <button
              type="button"
              id="close-shutdown"
              phx-click="close_confirm"
              phx-value-how="shutdown"
              class="rounded-md bg-warning px-3 py-1.5 text-xs font-semibold text-warning-content hover:brightness-110"
            >
              Desligar e sair
            </button>
          </div>
        {/if}
      </div>
    </div>
    """
  end
end
