defmodule QemuAdminWeb.Components.Pages.Catalog do
  @moduledoc """
  The **Catálogo** page: every command QEMU understands
  (`QemuAdmin.Terminal.Catalog`) in a table, like the Rockwell Viewer's tag table.

  Two search bars, as there:

    * the **busca** on top is the full-text search (`Catalog.search/2`): it looks in
      names, arguments and descriptions, every word must be found, a word matches
      the beginning of a token; its results drop down and picking one selects the
      command in the table (Enter takes the first);
    * the **filtro** over the table narrows the rows by name or description, and the
      tabs by kind (monitor, QMP, eventos, ferramentas).

  Clicking a row opens its **editor de argumentos** under it: one field per
  argument (type, required, description from the QEMU schema) and the line that
  results, live. From there the line goes to the VM's Terminal (**Enviar**) or
  becomes a step of a saved command (**Adicionar a comando salvo**).

  The state is `cat`, a map kept by `QemuAdminWeb.AdminLive`: `q` (filter), `kind`,
  `sel` (the open entry's id), `vals` (`%{arg => text}`), `to` (the saved command
  the step goes to, `""` = a new one), `gq`, `gres`, `gtotal`, `gopen` (the search).

  Events: `cat_search`, `cat_search_close`, `cat_pick` (`id`), `cat_filter`,
  `cat_kind` (`kind`), `cat_select` (`id`), `cat_vals`, `cat_send`, `cat_step`.
  """

  use Surface.Component

  import QemuAdminWeb.CoreComponents, only: [icon: 1]
  alias QemuAdmin.Terminal.Catalog

  @row_limit 200

  @doc "The page's state, see above."
  prop cat, :map, required: true

  @doc "`Catalog.all/0`."
  prop entries, :list, default: []

  @doc "Names of the saved commands a step can be added to."
  prop saved, :list, default: []

  @doc "Whether a VM is selected to receive the commands (`Enviar`)."
  prop vm_name, :any, default: nil

  data shown, :integer, default: 0
  data visible, :list, default: []
  data current, :any, default: nil
  data e, :any, default: nil

  @tabs [{"all", "Todos"}, {"hmp", "Monitor"}, {"qmp", "QMP"}, {"event", "Eventos"}, {"tool", "Ferramentas"}]

  defp tabs, do: @tabs

  defp kind_badge("hmp"), do: {"monitor", "bg-info/15 text-info"}
  defp kind_badge("qmp"), do: {"QMP", "bg-primary/15 text-primary"}
  defp kind_badge("event"), do: {"evento", "bg-accent/15 text-accent"}
  defp kind_badge("tool"), do: {"ferramenta", "bg-warning/15 text-warning"}
  defp kind_badge(_), do: {"?", "bg-base-300 text-base-content/60"}

  defp count(entries, "all"), do: length(entries)
  defp count(entries, kind), do: Enum.count(entries, &(&1.kind == kind))

  defp rows(entries, cat) do
    narrowed = Catalog.narrow(entries, cat.kind, cat.q)
    {length(narrowed), Enum.take(narrowed, @row_limit)}
  end

  defp selected(entries, %{sel: sel}) when is_binary(sel), do: Enum.find(entries, &(&1.id == sel))
  defp selected(_entries, _cat), do: nil

  def render(assigns) do
    {shown, visible} = rows(assigns.entries, assigns.cat)
    assigns = assign(assigns, shown: shown, visible: visible, current: selected(assigns.entries, assigns.cat))

    ~F"""
    <div id="catalog" class="flex h-full min-h-0 flex-col">
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
                placeholder="Buscar em todo o catálogo (nome, argumento, descrição)…"
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
        <span class="ml-auto shrink-0 font-mono text-[0.68rem] text-base-content/40">
          Terminal: {if @vm_name, do: @vm_name, else: "nenhuma VM selecionada"}
        </span>
      </div>

      <div class="flex shrink-0 flex-wrap items-center gap-3 border-b border-base-content/10 px-4 py-2">
        <div role="tablist" class="flex gap-1">
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
            {label} <span class="font-mono text-[0.62rem] text-base-content/45">{count(@entries, kind)}</span>
          </button>
        </div>
        <form id="cat-filter" phx-change="cat_filter" phx-submit="cat_filter" class="ml-auto flex items-center gap-3">
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

      <div class="min-h-0 flex-1 overflow-auto">
        <table id="cat-table" class="w-full text-xs">
          <thead class="sticky top-0 z-10 bg-base-200 text-left text-[0.62rem] uppercase tracking-wide text-base-content/50">
            <tr>
              <th class="w-24 px-3 py-1.5">Tipo</th>
              <th class="w-64 px-3 py-1.5">Comando</th>
              <th class="w-72 px-3 py-1.5">Uso</th>
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
                  {editor(assign(assigns, e: e))}
                </td>
              </tr>
            {/for}
            <tr :if={@visible == []}>
              <td colspan="4" class="px-3 py-6 text-center italic text-base-content/45">Nenhum comando com esse filtro.</td>
            </tr>
          </tbody>
        </table>
        <p :if={@shown > length(@visible)} class="px-3 py-2 text-center text-[0.65rem] text-base-content/40">
          {length(@visible)} de {@shown} — refine o filtro ou a busca para ver os outros
        </p>
      </div>
    </div>
    """
  end

  # The arguments' editor under the open row.
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
          <option :for={n <- @saved} value={n} selected={@cat.to == n}>{n}</option>
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
