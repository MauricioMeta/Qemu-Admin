defmodule QemuAdmin.VmServerTest do
  # Boots a real QEMU (the one `mix qemu.fetch` put in qemu/, or any found):
  # a diskless VM, headless, driven over QMP. Skipped without QEMU
  # (test_helper.exs).
  use ExUnit.Case, async: false

  @moduletag :qemu
  @moduletag timeout: 60_000

  alias QemuAdmin.{Paths, Settings, VmServer, VmStore, VmSupervisor}

  setup do
    File.rm_rf!(Paths.data_dir())
    Settings.reset()
    Phoenix.PubSub.subscribe(QemuAdmin.PubSub, QemuAdmin.topic())
    on_exit(fn -> File.rm_rf!(Paths.data_dir()) end)
    :ok
  end

  test "start, pause, resume, quit — over QMP" do
    {:ok, vm} =
      VmStore.create(%{"name" => "qmp", "memory" => "128", "accel" => "tcg", "display" => "none"})

    assert {:ok, _pid} = VmSupervisor.start_vm(vm)
    assert {:error, _} = VmSupervisor.start_vm(vm)

    assert_receive {:vm_status, "qmp", :running}, 20_000

    assert {:ok, _} = VmServer.pause("qmp")
    assert_receive {:vm_status, "qmp", :paused}, 5_000
    assert {:ok, %{"status" => "paused"}} = VmServer.qmp("qmp", "query-status")

    assert {:ok, _} = VmServer.resume("qmp")
    assert_receive {:vm_status, "qmp", :running}, 5_000

    assert Enum.any?(VmServer.log("qmp"), &String.contains?(&1, "-qmp tcp:127.0.0.1:"))

    VmServer.quit("qmp")
    assert_receive {:vm_status, "qmp", :stopped}, 10_000
    assert %{status: :stopped, exit_code: 0} = VmSupervisor.runtime("qmp")
    refute VmSupervisor.running?("qmp")
  end

  test "a missing disk is an error before anything starts" do
    {:ok, vm} = VmStore.create(%{"name" => "nodisk"})
    vm = %{vm | disks: [%{"path" => "gone.qcow2", "format" => "qcow2", "interface" => "virtio"}]}
    assert {:error, "disco não encontrado: " <> _} = VmSupervisor.start_vm(vm)
  end
end
