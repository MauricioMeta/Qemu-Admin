defmodule QemuAdminWeb.Components.App.Tabs do
  @moduledoc """
  The open VMs' tab bar, a slim strip between the toolbar and the
  breadcrumb, as the Rockwell Viewer's (Obsidian's editor tabs, square): the
  one on screen sits on the page below it (its colour, a thin border on the
  sides and a line of the primary colour at the top: `.qa-tab` in
  `app.css`), with a close button (always on the active one, on hover for
  the others) and a status dot.

  It only draws what the page tells it. Events: `activate_tab` and
  `close_tab` (`id`), a middle click closing too (`TabBar` hook).

  A tab is `%{id:, label:, status:}`.
  """

  use Surface.Component

  import QemuAdminWeb.CoreComponents, only: [icon: 1]

  alias QemuAdminWeb.Components.Vm.StatusDot

  @doc "`[%{id:, label:, status:}]`, in the order they were opened."
  prop tabs, :list, default: []

  @doc "The `id` of the tab on screen (nil: a page of the app is)."
  prop active, :any, default: nil

  def render(assigns) do
    ~F"""
    <div
      id="page-tabs"
      phx-hook="TabBar"
      aria-label="VMs abertas"
      class="relative flex h-[var(--qa-bar)] shrink-0 items-end bg-base-200"
    >
      <!-- the strip's line, under the tabs: the active one covers it -->
      <div class="pointer-events-none absolute inset-x-0 bottom-0 h-px bg-primary/20" />
      <div class="flex min-w-0 flex-1 items-end gap-px qa-no-scrollbar overflow-x-auto overflow-y-hidden">
        {#for {tab, i} <- Enum.with_index(@tabs)}
          <div
            id={"tab-#{i}"}
            data-tab-id={tab.id}
            aria-current={if tab.id == @active, do: "true"}
            data-active={tab.id == @active}
            class={
              "qa-tab group flex h-[var(--qa-bar)] min-w-0 max-w-[16rem] shrink-0 items-center gap-1.5 border-x pl-3 pr-1.5 text-xs",
              "border-primary/20 font-semibold text-base-content": tab.id == @active,
              "border-transparent text-base-content/55 hover:bg-base-content/5 hover:text-base-content":
                tab.id != @active
            }
          >
            <StatusDot status={tab.status} />
            <button
              type="button"
              phx-click="activate_tab"
              phx-value-id={tab.id}
              title={tab.label}
              class="min-w-0 truncate py-1 text-left"
            >
              {tab.label}
            </button>
            <button
              type="button"
              phx-click="close_tab"
              phx-value-id={tab.id}
              title="Fechar"
              aria-label={"Fechar #{tab.label}"}
              class={
                "grid size-5 shrink-0 place-items-center rounded text-base-content/45 hover:bg-base-300 hover:text-base-content",
                "opacity-0 focus:opacity-100 group-hover:opacity-100": tab.id != @active
              }
            >
              <.icon name="hero-x-mark" class="size-3.5" />
            </button>
          </div>
        {/for}
      </div>
    </div>
    """
  end
end
