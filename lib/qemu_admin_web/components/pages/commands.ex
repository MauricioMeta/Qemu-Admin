defmodule QemuAdminWeb.Components.Pages.Commands do
  @moduledoc """
  The **Comandos** page: every saved command of the workspace (`terminal.json`,
  `QemuAdmin.Terminal.Saved`) to create, edit and delete. A saved command is a
  name that the Terminal runs as a sequence of steps on a VM; to run one, type its
  name in a VM's Terminal (or use *Comandos salvos* there).

  `editing` is nil (the list) or the form's map (`"original"`, `"name"`,
  `"description"`, `"vm"`, `"steps"` as text, `"continue_on_error"`); `error` is
  what the last save said was wrong; `file_error` that `terminal.json` cannot be
  read (the page then refuses to overwrite it).

  Events: `cp_new`, `cp_edit` (`name`), `cp_change`, `cp_cancel`, `cp_save`,
  `cp_delete` (`name`).
  """

  use Surface.Component

  import QemuAdminWeb.CoreComponents, only: [icon: 1]

  @doc "`QemuAdmin.Terminal.Saved.load/0`, sorted by name."
  prop commands, :list, default: []

  @doc "`[{vm, runtime}]`, for the \"vale para\" menu."
  prop vms, :list, default: []

  @doc "The form: nil or a map."
  prop editing, :any, default: nil

  prop error, :any, default: nil

  prop file_error, :any, default: nil

  @doc "Where `terminal.json` is."
  prop path, :string, default: ""

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

  def render(assigns) do
    ~F"""
    <div id="commands-page" class="min-h-0 flex-1 overflow-y-auto p-5">
      <section class="qa-card mb-4 flex items-center gap-3 p-4 text-xs">
        <.icon name="hero-command-line" class="size-8 shrink-0 text-primary/70" />
        <div class="min-w-0 flex-1">
          <div class="font-semibold">Comandos salvos</div>
          <p class="text-base-content/55">
            Um nome (como <code class="text-primary/80">start</code>) que o Terminal de uma VM executa como uma sequência de passos.
            Digite o nome no Terminal da VM e dê Enter, ou use <strong>Comandos salvos</strong> lá.
          </p>
          <p class="mt-1 truncate font-mono text-[0.62rem] text-base-content/40" title={@path}>{@path}</p>
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
      </section>

      <p :if={@file_error} class="qa-card mb-4 border-error/40 p-3 text-xs text-error">
        {@file_error} — corrija ou apague o arquivo: esta página não o sobrescreve.
      </p>

      <form
        :if={@editing}
        id="cp-form"
        phx-change="cp_change"
        phx-submit="cp_save"
        class="qa-card mb-4 space-y-3 p-4 text-xs"
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

      <p :if={@commands == [] and is_nil(@file_error) and is_nil(@editing)} class="qa-card p-6 text-center text-xs text-base-content/50">
        Nenhum comando salvo ainda. Clique em <strong>Novo comando</strong>.
      </p>

      <ul :if={@commands != []} id="cp-list" class="space-y-2">
        <li :for={c <- @commands} id={"cp-#{c["name"]}"} class="qa-card p-3 text-xs">
          <div class="flex items-start gap-2">
            <div class="min-w-0 flex-1">
              <div class="flex flex-wrap items-baseline gap-2">
                <span class="font-mono text-sm font-semibold text-primary">{c["name"]}</span>
                <span class="rounded bg-base-300 px-1.5 text-[0.6rem] text-base-content/60">
                  {if c["vm"], do: "só #{vm_name(@vms, c["vm"])}", else: "todas as VMs"}
                </span>
                <span :if={c["continue_on_error"]} class="rounded bg-warning/15 px-1.5 text-[0.6rem] text-warning">segue se falhar</span>
                <span class="truncate text-base-content/55">{c["description"]}</span>
              </div>
              <ol class="mt-2 space-y-0.5 font-mono text-[0.68rem]">
                <li :for={{step, i} <- Enum.with_index(c["steps"], 1)} class="flex items-baseline gap-2">
                  <span class="w-4 shrink-0 text-right text-base-content/30">{i}</span>
                  <span class={"w-14 shrink-0 rounded px-1 text-center text-[0.58rem]", elem(via(step), 1)}>{elem(via(step), 0)}</span>
                  <span class="min-w-0 flex-1 break-all text-base-content/80">{step}</span>
                </li>
              </ol>
            </div>
            <button
              type="button"
              phx-click="cp_edit"
              phx-value-name={c["name"]}
              class="shrink-0 rounded border border-base-content/20 px-2 py-1 hover:bg-base-300"
            >
              Editar
            </button>
            <button
              type="button"
              phx-click="cp_delete"
              phx-value-name={c["name"]}
              data-confirm={"Excluir o comando salvo #{c["name"]}?"}
              class="shrink-0 rounded border border-error/30 px-2 py-1 text-error hover:bg-error/10"
            >
              Excluir
            </button>
          </div>
        </li>
      </ul>
    </div>
    """
  end
end
