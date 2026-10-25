defmodule QemuAdmin.TerminalTest do
  use ExUnit.Case, async: false

  alias QemuAdmin.{Paths, Qemu, Settings, Terminal, Vm, VmServer, VmStore}

  setup do
    File.rm_rf!(Paths.data_dir())
    Settings.reset()
    on_exit(fn -> File.rm_rf!(Paths.data_dir()) end)
    :ok
  end

  describe "route/1" do
    test "the QEMU tools run with the VM off" do
      assert {:tool, "qemu-img"} = Terminal.route("qemu-img info disco.qcow2")
      assert {:tool, "qemu-img"} = Terminal.route("  QEMU-IMG.exe create x.img 1M")
      assert {:tool, "qemu-io"} = Terminal.route(~s(qemu-io -c "read 0 512" disco.img))
      assert {:tool, "qemu-system-arm"} = Terminal.route("qemu-system-arm -machine help")
      assert {:tool, "qemu-system-x86_64"} = Terminal.route("qemu-system-x86_64 -cpu help")
      assert {:tool, "qemu-system-arm"} = Terminal.route("qemu-system-arm -device e1000,help")
      assert {:tool, "qemu-system-arm"} = Terminal.route("qemu-system-arm -version")
    end

    test "anything else is a monitor or QMP command" do
      assert :monitor = Terminal.route("info registers")
      assert :monitor = Terminal.route(~s({"execute": "query-status"}))
      assert :monitor = Terminal.route("stop")
      assert :monitor = Terminal.route("")
      # not a tool of ours: a name that merely starts alike
      assert :monitor = Terminal.route("qemu-system-nope -machine help")
      assert :monitor = Terminal.route("qemu-imgx info a")
    end

    test "qemu-system-* only to list what QEMU has — never to start a VM" do
      assert {:error, msg} = Terminal.route("qemu-system-arm -machine netduinoplus2 -kernel fw.elf")
      assert msg =~ "Ligar"
      # `help` as a value of something else is not the introspection
      assert {:error, _} = Terminal.route("qemu-system-arm -machine raspi3b -name help")
      assert {:error, _} = Terminal.route("qemu-system-arm")
    end

    test "qemu-io is interactive: it must be given -c" do
      assert {:error, msg} = Terminal.route("qemu-io disco.img")
      assert msg =~ "-c"
    end
  end

  describe "run/2" do
    @describetag :qemu
    @describetag :tmp_dir

    setup do
      {:ok, vm} = VmStore.create(%{"name" => "ferramentas", "arch" => "x86_64", "machine" => "q35"})
      %{vm: vm}
    end

    test "qemu-img creates and describes a disk inside the VM's folder", %{vm: vm} do
      if Qemu.available?() do
        assert {:ok, out, 0} = Terminal.run(vm, "qemu-img create -f qcow2 novo.qcow2 8M")
        assert out =~ "Formatting"
        assert File.regular?(Path.join(Vm.dir(vm), "novo.qcow2"))

        assert {:ok, out, 0} = Terminal.run(vm, "qemu-img info novo.qcow2")
        assert out =~ "file format: qcow2"
        assert out =~ "virtual size: 8 MiB"

        assert {:ok, json, 0} = Terminal.run(vm, "qemu-img info --output json novo.qcow2")
        assert %{"format" => "qcow2", "virtual-size" => 8_388_608} = Jason.decode!(json)
      end
    end

    test "a failing command comes back with its message and exit code", %{vm: vm} do
      if Qemu.available?() do
        assert {:ok, out, status} = Terminal.run(vm, "qemu-img info nao-existe.img")
        assert status != 0
        assert out =~ "nao-existe.img"
      end
    end

    test "the emulators list what they have", %{vm: vm} do
      if "arm" in Qemu.info().emulators do
        assert {:ok, out, 0} = Terminal.run(vm, "qemu-system-arm -machine help")
        assert out =~ "netduinoplus2"

        assert {:ok, out, 0} = Terminal.run(vm, "qemu-system-arm -version")
        assert out =~ "QEMU emulator version"
      end
    end

    test "refuses what route/1 refuses, and what is not a tool", %{vm: vm} do
      assert {:error, _} = Terminal.run(vm, "qemu-system-arm -machine netduinoplus2")
      assert {:error, "não é uma ferramenta do QEMU"} = Terminal.run(vm, "info registers")
      assert {:error, _} = Terminal.run(vm, ~s(qemu-img info "sem fechar))
    end
  end

  describe "qmp_message/1" do
    test "a command name, with arguments as a JSON object, or a whole message" do
      assert {:ok, ~s({"execute":"stop"})} = Terminal.qmp_message("stop")
      assert {:ok, ~s({"execute": "x"})} = Terminal.qmp_message(~s({"execute": "x"}))

      assert {:ok, json} = Terminal.qmp_message(~s(block_resize {"device": "d0", "size": 5}))

      assert %{"execute" => "block_resize", "arguments" => %{"device" => "d0", "size" => 5}} =
               Jason.decode!(json)

      assert {:error, _} = Terminal.qmp_message("")
      assert {:error, _} = Terminal.qmp_message("stop agora")
      assert {:error, _} = Terminal.qmp_message("1stop")
    end
  end

  describe "execute/3 with the VM off" do
    setup do
      {:ok, vm} = VmStore.create(%{"name" => "off", "arch" => "x86_64", "machine" => "q35"})
      %{vm: vm}
    end

    test "every line is an entry: what the user sees, where it came from, how it goes to QEMU", %{vm: vm} do
      assert :error = Terminal.execute(vm, "qmp: stop", "salvo: parar (passo 1/1)")
      assert :error = Terminal.execute(vm, "hmp: info status")
      assert :error = Terminal.execute(vm, "cli: info status")

      assert [
               %{dir: "cmd", text: "stop", src: "salvo: parar (passo 1/1)", via: "QMP", x: 1},
               %{dir: "error", x: 1, text: "a VM está desligada" <> _},
               %{dir: "cmd", text: "info status", src: "digitado", via: "monitor (HMP)", x: 3},
               %{dir: "error", x: 3},
               %{dir: "cmd", text: "info status", via: "linha de comando", x: 5},
               %{dir: "error", x: 5, text: "cli: só roda" <> _}
             ] = VmServer.commands(vm.id)
    end

    test "a tool shows the process that really runs", %{vm: vm} do
      if Qemu.exe("qemu-img") != {:error, :no_qemu} do
        assert :ok = Terminal.execute(vm, "cli: qemu-img --version")

        assert [
                 %{dir: "cmd", via: "linha de comando", x: x},
                 %{dir: "tool", x: x, text: process},
                 %{dir: "received", x: x}
               ] = VmServer.commands(vm.id)

        assert process =~ "qemu-img" and process =~ "--version" and process =~ "na pasta da VM"
      end
    end
  end

  describe "log/3 with the VM off" do
    test "the history is the file, numbered, and each entry is broadcast" do
      Phoenix.PubSub.subscribe(QemuAdmin.PubSub, QemuAdmin.topic())
      {:ok, vm} = VmStore.create(%{"name" => "historico", "arch" => "x86_64", "machine" => "q35"})
      assert VmServer.commands(vm.id) == []

      assert 1 = Terminal.log(vm.id, "tool", "qemu-img info disco.qcow2")
      assert 2 = Terminal.log(vm.id, "received", "image: disco.qcow2")
      assert 3 = Terminal.log(vm.id, "error", "saiu com o código 1")

      assert_receive {:vm_cmd, "historico", %{seq: 1, dir: "tool"}}
      assert_receive {:vm_cmd, "historico", %{seq: 3, dir: "error"}}

      assert [
               %{seq: 1, dir: "tool", text: "qemu-img info disco.qcow2"},
               %{seq: 2, dir: "received", text: "image: disco.qcow2"},
               %{seq: 3, dir: "error", text: "saiu com o código 1"}
             ] = VmServer.commands(vm.id)
    end
  end
end
