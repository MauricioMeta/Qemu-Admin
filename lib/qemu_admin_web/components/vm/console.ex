defmodule QemuAdminWeb.Components.Vm.Console do
  @moduledoc """
  A VM's screen in the page: the noVNC client (`VncConsole` hook) connected
  to QEMU's VNC WebSocket. With the VM off — or showing in its own SDL/GTK
  window, or headless — it says so instead.

  The hook reconnects when `ws` changes (the VM was restarted). The page's
  toolbar sends `qa:vnc-*` window events for Ctrl+Alt+Del, fullscreen and
  scaling.
  """

  use Surface.Component

  import QemuAdminWeb.CoreComponents, only: [icon: 1]
  import QemuAdminWeb.VmHelpers

  alias QemuAdmin.Vm

  prop vm, :struct, required: true
  prop rt, :map, required: true

  defp ws_port(%{ports: %{ws: ws}}), do: to_string(ws)
  defp ws_port(_), do: nil

  def render(assigns) do
    ~F"""
    {#if running?(@rt) and @vm.display == "vnc"}
      <div
        id={"vnc-console-#{@vm.id}"}
        phx-hook="VncConsole"
        phx-update="ignore"
        data-ws-port={ws_port(@rt)}
        class="qa-console relative min-h-0 flex-1 bg-black/60"
      >
        <div data-screen class="absolute inset-0" />
        <div
          data-status
          class="pointer-events-none absolute left-1/2 top-1/2 -translate-x-1/2 -translate-y-1/2 rounded bg-base-100/80 px-3 py-1.5 text-xs text-base-content/70"
        >
          conectando…
        </div>
      </div>
    {#else}
      <div class="grid min-h-0 flex-1 place-items-center p-8 text-center">
        <div class="max-w-sm">
          {#if stopped?(@rt)}
            <.icon name="hero-power" class="mx-auto mb-3 size-10 text-base-content/20" />
            <p class="text-sm font-semibold text-base-content/70">A VM está desligada</p>
            <button
              type="button"
              phx-click="start_vm"
              phx-value-id={@vm.id}
              class="mt-4 inline-flex items-center gap-2 rounded-md border border-success/40 px-3 py-1.5 text-xs text-success hover:bg-success/10"
            >
              <.icon name="hero-play-solid" class="size-4" /> Ligar
            </button>
          {#else}
            <.icon name="hero-window" class="mx-auto mb-3 size-10 text-base-content/20" />
            <p class="text-sm font-semibold text-base-content/70">{Vm.display_label(@vm.display)}</p>
            <p class="mt-1 text-xs text-base-content/45">
              {if @vm.display == "none",
                do: "Esta VM roda sem tela. Use a rede (portas redirecionadas) para acessá-la.",
                else:
                  "A tela desta VM abre em uma janela do próprio QEMU. Para vê-la aqui, mude a tela para \"Console no app\" na Configuração."}
            </p>
          {/if}
        </div>
      </div>
    {/if}
    """
  end
end
