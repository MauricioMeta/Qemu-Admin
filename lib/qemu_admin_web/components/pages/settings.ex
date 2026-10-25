defmodule QemuAdminWeb.Components.Pages.Settings do
  @moduledoc """
  The settings page: the selected section's controls, drawn from
  `QemuAdmin.Settings.schema/0`. As in the Rockwell Viewer nothing is saved
  by hand — each control writes when it changes (`set_setting`, a form per
  control carrying `key` and `value`). "Restaurar padrões" sends
  `reset_settings`.

  The "Sobre" section shows the app's folders and versions.
  """

  use Surface.Component

  import QemuAdminWeb.CoreComponents, only: [icon: 1]

  alias QemuAdmin.{Paths, Qemu, Settings}
  alias QemuAdminWeb.Components.Pages.SettingsNav

  prop section, :atom, default: :qemu
  prop settings, :map, required: true

  defp app_version do
    case :application.get_key(:qemu_admin, :vsn) do
      {:ok, v} -> to_string(v)
      _ -> "dev"
    end
  end

  defp control(assigns) do
    ~F"""
    <form
      id={"setting-#{@entry.key}"}
      phx-change="set_setting"
      class="grid gap-1 border-t border-base-content/5 py-3 first:border-t-0 md:grid-cols-[16rem_1fr] md:gap-4"
      onsubmit="return false"
    >
      <input type="hidden" name="key" value={@entry.key}>
      <div>
        <p class="text-xs font-semibold">{@entry.label}</p>
        <p class="text-[0.65rem] text-base-content/45">{@entry.help}</p>
      </div>
      <div class="flex items-center">
        {#case @entry.type}
          {#match :boolean}
            <input type="hidden" name="value" value="false">
            <input
              type="checkbox"
              name="value"
              value="true"
              checked={@value}
              class="toggle toggle-sm toggle-primary"
            />
          {#match :select}
            <select name="value" class="qa-field md:max-w-sm">
              <option :for={{v, label} <- @entry.choices} value={v} selected={v == @value}>{label}</option>
            </select>
          {#match :integer}
            <input
              type="number"
              name="value"
              value={@value}
              min={@entry[:min]}
              max={@entry[:max]}
              class="qa-field md:max-w-[8rem]"
              phx-debounce="400"
            />
          {#match _}
            <input
              type="text"
              name="value"
              value={@value}
              class="qa-field"
              phx-debounce="600"
              placeholder="(padrão)"
            />
        {/case}
      </div>
    </form>
    """
  end

  def render(assigns) do
    ~F"""
    <div id="settings-page" class="min-h-0 flex-1 overflow-y-auto p-5">
      <section class="qa-card p-5">
        <div class="mb-3 flex items-start justify-between gap-4">
          <div>
            <h2 class="flex items-center gap-2 text-sm font-bold text-primary">
              <.icon name={SettingsNav.section(@section).icon} class="size-4" />
              {SettingsNav.section(@section).label}
            </h2>
            <p class="text-xs text-base-content/50">{SettingsNav.section(@section).hint}</p>
          </div>
          <button
            :if={@section != :about}
            type="button"
            id="reset-settings"
            phx-click="reset_settings"
            phx-value-section={@section}
            class="shrink-0 rounded border border-base-content/15 px-2 py-1 text-[0.68rem] text-base-content/60 hover:bg-base-300"
          >
            Restaurar padrões
          </button>
        </div>

        {#if @section == :about}
          <dl class="grid gap-x-6 gap-y-2 text-xs md:grid-cols-[12rem_1fr]">
            <dt class="text-base-content/45">QEMU Admin</dt><dd>v{app_version()}</dd>
            <dt class="text-base-content/45">QEMU</dt><dd>{Qemu.info().version || "não encontrado"}</dd>
            <dt class="text-base-content/45">Elixir / OTP</dt><dd>{System.version()} / {System.otp_release()}</dd>
            <dt class="text-base-content/45">Pasta de dados</dt><dd class="break-all font-mono text-[0.68rem]">{Paths.data_dir()}</dd>
            <dt class="text-base-content/45">Workspace</dt><dd class="break-all font-mono text-[0.68rem]">{Paths.workspace_dir()}</dd>
            <dt class="text-base-content/45">VMs</dt><dd class="break-all font-mono text-[0.68rem]">{Paths.vms_dir()}</dd>
            <dt class="text-base-content/45">Imagens</dt><dd class="break-all font-mono text-[0.68rem]">{Paths.images_dir()}</dd>
            <dt class="text-base-content/45">Modo</dt><dd>{if Application.get_env(:qemu_admin, :desktop?), do: "app desktop (Tauri)", else: "navegador"}</dd>
          </dl>
        {#else}
          {#for entry <- Settings.section(@section)}
            {control(%{entry: entry, value: Map.get(@settings, entry.key)})}
          {/for}
        {/if}
      </section>
    </div>
    """
  end
end
