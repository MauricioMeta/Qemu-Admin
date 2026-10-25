defmodule QemuAdmin.CortexMTest do
  use ExUnit.Case, async: false

  alias QemuAdmin.{Board, Paths, Qemu, Settings, Vm, VmServer, VmStore, VmSupervisor}
  alias QemuAdmin.CortexM.Firmware
  alias QemuAdmin.Vm.Args

  @ports %{qmp: 4444, vnc: 5901, ws: 5701, serial: 5555}

  # A Cortex-M program in Thumb code: enables USART1 (CR1 = UE|TE) and writes
  # "hello from stm32" to its data register. Vector table: the stack, then the
  # reset handler at 0x08000009 (the flash is at 0x08000000, aliased at 0).
  @hello <<0x00, 0x00, 0x02, 0x20, 0x09, 0x00, 0x00, 0x08, 0x05, 0x48, 0x06, 0x49, 0xC1, 0x60,
           0x06, 0x4A, 0x13, 0x78, 0x01, 0x32, 0x00, 0x2B, 0x01, 0xD0, 0x43, 0x60, 0xF9, 0xE7,
           0xFE, 0xE7, 0x00, 0xBF, 0x00, 0x10, 0x01, 0x40, 0x08, 0x20, 0x00, 0x00, 0x2C, 0x00,
           0x00, 0x08, "hello from stm32\r\n", 0>>

  setup do
    File.rm_rf!(Paths.data_dir())
    Settings.reset()
    on_exit(fn -> File.rm_rf!(Paths.data_dir()) end)
    :ok
  end

  describe "the board" do
    test "is in the catalog and the machine list, as a Cortex-M" do
      board = Board.get("netduinoplus2")
      assert board.kind == :cortexm and board.arch == "arm" and board.machine == "netduinoplus2"
      assert "netduinoplus2" in Vm.machines("arm")
      assert Vm.default_machine("arm") == "raspi2b"
      assert Vm.kind("arm", "netduinoplus2") == :cortexm
      assert Vm.kind("arm", "raspi0") == :raspi
    end
  end

  describe "a VM" do
    test "is a microcontroller: no disk, no network, one core, TCG" do
      {:ok, vm} =
        Vm.cast(Vm.new(), %{"name" => "stm", "arch" => "arm", "machine" => "netduinoplus2"})

      assert Vm.kind(vm) == :cortexm and Vm.mcu?(vm) and Vm.serial?(vm)
      assert vm.disks == [] and vm.net_mode == "none" and vm.cpus == 1 and vm.accel == "tcg"
      assert vm.display == "none" and vm.memory == 0
    end

    test "loads its program with -kernel, on a serial socket, with no -S/-gdb" do
      {:ok, vm} =
        VmStore.create(%{"name" => "stm", "arch" => "arm", "machine" => "netduinoplus2"})

      assert "-kernel" not in Args.build(vm, @ports)

      File.write!(Path.join(Vm.dir(vm), "firmware.elf"), "x")
      args = Args.build(vm, @ports)
      assert Enum.chunk_every(args, 2, 1) |> Enum.member?(["-machine", "netduinoplus2"])
      assert ["-kernel", file] = Enum.chunk_every(args, 2, 1) |> Enum.find(&(hd(&1) == "-kernel"))
      assert file =~ "firmware.elf"
      assert "tcp:127.0.0.1:5555,server=on,wait=on,nodelay=on" in args
      assert "-qmp" in args and "-S" not in args and "-gdb" not in args
      assert "-bios" not in args and "-drive" not in args and "-nic" not in args
    end
  end

  describe "the firmware" do
    @describetag :tmp_dir

    test "an ELF and a raw binary are kept; the other is replaced", %{tmp_dir: dir} do
      elf = Path.join(dir, "app.elf")
      bin = Path.join(dir, "app.bin")
      File.write!(elf, <<0x7F, "ELF", 1, 2, 3>>)
      File.write!(bin, @hello)

      assert :ok = Firmware.install(dir, elf)
      assert File.regular?(Path.join(dir, "firmware.elf"))

      assert :ok = Firmware.install(dir, bin)
      assert File.read!(Path.join(dir, "firmware.bin")) == @hello
      refute File.exists?(Path.join(dir, "firmware.elf"))

      Firmware.erase(dir)
      refute File.exists?(Path.join(dir, "firmware.bin"))
    end

    test "refuses what is not a program", %{tmp_dir: dir} do
      txt = Path.join(dir, "a.txt")
      notelf = Path.join(dir, "a.elf")
      File.write!(txt, "x")
      File.write!(notelf, "not an elf")

      assert {:error, "formato .txt" <> _} = Firmware.install(dir, txt)
      assert {:error, "não é um arquivo ELF"} = Firmware.install(dir, notelf)
      assert {:error, _} = Firmware.install(dir, Path.join(dir, "missing.bin"))
    end

    test "an Intel HEX starts at its lowest address (the STM32's flash is at 0x08000000)", %{
      tmp_dir: dir
    } do
      # extended linear address 0x0800, then 4 bytes at 0x0000 and 2 at 0x0006
      hex = """
      :020000040800F2
      :04000000DEADBEEFC4
      :02000600CAFE30
      :00000001FF
      """

      path = Path.join(dir, "app.hex")
      File.write!(path, hex)
      assert :ok = Firmware.install(dir, path)

      assert File.read!(Path.join(dir, "firmware.bin")) ==
               <<0xDE, 0xAD, 0xBE, 0xEF, 0xFF, 0xFF, 0xCA, 0xFE>>
    end
  end

  describe "running" do
    @describetag :qemu
    @describetag timeout: 60_000

    test "the program speaks on USART1, which is the serial tab" do
      if "arm" in Qemu.info().emulators do
        Phoenix.PubSub.subscribe(QemuAdmin.PubSub, QemuAdmin.topic())

        {:ok, vm} =
          VmStore.create(%{"name" => "stm", "arch" => "arm", "machine" => "netduinoplus2"})

        File.write!(Path.join(Vm.dir(vm), "firmware.bin"), @hello)
        assert {:ok, _} = VmSupervisor.start_vm(vm)
        assert_receive {:vm_status, "stm", :running}, 20_000
        assert_receive {:vm_serial, "stm", 0, _bytes}, 20_000

        Process.sleep(500)
        {out, _total} = VmServer.serial_buffer("stm")
        assert out == "hello from stm32\r\n"

        assert {:ok, _} = VmServer.quit("stm")
        assert_receive {:vm_status, "stm", :stopped}, 10_000
        {saved, _} = VmServer.serial_buffer("stm")
        assert saved == out
      end
    end
  end
end
