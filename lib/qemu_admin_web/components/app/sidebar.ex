defmodule QemuAdminWeb.Components.App.Sidebar do
  @moduledoc """
  The left-most icon rail, as in the Rockwell Viewer: the mark on top, one
  icon per view, and Configurações, the theme menu and the expand/collapse
  button at the bottom. Collapsed it is a strip of icons; expanded it shows
  labels.

  Purely presentational: every item sends `nav` with its `view`, handled by
  `QemuAdminWeb.AdminLive`. The VMs item carries a badge with how many are
  running.
  """

  use Surface.Component

  import QemuAdminWeb.CoreComponents, only: [icon: 1]
  alias QemuAdminWeb.Components.App.Logo

  @doc "Whether the rail is expanded (labels shown)."
  prop expanded, :boolean, default: false

  @doc "The highlighted item's view."
  prop current, :string, default: "vms"

  @doc "How many VMs are running (the badge on Máquinas virtuais)."
  prop running, :integer, default: 0

  @doc "Every selectable daisyUI theme, in menu order."
  prop themes, :list, default: []

  @items [
    %{icon: "hero-computer-desktop", label: "Máquinas virtuais", view: "vms"},
    %{icon: "hero-circle-stack", label: "Discos", view: "disks"},
    %{icon: "hero-disc", label: "Imagens", view: "images"},
    %{icon: "hero-cpu-chip", label: "QEMU", view: "qemu"},
    %{icon: "hero-command-line", label: "Comandos", view: "commands"}
  ]

  defp items, do: @items

  def render(assigns) do
    ~F"""
    <aside class={
      "relative z-40 flex flex-col justify-between shrink-0 h-full border-r border-primary/20 panel-glass transition-[width] duration-200 ease-out",
      "w-56": @expanded,
      "w-[var(--qa-rail)]": not @expanded
    }>
      <div>
        <div class="flex items-center gap-2 h-[var(--qa-bar)] px-[10.5px] border-b border-primary/20 overflow-hidden">
          <Logo class="size-5 text-primary svg-glow shrink-0" />
          <span
            :if={@expanded}
            class="font-bold tracking-widest text-primary text-glow whitespace-nowrap text-sm"
          >
            QEMU<span class="text-base-content">.ADMIN</span>
          </span>
        </div>
        <nav class="flex flex-col gap-1.5 p-1" aria-label="Navegação">
          {#for item <- items()}
            <button
              type="button"
              id={"nav-#{item.view}"}
              phx-click="nav"
              phx-value-view={item.view}
              class={
                "relative flex items-center gap-3 rounded px-[6.5px] h-8 text-sm transition-colors overflow-hidden text-left",
                "bg-primary/10 text-primary border border-primary/30": item.view == @current,
                "text-base-content/60 border border-transparent hover:bg-base-300 hover:text-base-content":
                  item.view != @current
              }
              title={item.label}
            >
              <.icon name={item.icon} class="size-5 shrink-0" />
              <span :if={@expanded} class="whitespace-nowrap">{item.label}</span>
              <span
                :if={item.view == "vms" and @running > 0}
                class="absolute right-0.5 top-0.5 grid min-w-3.5 h-3.5 place-items-center rounded-full bg-success px-0.5 text-[0.55rem] font-bold leading-none text-success-content"
              >
                {@running}
              </span>
            </button>
          {/for}
        </nav>
      </div>
      <div class="p-1 border-t border-primary/20 space-y-1.5">
        <button
          type="button"
          id="nav-settings"
          phx-click="nav"
          phx-value-view="settings"
          class={
            "flex items-center gap-3 w-full rounded px-[6.5px] h-8 text-sm transition-colors overflow-hidden text-left",
            "bg-primary/10 text-primary border border-primary/30": @current == "settings",
            "text-base-content/60 border border-transparent hover:bg-base-300 hover:text-primary":
              @current != "settings"
          }
          title="Configurações"
        >
          <.icon name="hero-cog-6-tooth" class="size-5 shrink-0" />
          <span :if={@expanded} class="whitespace-nowrap">Configurações</span>
        </button>
        <!-- Opens rightward: the rail is against the window's left edge. -->
        <div class="dropdown dropdown-top dropdown-start w-full">
          <div
            tabindex="0"
            role="button"
            title="Tema"
            class="flex items-center gap-3 w-full rounded px-[6.5px] h-8 text-sm text-base-content/60 hover:bg-base-300 hover:text-primary transition-colors cursor-pointer"
          >
            <.icon name="hero-swatch" class="size-5 shrink-0" />
            <span :if={@expanded} class="whitespace-nowrap">Tema</span>
          </div>
          <ul
            tabindex="0"
            class="dropdown-content z-50 menu menu-sm bg-base-200 text-base-content border border-primary/20 rounded-lg shadow-xl w-56 max-h-80 flex-nowrap overflow-y-auto p-1"
          >
            <li :for={name <- @themes}>
              <button
                type="button"
                phx-click={Phoenix.LiveView.JS.dispatch("phx:set-theme")}
                data-phx-theme={name}
                class="flex items-center gap-2 font-mono text-xs"
              >
                <!-- Each swatch carries its own data-theme, so it previews that palette. -->
                <span
                  data-theme={name}
                  class="flex gap-0.5 shrink-0 rounded p-0.5 bg-base-100 border border-base-content/20"
                >
                  <span class="size-2 rounded-sm bg-primary" />
                  <span class="size-2 rounded-sm bg-secondary" />
                  <span class="size-2 rounded-sm bg-accent" />
                  <span class="size-2 rounded-sm bg-neutral" />
                </span>
                <span class="truncate">{name}</span>
              </button>
            </li>
          </ul>
        </div>
        <button
          type="button"
          phx-click="toggle_sidebar"
          class="flex items-center gap-3 w-full rounded px-[6.5px] h-8 text-sm text-base-content/60 hover:bg-base-300 hover:text-primary transition-colors"
          title={if @expanded, do: "Recolher", else: "Expandir"}
        >
          <.icon
            name={if @expanded, do: "hero-chevron-double-left", else: "hero-chevron-double-right"}
            class="size-5 shrink-0"
          />
          <span :if={@expanded} class="whitespace-nowrap">Recolher</span>
        </button>
      </div>
    </aside>
    """
  end
end
