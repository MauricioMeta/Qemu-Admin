defmodule QemuAdminWeb.Components.Vm.Terminal do
  @moduledoc """
  The terminal at the bottom of a VM's page: the history of what was
  sent to QEMU (`QemuAdmin.VmServer.commands/1` — the command line the run
  started with, the QMP commands and their answers, the QMP events) and a
  prompt to send more: a monitor command (`info registers`) or a QMP message
  as JSON. It is there so that one can see — and learn — how the page drives
  QEMU. The prompt recalls what was sent before with the arrow keys, to edit
  and send again (`CmdInput` hook).

  As one types, the prompt suggests commands, with their usage and
  description, from `priv/terminal/commands.json` (the `CmdInput` hook).

  The prompt is always on: a QEMU tool (`qemu-img`, `qemu-io`, `qemu-system-*
  -machine help`…) runs with the VM off or on (`QemuAdmin.Terminal`), and the
  monitor and QMP commands go to the VM when it is running.

  The entries are a stream (`@streams.cmds`); the times come as UTC and the
  `CmdLog` hook shows them in the local zone. The launch line can be edited
  there (`edit`: nil or `%{text:, error:}`): what is saved is the VM's own
  command line (`Vm` `command`), with `{qmp}`, `{serial}`… for the ports,
  used from the next start. Events: `cmd_send` (`cmd`), `cmds_toggle`,
  `cmd_edit`, `cmd_edit_change`, `cmd_edit_save`, `cmd_edit_reset`,
  `cmd_edit_cancel`.
  """

  use Surface.Component

  import QemuAdminWeb.CoreComponents, only: [icon: 1]
  import QemuAdminWeb.VmHelpers

  alias Phoenix.LiveView.JS
  alias QemuAdmin.Terminal.Groups

  prop vm, :struct, required: true
  prop rt, :map, required: true

  @doc "The `:cmds` stream."
  prop entries, :any, required: true

  @doc "What was sent before (oldest first), for the prompt's arrow keys."
  prop history, :list, default: []

  prop open, :boolean, default: true

  @doc "The saved commands the VM has (`QemuAdmin.Terminal.Saved.list/1`), for the suggestions."
  prop saved, :list, default: []

  defp saved_json(saved) do
    saved
    |> Enum.map(&Map.take(&1, ["name", "description", "steps"]))
    |> Jason.encode!()
  end

  # what a line of a command is, when it is opened
  defp caption("sent"), do: "enviado ao QEMU"
  defp caption("tool"), do: "processo"
  defp caption("received"), do: "resposta"
  defp caption("event"), do: "evento"
  defp caption("error"), do: "erro"
  defp caption(_), do: ""

  defp status_class(:error), do: "text-error"
  defp status_class(:done), do: "text-success"
  defp status_class(_), do: "text-base-content/40"

  defp status_text(:error), do: "erro"
  defp status_text(:done), do: "ok"
  defp status_text(_), do: "…"

  defp prefix("launch"), do: "$"
  defp prefix("tool"), do: "$"
  defp prefix("typed"), do: "›"
  defp prefix("macro"), do: "▶"
  defp prefix("sent"), do: "›"
  defp prefix("hmp"), do: "(qemu)"
  defp prefix("received"), do: "‹"
  defp prefix("event"), do: "·"
  defp prefix("error"), do: "!"
  defp prefix(_), do: " "

  defp tone("launch"), do: "text-base-content/45"
  defp tone("tool"), do: "text-primary"
  defp tone("typed"), do: "text-base-content/55"
  defp tone("macro"), do: "text-warning"
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
    <section
      id="vm-terminal"
      class="relative flex shrink-0 flex-col border-t border-primary/20 bg-base-200/60"
      style={if @open, do: "height: var(--terminal-h, 18rem)", else: ""}
    >
      {!-- the top edge: drag to resize the Terminal (the DockResizer hook), double click for the default --}
      <div
        id="terminal-resizer"
        phx-hook="DockResizer"
        class="dock-resizer"
        title="Arraste para redimensionar · duplo clique volta ao padrão"
      />
      <div class="flex min-h-8 shrink-0 flex-wrap items-center gap-x-2 gap-y-1 px-3 py-1 text-xs">
        <button
          type="button"
          id="cmds-toggle"
          phx-click="cmds_toggle"
          class="flex items-center gap-1.5 text-base-content/70 hover:text-primary"
          title={if @open, do: "Recolher", else: "Expandir"}
        >
          <.icon name={if @open, do: "hero-chevron-down", else: "hero-chevron-up"} class="size-3.5" />
          <.icon name="hero-command-line" class="size-4" />
          <span class="text-[0.62rem] font-semibold uppercase leading-none tracking-[0.06em] text-base-content/60">Terminal</span>
        </button>
        <span class="min-w-0 flex-1" />
        <button
          :if={@vm.command not in [nil, ""]}
          type="button"
          phx-click="open_launch"
          class="shrink-0 whitespace-nowrap rounded bg-warning/15 px-1.5 py-0.5 text-[0.62rem] text-warning hover:bg-warning/25"
          title="A linha de partida desta VM foi editada: abrir a página Comandos"
        >
          linha de partida editada
        </button>
        <button
          type="button"
          id="cmds-clear"
          phx-click="cmds_clear"
          data-confirm="Limpar o histórico do Terminal desta VM?"
          class="flex shrink-0 items-center gap-1 rounded border border-base-content/20 px-2 py-0.5 text-[0.68rem] text-base-content/70 hover:border-primary/40 hover:text-primary"
          title="Apaga o histórico do Terminal desta VM (o commands.log)"
        >
          <.icon name="hero-trash" class="size-3" /> Limpar
        </button>
      </div>
      <div :if={@open} class="flex min-h-0 flex-1 flex-col">
        <div
          id="vm-cmds"
          phx-hook="CmdLog"
          phx-update="stream"
          class="min-h-12 flex-1 overflow-y-auto border-y border-primary/10 bg-base-300/40 px-3 py-2 font-mono text-[0.68rem] leading-relaxed"
        >
          <div :for={{dom_id, e} <- @entries} id={dom_id}>
            {!-- a command: one line that opens to what went to QEMU, the answer and the events (like NBSim's history) --}
            {#if e.dir == "cmd"}
              <details class="group" phx-mounted={JS.ignore_attributes(["open"])}>
                <summary class="flex cursor-pointer list-none items-baseline gap-2 rounded px-0.5 hover:bg-primary/5 [&::-webkit-details-marker]:hidden">
                  <span class="shrink-0 text-base-content/30" data-utc={e.at}>{time(e.at)}</span>
                  <.icon name="hero-chevron-right" class="size-3 shrink-0 self-center text-base-content/40 transition-transform group-open:rotate-90" />
                  <span class="min-w-0 max-w-[55%] shrink-0 truncate font-semibold text-primary" title={e.text}>{e.text}</span>
                  <span :if={e[:via]} class="shrink-0 rounded bg-primary/10 px-1 text-[0.58rem] text-primary/80">{e[:via]}</span>
                  <span :if={e[:src]} class="shrink-0 rounded bg-base-content/10 px-1 text-[0.58rem] text-base-content/55">{e[:src]}</span>
                  <span class="min-w-0 flex-1 truncate text-base-content/45 group-open:invisible">{Groups.preview(e)}</span>
                  <span class={"shrink-0 text-[0.62rem]", status_class(Groups.status(e))}>{status_text(Groups.status(e))}</span>
                </summary>
                <div class="mb-1 ml-5 space-y-0.5 border-l border-primary/20 py-1 pl-2">
                  <div :for={i <- e.items} class={"flex gap-2", tone(i.dir)}>
                    <span class="w-28 shrink-0 text-right text-[0.6rem] uppercase tracking-wide text-base-content/35">{caption(i.dir)}</span>
                    <span class="min-w-0 flex-1 whitespace-pre-wrap break-all">{i.text}</span>
                  </div>
                  <p :if={e.items == []} class="text-base-content/35">Nada foi enviado.</p>
                </div>
              </details>
            {#else}
              {!-- a line on its own: the launch command, a saved command's start and end, an older history --}
              <div class={"flex gap-2", tone(e.dir)}>
                <span class="shrink-0 text-base-content/30" data-utc={e.at}>{time(e.at)}</span>
                <span class="w-9 shrink-0 text-right">{prefix(e.dir)}</span>
                <span class="min-w-0 flex-1 whitespace-pre-wrap break-all">{e.text}</span>
              </div>
            {/if}
          </div>
          <div id="vm-cmds-empty" class="hidden only:block text-base-content/35">
            Nada ainda. Digite um comando abaixo.
          </div>
        </div>
        <form id="cmd-form" phx-submit="cmd_send" class="relative flex shrink-0 items-center gap-2 px-3 py-2" autocomplete="off">
          {!-- the suggestions: filled by the CmdInput hook, LiveView leaves it alone --}
          <div
            id="cmd-suggest"
            phx-update="ignore"
            class="absolute inset-x-3 bottom-full z-30 mb-1 hidden overflow-hidden rounded-lg border border-primary/25 bg-base-200 text-xs shadow-xl"
          />
          <span class="font-mono text-xs text-primary">›</span>
          <input
            id="cmd-input"
            name="cmd"
            type="text"
            phx-hook="CmdInput"
            data-history={Jason.encode!(@history)}
            data-saved={saved_json(@saved)}
            spellcheck="false"
            placeholder={
              if stopped?(@rt),
                do: "qemu-img info disco.qcow2 · qemu-system-arm -machine help · (monitor e QMP: com a VM ligada)",
                else: ~s(info registers · {"execute": "query-status"} · qemu-img info disco.qcow2)
            }
            class="qa-field min-w-0 flex-1 font-mono !text-xs"
          />
          <button
            type="submit"
            id="cmd-send"
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
