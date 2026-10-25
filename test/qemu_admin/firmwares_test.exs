defmodule QemuAdmin.FirmwaresTest do
  use ExUnit.Case, async: false

  alias QemuAdmin.{Firmwares, Paths, Renode, Settings, Vm, VmStore}

  setup do
    File.rm_rf!(Paths.data_dir())
    Settings.reset()
    on_exit(fn -> File.rm_rf!(Paths.data_dir()) end)
    :ok
  end

  defp netduino do
    {:ok, vm} = VmStore.create(%{"name" => "Placa", "arch" => "arm", "machine" => "netduinoplus2"})
    vm
  end

  defp touch(vm, rel, bytes \\ "x") do
    path = Path.join(Vm.dir(vm), rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes)
    path
  end

  test "only the boards that run a program have firmwares" do
    {:ok, pc} = VmStore.create(%{"name" => "PC"})
    refute Firmwares.supported?(pc)
    assert Firmwares.list(pc) == []

    assert Firmwares.supported?(netduino())
  end

  test "lists the legacy file and the firmware/ folder, by the extensions the board loads" do
    vm = netduino()
    assert Firmwares.list(vm) == []

    touch(vm, "firmware.elf", "legacy")
    touch(vm, "firmware/b.bin")
    touch(vm, "firmware/a.elf")
    touch(vm, "firmware/notes.txt")
    # a .hex is not what a Cortex-M board loads
    touch(vm, "firmware/c.hex")

    assert Enum.map(Firmwares.list(vm), & &1.file) == ["firmware.elf", "firmware/a.elf", "firmware/b.bin"]
  end

  test "the active firmware: the program the VM names, else the legacy file" do
    vm = netduino()
    touch(vm, "firmware.elf")
    touch(vm, "firmware/a.elf")

    assert Firmwares.active(vm) == "firmware.elf"
    assert [%{active?: true, file: "firmware.elf"}, %{active?: false}] = Firmwares.list(vm)

    vm = %{vm | program: "firmware/a.elf"}
    assert Firmwares.active(vm) == "firmware/a.elf"
    assert Firmwares.path(vm) == Path.join(Vm.dir(vm), "firmware/a.elf")

    # a name that is not there, or not loadable, falls back
    assert Firmwares.active(%{vm | program: "firmware/gone.elf"}) == "firmware.elf"
    assert Firmwares.active(%{vm | program: "../vm.json"}) == "firmware.elf"
  end

  test "QEMU's command line takes the active firmware" do
    vm = netduino()
    touch(vm, "firmware/a.elf")
    vm = %{vm | program: "firmware/a.elf"}

    args = QemuAdmin.Vm.Args.build_run(vm, %{qmp: 1, ws: 2, serial: 3, vnc: 5900})
    assert Enum.at(args, Enum.find_index(args, &(&1 == "-kernel")) + 1) =~ "firmware/a.elf"
  end

  test "add copies a file into firmware/ if the board loads that format" do
    vm = netduino()
    src = Path.join(Paths.data_dir(), "novo.elf")
    File.write!(src, "elf")

    assert {:ok, "firmware/novo.elf"} = Firmwares.add(vm, src)
    assert File.regular?(Path.join(Vm.dir(vm), "firmware/novo.elf"))

    bad = Path.join(Paths.data_dir(), "nao.txt")
    File.write!(bad, "x")
    assert {:error, msg} = Firmwares.add(vm, bad)
    assert msg =~ ".txt"
  end

  test "a Renode board is its own kind, a UART-only MCU" do
    assert Vm.kind("renode", "stm32f4_discovery") == :renode
    vm = %Vm{arch: "renode", machine: "x"}
    assert Vm.mcu?(vm)
    assert Vm.serial?(vm)
    assert Firmwares.extensions(vm) == ~w(.elf .hex .axf)
  end

  describe "with Renode installed" do
    @describetag skip: not Renode.available?()

    test "the boards, their UARTs (through `using`) and the script" do
      assert "stm32f4_discovery" in Renode.platforms()
      assert "usart1" in Renode.uarts("stm32f4_discovery")

      vm = %Vm{id: "r1", name: "Placa \"x\"", arch: "renode", machine: "stm32f4_discovery", uart: "usart2"}
      script = Renode.script(vm, %{serial: 4567, monitor: 4568}, "d:/a b/fw.elf")

      assert script =~ ~s|machine LoadPlatformDescription "|
      assert script =~ ~s|CreateServerSocketTerminal 4567 "uart_term" false|
      assert script =~ "connector Connect sysbus.usart2 uart_term"
      assert script =~ ~s|sysbus LoadELF "d:/a b/fw.elf"|
      assert Renode.args(vm, %{serial: 1, monitor: 4568}) |> Enum.member?("4568")

      # without a named UART, the board's first
      assert Renode.uart(%{vm | uart: ""}) == "usart1"
    end

    test "a Renode VM can be created, and does not start without a firmware" do
      {:ok, vm} = VmStore.create(%{"name" => "R", "arch" => "renode", "machine" => "stm32f4_discovery"})
      assert vm.arch == "renode"
      assert {:error, msg} = QemuAdmin.VmSupervisor.start_vm(vm)
      assert msg =~ "firmware"
    end
  end
end
