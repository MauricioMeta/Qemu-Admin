defmodule QemuAdminWeb.Components.Vm.Commands do
  @moduledoc """
  The command panel at the bottom of a VM's page: the history of what was
  sent to QEMU (`QemuAdmin.VmServer.commands/1` — the command line the run
  started with, the QMP commands and their answers, the QMP events) and a
  prompt to send more: a monitor command (`info registers`) or a QMP message
  as JSON. It is there so that one can see — and learn — how the page drives
  QEMU. The prompt recalls what was sent before with the arrow keys, to edit
  and send again (`CmdInput` hook).

  The entries are a stream (`@streams.cmds`); the times come as UTC and the
  `CmdLog` hook shows them in the local zone. Events: `cmd_send` (`cmd`),
  `cmds_toggle`.
  """

  use Surface.Component

  import QemuAdminWeb.CoreComponents, only: [icon: 1]
  import QemuAdminWeb.VmHelpers

  prop vm, :struct, required: true
  prop rt, :map, required: true

  @doc "The `:cmds` stream."
  prop entries, :any, required: true

  @doc "What was sent before (oldest first), for the prompt's arrow keys."
  prop history, :list, default: []

  prop open, :boolean, default: true

  defp prefix("launch"), do: "$"
  defp prefix("sent"), do: "›"
  defp prefix("hmp"), do: "(qemu)"
  defp prefix("received"), do: "‹"
  defp prefix("event"), do: "·"
  defp prefix("error"), do: "!"
  defp prefix(_), do: " "

  defp tone("launch"), do: "text-base-content/45"
  defp tone("sent"), do: "text-primary"
  defp tone("hmp"), do: "text-primary"
  defp tone("received"), do: "text-base-content/80"
  defp tone("event"), do: "text-info/70"
  defp tone("error"), do: "text-error"
  defp tone(_), do: "text-base-content/60"

  # "2026-10-25T01:02:03Z" → "01:02:03"
  defp time(at) when is_binary(at) do
    case String.split(at, ["T", "Z", "+"]) do
      [_, t | _] -> t
      _ -> at
    end
  end

  defp time(_), do: ""

  def render(assigns) do
    ~F"""
    <section id="vm-commands" class="flex shrink-0 flex-col border-t border-primary/20 bg-base-200/60">
      <div class="flex h-8 shrink-0 items-center gap-2 px-3 text-xs">
        <button
          type="button"
          id="cmds-toggle"
          phx-click="cmds_toggle"
          class="flex items-center gap-1.5 text-base-content/70 hover:text-primary"
          title={if @open, do: "Recolher", else: "Expandir"}
        >
          <.icon name={if @open, do: "hero-chevron-down", else: "hero-chevron-up"} class="size-3.5" />
          <.icon name="hero-command-line" class="size-4" />
          <span class="qa-label mb-0">Comandos</span>
        </button>
        <span class="truncate text-[0.65rem] text-base-content/40">
          o que foi enviado ao QEMU (QMP) · envie o seu: comando do monitor ou JSON
        </span>
      </div>
      <div :if={@open} class="flex flex-col">
        <div
          id="vm-cmds"
          phx-hook="CmdLog"
          phx-update="stream"
          class="h-44 overflow-y-auto border-y border-primary/10 bg-base-300/40 px-3 py-2 font-mono text-[0.68rem] leading-relaxed"
        >
          <div
            :for={{dom_id, e} <- @entries}
            id={dom_id}
            class={"flex gap-2", tone(e.dir)}
          >
            <span class="shrink-0 text-base-content/30" data-utc={e.at}>{time(e.at)}</span>
            <span class="w-9 shrink-0 text-right">{prefix(e.dir)}</span>
            <span class="min-w-0 flex-1 whitespace-pre-wrap break-all">{e.text}</span>
          </div>
          <div id="vm-cmds-empty" class="hidden only:block text-base-content/35">
            Nada ainda. Ligue a VM e digite um comando abaixo.
          </div>
        </div>
        <form id="cmd-form" phx-submit="cmd_send" class="flex items-center gap-2 px-3 py-2" autocomplete="off">
          <span class="font-mono text-xs text-primary">›</span>
          <input
            id="cmd-input"
            name="cmd"
            type="text"
            phx-hook="CmdInput"
            data-history={Jason.encode!(@history)}
            disabled={stopped?(@rt)}
            spellcheck="false"
            placeholder={
              if stopped?(@rt),
                do: "Ligue a VM para enviar comandos",
                else: ~s(info status · info registers · {"execute": "query-status"})
            }
            class="qa-field min-w-0 flex-1 font-mono !text-xs"
          />
          <button
            type="submit"
            id="cmd-send"
            disabled={stopped?(@rt)}
            class="rounded-md bg-primary px-3 py-1.5 text-xs font-semibold text-primary-content hover:brightness-110 disabled:opacity-40"
          >
            Enviar
          </button>
        </form>
      </div>
    </section>
    """
  end
end
