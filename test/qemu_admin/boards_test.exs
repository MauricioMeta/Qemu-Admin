defmodule QemuAdmin.BoardsTest do
  use ExUnit.Case, async: false

  import Bitwise

  alias QemuAdmin.{Board, Gpio, Paths, Settings, Vm, VmServer, VmStore, VmSupervisor, Workspace}
  alias QemuAdmin.Avr.Firmware
  alias QemuAdmin.Gpio.{Avr, Esp32, Raspi}
  alias QemuAdmin.Raspi.Image
  alias QemuAdmin.Vm.Args

  @ports %{qmp: 4444, vnc: 5901, ws: 5701, serial: 5555}

  setup do
    File.rm_rf!(Paths.data_dir())
    Settings.reset()
    on_exit(fn -> File.rm_rf!(Paths.data_dir()) end)
    :ok
  end

  describe "the catalog" do
    test "every board has its machine among the VM's, and pins that do not overlap" do
      for board <- Board.all() do
        assert board.machine in Vm.machines(board.arch), board.id
        assert Vm.kind(board.arch, board.machine) == board.kind

        positions = Enum.map(Board.pins(board), &{&1.x, &1.y})
        assert positions == Enum.uniq(positions), "#{board.id}: two pins in one place"
      end
    end

    test "the Arduino pins are their port bits" do
      uno = Board.get("arduino-uno")
      assert Board.avr_gpio("B", 5) in Board.gpios(uno)
      assert Board.avr_name(Board.avr_gpio("B", 5)) == "PB5"
      mega = Board.get("arduino-mega2560")
      assert Enum.find(Board.pins(mega), &(&1.label == "13")).ref == Board.avr_gpio("B", 7)
      assert Enum.find(Board.pins(mega), &(&1.label == "53")).ref == Board.avr_gpio("B", 0)
    end
  end

  describe "VMs of each board" do
    test "an Arduino has no disk, no network, one core" do
      {:ok, vm} =
        Vm.cast(Vm.new(), %{"name" => "uno", "arch" => "avr", "machine" => "arduino-uno"})

      assert Vm.kind(vm) == :avr and Vm.mcu?(vm) and Vm.serial?(vm)
      assert vm.disks == [] and vm.net_mode == "none" and vm.cpus == 1
    end

    test "a Raspberry Pi takes the board's memory and its SD card" do
      {:ok, vm} =
        Vm.cast(Vm.new(), %{
          "name" => "pi",
          "arch" => "aarch64",
          "machine" => "raspi3b",
          "disks" => %{"0" => %{"path" => "sd.img", "format" => "qcow2", "interface" => "virtio"}}
        })

      assert Vm.kind(vm) == :raspi and not Vm.mcu?(vm) and Vm.serial?(vm)
      assert vm.memory == 1024 and vm.accel == "tcg"
      assert [%{"format" => "raw", "interface" => "sd"}] = vm.disks
    end

    test "the Arduino's command line: its program, the UART, the gdbstub paused" do
      {:ok, vm} = VmStore.create(%{"name" => "uno", "arch" => "avr", "machine" => "arduino-uno"})
      File.write!(Path.join(Vm.dir(vm), "firmware.bin"), <<0xFF, 0xCF>>)
      args = Args.build(vm, Map.put(@ports, :gdb, 1234))

      assert "-bios" in args
      assert "-S" in args and "tcp:127.0.0.1:1234" in args
      assert "tcp:127.0.0.1:5555,server=on,wait=on,nodelay=on" in args
      refute "-gdb" in Args.build(vm, @ports)
    end

    test "the Raspberry Pi's: kernel, device tree, SD card, USB" do
      vm = %{
        Vm.new()
        | id: "pi",
          name: "pi",
          arch: "aarch64",
          machine: "raspi3b",
          kernel: "kernel8.img",
          dtb: "bcm2710-rpi-3-b.dtb",
          append: "console=ttyAMA0",
          disks: [%{"path" => "sd.img", "format" => "raw", "interface" => "sd"}],
          forwards: ["tcp:2222:22"]
      }

      args = Args.build(vm, @ports)
      assert Enum.any?(args, &String.ends_with?(&1, "kernel8.img"))
      assert Enum.any?(args, &(&1 =~ ~r/sd\.img,if=sd,format=raw$/))
      assert "usb-net,netdev=net0" in args
      assert "user,id=net0,hostfwd=tcp:127.0.0.1:2222-:22" in args
      refute "-smp" in args

      no_usb = Args.build(%{vm | machine: "raspi4b", dtb: "bcm2711-rpi-4-b.dtb"}, @ports)
      refute "usb-kbd" in no_usb
    end
  end

  describe "ESP32 GPIO" do
    test "decodes the stores and loads gpio_ll compiles to" do
      # s32i.n a8, a9, 8 · s32i a3, a4, 0x3c · l32i.n a2, a5, 0x3c (imm4 15)
      assert Esp32.decode(<<0x89, 0x29, 0x00>>) == {:store, 8, 9, 8}
      assert Esp32.decode(<<0x32, 0x64, 0x0F>>) == {:store, 3, 4, 60}
      assert Esp32.decode(<<0x28, 0xF5, 0x00>>) == {:load, 2, 5, 60}
      assert Esp32.decode(<<0xC0, 0x20, 0x00>>) == :unknown
    end

    test "W1TS/W1TC and the enables make the outputs; IN mixes in the inputs" do
      b = %{base: 0x3FF44000, out: 0, en: 0}
      b = b |> Esp32.write(0x24, 1 <<< 2) |> Esp32.write(0x08, 1 <<< 2) |> Esp32.write(0x30, 1)
      b = Esp32.write(b, 0x14, 1)
      assert Esp32.read(b, 0x3C, %{4 => 1}) == (1 <<< 2 ||| 1 <<< 4)
      assert Esp32.read(b, 0x40, %{}) == 1
      assert Esp32.read(Esp32.write(b, 0x0C, 1 <<< 2), 0x3C, %{}) == 0
      assert Esp32.read(b, 0x38, %{}) == nil

      pins = Esp32.pins(b, Board.get("esp32-devkitc"), %{4 => 1})
      assert pins[2] == %{dir: :out, level: 1}
      assert pins[4] == %{dir: :in, level: 1}
    end
  end

  describe "Arduino GPIO" do
    setup do
      {:ok, b: Avr.init(Board.get("arduino-uno"))}
    end

    defp regs(pairs) do
      Enum.reduce(pairs, List.duplicate(0, 32), fn {i, v}, acc -> List.replace_at(acc, i, v) end)
      |> List.to_tuple()
    end

    test "decodes the port accesses" do
      r = regs([{24, 0x20}, {30, 0x25}, {31, 0}, {26, 0x29}, {27, 0}])
      # sbi DDRB,5 · cbi PORTB,5 · in r16,PIND · out PORTB,r24
      assert Avr.decode(0x9A25, 0, r) == {:bit, true, 0x24, 5}
      assert Avr.decode(0x982D, 0, r) == {:bit, false, 0x25, 5}
      assert Avr.decode(0xB109, 0, r) == {:load, 16, 0x29}
      assert Avr.decode(0xB985, 0, r) == {:store, 24, 0x25}
      # sbis PIND,2 · lds r24,0x0029 · st Z,r18 · ld r24,X · ldd r24,Z+2
      assert Avr.decode(0x9B4A, 0, r) == {:skip_if, 1, 0x29, 2}
      assert Avr.decode(0x9180, 0x29, r) == {:load, 24, 0x29}
      assert Avr.decode(0x8320, 0, r) == {:store, 18, 0x25}
      assert Avr.decode(0x918C, 0, r) == {:load, 24, 0x29}
      assert Avr.decode(0x8182, 0, r) == {:load, 24, 0x27}
    end

    test "port semantics: DDR, PORT, PIN with pull-ups and inputs", %{b: b} do
      b = b |> Avr.store(0x24, 0x20) |> Avr.store(0x25, 0x20) |> Avr.store(0x2B, 0x04)
      assert Avr.load(b, 0x23, %{}) == 0x20
      # PD2 pulled up, then pressed
      assert (Avr.load(b, 0x29, %{}) &&& 0x04) == 0x04
      assert (Avr.load(b, 0x29, %{Board.avr_gpio("D", 2) => 0}) &&& 0x04) == 0
      # writing PINB toggles PORTB
      b = Avr.store(b, 0x23, 0x20)
      assert Avr.load(b, 0x25, %{}) == 0
      assert Avr.load(b, 0x60, %{}) == nil
    end

    test "breaks on port instructions and plain pointer accesses only", %{b: b} do
      program =
        <<0x9A25::little-16, 0x0000::little-16, 0x918C::little-16, 0x9180::little-16,
          0x0100::little-16, 0x9180::little-16, 0x0025::little-16>>

      # sbi at 0, ld X at 4, lds 0x100 (RAM) at 6 skipped, lds PORTB at 10
      assert Avr.breakpoints(program, b) == [0, 4, 10]
    end
  end

  test "Raspberry Pi GPIO from xp's text" do
    text =
      "000000003f200000: 0x00000040 0x00000000 0x00000000 0x00000000\r\n" <>
        "000000003f200010: 0x00000000 0x00000000 0x00000000 0x00000000\r\n" <>
        "000000003f200020: 0x00000000 0x00000000 0x00000000 0x00000000\r\n" <>
        "000000003f200030: 0x00000000 0x00000004 0x00000000\r\n"

    board = Board.get("raspi3b")
    pins = board |> Raspi.init() |> Raspi.parse(text) |> Raspi.pins(board, %{})
    assert pins[2] == %{dir: :out, level: 1}
    assert pins[3] == %{dir: :in, level: 0}
  end

  describe "Arduino firmware" do
    test "Intel HEX to a flash image" do
      hex = ":0400000025 9A 2D 9A 76\n:02000600FFCF2A\n:00000001FF\n" |> String.replace(" ", "")
      assert Firmware.parse_hex(hex) == {:ok, <<0x25, 0x9A, 0x2D, 0x9A, 0xFF, 0xFF, 0xFF, 0xCF>>}

      assert {:error, _} =
               Firmware.parse_hex(":0400000025 9A 2D 9A 00\n" |> String.replace(" ", ""))
    end

    test "installed as the board's program", %{} do
      dir = Path.join(Paths.data_dir(), "fw")
      src = Path.join(Paths.data_dir(), "blink.hex")
      File.mkdir_p!(dir)
      File.write!(src, ":02000000FFCF30\n:00000001FF\n")
      assert :ok = Firmware.install(dir, src, "arduino-uno")
      assert File.read!(Path.join(dir, "firmware.bin")) == <<0xFF, 0xCF>>

      assert {:error, _} =
               Firmware.install(dir, Path.join(dir, "firmware.bin") <> ".txt", "arduino-uno")
    end
  end

  test "the Raspberry Pi's kernel command line" do
    cmdline =
      "console=serial0,115200 console=tty1 root=PARTUUID=abc-02 rootfstype=ext4 fsck.repair=yes rootwait\n"

    append = Image.append(cmdline, Board.get("raspi3b").uart)
    assert String.starts_with?(append, "console=tty1 console=ttyAMA1,115200 root=PARTUUID=abc-02")
    assert Image.append(cmdline, Board.get("raspi2b").uart) =~ "console=ttyAMA0,115200"
    refute append =~ "serial0"
    assert Image.append("") =~ "root=/dev/mmcblk0p2"
  end

  describe "workspaces" do
    test "opening a folder makes its vms/ and images/ and keeps it in the list" do
      dir = Path.join(Paths.data_dir(), "meu-workspace")
      assert {:ok, ^dir} = Workspace.open(dir)
      assert Paths.vms_dir() == Path.join(dir, "vms")
      assert File.dir?(Path.join(dir, "images"))

      {:ok, vm} = VmStore.create(%{"name" => "No workspace", "disk_size" => ""})
      assert String.starts_with?(Vm.dir(vm), dir)
      assert Enum.find(Workspace.list(), & &1.current?).vms == 1

      assert {:ok, _} = Workspace.open("")
      assert Workspace.default?()
      assert VmStore.list() == []
      assert Enum.any?(Workspace.list(), &(&1.path == dir))

      Workspace.forget(dir)
      refute Enum.any?(Workspace.list(), &(&1.path == dir))
    end

    test "an old isos/ becomes images/" do
      dir = Path.join(Paths.data_dir(), "antigo")
      File.mkdir_p!(Path.join(dir, "isos"))
      File.write!(Path.join([dir, "isos", "a.iso"]), "x")
      assert {:ok, _} = Workspace.open(dir)
      assert File.regular?(Path.join([dir, "images", "a.iso"]))
    end
  end

  describe "a running Arduino" do
    @describetag :qemu_avr
    @describetag timeout: 60_000

    # sbi DDRB,5 · sbi PORTD,2 · loop: in r16,PIND · sbrs r16,2 · rjmp on ·
    # cbi PORTB,5 · rjmp loop · on: sbi PORTB,5 · rjmp loop — the LED (D13)
    # lights while the button on D2 is held down
    @button <<0x25, 0x9A, 0x5A, 0x9A, 0x09, 0xB1, 0x02, 0xFF, 0x02, 0xC0, 0x2D, 0x98, 0xFB, 0xCF,
              0x2D, 0x9A, 0xF9, 0xCF>>

    test "its pins follow the program, and a pressed button reaches it" do
      Phoenix.PubSub.subscribe(QemuAdmin.PubSub, QemuAdmin.topic())

      {:ok, vm} =
        VmStore.create(%{"name" => "botao", "arch" => "avr", "machine" => "arduino-uno"})

      File.write!(Path.join(Vm.dir(vm), "firmware.bin"), @button)
      assert {:ok, _} = VmSupervisor.start_vm(vm)

      d2 = Board.avr_gpio("D", 2)
      assert wait_for(fn -> match?(%{pins: %{13 => %{dir: :out}}}, Gpio.snapshot(vm.id)) end)
      assert %{pins: %{13 => %{level: 0}} = pins} = Gpio.snapshot(vm.id)
      assert pins[d2] == %{dir: :in, level: 1, pullup: true}

      Gpio.set_input(vm.id, d2, 0)
      assert wait_for(fn -> match?(%{pins: %{13 => %{level: 1}}}, Gpio.snapshot(vm.id)) end)

      assert {:ok, _} = VmServer.pause(vm.id)
      assert VmSupervisor.runtime(vm.id).status == :paused
      assert {:ok, _} = VmServer.resume(vm.id)

      Gpio.set_input(vm.id, d2, 1)
      assert wait_for(fn -> match?(%{pins: %{13 => %{level: 0}}}, Gpio.snapshot(vm.id)) end)
      assert {:ok, _} = VmServer.quit(vm.id)
      assert_receive {:vm_status, "botao", :stopped}, 10_000
    end
  end

  defp wait_for(fun, tries \\ 50) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(200) && wait_for(fun, tries - 1)
    end
  end
end
