defmodule QemuAdminWeb.Components.App.Footer do
  @moduledoc """
  The slim status bar along the bottom, as in the Rockwell Viewer: the app
  name and version on the left; on the right the QEMU in use (version and
  where it came from — a click opens its page) and how many VMs are running.
  """

  use Surface.Component

  alias QemuAdmin.Qemu

  @doc "`QemuAdmin.Qemu.info/0`."
  prop qemu, :map, required: true

  @doc "How many VMs are running."
  prop running, :integer, default: 0

  @doc "Total VMs defined."
  prop total, :integer, default: 0

  defp version do
    case :application.get_key(:qemu_admin, :vsn) do
      {:ok, vsn} -> to_string(vsn)
      _ -> "dev"
    end
  end

  def render(assigns) do
    ~F"""
    <footer class="flex items-center justify-between gap-3 px-4 h-8 shrink-0 border-t border-primary/20 panel-glass text-[0.7rem] font-mono">
      <span class="text-base-content/40">
        QEMU<span class="text-base-content/60">.ADMIN</span>
        <span class="text-base-content/25 ml-1">v{version()}</span>
      </span>

      <div class="flex items-center gap-4">
        <span
          id="footer-vms"
          class={if @running > 0, do: "text-success/80", else: "text-base-content/35"}
        >
          <span class={
            "inline-block size-1.5 rounded-full mr-1",
            "bg-success status-dot-live": @running > 0,
            "bg-base-content/30": @running == 0
          } />
          {@running}/{@total} em execução
        </span>
        <button
          type="button"
          id="footer-qemu"
          phx-click="nav"
          phx-value-view="qemu"
          class={
            "flex items-center gap-1.5 hover:underline",
            "text-base-content/50": @qemu.dir,
            "text-warning": is_nil(@qemu.dir)
          }
          title={@qemu.dir || "QEMU não encontrado"}
        >
          {#if @qemu.dir}
            QEMU {@qemu.version || "?"} · {Qemu.source_label(@qemu.source)}
          {#else}
            QEMU não encontrado
          {/if}
        </button>
      </div>
    </footer>
    """
  end
end
