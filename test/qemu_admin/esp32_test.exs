defmodule QemuAdmin.Esp32Test do
  use ExUnit.Case, async: false

  alias QemuAdmin.{Paths, Settings, Vm, VmServer, VmStore, VmSupervisor}
  alias QemuAdmin.Esp32.{AtomVM, Flash}
  alias QemuAdmin.Vm.Args

  @mib 1_048_576

  setup do
    File.rm_rf!(Paths.data_dir())
    Settings.reset()
    on_exit(fn -> File.rm_rf!(Paths.data_dir()) end)
    dir = Path.join(Paths.data_dir(), "esp")
    File.mkdir_p!(dir)
    {:ok, flash: Path.join(dir, "flash.bin")}
  end

  # AtomVM's own table: nvs, phy_init, factory, boot.avm, main.avm
  defp entry(name, type, sub, offset, size) do
    <<0xAA, 0x50, type, sub, offset::little-32, size::little-32,
      String.pad_trailing(name, 16, <<0>>)::binary, 0::32>>
  end

  defp atomvm_table do
    entry("nvs", 1, 2, 0x9000, 0x6000) <>
      entry("phy_init", 1, 1, 0xF000, 0x1000) <>
      entry("factory", 0, 0, 0x10000, 0x1C0000) <>
      entry("boot.avm", 1, 1, 0x1D0000, 0x80000) <>
      entry("main.avm", 1, 1, 0x250000, 0x100000) <> <<0xEB, 0xEB>>
  end

  describe "Flash" do
    test "a blank chip is all 0xFF, in the sizes QEMU takes", %{flash: flash} do
      assert :ok = Flash.create(flash, 4)
      assert {:ok, 4_194_304} = Flash.size(flash)
      assert File.read!(flash) == :binary.copy(<<0xFF>>, 4 * @mib)
      assert {:error, _} = Flash.create(flash, 3)
      assert Flash.partitions(flash) == []
    end

    test "writes at an offset, refusing past the end", %{flash: flash} do
      :ok = Flash.create(flash, 2)
      assert :ok = Flash.write(flash, 0x1000, "abc")
      assert <<_::binary-size(0x1000), "abc", 0xFF, _::binary>> = File.read!(flash)
      assert {:error, msg} = Flash.write(flash, 2 * @mib - 1, "ab")
      assert msg =~ "passam do fim"
    end

    test "reads the partition table", %{flash: flash} do
      :ok = Flash.create(flash, 4)
      :ok = Flash.write(flash, 0x8000, atomvm_table())
      :ok = Flash.write(flash, 0x1D0000, "libs")

      parts = Flash.partitions(flash)
      assert Enum.map(parts, & &1.name) == ~w(nvs phy_init factory boot.avm main.avm)
      assert %{type: :app, offset: 0x10000} = Enum.find(parts, &(&1.name == "factory"))
      assert %{used: true} = Flash.partition(flash, "boot.avm")
      assert %{used: false, offset: 0x250000} = Flash.partition(flash, "main.avm")
      assert [%{name: "main.avm"}] = Flash.avm_partitions(flash)
    end

    test "offsets are hexadecimal, as esptool's" do
      assert Flash.parse_offset("0x250000") == {:ok, 0x250000}
      assert Flash.parse_offset(" 1000 ") == {:ok, 0x1000}
      assert {:error, _} = Flash.parse_offset("0xZZ")
      assert Flash.bootloader_offset("esp32") == 0x1000
      assert Flash.bootloader_offset("esp32s3") == 0
    end
  end

  describe "AtomVM" do
    test "an image and an app go where the chip and the table say", %{flash: flash} do
      :ok = Flash.create(flash, 4)
      image = Path.join(Path.dirname(flash), "atomvm.img")
      # bootloader at 0x1000, the table 0x7000 bytes into the image (0x8000)
      File.write!(image, <<0xE9>> <> :binary.copy(<<0>>, 0x7000 - 1) <> atomvm_table())
      File.write!(flash, :binary.copy(<<0x00>>, 4 * @mib))

      assert :ok = AtomVM.install(flash, "esp32", image)
      assert <<0xFF, _::binary-size(0xFFF), 0xE9, _::binary>> = File.read!(flash)
      assert %{offset: 0x250000} = Flash.partition(flash, "main.avm")

      avm = Path.join(Path.dirname(flash), "app.avm")
      File.write!(avm, "#!/usr/bin/env AtomVM\n" <> <<0, 0>> <> "beams")
      assert :ok = AtomVM.write_app(flash, avm)
      assert %{used: true} = Flash.partition(flash, "main.avm")

      File.write!(avm, "not an avm")
      assert {:error, msg} = AtomVM.write_app(flash, avm)
      assert msg =~ ".avm"
    end

    test "an app needs AtomVM's table first", %{flash: flash} do
      :ok = Flash.create(flash, 4)
      avm = Path.join(Path.dirname(flash), "app.avm")
      File.write!(avm, "#!/usr/bin/env AtomVM\n")
      assert {:error, msg} = AtomVM.write_app(flash, avm)
      assert msg =~ "main.avm"
    end

    test "image names follow the releases" do
      assert AtomVM.image_name("esp32", "v0.6.6", "elixir") == "AtomVM-esp32-elixir-v0.6.6.img"
      assert AtomVM.image_name("esp32s3", "v0.6.6", "erlang") == "AtomVM-esp32s3-v0.6.6.img"
    end
  end

  describe "an ESP32 VM" do
    test "is a chip: no CD, UEFI, video or choice of accelerator" do
      {:ok, vm} =
        Vm.cast(Vm.new(), %{
          "name" => "esp",
          "arch" => "xtensa",
          "uefi" => "true",
          "accel" => "whpx",
          "cdrom" => "x.iso",
          "disks" => %{
            "0" => %{"path" => "flash.bin", "format" => "qcow2", "interface" => "virtio"}
          }
        })

      assert %{machine: "esp32", accel: "tcg", uefi: false, cdrom: "", display: "none", memory: 4} =
               vm

      assert [%{"format" => "raw", "interface" => "mtd"}] = vm.disks
      assert {:error, errors} = Vm.cast(vm, %{"memory" => "64"})
      assert errors[:memory]
      assert {:error, errors} = Vm.cast(vm, %{"disks" => %{}})
      assert errors[:disks]
    end

    test "its command line: flash on mtd, UART on a socket QEMU waits for" do
      vm = %Vm{
        Vm.new()
        | id: "esp",
          name: "ESP",
          arch: "xtensa",
          machine: "esp32",
          memory: 4,
          disks: [%{"path" => "C:/vms/esp/flash.bin", "format" => "raw", "interface" => "mtd"}],
          forwards: ["tcp:8080:80"]
      }

      args = Args.build(vm, %{qmp: 4444, vnc: 5900, ws: 5700, serial: 5555})
      line = Enum.join(args, " ")
      assert line =~ "-machine esp32 -m 4M"
      assert line =~ "-drive file=C:/vms/esp/flash.bin,if=mtd,format=raw"
      assert line =~ "-serial tcp:127.0.0.1:5555,server=on,wait=on,nodelay=on"
      assert line =~ "-nic user,model=open_eth,mac=52:54:00:"
      assert line =~ "hostfwd=tcp:127.0.0.1:8080-:80"
      refute line =~ "-accel"
      refute line =~ "-vnc"
    end

    test "is created with a blank flash" do
      {:ok, vm} = VmStore.create(%{"name" => "Placa", "arch" => "xtensa", "flash_size" => "8"})
      assert [%{"path" => "flash.bin"}] = vm.disks
      assert {:ok, 8_388_608} = Flash.size(Vm.resolve(vm, "flash.bin"))
    end
  end

  describe "running" do
    @describetag :qemu_esp
    @describetag timeout: 60_000

    # A blank flash: the ROM boots, finds no bootloader, and says so on the
    # UART — enough to prove the serial path end to end, offline.
    test "the ROM speaks on the serial port" do
      Phoenix.PubSub.subscribe(QemuAdmin.PubSub, QemuAdmin.topic())
      {:ok, vm} = VmStore.create(%{"name" => "rom", "arch" => "xtensa"})
      assert {:ok, _} = VmSupervisor.start_vm(vm)
      assert_receive {:vm_status, "rom", :running}, 20_000
      assert_receive {:vm_serial, "rom", 0, _bytes}, 20_000

      Process.sleep(1_000)
      {out, total} = VmServer.serial_buffer("rom")
      assert out =~ "rst:0x1 (POWERON_RESET)"
      assert total == byte_size(out)

      assert {:ok, _} = VmServer.quit("rom")
      assert_receive {:vm_status, "rom", :stopped}, 10_000
      # off, the output is read back from serial.log
      {saved, _} = VmServer.serial_buffer("rom")
      assert String.starts_with?(saved, out)
    end
  end
end
