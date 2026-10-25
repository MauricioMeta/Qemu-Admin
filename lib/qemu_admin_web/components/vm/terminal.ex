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

  @doc "The saved commands the VM has (`QemuAdmin.Terminal.Saved.list/1`)."
  prop saved, :list, default: []

  @doc "The saved commands panel: nil (closed) or `%{editing:, error:, file_error:}`."
  prop panel, :any, default: nil

  @doc "Where the saved commands are (`terminal.json`)."
  prop saved_path, :string, default: ""

  defp saved_json(saved) do
    saved
    |> Enum.map(&Map.take(&1, ["name", "description", "steps"]))
    |> Jason.encode!()
  end

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
    <section id="vm-terminal" class="flex shrink-0 flex-col border-t border-primary/20 bg-base-200/60">
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
          <span class="qa-label mb-0">Terminal</span>
        </button>
        <span class="min-w-0 flex-1" />
        <span :if={@vm.command not in [nil, ""]} class="shrink-0 whitespace-nowrap rounded bg-warning/15 px-1.5 py-0.5 text-[0.62rem] text-warning">
          linha de partida editada
        </span>
        <button
          type="button"
          id="saved-open"
          phx-click="saved_open"
          class="shrink-0 whitespace-nowrap rounded border border-primary/30 px-2 py-0.5 text-[0.68rem] text-primary hover:bg-primary/10"
          title="Comandos salvos: um nome que executa uma sequência de comandos"
        >
          Comandos salvos
        </button>
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
      <section
        :if={@open and @panel}
        id="saved-panel"
        class="max-h-56 space-y-2 overflow-y-auto border-t border-primary/15 px-3 py-2 text-xs"
      >
        <div class="flex items-center gap-2">
          <h4 class="qa-label mb-0 text-primary">Comandos salvos</h4>
          <span class="min-w-0 flex-1 truncate font-mono text-[0.62rem] text-base-content/40" title={@saved_path}>
            {@saved_path}
          </span>
          <button
            type="button"
            id="saved-new"
            phx-click="saved_new"
            class="rounded border border-primary/30 px-2 py-0.5 text-[0.68rem] text-primary hover:bg-primary/10"
          >
            Novo
          </button>
          <button
            type="button"
            id="saved-close"
            phx-click="saved_close"
            class="rounded border border-base-content/20 px-2 py-0.5 text-[0.68rem] hover:bg-base-300"
          >
            Fechar
          </button>
        </div>
        <p :if={@panel[:file_error]} class="text-error">{@panel[:file_error]}</p>
        <p :if={@saved == [] and is_nil(@panel.editing)} class="text-base-content/50">
          Nenhum comando salvo. Um comando salvo é um nome (como <code class="text-primary/80">start</code>) que executa
          uma sequência de comandos nesta VM: clique em <strong>Novo</strong>, ou edite o arquivo acima à mão.
        </p>
        <ul :if={@saved != []} class="divide-y divide-primary/10 rounded border border-primary/15">
          <li :for={c <- @saved} id={"saved-#{c["name"]}"} class="flex items-center gap-2 px-2 py-1.5">
            <div class="min-w-0 flex-1">
              <div class="flex items-baseline gap-2">
                <span class="font-mono font-semibold text-primary">{c["name"]}</span>
                <span :if={c["vm"]} class="rounded bg-base-300 px-1 text-[0.58rem] text-base-content/55">só {c["vm"]}</span>
                <span class="truncate text-base-content/55">{c["description"]}</span>
              </div>
              <div class="truncate font-mono text-[0.62rem] text-base-content/40" title={Enum.join(c["steps"], "  ›  ")}>
                {Enum.join(c["steps"], "  ›  ")}
              </div>
            </div>
            <button
              type="button"
              phx-click="saved_run"
              phx-value-name={c["name"]}
              class="rounded bg-success/15 px-2 py-0.5 text-[0.68rem] text-success hover:bg-success/25"
            >
              Executar
            </button>
            <button
              type="button"
              phx-click="saved_edit"
              phx-value-name={c["name"]}
              class="rounded border border-base-content/20 px-2 py-0.5 text-[0.68rem] hover:bg-base-300"
            >
              Editar
            </button>
            <button
              type="button"
              phx-click="saved_delete"
              phx-value-name={c["name"]}
              data-confirm={"Excluir o comando salvo #{c["name"]}?"}
              class="rounded border border-error/30 px-2 py-0.5 text-[0.68rem] text-error hover:bg-error/10"
            >
              Excluir
            </button>
          </li>
        </ul>
        <form
          :if={@panel.editing}
          id="saved-form"
          phx-change="saved_change"
          phx-submit="saved_save"
          class="space-y-2 rounded border border-primary/20 bg-base-300/30 p-2"
          autocomplete="off"
        >
          <div class="grid grid-cols-2 gap-2">
            <div>
              <label class="qa-label" for="saved_name">Nome (uma palavra)</label>
              <input id="saved_name" name="saved[name]" value={@panel.editing["name"]} class="qa-field font-mono" placeholder="start" phx-debounce="300" />
            </div>
            <div>
              <label class="qa-label" for="saved_vm">Vale para</label>
              <select id="saved_vm" name="saved[vm]" class="qa-field">
                <option value="" selected={@panel.editing["vm"] in [nil, ""]}>Todas as VMs</option>
                <option value={@vm.id} selected={@panel.editing["vm"] == @vm.id}>Só esta VM ({@vm.name})</option>
              </select>
            </div>
          </div>
          <div>
            <label class="qa-label" for="saved_description">Descrição</label>
            <input id="saved_description" name="saved[description]" value={@panel.editing["description"]} class="qa-field" placeholder="Liga a VM e mostra o estado" phx-debounce="300" />
          </div>
          <div>
            <label class="qa-label" for="saved_steps">Passos (um por linha, executados em ordem)</label>
            <textarea
              id="saved_steps"
              name="saved[steps]"
              rows="5"
              spellcheck="false"
              phx-debounce="300"
              class="qa-field font-mono !text-[0.68rem]"
              placeholder={"@start\ninfo status\nqemu-img info disk0.qcow2"}
            >{@panel.editing["steps"]}</textarea>
            <p class="mt-1 text-[0.62rem] text-base-content/45">
              Cada passo é como se digita aqui: <code>info registers</code>, <code>{"{\"execute\": \"stop\"}"}</code>, <code>qemu-img info disk0.qcow2</code>.
              Do app: <code>@start</code> (liga a VM e espera) e <code>@wait 3</code> (segundos).
              <code>{"{vm}"}</code>, <code>{"{name}"}</code> e <code>{"{dir}"}</code> viram o id, o nome e a pasta da VM. Linhas com # são ignoradas.
            </p>
          </div>
          <label class="flex items-center gap-2">
            <input type="hidden" name="saved[continue_on_error]" value="false" />
            <input
              type="checkbox"
              name="saved[continue_on_error]"
              value="true"
              checked={@panel.editing["continue_on_error"] == true}
              class="checkbox checkbox-xs checkbox-primary"
            />
            Seguir para o próximo passo mesmo se um falhar
          </label>
          <p :if={@panel.error} class="text-error">{@panel.error}</p>
          <div class="flex gap-2">
            <button type="submit" id="saved-save" class="rounded-md bg-primary px-3 py-1 font-semibold text-primary-content hover:brightness-110">
              Salvar
            </button>
            <button type="button" id="saved-cancel" phx-click="saved_cancel" class="rounded-md border border-base-content/20 px-3 py-1 hover:bg-base-300">
              Cancelar
            </button>
          </div>
        </form>
      </section>
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
          class={
            "overflow-y-auto border-y border-primary/10 bg-base-300/40 px-3 py-2 font-mono text-[0.68rem] leading-relaxed",
            "h-44": is_nil(@panel) and is_nil(@edit),
            "h-28": @panel || @edit
          }
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
            Nada ainda. Digite um comando abaixo.
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
