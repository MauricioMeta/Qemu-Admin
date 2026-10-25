defmodule QemuAdmin.Qemu.InstallJob do
  @moduledoc """
  Installs QEMU from the app (the QEMU page's download buttons), in the
  background, into the data directory: `kind` `:qemu` is the portable QEMU
  (`QemuAdmin.Qemu.Installer`), `:esp` Espressif's (`QemuAdmin.Qemu.Esp`).
  One process per kind; the progress is broadcast on the `"qemu"` topic as
  `{:qemu_install, kind, state}` and kept here, so a page opened halfway
  through still shows it.

  `state` is `%{phase:, received:, total:, error:}`, `phase` one of `:idle`,
  `:resolve`, `:download`, `:verify`, `:extract`, `:done`, `:error`.
  """

  use GenServer

  alias QemuAdmin.{Paths, Qemu}
  alias QemuAdmin.Qemu.{Esp, Installer}

  @idle %{phase: :idle, received: 0, total: nil, error: nil}

  def child_spec(kind), do: %{id: {__MODULE__, kind}, start: {__MODULE__, :start_link, [kind]}}

  def start_link(kind), do: GenServer.start_link(__MODULE__, kind, name: name(kind))

  defp name(:qemu), do: __MODULE__
  defp name(kind), do: Module.concat(__MODULE__, kind |> to_string() |> Macro.camelize())

  def state(kind \\ :qemu), do: GenServer.call(name(kind), :state)

  @doc "Starts the install unless one is running."
  def start(kind \\ :qemu), do: GenServer.call(name(kind), :start)

  @impl true
  def init(kind), do: {:ok, %{kind: kind, job: @idle, task: nil}}

  @impl true
  def handle_call(:state, _from, s), do: {:reply, s.job, s}

  def handle_call(:start, _from, %{task: task} = s) when not is_nil(task),
    do: {:reply, {:error, :running}, s}

  def handle_call(:start, _from, s) do
    me = self()

    task =
      Task.async(fn ->
        opts = [
          cache_dir: Path.join(Paths.data_dir(), "cache"),
          progress: fn event -> send(me, {:progress, event}) end
        ]

        case s.kind do
          :qemu -> Installer.install(Paths.downloaded_qemu_dir(), opts)
          :esp -> Esp.install(Esp.downloaded_dir(), opts)
        end
      end)

    {:reply, :ok, update(%{s | task: task}, %{@idle | phase: :resolve})}
  end

  @impl true
  def handle_info({:progress, {:download, {received, total}}}, s) do
    # ~200 MB in 64 KB chunks: tell the page every 2 MB or so
    if s.job.phase != :download or received - s.job.received > 2_097_152 or received == total,
      do: {:noreply, update(s, %{s.job | phase: :download, received: received, total: total})},
      else: {:noreply, s}
  end

  def handle_info({:progress, {phase, _}}, s) when phase in [:resolve, :verify, :extract],
    do: {:noreply, update(s, %{s.job | phase: phase})}

  def handle_info({:progress, _}, s), do: {:noreply, s}

  def handle_info({ref, result}, %{task: %Task{ref: ref}} = s) do
    Process.demonitor(ref, [:flush])

    job =
      case result do
        {:ok, _dir} ->
          Qemu.refresh()
          %{s.job | phase: :done}

        {:error, reason} ->
          %{s.job | phase: :error, error: to_string(reason)}
      end

    {:noreply, update(%{s | task: nil}, job)}
  end

  def handle_info({:DOWN, ref, :process, _, reason}, %{task: %Task{ref: ref}} = s) do
    {:noreply, update(%{s | task: nil}, %{s.job | phase: :error, error: inspect(reason)})}
  end

  def handle_info(_msg, s), do: {:noreply, s}

  defp update(s, job) do
    Phoenix.PubSub.broadcast(QemuAdmin.PubSub, "qemu", {:qemu_install, s.kind, job})
    %{s | job: job}
  end
end
