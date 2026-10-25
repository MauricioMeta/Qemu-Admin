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

  prop vm, :struct, required: true
  prop rt, :map, required: true

  @doc "The `:cmds` stream."
  prop entries, :any, required: true

  @doc "What was sent before (oldest first), for the prompt's arrow keys."
  prop history, :list, default: []

  prop open, :boolean, default: true

  @doc "The launch line's editor: nil (closed) or `%{text:, error:}`."
  prop edit, :any, default: nil

  @doc "The emulator's executable, shown before the edited arguments."
  prop exe, :string, default: ""

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
    <section id="vm-terminal" class="flex shrink-0 flex-col border-t border-primary/20 bg-base-200/60">
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
          <span class="qa-label mb-0">Terminal</span>
        </button>
        <span class="min-w-0 flex-1 truncate text-[0.65rem] text-base-content/40">
          o que foi enviado ao QEMU (QMP) · envie o seu: comando do monitor ou JSON
        </span>
        <span :if={@vm.command not in [nil, ""]} class="shrink-0 whitespace-nowrap rounded bg-warning/15 px-1.5 py-0.5 text-[0.62rem] text-warning">
          linha de partida editada
        </span>
        <button
          type="button"
          id="cmd-edit"
          phx-click="cmd_edit"
          class="shrink-0 rounded border border-primary/30 px-2 py-0.5 text-[0.68rem] text-primary hover:bg-primary/10"
          title="Editar a linha de comando com que a VM é iniciada"
        >
          Editar linha de partida
        </button>
      </div>
      <form
        :if={@open and @edit}
        id="cmd-edit-form"
        phx-change="cmd_edit_change"
        phx-submit="cmd_edit_save"
        class="flex flex-col gap-2 border-t border-primary/15 px-3 py-2"
      >
        <p class="text-[0.68rem] text-base-content/55">
          Os argumentos de <code class="text-primary/80">{Path.basename(@exe)}</code>. No lugar das portas que o app escolhe a cada
          início, use {#for p <- QemuAdmin.Vm.Args.placeholders()}<code class="mr-1.5 text-primary/80">{p}</code>{/for}.
          Vale a partir do <strong>próximo boot</strong>{if running?(@rt), do: " (a VM está ligada)"}.
        </p>
        <textarea
          id="cmd-edit-text"
          name="text"
          rows="5"
          spellcheck="false"
          phx-debounce="300"
          class={"qa-field font-mono !text-[0.68rem]", "!border-error": @edit.error}
        >{@edit.text}</textarea>
        <p :if={@edit.error} class="text-[0.68rem] text-error">{@edit.error}</p>
        <div class="flex items-center gap-2">
          <button
            type="submit"
            id="cmd-edit-save"
            class="rounded-md bg-primary px-3 py-1 text-xs font-semibold text-primary-content hover:brightness-110"
          >
            Salvar
          </button>
          <button
            type="button"
            id="cmd-edit-cancel"
            phx-click="cmd_edit_cancel"
            class="rounded-md border border-base-content/20 px-3 py-1 text-xs hover:bg-base-300"
          >
            Cancelar
          </button>
          <button
            type="button"
            id="cmd-edit-reset"
            phx-click="cmd_edit_reset"
            class="ml-auto rounded-md border border-base-content/20 px-3 py-1 text-xs hover:bg-base-300"
            title="Voltar à linha que o app monta sozinho"
          >
            Restaurar a padrão
          </button>
        </div>
      </form>
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
        <form id="cmd-form" phx-submit="cmd_send" class="relative flex items-center gap-2 px-3 py-2" autocomplete="off">
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
