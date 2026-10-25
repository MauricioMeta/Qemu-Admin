defmodule QemuAdmin do
  @moduledoc """
  QEMU Admin: a local manager for QEMU virtual machines, laid out as the
  Rockwell Viewer (icon rail, side panel, page header, status footer) and
  shipped as a Tauri desktop app with its own portable QEMU.

  The domain:

    * `QemuAdmin.Paths` — where VMs, settings and a downloaded QEMU live;
    * `QemuAdmin.Settings` — the user's preferences (`settings.json`);
    * `QemuAdmin.Qemu` — finds the QEMU binaries (bundled, downloaded, PATH);
    * `QemuAdmin.Qemu.Installer` — fetches the portable Windows build;
    * `QemuAdmin.Qemu.Img` — `qemu-img` (create, info, resize);
    * `QemuAdmin.Vm` — a machine's definition; `QemuAdmin.Vm.Args` its
      command line;
    * `QemuAdmin.VmStore` — the definitions on disk (`vms/<id>/vm.json`);
    * `QemuAdmin.VmServer` — one process per running VM (the QEMU port and
      its QMP socket), under `QemuAdmin.VmSupervisor`.
  """

  @doc "The PubSub topic every VM change is broadcast on."
  def topic, do: "vms"
end
