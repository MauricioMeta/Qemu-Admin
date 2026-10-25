defmodule QemuAdminWeb.Components.App.TitleBar do
  @moduledoc """
  The window's title bar, drawn by the app instead of by the system — the
  one from Eleuther.IO.

  The desktop window is built without decorations (`src-tauri/src/main.rs`)
  so the bar follows the daisyUI theme. Dragging comes from
  `data-tauri-drag-region`; the three buttons go through the IPC from the
  `WindowControls` hook (`assets/js/hooks/window_controls.js`), with the
  permissions in `src-tauri/capabilities/default.json`.

  Closing is the app's: the hook asks the page first (`window_close`), which
  confirms when VMs are running — see `QemuAdminWeb.AdminLive`.

  In a browser tab there is no window to move and the bar renders nothing
  (`:desktop?` in `config/runtime.exs`).
  """

  use Surface.Component

  defp desktop?, do: Application.get_env(:qemu_admin, :desktop?, false)

  def render(assigns) do
    ~F"""
    <header
      :if={desktop?()}
      id="window-chrome"
      phx-hook="WindowControls"
      data-tauri-drag-region="true"
      class="group flex items-center shrink-0 h-8 select-none bg-neutral text-neutral-content"
    >
      <!-- Everything that isn't a button gives up the pointer, so a press
           anywhere on the bar lands on the bar itself — the element carrying
           the drag region. -->
      <div class="flex-1 min-w-0 px-3 text-center pointer-events-none">
        <span class="text-[0.7rem] font-mono tracking-wider text-neutral-content/70 truncate">
          QEMU Admin
        </span>
      </div>
      <button
        type="button"
        data-action="minimize"
        title="Minimizar"
        class="flex items-center justify-center w-11 h-full text-neutral-content/70 hover:bg-neutral-content/15 hover:text-neutral-content transition-colors"
      >
        <svg width="10" height="10" viewBox="0 0 10 10" fill="none" stroke="currentColor">
          <path d="M0 5.5h10" />
        </svg>
      </button>
      <button
        type="button"
        data-action="maximize"
        title="Maximizar"
        class="flex items-center justify-center w-11 h-full text-neutral-content/70 hover:bg-neutral-content/15 hover:text-neutral-content transition-colors"
      >
        <svg
          width="10"
          height="10"
          viewBox="0 0 10 10"
          fill="none"
          stroke="currentColor"
          class="group-data-[maximized]:hidden"
        >
          <rect x="0.5" y="0.5" width="9" height="9" />
        </svg>
        <svg
          width="10"
          height="10"
          viewBox="0 0 10 10"
          fill="none"
          stroke="currentColor"
          class="hidden group-data-[maximized]:block"
        >
          <rect x="0.5" y="2.5" width="7" height="7" /><path d="M2.5 2.5v-2h7v7h-2" />
        </svg>
      </button>
      <button
        type="button"
        data-action="close"
        title="Fechar"
        class="flex items-center justify-center w-11 h-full text-neutral-content/70 hover:bg-error hover:text-error-content transition-colors"
      >
        <svg width="10" height="10" viewBox="0 0 10 10" fill="none" stroke="currentColor">
          <path d="M0.5 0.5l9 9M9.5 0.5l-9 9" />
        </svg>
      </button>
    </header>
    """
  end
end
