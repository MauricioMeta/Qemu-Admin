defmodule QemuAdminWeb.Components.Pages.SettingsNav do
  @moduledoc """
  The side panel while the rail is on Configurações: the sections, one row
  each, as the Rockwell Viewer's. A click sends `show_section`.

  Also the one list of sections (`sections/0`), which
  `Pages.Settings` draws and `QemuAdmin.Settings` tags its entries with.
  """

  use Surface.Component

  import QemuAdminWeb.CoreComponents, only: [icon: 1]

  prop section, :atom, default: :qemu

  @sections [
    %{
      key: :qemu,
      label: "QEMU",
      icon: "hero-cpu-chip",
      hint: "Qual QEMU usar e os padrões das VMs novas."
    },
    %{
      key: :storage,
      label: "Armazenamento",
      icon: "hero-folder",
      hint: "Onde ficam as VMs e as ISOs."
    },
    %{
      key: :general,
      label: "Geral",
      icon: "hero-adjustments-horizontal",
      hint: "O que acontece ao fechar o app."
    },
    %{
      key: :about,
      label: "Sobre",
      icon: "hero-information-circle",
      hint: "Versões e pastas do app."
    }
  ]

  def sections, do: @sections

  def section(key) when is_binary(key), do: Enum.find(@sections, &(Atom.to_string(&1.key) == key))
  def section(key), do: Enum.find(@sections, &(&1.key == key))

  def render(assigns) do
    ~F"""
    <div class="flex h-full min-h-0 flex-col">
      <div class="flex h-[var(--qa-bar)] shrink-0 items-center gap-2 border-b border-primary/20 px-3">
        <.icon name="hero-cog-6-tooth" class="size-4 shrink-0 text-primary" />
        <span class="truncate text-sm font-semibold text-primary">Configurações</span>
      </div>
      <nav class="flex-1 space-y-1 overflow-y-auto p-2" aria-label="Seções das configurações">
        {#for item <- sections()}
          <button
            type="button"
            id={"settings-section-#{item.key}"}
            phx-click="show_section"
            phx-value-section={item.key}
            aria-current={if @section == item.key, do: "page"}
            class={
              "flex w-full items-center gap-2 rounded-md px-3 py-2 text-left text-xs font-bold uppercase tracking-wider transition-colors",
              "bg-primary/15 text-primary": @section == item.key,
              "text-base-content/50 hover:bg-base-content/5 hover:text-base-content/80": @section != item.key
            }
          >
            <.icon name={item.icon} class="size-4 shrink-0" />
            <span class="truncate">{item.label}</span>
          </button>
        {/for}
      </nav>
    </div>
    """
  end
end
