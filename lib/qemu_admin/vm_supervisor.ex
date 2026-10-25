defmodule QemuAdmin.VmSupervisor do
  @moduledoc """
  Runs the VMs: one `QemuAdmin.VmServer` per running VM, started on demand.

  It also owns the **runtime table** (ETS), where each VmServer keeps what
  the page needs to draw a VM without asking it — status, the ports of its
  console, when it started, how its last run ended. Reading it never blocks
  on a busy VM; `runtime/1` answers `%{status: :stopped}` for a VM that never
  ran.
  """

  use DynamicSupervisor

  alias QemuAdmin.{Qemu, Renode, RenodeServer, Vm, VmServer}
  alias QemuAdmin.Vm.Args

  @table :qemu_admin_runtime

  def start_link(_opts), do: DynamicSupervisor.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Starts `vm`, after checking everything it needs is there — so a missing
  disk is an `{:error, message}` for the page and not a crashed process.
  """
  def start_vm(%Vm{} = vm) do
    if Vm.kind(vm) == :renode, do: start_renode(vm), else: start_qemu(vm)
  end

  # A board of Renode: its executable, its board description and a program to run.
  defp start_renode(vm) do
    with :ok <- not_running(vm.id),
         {:ok, exe} <- renode_exe(),
         :ok <- renode_ready(vm) do
      case DynamicSupervisor.start_child(__MODULE__, {RenodeServer, {vm, exe}}) do
        {:ok, pid} -> {:ok, pid}
        {:error, {:already_started, _}} -> {:error, "a VM já está em execução"}
        {:error, reason} -> {:error, "não foi possível iniciar: #{inspect(reason)}"}
      end
    end
  end

  defp renode_exe do
    case Renode.exe() do
      {:ok, exe} -> {:ok, exe}
      {:error, :no_renode} -> {:error, "Renode não encontrado — coloque-o na pasta renode/ ao lado do app"}
    end
  end

  defp renode_ready(vm) do
    cond do
      is_nil(Renode.platform_file(vm.machine)) -> {:error, "a placa #{vm.machine} não existe nesta instalação do Renode"}
      is_nil(QemuAdmin.Firmwares.path(vm)) -> {:error, "escolha um firmware para esta VM (árvore da lateral)"}
      true -> :ok
    end
  end

  defp start_qemu(%Vm{} = vm) do
    with :ok <- not_running(vm.id),
         {:ok, exe} <- emulator(vm),
         :ok <- prepare(vm) do
      case DynamicSupervisor.start_child(__MODULE__, {VmServer, {vm, exe}}) do
        {:ok, pid} -> {:ok, pid}
        {:error, {:already_started, _}} -> {:error, "a VM já está em execução"}
        {:error, reason} -> {:error, "não foi possível iniciar: #{inspect(reason)}"}
      end
    end
  end

  defp not_running(id) do
    if running?(id), do: {:error, "a VM já está em execução"}, else: :ok
  end

  defp emulator(vm) do
    case Qemu.system_exe(vm.arch) do
      {:ok, exe} -> {:ok, exe}
      {:error, :no_qemu} -> {:error, "QEMU não encontrado — instale em Configurações › QEMU"}
      {:error, _} -> {:error, "este QEMU não tem qemu-system-#{vm.arch}"}
    end
  end

  @doc false
  def prepare(vm) do
    missing =
      Enum.find(vm.disks, fn d -> not File.regular?(Vm.resolve(vm, d["path"])) end)

    cdrom = Vm.resolve(vm, vm.cdrom)

    cond do
      missing ->
        {:error, "disco não encontrado: #{Vm.resolve(vm, missing["path"])}"}

      cdrom && not File.regular?(cdrom) ->
        {:error, "ISO não encontrada: #{cdrom}"}

      vm.uefi ->
        prepare_uefi(vm)

      true ->
        :ok
    end
  end

  # The variables are the VM's own (boot entries, Secure Boot keys): copied
  # once from the template, then left alone.
  defp prepare_uefi(vm) do
    {code, vars} = Args.uefi_images(vm.arch)
    efivars = Args.efivars(vm)

    cond do
      is_nil(Qemu.firmware(code)) ->
        {:error, "firmware UEFI #{code} não encontrado ao lado do QEMU"}

      File.regular?(efivars) ->
        :ok

      template = Qemu.firmware(vars) ->
        File.mkdir_p!(Path.dirname(efivars))
        File.cp!(template, efivars)
        :ok

      true ->
        {:error, "variáveis UEFI #{vars} não encontradas ao lado do QEMU"}
    end
  end

  @doc "What the page knows of VM `id` while (or after) it runs."
  def runtime(id) do
    case :ets.lookup(@table, id) do
      [{^id, rt}] -> rt
      [] -> %{status: :stopped}
    end
  end

  @doc false
  def put_runtime(id, rt), do: :ets.insert(@table, {id, rt})

  def running?(id), do: runtime(id).status != :stopped

  @doc "The ids of the VMs not stopped."
  def running do
    for {id, %{status: s}} <- :ets.tab2list(@table), s != :stopped, do: id
  end

  @doc "Ports in use by the running VMs, so two starts never pick the same."
  def ports_in_use do
    for {_id, %{status: s, ports: ports}} <- :ets.tab2list(@table),
        s != :stopped,
        port <- Map.values(ports),
        do: port
  end

  @doc """
  Stops every VM: ACPI power button first, waiting up to `timeout` seconds
  for the guests to shut down, then `quit`, then the process is killed.
  Returns the ids that had to be forced.
  """
  def shutdown_all(timeout) do
    ids = running()
    Enum.each(ids, &VmServer.powerdown/1)
    wait(timeout * 1000)

    forced = running()
    Enum.each(forced, &VmServer.quit/1)
    wait(3_000)
    Enum.each(running(), &VmServer.kill/1)
    wait(2_000)
    forced
  end

  defp wait(ms) when ms <= 0, do: :ok

  defp wait(ms) do
    if running() == [] do
      :ok
    else
      Process.sleep(200)
      wait(ms - 200)
    end
  end
end
