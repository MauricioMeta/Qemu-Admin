defmodule QemuAdmin.LaunchCommandTest do
  use ExUnit.Case, async: false

  alias QemuAdmin.{Paths, Qemu, Settings, Vm, VmServer, VmStore, VmSupervisor}
  alias QemuAdmin.Vm.Args

  @ports %{qmp: 4444, vnc: 5901, ws: 5701, serial: 5555, gdb: 4445}
  @host %{accels: ["tcg"], os: :windows, arch: "x86_64"}

  setup do
    File.rm_rf!(Paths.data_dir())
    Settings.reset()
    on_exit(fn -> File.rm_rf!(Paths.data_dir()) end)
    :ok
  end

  defp vm(params) do
    {:ok, vm} = Vm.cast(Vm.new(), Map.put_new(params, "name", "linha"))
    %{vm | id: "linha"}
  end

  @kinds [
    %{"arch" => "x86_64", "machine" => "q35"},
    %{
      "arch" => "xtensa",
      "machine" => "esp32",
      "disks" => %{"0" => %{"path" => "flash.bin", "format" => "raw", "interface" => "mtd"}}
    },
    %{"arch" => "avr", "machine" => "arduino-uno"},
    %{"arch" => "arm", "machine" => "netduinoplus2"},
    %{
      "arch" => "aarch64",
      "machine" => "raspi3b",
      "disks" => %{"0" => %{"path" => "sd.img", "format" => "raw", "interface" => "sd"}}
    }
  ]

  describe "the template" do
    test "is the app's own line with the ports as placeholders, and runs as the same line" do
      for params <- @kinds do
        vm = vm(params)
        text = Args.template(vm, @host)
        assert text =~ "{qmp}", inspect(params)
        refute text =~ "41001"

        # gives back what the app builds, for any ports
        edited = %{vm | command: text}
        ports = if Vm.kind(vm) in [:esp32, :avr], do: @ports, else: Map.delete(@ports, :gdb)
        assert Args.build_run(edited, ports, @host) == Args.build(vm, ports, @host), inspect(params)
      end
    end

    test "the display's VNC and WebSocket ports are placeholders too" do
      text = Args.template(vm(%{"arch" => "x86_64", "machine" => "q35", "display" => "vnc"}), @host)
      assert text =~ "-vnc 127.0.0.1:{vnc},websocket=127.0.0.1:{ws}"
    end

    test "a board's serial and gdbstub ports are placeholders" do
      text = Args.template(vm(%{"arch" => "avr", "machine" => "arduino-uno"}), @host)
      assert text =~ "tcp:127.0.0.1:{serial},server=on"
      assert text =~ "-gdb tcp:127.0.0.1:{gdb}"
    end
  end

  describe "a custom line" do
    test "is run with the ports filled in, quotes respected" do
      vm = %{vm(%{}) | command: ~s(-name "uma vm" -machine q35 -qmp tcp:127.0.0.1:{qmp},server=on)}
      assert Args.build_run(vm, @ports, @host) ==
               ["-name", "uma vm", "-machine", "q35", "-qmp", "tcp:127.0.0.1:4444,server=on"]
    end

    test "is checked: well-formed and keeping the app's control of the VM" do
      pc = vm(%{"arch" => "x86_64", "machine" => "q35"})
      assert :ok = Args.check_command(pc, "-machine q35 -qmp tcp:127.0.0.1:{qmp},server=on")
      assert {:error, "aspas sem fechar"} = Args.check_command(pc, ~s(-name "x -qmp {qmp}))
      assert {:error, "a linha está vazia"} = Args.check_command(pc, "  ")
      assert {:error, "faltam {qmp}" <> _} = Args.check_command(pc, "-machine q35")

      board = vm(%{"arch" => "avr", "machine" => "arduino-uno"})
      assert {:error, msg} = Args.check_command(board, "-machine arduino-uno -qmp {qmp}")
      assert msg =~ "{serial}" and msg =~ "{gdb}"

      stm = vm(%{"arch" => "arm", "machine" => "netduinoplus2"})
      assert {:error, msg} = Args.check_command(stm, "-machine netduinoplus2 -qmp {qmp}")
      assert msg =~ "{serial}" and not (msg =~ "{gdb}")
    end

    test "is kept in vm.json and survives a reload" do
      {:ok, vm} = VmStore.create(%{"name" => "linha", "arch" => "x86_64", "machine" => "q35"})
      assert vm.command == ""
      VmStore.save(%{vm | command: "-qmp tcp:127.0.0.1:{qmp},server=on -no-reboot"})
      assert {:ok, again} = VmStore.get("linha")
      assert again.command == "-qmp tcp:127.0.0.1:{qmp},server=on -no-reboot"
    end
  end

  describe "running" do
    @describetag :qemu
    @describetag timeout: 60_000

    test "QEMU starts with the edited line, and the app still controls it" do
      if "x86_64" in Qemu.info().emulators do
        Phoenix.PubSub.subscribe(QemuAdmin.PubSub, QemuAdmin.topic())

        {:ok, vm} =
          VmStore.create(%{
            "name" => "editada",
            "arch" => "x86_64",
            "machine" => "q35",
            "memory" => "64",
            "display" => "none",
            "accel" => "tcg"
          })

        text = Args.template(vm) <> " -no-reboot -name editada-vm"
        assert :ok = Args.check_command(vm, text)
        VmStore.save(%{vm | command: text})
        {:ok, vm} = VmStore.get("editada")

        assert {:ok, _} = VmSupervisor.start_vm(vm)
        assert_receive {:vm_status, "editada", :running}, 20_000
        assert_receive {:vm_cmd, "editada", %{dir: "launch", text: launch}}, 5_000
        assert launch =~ "-no-reboot" and launch =~ "-name editada-vm"
        refute launch =~ "{qmp}"

        assert {:ok, status} = VmServer.console("editada", "info status")
        assert status =~ "running"

        assert {:ok, _} = VmServer.quit("editada")
        assert_receive {:vm_status, "editada", :stopped}, 10_000
      end
    end
  end
end
