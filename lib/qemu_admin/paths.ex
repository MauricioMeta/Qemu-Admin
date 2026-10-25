defmodule QemuAdmin.Paths do
  @moduledoc """
  Where things live on disk.

    * `data_dir/0` — `config :qemu_admin, :data_dir`; `~/.qemu_admin` when
      unset (dev). The release sets it to the per-user data directory
      (`config/runtime.exs`), the tests to a temporary folder.
    * `workspace_dir/0` — the folder the user works in (the setting
      `workspace`, `QemuAdmin.Workspace`); the data directory when unset.
    * `vms_dir/0` — `vms/` in the workspace: one folder per VM (`vm.json`,
      its disks, UEFI vars).
    * `images_dir/0` — `images/` in the workspace: the library the Imagens
      page lists (ISOs, disk and SD images, firmware).
    * `downloaded_qemu_dir/0` — a QEMU installed from the app at runtime.
  """

  alias QemuAdmin.Settings

  # Everything goes through Path.expand: on Windows the home folder and the
  # paths the Tauri shell passes come with backslashes, which Path.wildcard
  # reads as escapes.
  def data_dir do
    (Application.get_env(:qemu_admin, :data_dir) || Path.join(System.user_home!(), ".qemu_admin"))
    |> Path.expand()
  end

  def settings_file, do: Path.join(data_dir(), "settings.json")

  def workspace_dir do
    case Settings.get(:workspace) do
      dir when is_binary(dir) and dir != "" -> Path.expand(dir)
      _ -> data_dir()
    end
  end

  def vms_dir, do: Path.join(workspace_dir(), "vms")

  def images_dir, do: Path.join(workspace_dir(), "images")

  def downloaded_qemu_dir, do: Path.join(data_dir(), "qemu")

  def vm_dir(id), do: Path.join(vms_dir(), id)
end
