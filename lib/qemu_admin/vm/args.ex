defmodule QemuAdmin.Vm.Args do
  @moduledoc """
  A VM's QEMU command line. Pure: what the host offers comes in `host`
  (`%{accels:, os:, arch:}`, from `QemuAdmin.Qemu.info/0` by default) and the
  ports picked for this run in `ports` (`%{qmp:, vnc:, ws:, serial:, gdb:}`),
  so the tests can pin both.

  The pieces:

    * **QMP** on a loopback TCP port — `QemuAdmin.VmServer` drives the VM
      through it (power, pause, CD, screenshots);
    * **display** — `vnc` exposes VNC with QEMU's own WebSocket listener,
      which the noVNC console in the page connects to; `sdl`/`gtk` open
      QEMU's own window; `none` is headless;
    * **accel** — `auto` asks for the host's hypervisor and falls back to
      TCG (`-accel whpx -accel tcg`: QEMU tries them in order);
    * **disks** as `-drive if=none` + a `-device`, with `bootindex` deciding
      the boot order (SeaBIOS and OVMF both honour it);
    * a **CD-ROM** always present (`cd0`), so media can be swapped while the
      VM runs;
    * **UEFI** from the edk2 images beside QEMU, the variables copied into
      the VM's folder (`efivars.fd`) on first boot.

  The development boards (`Vm.kind/1`) are other machines altogether, all
  with UART0 on a loopback socket `QemuAdmin.VmServer` reads
  (`ports.serial`) — `wait=on`, so QEMU holds the board until it is
  connected and not a byte of the boot log is lost:

    * an **ESP32** (`build_esp32/2`): the chip as the board, the SPI flash as
      an `mtd` drive, the OpenCores Ethernet MAC Espressif added;
    * an **Arduino** (`build_avr/2`): the program as the flash (`-bios`);
    * a **Cortex-M board** (`build_cortexm/2`): the program as the kernel
      (`-kernel`), USART1 on the UART socket;
    * a **Raspberry Pi** (`build_raspi/2`): the kernel and device tree from
      the SD card, the card itself, and USB keyboard, tablet and network on
      the boards QEMU gives USB.

  With `ports.gdb`, an ESP32 or an Arduino also gets QEMU's gdbstub and
  starts paused (`-S`): `QemuAdmin.Gpio` attaches to follow the pins and lets
  it run.
  """

  alias QemuAdmin.{Qemu, Vm}

  @doc "The emulator's arguments (not the executable)."
  def build(vm, ports, host \\ host())

  def build(%Vm{} = vm, ports, host) do
    case Vm.kind(vm) do
      :esp32 -> build_esp32(vm, ports)
      :avr -> build_avr(vm, ports)
      :cortexm -> build_cortexm(vm, ports)
      :raspi -> build_raspi(vm, ports)
      :pc -> build_pc(vm, ports, host)
    end
  end

  defp build_pc(vm, ports, host) do
    List.flatten([
      ["-name", "#{esc(vm.name)},process=qemu-admin-#{vm.id}"],
      ["-machine", machine(vm)],
      accel(vm, host),
      cpu(vm),
      ["-smp", to_string(vm.cpus), "-m", to_string(vm.memory)],
      firmware(vm),
      storage(vm),
      network(vm),
      usb(vm),
      video(vm),
      display(vm, ports),
      rtc(vm),
      ["-qmp", "tcp:127.0.0.1:#{ports.qmp},server=on,wait=off"],
      extra(vm)
    ])
  end

  defp build_esp32(vm, ports) do
    List.flatten([
      ["-name", "#{esc(vm.name)},process=qemu-admin-#{vm.id}"],
      ["-machine", vm.machine],
      if(is_integer(vm.memory) and vm.memory > 0, do: ["-m", "#{vm.memory}M"], else: []),
      Enum.map(vm.disks, fn d ->
        ["-drive", "file=#{esc(Vm.resolve(vm, d["path"]))},if=mtd,format=raw"]
      end),
      mcu_network(vm),
      ["-display", "none"],
      serial(ports),
      ["-qmp", "tcp:127.0.0.1:#{ports.qmp},server=on,wait=off"],
      gdb(ports),
      extra(vm)
    ])
  end

  @doc "An Arduino's program in its folder: `firmware.elf` or `firmware.bin`, or nil."
  def avr_firmware(vm) do
    ~w(firmware.elf firmware.bin)
    |> Enum.map(&Path.join(Vm.dir(vm), &1))
    |> Enum.find(&File.regular?/1)
  end

  @doc "A Cortex-M board's program in its folder: `firmware.elf` or `firmware.bin`, or nil."
  def cortexm_firmware(vm), do: avr_firmware(vm)

  # QEMU's STM32 machines take the program with -kernel (an ELF, or a raw
  # image loaded at the flash). The first -serial is USART1. No -S/-gdb: the
  # pins are not followed (yet).
  defp build_cortexm(vm, ports) do
    List.flatten([
      ["-name", "#{esc(vm.name)},process=qemu-admin-#{vm.id}"],
      ["-machine", vm.machine],
      case cortexm_firmware(vm) do
        nil -> []
        file -> ["-kernel", esc(file)]
      end,
      ["-display", "none"],
      serial(ports),
      ["-qmp", "tcp:127.0.0.1:#{ports.qmp},server=on,wait=off"],
      extra(vm)
    ])
  end

  defp build_avr(vm, ports) do
    List.flatten([
      ["-name", "#{esc(vm.name)},process=qemu-admin-#{vm.id}"],
      ["-machine", vm.machine],
      case avr_firmware(vm) do
        nil -> []
        file -> ["-bios", esc(file)]
      end,
      ["-display", "none"],
      serial(ports),
      ["-qmp", "tcp:127.0.0.1:#{ports.qmp},server=on,wait=off"],
      gdb(ports),
      extra(vm)
    ])
  end

  defp build_raspi(vm, ports) do
    board = Vm.board(vm)

    List.flatten([
      ["-name", "#{esc(vm.name)},process=qemu-admin-#{vm.id}"],
      ["-machine", vm.machine],
      if(vm.kernel != "", do: ["-kernel", esc(Vm.resolve(vm, vm.kernel))], else: []),
      if(vm.dtb != "", do: ["-dtb", esc(Vm.resolve(vm, vm.dtb))], else: []),
      if(vm.append != "", do: ["-append", vm.append], else: []),
      Enum.map(vm.disks, fn d ->
        ["-drive", "file=#{esc(Vm.resolve(vm, d["path"]))},if=sd,format=raw"]
      end),
      if(board.usb?, do: raspi_usb(vm), else: []),
      display(vm, ports),
      serial(ports),
      ["-qmp", "tcp:127.0.0.1:#{ports.qmp},server=on,wait=off"],
      extra(vm)
    ])
  end

  # The BCM283x's USB controller: a keyboard and a tablet for the console, and
  # the network as a USB Ethernet adapter (the Pi 3's own sits on USB too).
  defp raspi_usb(vm) do
    net =
      if vm.net_mode == "none",
        do: [],
        else: ["-netdev", "user,id=net0" <> forwards(vm), "-device", "usb-net,netdev=net0"]

    [["-device", "usb-kbd", "-device", "usb-tablet"], net]
  end

  defp serial(ports),
    do: ["-serial", "tcp:127.0.0.1:#{ports.serial},server=on,wait=on,nodelay=on"]

  defp gdb(%{gdb: port}) when is_integer(port), do: ["-S", "-gdb", "tcp:127.0.0.1:#{port}"]
  defp gdb(_ports), do: []

  defp forwards(vm) do
    Enum.map_join(vm.forwards, fn spec ->
      case Vm.parse_forward(spec) do
        {:ok, {proto, h, g}} -> ",hostfwd=#{proto}:127.0.0.1:#{h}-:#{g}"
        :error -> ""
      end
    end)
  end

  defp mcu_network(%Vm{net_mode: "none"}), do: ["-nic", "none"]

  defp mcu_network(%Vm{} = vm),
    do: ["-nic", "user,model=open_eth,mac=#{Vm.mac(vm)}" <> forwards(vm)]

  @doc "What the host offers, for `build/3`."
  def host do
    info = Qemu.info()

    %{
      accels: info.accels,
      os: os(),
      arch: host_arch()
    }
  end

  defp os do
    case :os.type() do
      {:win32, _} -> :windows
      {:unix, :darwin} -> :macos
      _ -> :linux
    end
  end

  defp host_arch do
    arch = to_string(:erlang.system_info(:system_architecture))

    cond do
      arch =~ ~r/aarch64|arm64/ -> "aarch64"
      arch =~ ~r/x86_64|amd64|win32/i -> "x86_64"
      true -> arch
    end
  end

  # QEMU's option syntax: a comma inside a value is written twice.
  defp esc(value), do: String.replace(to_string(value), ",", ",,")

  defp machine(%Vm{arch: "aarch64", machine: "virt"}), do: "virt"
  defp machine(%Vm{machine: m}), do: m

  @doc """
  The `-accel` options. `auto` lists the host's hypervisor when QEMU has it
  and the guest is the host's architecture, then TCG.
  """
  def accel(%Vm{accel: "auto"} = vm, host) do
    native =
      cond do
        not same_arch?(vm.arch, host.arch) -> nil
        host.os == :windows -> "whpx"
        host.os == :linux -> "kvm"
        host.os == :macos -> "hvf"
      end

    accels =
      if native && native in host.accels,
        do: [accel_opt(native), "tcg"],
        else: ["tcg"]

    Enum.flat_map(accels, &["-accel", &1])
  end

  def accel(%Vm{accel: a}, _host), do: ["-accel", accel_opt(a)]

  # WHPX with QEMU's in-kernel irqchip is still unreliable; the userspace
  # one is what works across Windows builds.
  defp accel_opt("whpx"), do: "whpx,kernel-irqchip=off"
  defp accel_opt(a), do: a

  defp same_arch?(guest, host), do: guest == host or (guest == "i386" and host == "x86_64")

  defp cpu(%Vm{cpu: cpu}) when cpu in [nil, ""], do: []
  defp cpu(%Vm{cpu: cpu}), do: ["-cpu", cpu]

  @doc "The UEFI images, as `{code, vars_template}` file names."
  def uefi_images("x86_64"), do: {"edk2-x86_64-code.fd", "edk2-i386-vars.fd"}
  def uefi_images("i386"), do: {"edk2-i386-code.fd", "edk2-i386-vars.fd"}
  def uefi_images("aarch64"), do: {"edk2-aarch64-code.fd", "edk2-arm-vars.fd"}

  @doc "Where the VM keeps its UEFI variables."
  def efivars(vm), do: Path.join(Vm.dir(vm), "efivars.fd")

  defp firmware(%Vm{uefi: false}), do: []

  defp firmware(%Vm{} = vm) do
    {code, _vars} = uefi_images(vm.arch)
    code = Qemu.firmware(code) || code

    [
      "-drive",
      "if=pflash,format=raw,unit=0,readonly=on,file=#{esc(code)}",
      "-drive",
      "if=pflash,format=raw,unit=1,file=#{esc(efivars(vm))}"
    ]
  end

  defp storage(%Vm{} = vm) do
    disks = Enum.with_index(vm.disks)
    n = length(vm.disks)
    cd_index = if vm.boot == "cdrom", do: 0, else: n
    disk_index = fn i -> if vm.boot == "cdrom", do: i + 1, else: i end

    # aarch64's virt board has no IDE/AHCI: SATA disks and the CD go on a
    # virtio-scsi controller instead.
    scsi? = vm.arch == "aarch64"

    controller =
      if scsi?, do: ["-device", "virtio-scsi-pci,id=scsi0"], else: []

    drives =
      Enum.map(disks, fn {d, i} ->
        path = Vm.resolve(vm, d["path"])

        [
          "-drive",
          "file=#{esc(path)},if=none,id=disk#{i},format=#{d["format"]},cache=writeback,discard=unmap",
          "-device",
          disk_device(d["interface"], i, disk_index.(i), scsi?)
        ]
      end)

    cd_file =
      case Vm.resolve(vm, vm.cdrom) do
        nil -> ""
        path -> ",file=#{esc(path)}"
      end

    cd = [
      "-drive",
      "if=none,id=cdrom0,media=cdrom,readonly=on#{cd_file}",
      "-device",
      if(scsi?,
        do: "scsi-cd,bus=scsi0.0,drive=cdrom0,id=cd0,bootindex=#{cd_index}",
        else: "ide-cd,drive=cdrom0,id=cd0,bootindex=#{cd_index}"
      )
    ]

    [controller, drives, cd]
  end

  defp disk_device("virtio", i, boot, _scsi?),
    do: "virtio-blk-pci,drive=disk#{i},bootindex=#{boot}"

  defp disk_device("nvme", i, boot, _scsi?),
    do: "nvme,drive=disk#{i},serial=qa-disk#{i},bootindex=#{boot}"

  defp disk_device("sata", i, boot, true),
    do: "scsi-hd,bus=scsi0.0,drive=disk#{i},bootindex=#{boot}"

  defp disk_device("sata", i, boot, false), do: "ide-hd,drive=disk#{i},bootindex=#{boot}"

  defp network(%Vm{net_mode: "none"}), do: ["-nic", "none"]

  defp network(%Vm{} = vm) do
    [
      "-netdev",
      "user,id=net0" <> forwards(vm),
      "-device",
      "#{vm.net_model},netdev=net0,mac=#{Vm.mac(vm)}"
    ]
  end

  # The tablet gives an absolute pointer: in a VNC console a relative mouse
  # drifts away from the cursor. aarch64 has no PS/2 keyboard either.
  defp usb(%Vm{arch: "aarch64"}),
    do: ["-device", "qemu-xhci,id=xhci", "-device", "usb-kbd", "-device", "usb-tablet"]

  defp usb(%Vm{usb_tablet: true}), do: ["-device", "qemu-xhci,id=xhci", "-device", "usb-tablet"]
  defp usb(_vm), do: []

  defp video(%Vm{display: "none"}), do: []
  defp video(%Vm{arch: "aarch64"}), do: ["-device", "virtio-gpu-pci"]
  defp video(%Vm{vga: vga}), do: ["-vga", vga]

  defp display(%Vm{display: "vnc"}, ports) do
    [
      "-display",
      "none",
      "-vnc",
      "127.0.0.1:#{ports.vnc - 5900},websocket=127.0.0.1:#{ports.ws}"
    ]
  end

  defp display(%Vm{display: d}, _ports) when d in ["sdl", "gtk"], do: ["-display", d]
  defp display(_vm, _ports), do: ["-display", "none"]

  defp rtc(%Vm{localtime: true}), do: ["-rtc", "base=localtime"]
  defp rtc(_vm), do: []

  defp extra(%Vm{extra_args: text}) do
    case Vm.split_args(text) do
      {:ok, args} -> args
      _ -> []
    end
  end

  @doc "The command line as one string, for the page (and for copying into a terminal)."
  def command_line(exe, args) do
    Enum.map_join([exe | args], " ", fn arg ->
      if arg =~ ~r/[\s"]/, do: ~s("#{String.replace(arg, "\"", "\\\"")}"), else: arg
    end)
  end
end
