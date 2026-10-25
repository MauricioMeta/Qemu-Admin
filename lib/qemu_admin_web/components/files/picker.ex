defmodule QemuAdminWeb.Components.Files.Picker do
  @moduledoc """
  A modal to pick a file on this machine (an ISO, a disk image): the server
  lists the folder (`QemuAdminWeb.Files.list/2`), so it works the same in a
  browser tab and in the desktop window. On Windows, the top level is the
  drives.

  `picker` is `%{target:, dir:, entries:, exts:, error:, dirs?:}` or nil.
  With `dirs?` it picks a folder instead (only folders listed, the one
  shown is chosen, and a new one can be made in it). Events: `picker_cd`
  (`dir`), `picker_pick` (`path`), `picker_close`, `picker_go` (the typed
  path, a form), `picker_mkdir` (`name`, a form).
  """

  use Surface.Component

  import QemuAdminWeb.CoreComponents, only: [icon: 1]

  prop picker, :any, default: nil

  defp up(""), do: nil

  defp up(dir) do
    parent = Path.dirname(dir)
    if parent == dir, do: "", else: parent
  end

  def render(assigns) do
    ~F"""
    <div
      :if={@picker}
      id="file-picker"
      class="fixed inset-0 z-50 grid place-items-center bg-black/50 p-6"
      phx-window-keydown="picker_close"
      phx-key="Escape"
    >
      <div
        class="flex max-h-[80vh] w-full max-w-2xl flex-col overflow-hidden rounded-lg border border-primary/25 bg-base-200 shadow-2xl"
        phx-click-away="picker_close"
      >
        <div class="flex h-[var(--qa-bar)] shrink-0 items-center gap-2 border-b border-primary/20 px-3">
          <.icon name="hero-folder-open" class="size-4 text-primary" />
          <span class="flex-1 text-sm font-semibold text-primary">{if @picker[:dirs?], do: "Escolher pasta", else: "Escolher arquivo"}</span>
          <span class="text-[0.65rem] text-base-content/40">{Enum.join(@picker.exts, " ")}</span>
          <button
            type="button"
            phx-click="picker_close"
            class="grid size-6 place-items-center rounded hover:bg-base-300"
            title="Fechar"
          >
            <.icon name="hero-x-mark" class="size-4" />
          </button>
        </div>
        <form phx-submit="picker_go" class="flex shrink-0 gap-1 border-b border-primary/10 p-2">
          <button
            type="button"
            phx-click="picker_cd"
            phx-value-dir={up(@picker.dir)}
            disabled={is_nil(up(@picker.dir))}
            title="Pasta acima"
            class="grid size-7 shrink-0 place-items-center rounded border border-base-content/15 hover:text-primary disabled:opacity-30"
          >
            <.icon name="hero-arrow-up" class="size-4" />
          </button>
          <input name="path" value={@picker.dir} class="qa-field" placeholder="Unidades">
        </form>
        <p :if={@picker.error} class="px-3 py-2 text-xs text-error">{@picker.error}</p>
        <ul class="min-h-0 flex-1 overflow-y-auto p-1 text-xs">
          {#for e <- @picker.entries, e.dir? or not @picker[:dirs?]}
            <li>
              <button
                type="button"
                phx-click={if e.dir?, do: "picker_cd", else: "picker_pick"}
                phx-value-dir={e.dir? && e.path}
                phx-value-path={!e.dir? && e.path}
                class="flex w-full items-center gap-2 rounded px-2 py-1.5 text-left hover:bg-primary/10"
              >
                <.icon
                  name={if e.dir?, do: "hero-folder", else: "hero-document"}
                  class={"size-4 shrink-0", "text-primary/70": e.dir?, "text-base-content/50": not e.dir?}
                />
                <span class="min-w-0 flex-1 truncate">{e.name}</span>
                <span :if={e.size} class="shrink-0 text-base-content/40">{QemuAdmin.Qemu.Img.human(e.size)}</span>
              </button>
            </li>
          {/for}
          <li
            :if={@picker.entries == [] and is_nil(@picker.error) and not @picker[:dirs?]}
            class="px-3 py-6 text-center text-base-content/40"
          >
            Nada aqui com {Enum.join(@picker.exts, " ")}.
          </li>
        </ul>
        <div
          :if={@picker[:dirs?]}
          class="flex shrink-0 items-center gap-2 border-t border-primary/10 p-2"
        >
          <form id="picker-mkdir" phx-submit="picker_mkdir" class="flex flex-1 gap-1">
            <input name="name" class="qa-field" placeholder="Nova pasta aqui" disabled={@picker.dir == ""}>
            <button
              type="submit"
              disabled={@picker.dir == ""}
              class="rounded border border-base-content/15 px-2 text-xs hover:text-primary disabled:opacity-30"
            >Criar</button>
          </form>
          <button
            type="button"
            id="picker-choose"
            phx-click="picker_pick"
            phx-value-path={@picker.dir}
            disabled={@picker.dir == ""}
            class="rounded-md bg-primary px-3 py-1.5 text-xs font-semibold text-primary-content hover:brightness-110 disabled:opacity-40"
          >
            Usar esta pasta
          </button>
        </div>
      </div>
    </div>
    """
  end
end
