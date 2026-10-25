defmodule QemuAdminWeb.Components.Pages.Commands do
  @moduledoc """
  The **Comandos** page: one table for every command there is, the user's own and
  QEMU's (`QemuAdmin.Terminal.Catalog`), like the Rockwell Viewer's tag table.

  Rows are of five kinds, with a tab each (and **Todos**):

    * **Meus** — the saved commands of the workspace (`terminal.json`,
      `QemuAdmin.Terminal.Saved`): a name that a VM's Terminal runs as a sequence of
      steps. Opening a row shows its numbered steps (each with how it reaches QEMU)
      and **Executar**, **Editar** and **Excluir**; **Novo comando** is on the bar.
    * **Monitor**, **QMP**, **Eventos**, **Ferramentas** — the catalog of QEMU. Opening
      a row shows an editor of its arguments, one field per argument, and the line
      that results; that line is sent to the Terminal (**Enviar**) or becomes a step
      of a saved command (**Adicionar como passo**).

  Two search bars, as in the Rockwell Viewer: the **busca** on top is the full-text
  search over names, arguments, descriptions and the steps of saved commands (every
  word must be found, a word matches the start of a term, picking a result opens it
  in the table); the **filtro** over the table narrows the rows by name or
  description. A last tab, **Linhas de partida**, replaces the table with the
  arguments QEMU starts each VM with, editable by hand.

  `cat` is the state kept by `QemuAdminWeb.AdminLive`: `q` (filter), `kind` (a tab:
  `all saved hmp qmp event tool launch`), `sel` (the open row's id), `vals`
  (`%{arg => text}`), `to` (the saved command a step goes to, `""` = a new one),
  `gq`, `gres`, `gtotal`, `gopen` (the search). `editing`, `error`, `file_error`
  are the saved command's form and the state of `terminal.json`; `lp` the launch
  line's editor (`nil` or `%{id:, text:, error:}`).

  Events: `cat_search`, `cat_search_close`, `cat_pick`, `cat_filter`, `cat_kind`,
  `cat_select`, `cat_vals`, `cat_send`, `cat_step`, `cat_run`; `cp_new`, `cp_edit`,
  `cp_change`, `cp_cancel`, `cp_save`, `cp_delete`; `lp_edit`, `lp_change`,
  `lp_cancel`, `lp_save`, `lp_reset`.
  """

  use Surface.Component

  import QemuAdminWeb.CoreComponents, only: [icon: 1]
  alias QemuAdmin.Terminal.Catalog

  @row_limit 200

  @doc "The page's state, see above."
  prop cat, :map, required: true

  @doc "The saved commands as entries, then `Catalog.all/0`."
  prop entries, :list, default: []

  @doc "`QemuAdmin.Terminal.Saved.load/0`, sorted by name (names go to the step menu)."
  prop commands, :list, default: []

  @doc "`[{vm, runtime}]`, for the \"vale para\" menu."
  prop vms, :list, default: []

  @doc "Name of the VM that receives the commands, or nil."
  prop vm_name, :any, default: nil

  @doc "The saved command's form: nil or a map."
  prop editing, :any, default: nil

  prop error, :any, default: nil

  prop file_error, :any, default: nil

  @doc "Where `terminal.json` is."
  prop path, :string, default: ""

  @doc "The launch line's editor: nil or `%{id:, text:, error:}`."
  prop lp, :any, default: nil

  @doc "`%{vm id => the emulator's executable name}`."
  prop exes, :map, default: %{}

  @doc "`%{vm id => the launch line}`: the edited one, else the one the app builds."
  prop lines, :map, default: %{}

  data shown, :integer, default: 0
  data visible, :list, default: []
  data e, :any, default: nil

  @tabs [
    {"all", "Todos"},
    {"saved", "Meus"},
    {"hmp", "Monitor"},
    {"qmp", "QMP"},
    {"event", "Eventos"},
    {"tool", "Ferramentas"},
    {"launch", "Linhas de partida"}
  ]

  defp tabs, do: @tabs

  defp kind_badge("saved"), do: {"salvo", "bg-success/15 text-success"}
  defp kind_badge("hmp"), do: {"monitor", "bg-info/15 text-info"}
  defp kind_badge("qmp"), do: {"QMP", "bg-primary/15 text-primary"}
  defp kind_badge("event"), do: {"evento", "bg-accent/15 text-accent"}
  defp kind_badge("tool"), do: {"ferramenta", "bg-warning/15 text-warning"}
  defp kind_badge(_), do: {"?", "bg-base-300 text-base-content/60"}

  # how a step reaches QEMU: the badge next to it
  defp via("qmp:" <> _), do: {"QMP", "bg-primary/15 text-primary"}
  defp via("hmp:" <> _), do: {"monitor", "bg-info/15 text-info"}
  defp via("cli:" <> _), do: {"processo", "bg-warning/15 text-warning"}
  defp via("@" <> _), do: {"app", "bg-base-content/10 text-base-content/60"}
  defp via("{" <> _), do: {"QMP", "bg-primary/15 text-primary"}
  defp via(_), do: {"auto", "bg-base-content/10 text-base-content/50"}

  defp vm_name(vms, id) do
    case Enum.find(vms, fn {vm, _rt} -> vm.id == id end) do
      {vm, _} -> vm.name
      nil -> id
    end
  end

  defp count(entries, "all"), do: length(entries)
  defp count(_entries, "launch"), do: nil
  defp count(entries, kind), do: Enum.count(entries, &(&1.kind == kind))

  defp rows(entries, cat) do
    narrowed = Catalog.narrow(entries, cat.kind, cat.q)
    {length(narrowed), Enum.take(narrowed, @row_limit)}
  end

  def render(assigns) do
    {shown, visible} = rows(assigns.entries, assigns.cat)
    assigns = assign(assigns, shown: shown, visible: visible)

    ~F"""
    <div id="commands-page" class="flex h-full min-h-0 flex-col">
      <div class="flex shrink-0 items-center gap-3 border-b border-base-content/10 px-4 py-2">
        <div class="relative w-full max-w-xl" phx-click-away="cat_search_close">
          <form id="cat-search-form" phx-change="cat_search" phx-submit="cat_search_enter" autocomplete="off">
            <label class="relative block">
              <.icon
                name="hero-magnifying-glass"
                class="pointer-events-none absolute top-1/2 left-2.5 size-3.5 -translate-y-1/2 text-base-content/40"
              />
              <input
                id="cat-search"
                type="text"
                name="q"
                value={@cat.gq}
                placeholder="Buscar em todos os comandos (nome, argumento, descrição, passos)…"
                spellcheck="false"
                phx-debounce="150"
                phx-focus="cat_search_focus"
                phx-keydown="cat_search_close"
                phx-key="Escape"
                role="combobox"
                aria-expanded={to_string(@cat.gopen and String.trim(@cat.gq) != "")}
                class="w-full rounded-md border border-primary/25 bg-base-200 py-1.5 pr-3 pl-8 text-xs outline-none focus:border-primary"
              />
            </label>
          </form>
          <div
            :if={@cat.gopen and String.trim(@cat.gq) != ""}
            id="cat-results"
            role="listbox"
            class="absolute top-full left-0 z-50 mt-1 max-h-[70vh] w-full overflow-y-auto rounded-lg border border-primary/25 bg-base-100 shadow-xl"
          >
            <p :if={@cat.gres == []} class="px-3 py-3 text-[0.7rem] italic text-base-content/45">
              Nada encontrado para “{@cat.gq}”.
            </p>
            <button
              :for={e <- @cat.gres}
              type="button"
              role="option"
              phx-click="cat_pick"
              phx-value-id={e.id}
              data-kind={e.kind}
              class="flex w-full items-start gap-2 border-b border-base-content/5 px-3 py-1.5 text-left last:border-b-0 hover:bg-primary/10"
            >
              <span class="min-w-0 flex-1">
                <span class="flex items-baseline gap-2">
                  <span class="truncate font-mono text-xs font-semibold">{e.name}</span>
                  <span class={"shrink-0 rounded px-1 text-[0.55rem] uppercase tracking-wide", elem(kind_badge(e.kind), 1)}>{elem(kind_badge(e.kind), 0)}</span>
                </span>
                <span class="block truncate text-[0.68rem] text-base-content/60">{e.description}</span>
              </span>
            </button>
            <p
              :if={@cat.gtotal > length(@cat.gres)}
              class="border-t border-base-content/10 px-3 py-1.5 text-center text-[0.62rem] text-base-content/40"
            >
              {length(@cat.gres)} de {@cat.gtotal} resultados — refine a busca
            </p>
          </div>
        </div>
        <button
          :if={is_nil(@editing) and is_nil(@file_error)}
          type="button"
          id="cp-new"
          phx-click="cp_new"
          class="shrink-0 rounded-md bg-primary px-3 py-1.5 text-xs font-semibold text-primary-content hover:brightness-110"
        >
          Novo comando
        </button>
        <span class="ml-auto shrink-0 font-mono text-[0.68rem] text-base-content/40">
          Terminal: {if @vm_name, do: @vm_name, else: "nenhuma VM selecionada"}
        </span>
      </div>

      <p :if={@file_error} class="qa-card m-4 border-error/40 p-3 text-xs text-error">
        {@file_error} — corrija ou apague o arquivo: esta página não o sobrescreve.
      </p>

      <form
        :if={@editing}
        id="cp-form"
        phx-change="cp_change"
        phx-submit="cp_save"
        class="qa-card m-4 shrink-0 space-y-3 p-4 text-xs"
        autocomplete="off"
      >
        <h3 class="qa-label mb-0 text-primary">{if @editing["original"] in [nil, ""], do: "Novo comando", else: "Editar #{@editing["original"]}"}</h3>
        <div class="grid gap-3 sm:grid-cols-2">
          <div>
            <label class="qa-label" for="cp_name">Nome (uma palavra)</label>
            <input id="cp_name" name="saved[name]" value={@editing["name"]} class="qa-field font-mono" placeholder="parar" phx-debounce="300" />
          </div>
          <div>
            <label class="qa-label" for="cp_vm">Vale para</label>
            <select id="cp_vm" name="saved[vm]" class="qa-field">
              <option value="" selected={@editing["vm"] in [nil, ""]}>Todas as VMs</option>
              <option :for={{vm, _rt} <- @vms} value={vm.id} selected={@editing["vm"] == vm.id}>Só {vm.name}</option>
            </select>
          </div>
        </div>
        <div>
          <label class="qa-label" for="cp_description">Descrição</label>
          <input id="cp_description" name="saved[description]" value={@editing["description"]} class="qa-field" placeholder="Pausa a VM" phx-debounce="300" />
        </div>
        <div>
          <label class="qa-label" for="cp_steps">Passos (um por linha, executados em ordem)</label>
          <textarea
            id="cp_steps"
            name="saved[steps]"
            rows="6"
            spellcheck="false"
            phx-debounce="300"
            class="qa-field font-mono !text-[0.7rem]"
            placeholder={"@start\nqmp: query-status\nhmp: info registers\ncli: qemu-img info {dir}/disk0.qcow2"}
          >{@editing["steps"]}</textarea>
        </div>
        <div class="grid gap-2 rounded border border-primary/15 bg-base-300/30 p-3 text-[0.68rem] text-base-content/60 sm:grid-cols-2">
          <p><code class="text-primary">qmp: stop</code> — um comando QMP, que o app manda direto ao QEMU. Com argumentos em JSON: <code>{"qmp: block_resize {\"device\": \"d0\", \"size\": 1048576}"}</code>, ou a mensagem inteira.</p>
          <p><code class="text-info">hmp: info status</code> — um comando do monitor (o QEMU o recebe embrulhado no QMP <code>human-monitor-command</code>).</p>
          <p><code class="text-warning">cli: qemu-img info disk0.qcow2</code> — uma ferramenta do QEMU, rodada como processo na pasta da VM (só <code>qemu-img</code>, <code>qemu-io</code> e <code>qemu-system-*</code> com <code>help</code>/<code>-version</code>).</p>
          <p>Sem prefixo, o Terminal descobre sozinho. Do app: <code>@start</code> (liga e espera) e <code>@wait 3</code> (segundos). <code>{"{vm}"}</code>, <code>{"{name}"}</code> e <code>{"{dir}"}</code> viram o id, o nome e a pasta da VM. Linhas com # são ignoradas.</p>
        </div>
        <label class="flex items-center gap-2">
          <input type="hidden" name="saved[continue_on_error]" value="false" />
          <input
            type="checkbox"
            name="saved[continue_on_error]"
            value="true"
            checked={@editing["continue_on_error"] == true}
            class="checkbox checkbox-xs checkbox-primary"
          />
          Seguir para o próximo passo mesmo se um falhar
        </label>
        <p :if={@error} id="cp-error" class="text-error">{@error}</p>
        <div class="flex gap-2">
          <button type="submit" id="cp-save" class="rounded-md bg-primary px-3 py-1.5 font-semibold text-primary-content hover:brightness-110">
            Salvar
          </button>
          <button type="button" id="cp-cancel" phx-click="cp_cancel" class="rounded-md border border-base-content/20 px-3 py-1.5 hover:bg-base-300">
            Cancelar
          </button>
        </div>
      </form>

      <div class="flex shrink-0 flex-wrap items-center gap-3 border-b border-base-content/10 px-4 py-2">
        <div role="tablist" class="flex flex-wrap gap-1">
          <button
            :for={{kind, label} <- tabs()}
            type="button"
            role="tab"
            id={"cat-tab-#{kind}"}
            phx-click="cat_kind"
            phx-value-kind={kind}
            aria-selected={to_string(@cat.kind == kind)}
            class={
              "rounded-md px-2.5 py-1 text-xs hover:bg-base-300",
              "bg-primary/15 font-semibold text-primary": @cat.kind == kind
            }
          >
            {label} <span :if={count(@entries, kind)} class="font-mono text-[0.62rem] text-base-content/45">{count(@entries, kind)}</span>
          </button>
        </div>
        <form
          :if={@cat.kind != "launch"}
          id="cat-filter"
          phx-change="cat_filter"
          phx-submit="cat_filter"
          class="ml-auto flex items-center gap-3"
        >
          <label class="relative block">
            <.icon
              name="hero-funnel"
              class="pointer-events-none absolute top-1/2 left-2.5 size-3.5 -translate-y-1/2 text-base-content/40"
            />
            <input
              type="text"
              name="q"
              value={@cat.q}
              placeholder="Filtrar a tabela por nome ou descrição"
              autocomplete="off"
              phx-debounce="200"
              class="w-80 max-w-full rounded-md border border-primary/25 bg-base-200 py-1 pr-3 pl-8 text-xs outline-none focus:border-primary"
            />
          </label>
          <span class="font-mono text-[0.68rem] text-base-content/40">{@shown} de {length(@entries)} comandos</span>
        </form>
      </div>

      <div :if={@cat.kind != "launch"} class="min-h-0 flex-1 overflow-auto">
        <table id="cat-table" class="w-full text-xs">
          <thead class="sticky top-0 z-10 bg-base-200 text-left text-[0.62rem] uppercase tracking-wide text-base-content/50">
            <tr>
              <th class="w-24 px-3 py-1.5">Tipo</th>
              <th class="w-56 px-3 py-1.5">Comando</th>
              <th class="w-64 px-3 py-1.5">Uso</th>
              <th class="px-3 py-1.5">Descrição</th>
            </tr>
          </thead>
          <tbody>
            {#for e <- @visible}
              <tr
                id={"cat-row-#{e.id}"}
                phx-click="cat_select"
                phx-value-id={e.id}
                data-kind={e.kind}
                class={
                  "cursor-pointer border-b border-base-content/5 align-top hover:bg-primary/5",
                  "bg-primary/10": @cat.sel == e.id
                }
              >
                <td class="px-3 py-1.5">
                  <span class={"rounded px-1.5 py-0.5 text-[0.6rem]", elem(kind_badge(e.kind), 1)}>{elem(kind_badge(e.kind), 0)}</span>
                </td>
                <td class="px-3 py-1.5 font-mono font-semibold">{e.name}</td>
                <td class="px-3 py-1.5 font-mono text-[0.68rem] text-base-content/55">{e.usage}</td>
                <td class="px-3 py-1.5 text-base-content/75">{e.description}</td>
              </tr>
              <tr :if={@cat.sel == e.id} id="cat-editor-row" class="border-b border-primary/20 bg-base-200/60">
                <td colspan="4" class="px-4 py-3">
                  {if e.kind == "saved", do: saved_detail(assign(assigns, e: e)), else: editor(assign(assigns, e: e))}
                </td>
              </tr>
            {/for}
            <tr :if={@visible == []}>
              <td colspan="4" class="px-3 py-6 text-center italic text-base-content/45">
                {if @cat.kind == "saved" and @cat.q == "", do: "Nenhum comando salvo ainda. Clique em Novo comando.", else: "Nenhum comando com esse filtro."}
              </td>
            </tr>
          </tbody>
        </table>
        <p :if={@shown > length(@visible)} class="px-3 py-2 text-center text-[0.65rem] text-base-content/40">
          {length(@visible)} de {@shown} — refine o filtro ou a busca para ver os outros
        </p>
        <p class="px-3 py-2 font-mono text-[0.6rem] text-base-content/30" title="Onde os comandos salvos ficam">{@path}</p>
      </div>

      <section :if={@cat.kind == "launch"} id="launch-lines" class="min-h-0 flex-1 overflow-y-auto p-5">
        <p class="mb-3 text-xs text-base-content/55">
          Os argumentos com que cada VM inicia. O app os monta a partir da configuração da VM; aqui dá para
          <strong>editá-los à mão</strong> (vale no próximo boot). No lugar das portas que o app escolhe a cada início, use
          {#for p <- QemuAdmin.Vm.Args.placeholders()}<code class="mr-1.5 text-primary/80">{p}</code>{/for}.
        </p>
        <ul class="space-y-2">
          <li :for={{vm, _rt} <- @vms} id={"lp-#{vm.id}"} class="qa-card p-3 text-xs">
            <div class="flex items-start gap-2">
              <div class="min-w-0 flex-1">
                <div class="flex flex-wrap items-baseline gap-2">
                  <span class="font-semibold">{vm.name}</span>
                  <span
                    class={"rounded px-1.5 text-[0.6rem]", "bg-warning/15 text-warning": vm.command not in [nil, ""], "bg-base-300 text-base-content/55": vm.command in [nil, ""]}
                  >
                    {if vm.command in [nil, ""], do: "padrão do app", else: "editada"}
                  </span>
                </div>
                <p class="mt-1 break-all font-mono text-[0.65rem] text-base-content/60">
                  <span class="text-base-content/35">{Map.get(@exes, vm.id)}</span> {Map.get(@lines, vm.id)}
                </p>
              </div>
              <button
                :if={is_nil(@lp) or @lp.id != vm.id}
                type="button"
                phx-click="lp_edit"
                phx-value-id={vm.id}
                class="shrink-0 rounded border border-base-content/20 px-2 py-1 hover:bg-base-300"
              >
                Editar linha de partida
              </button>
            </div>
            <form
              :if={@lp && @lp.id == vm.id}
              id="lp-form"
              phx-change="lp_change"
              phx-submit="lp_save"
              class="mt-3 space-y-2"
              autocomplete="off"
            >
              <textarea
                id="lp-text"
                name="text"
                rows="5"
                spellcheck="false"
                phx-debounce="300"
                class={"qa-field font-mono !text-[0.68rem]", "!border-error": @lp.error}
              >{@lp.text}</textarea>
              <p :if={@lp.error} id="lp-error" class="text-error">{@lp.error}</p>
              <p class="text-[0.65rem] text-base-content/45">
                A linha precisa do que o app usa para controlar a VM: <code>{"{qmp}"}</code> sempre, <code>{"{serial}"}</code> nas placas
                e <code>{"{gdb}"}</code> no ESP32 e no Arduino. Em caminhos do Windows use <code>/</code>.
              </p>
              <div class="flex items-center gap-2">
                <button type="submit" id="lp-save" class="rounded-md bg-primary px-3 py-1 font-semibold text-primary-content hover:brightness-110">
                  Salvar
                </button>
                <button type="button" id="lp-cancel" phx-click="lp_cancel" class="rounded-md border border-base-content/20 px-3 py-1 hover:bg-base-300">
                  Cancelar
                </button>
                <button
                  type="button"
                  id="lp-reset"
                  phx-click="lp_reset"
                  class="ml-auto rounded-md border border-base-content/20 px-3 py-1 hover:bg-base-300"
                  title="Voltar à linha que o app monta sozinho"
                >
                  Restaurar a padrão
                </button>
              </div>
            </form>
          </li>
        </ul>
      </section>
    </div>
    """
  end

  # A saved command opened in the table: its steps, and what can be done with it.
  defp saved_detail(assigns) do
    ~F"""
    <div id={"cp-#{@e.name}"} class="text-xs">
      <div class="flex flex-wrap items-center gap-2">
        <span class="rounded bg-base-300 px-1.5 text-[0.6rem] text-base-content/60">
          {if @e.vm, do: "só #{vm_name(@vms, @e.vm)}", else: "todas as VMs"}
        </span>
        <span :if={@e.continue_on_error} class="rounded bg-warning/15 px-1.5 text-[0.6rem] text-warning">segue se falhar</span>
        <span class="ml-auto flex gap-2">
          <button
            type="button"
            id="cp-run"
            phx-click="cat_run"
            phx-value-name={@e.name}
            disabled={is_nil(@vm_name)}
            title={if @vm_name, do: "Executa no Terminal de #{@vm_name}", else: "Selecione uma VM"}
            class="rounded-md bg-primary px-3 py-1 font-semibold text-primary-content hover:brightness-110 disabled:opacity-40"
          >
            Executar
          </button>
          <button type="button" phx-click="cp_edit" phx-value-name={@e.name} class="rounded border border-base-content/20 px-2 py-1 hover:bg-base-300">
            Editar
          </button>
          <button
            type="button"
            phx-click="cp_delete"
            phx-value-name={@e.name}
            data-confirm={"Excluir o comando salvo #{@e.name}?"}
            class="rounded border border-error/30 px-2 py-1 text-error hover:bg-error/10"
          >
            Excluir
          </button>
        </span>
      </div>
      <ol class="mt-2 space-y-0.5 font-mono text-[0.68rem]">
        <li :for={{step, i} <- Enum.with_index(@e.steps, 1)} class="flex items-baseline gap-2">
          <span class="w-4 shrink-0 text-right text-base-content/30">{i}</span>
          <span class={"w-14 shrink-0 rounded px-1 text-center text-[0.58rem]", elem(via(step), 1)}>{elem(via(step), 0)}</span>
          <span class="min-w-0 flex-1 break-all text-base-content/80">{step}</span>
        </li>
      </ol>
    </div>
    """
  end

  # The arguments' editor under the open row of a QEMU command.
  defp editor(assigns) do
    ~F"""
    <form id="cat-form" phx-change="cat_vals" phx-submit="cat_send" autocomplete="off" class="space-y-2">
      <p :if={@e.since} class="text-[0.65rem] text-base-content/45">desde o QEMU {@e.since}</p>
      <p :if={@e.args == []} class="text-base-content/55">Este comando não tem argumentos.</p>
      <div :if={@e.args != []} class="grid gap-x-4 gap-y-2 md:grid-cols-2">
        <label :for={a <- @e.args} class="block">
          <span class="flex items-baseline gap-1.5">
            <span class="font-mono font-semibold">{a.name}</span>
            <span :if={a.type != ""} class="font-mono text-[0.62rem] text-base-content/45">{a.type}</span>
            <span :if={a.required} class="text-[0.6rem] text-warning">obrigatório</span>
          </span>
          <input
            type="text"
            name={"v[#{a.name}]"}
            value={Map.get(@cat.vals, a.name, "")}
            phx-debounce="150"
            spellcheck="false"
            disabled={@e.kind == "event"}
            class="qa-field mt-0.5 font-mono"
          />
          <span :if={a.description != ""} class="mt-0.5 block text-[0.65rem] text-base-content/50">{a.description}</span>
        </label>
      </div>
      <div :if={Catalog.line(@e, @cat.vals)} class="flex flex-wrap items-center gap-2 pt-1">
        <code id="cat-line" class="min-w-0 flex-1 break-all rounded bg-base-300 px-2 py-1 font-mono text-[0.7rem]">{Catalog.line(@e, @cat.vals)}</code>
        <button
          type="submit"
          id="cat-send"
          disabled={is_nil(@vm_name)}
          title={if @vm_name, do: "Executa no Terminal de #{@vm_name}", else: "Selecione uma VM"}
          class="rounded-md bg-primary px-3 py-1 font-semibold text-primary-content hover:brightness-110 disabled:opacity-40"
        >
          Enviar ao Terminal
        </button>
        <select name="to" id="cat-to" class="qa-field !w-auto" title="Comando salvo que recebe o passo">
          <option value="" selected={@cat.to == ""}>Novo comando salvo…</option>
          <option :for={c <- @commands} value={c["name"]} selected={@cat.to == c["name"]}>{c["name"]}</option>
        </select>
        <button
          type="button"
          id="cat-step"
          phx-click="cat_step"
          class="rounded-md border border-base-content/20 px-3 py-1 hover:bg-base-300"
        >
          Adicionar como passo
        </button>
      </div>
      <p :if={@e.kind == "event"} class="text-[0.65rem] text-base-content/50">
        Eventos são mensagens que o QEMU envia; aparecem no Terminal como “evento”. Não há o que enviar.
      </p>
      <p :if={@e.emulators != []} class="text-[0.62rem] text-base-content/40">
        Existe em: {Enum.join(@e.emulators, ", ")}
      </p>
    </form>
    """
  end
end
