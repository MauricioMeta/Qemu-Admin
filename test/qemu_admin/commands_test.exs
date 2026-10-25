defmodule QemuAdmin.CommandsTest do
  use ExUnit.Case, async: false

  alias QemuAdmin.{Paths, Qemu, Settings, VmServer, VmStore, VmSupervisor}

  # A VM with no disk and no display: QEMU boots the firmware and waits, which
  # is all the command history needs.
  @moduletag :qemu
  @moduletag timeout: 60_000

  setup do
    File.rm_rf!(Paths.data_dir())
    Settings.reset()
    on_exit(fn -> File.rm_rf!(Paths.data_dir()) end)
    :ok
  end

  defp start_vm do
    Phoenix.PubSub.subscribe(QemuAdmin.PubSub, QemuAdmin.topic())

    {:ok, vm} =
      VmStore.create(%{
        "name" => "cmds",
        "arch" => "x86_64",
        "machine" => "q35",
        "memory" => "64",
        "display" => "none",
        "accel" => "tcg"
      })

    assert {:ok, _} = VmSupervisor.start_vm(vm)
    assert_receive {:vm_status, "cmds", :running}, 20_000
    vm
  end

  test "the history has the launch line, the QMP commands, their answers and what was typed" do
    if "x86_64" in Qemu.info().emulators do
      start_vm()
      assert_receive {:vm_cmd, "cmds", %{dir: "launch", text: launch, seq: 1}}, 5_000
      assert launch =~ "-machine q35" and launch =~ "-qmp"

      # a monitor command goes through human-monitor-command
      assert {:ok, status} = VmServer.console("cmds", "info status")
      assert status =~ "running"
      assert_receive {:vm_cmd, "cmds", %{dir: "hmp", text: "info status"}}, 5_000
      assert_receive {:vm_cmd, "cmds", %{dir: "received", text: "VM status: running"}}, 5_000

      # a QMP message as JSON
      assert {:ok, %{"status" => "running"}} =
               VmServer.console("cmds", ~s({"execute": "query-status"}))

      assert_receive {:vm_cmd, "cmds", %{dir: "sent", text: ~s({"execute":"query-status"})}}, 5_000

      # the page's own buttons are logged too, with the events they cause
      assert {:ok, _} = VmServer.pause("cmds")
      assert_receive {:vm_cmd, "cmds", %{dir: "sent", text: ~s({"execute":"stop"})}}, 5_000
      assert_receive {:vm_cmd, "cmds", %{dir: "event", text: "STOP" <> _}}, 5_000
      assert {:ok, _} = VmServer.resume("cmds")

      # a mistake is an error entry, not a crash
      assert {:error, _} = VmServer.console("cmds", ~s({"execute": "nao-existe"}))
      assert_receive {:vm_cmd, "cmds", %{dir: "error"}}, 5_000
      assert {:error, "JSON QMP inválido" <> _} = VmServer.console("cmds", "{oops")
      assert {:error, "comando vazio"} = VmServer.console("cmds", "   ")

      history = VmServer.commands("cmds")
      assert Enum.map(history, & &1.seq) == Enum.to_list(1..length(history))
      refute Enum.any?(history, &(&1.text =~ "screendump"))

      assert {:ok, _} = VmServer.quit("cmds")
      assert_receive {:vm_status, "cmds", :stopped}, 10_000

      # off, it is read back from commands.log
      saved = VmServer.commands("cmds")
      assert Enum.take(saved, length(history)) == history
      assert Enum.any?(saved, &(&1.dir == "event" and &1.text =~ "SHUTDOWN"))
    end
  end

  test "a VM that is not running has no console" do
    assert {:error, :not_running} = VmServer.console("ninguem", "info status")
    assert VmServer.commands("ninguem") == []
  end
end
