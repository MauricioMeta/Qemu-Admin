defmodule QemuAdmin.Vm.ArgsTest do
  use ExUnit.Case, async: true

  alias QemuAdmin.Vm
  alias QemuAdmin.Vm.Args

  @ports %{qmp: 4444, vnc: 5901, ws: 5701}
  @windows %{accels: ["tcg", "whpx"], os: :windows, arch: "x86_64"}

  defp vm(attrs \\ %{}) do
    struct(%Vm{Vm.new() | id: "vm1", name: "VM 1"}, attrs)
  end

  defp args(vm, host \\ @windows), do: Args.build(vm, @ports, host)

  # the value after each occurrence of `flag`
  defp values(args, flag) do
    args
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.filter(fn [f, _] -> f == flag end)
    |> Enum.map(&List.last/1)
  end

  test "auto takes the host's hypervisor, TCG behind it" do
    assert values(args(vm()), "-accel") == ["whpx,kernel-irqchip=off", "tcg"]
    assert values(args(vm(), %{@windows | accels: ["tcg"]}), "-accel") == ["tcg"]

    assert values(args(vm(), %{accels: ["tcg", "kvm"], os: :linux, arch: "x86_64"}), "-accel") ==
             ["kvm", "tcg"]
  end

  test "a guest of another architecture is only emulated" do
    assert values(args(vm(%{arch: "aarch64", machine: "virt", uefi: true})), "-accel") == ["tcg"]
  end

  test "an explicit accelerator is used alone" do
    assert values(args(vm(%{accel: "tcg"})), "-accel") == ["tcg"]
  end

  test "QMP and the VNC console on loopback" do
    a = args(vm())
    assert values(a, "-qmp") == ["tcp:127.0.0.1:4444,server=on,wait=off"]
    assert values(a, "-vnc") == ["127.0.0.1:1,websocket=127.0.0.1:5701"]
    assert values(a, "-display") == ["none"]
  end

  test "SDL/GTK open QEMU's own window, without VNC" do
    a = args(vm(%{display: "sdl"}))
    assert values(a, "-display") == ["sdl"]
    assert values(a, "-vnc") == []
  end

  test "disks, CD and boot order" do
    a =
      args(
        vm(%{
          disks: [
            %{"path" => "disk0.qcow2", "format" => "qcow2", "interface" => "virtio"},
            %{"path" => "C:/d/data.img", "format" => "raw", "interface" => "sata"}
          ],
          cdrom: "C:/isos/debian.iso",
          boot: "cdrom"
        })
      )

    [d0, d1, cd] = values(a, "-drive")
    assert d0 =~ "vm1/disk0.qcow2,if=none,id=disk0,format=qcow2"
    assert d1 =~ "file=C:/d/data.img,if=none,id=disk1,format=raw"
    assert cd == "if=none,id=cdrom0,media=cdrom,readonly=on,file=C:/isos/debian.iso"

    devices = values(a, "-device")
    assert "virtio-blk-pci,drive=disk0,bootindex=1" in devices
    assert "ide-hd,drive=disk1,bootindex=2" in devices
    assert "ide-cd,drive=cdrom0,id=cd0,bootindex=0" in devices
  end

  test "an empty CD drive is still there, last in the boot order" do
    a = args(vm(%{disks: [%{"path" => "a.qcow2", "format" => "qcow2", "interface" => "nvme"}]}))
    assert "if=none,id=cdrom0,media=cdrom,readonly=on" in values(a, "-drive")
    assert "ide-cd,drive=cdrom0,id=cd0,bootindex=1" in values(a, "-device")
    assert "nvme,drive=disk0,serial=qa-disk0,bootindex=0" in values(a, "-device")
  end

  test "aarch64 puts the CD on virtio-scsi and adds a keyboard" do
    a = args(vm(%{arch: "aarch64", machine: "virt", uefi: true}))
    devices = values(a, "-device")
    assert "virtio-scsi-pci,id=scsi0" in devices
    assert Enum.any?(devices, &String.starts_with?(&1, "scsi-cd,bus=scsi0.0"))
    assert "usb-kbd" in devices
    assert "virtio-gpu-pci" in devices
  end

  test "UEFI: read-only code and the VM's own variables" do
    [code, vars] = args(vm(%{uefi: true})) |> values("-drive") |> Enum.filter(&(&1 =~ "pflash"))
    assert code =~ "unit=0,readonly=on,file="
    assert code =~ "edk2-x86_64-code.fd"
    assert vars =~ "unit=1,file="
    assert vars =~ "efivars.fd"
  end

  test "port forwards on the host's loopback" do
    a = args(vm(%{forwards: ["tcp:2222:22", "udp:5353:53"]}))

    assert values(a, "-netdev") == [
             "user,id=net0,hostfwd=tcp:127.0.0.1:2222-:22,hostfwd=udp:127.0.0.1:5353-:53"
           ]

    assert args(vm(%{net_mode: "none"})) |> values("-nic") == ["none"]
  end

  test "commas in the name are escaped, extra args appended" do
    a = args(vm(%{name: "a,b", extra_args: ~s(-device intel-hda -smbios "type=1,product=X Y")}))
    assert values(a, "-name") == ["a,,b,process=qemu-admin-vm1"]
    assert Enum.take(a, -4) == ["-device", "intel-hda", "-smbios", "type=1,product=X Y"]
  end

  test "command_line quotes what has spaces" do
    assert Args.command_line("C:/Program Files/qemu/q.exe", ["-name", "a b"]) ==
             ~s("C:/Program Files/qemu/q.exe" -name "a b")
  end
end
