defmodule QemuAdmin.Workspace do
  @moduledoc """
  The folder the user works in: its `vms/` (one folder per VM) and its
  `images/` (ISOs, disk and SD card images, firmware — the Imagens page).
  Any folder will do; opening it creates both. The data directory is the
  default one, so a fresh install works with nothing chosen.

  The current one is the setting `workspace`; the ones opened before are
  kept in `recent_workspaces` (most recent first), for the switcher above
  the VM list. Switching needs every VM off: a running one lives in the
  folder being left.
  """

  alias QemuAdmin.{Paths, Settings, VmSupervisor}

  @keep 8

  @doc "The current workspace's folder."
  def current, do: Paths.workspace_dir()

  def default?(dir \\ current()), do: same?(dir, Paths.data_dir())

  @doc "A workspace's display name: its folder's name (\"Pasta padrão\" for the data directory)."
  def name(dir), do: if(default?(dir), do: "Pasta padrão", else: Path.basename(dir))

  @doc """
  Makes `dir` the workspace — created when missing, as long as its parent
  exists. `nil` or `""` goes back to the data directory.
  """
  def open(dir) when dir in [nil, ""], do: open(Paths.data_dir())

  def open(dir) do
    dir = Path.expand(String.trim(dir))

    cond do
      VmSupervisor.running() != [] and not same?(dir, current()) ->
        {:error, "Desligue as VMs antes de trocar de workspace"}

      not File.dir?(dir) and not File.dir?(Path.dirname(dir)) ->
        {:error, "#{Path.dirname(dir)} não existe"}

      true ->
        with :ok <- ensure(dir) do
          recent = [dir | Enum.reject(recent_paths(), &same?(&1, dir))] |> Enum.take(@keep)
          setting = if default?(dir), do: "", else: dir
          Settings.put(%{workspace: setting, recent_workspaces: recent})
          {:ok, dir}
        end
    end
  end

  @doc "Takes `dir` off the recent list (the folder stays)."
  def forget(dir) do
    Settings.put(%{recent_workspaces: Enum.reject(recent_paths(), &same?(&1, dir))})
    :ok
  end

  @doc """
  The workspaces to offer: the current one, the default and the recent
  ones, each `%{path:, name:, current?:, exists?:, vms:}`.
  """
  def list do
    [current(), Paths.data_dir() | recent_paths()]
    |> Enum.uniq_by(&key/1)
    |> Enum.map(fn dir ->
      %{
        path: dir,
        name: name(dir),
        current?: same?(dir, current()),
        exists?: File.dir?(dir),
        vms: dir |> Path.join("vms/*/vm.json") |> Path.wildcard() |> length()
      }
    end)
  end

  @doc """
  Creates `vms/` and `images/` in `dir`. The ISO folder of older versions
  (`isos/`) becomes `images/`.
  """
  def ensure(dir \\ current()) do
    images = Path.join(dir, "images")
    isos = Path.join(dir, "isos")

    with :ok <- File.mkdir_p(Path.join(dir, "vms")),
         :ok <-
           if(File.dir?(isos) and not File.exists?(images),
             do: File.rename(isos, images),
             else: :ok
           ),
         :ok <- File.mkdir_p(images) do
      :ok
    else
      {:error, reason} -> {:error, "#{dir}: #{:file.format_error(reason)}"}
    end
  end

  defp recent_paths, do: Settings.get(:recent_workspaces) || []

  defp same?(a, b), do: key(a) == key(b)

  # Windows paths compare without case
  defp key(dir) do
    dir = Path.expand(dir)
    if match?({:win32, _}, :os.type()), do: String.downcase(dir), else: dir
  end
end
