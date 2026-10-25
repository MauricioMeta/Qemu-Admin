defmodule QemuAdmin.VmTest do
  use ExUnit.Case, async: true

  alias QemuAdmin.Vm

  defp base, do: %Vm{Vm.new() | id: "t", name: "T"}

  test "cast applies the form's params" do
    params = %{
      "name" => " Debian ",
      "cpus" => "4",
      "memory" => "4096",
      "uefi" => "true",
      "forwards" => "tcp:2222:22\ntcp:8080:80",
      "disks" => %{
        "1" => %{"path" => "b.qcow2", "format" => "qcow2", "interface" => "sata"},
        "0" => %{"path" => "a.qcow2", "format" => "raw", "interface" => "virtio"},
        "2" => %{"path" => "  ", "format" => "qcow2", "interface" => "virtio"}
      }
    }

    assert {:ok, vm} = Vm.cast(base(), params)
    assert vm.name == "Debian"
    assert vm.cpus == 4 and vm.memory == 4096 and vm.uefi
    assert vm.forwards == ["tcp:2222:22", "tcp:8080:80"]
    # in index order, the blank row dropped
    assert Enum.map(vm.disks, & &1["path"]) == ["a.qcow2", "b.qcow2"]
  end

  test "cast reports what is wrong, field by field" do
    assert {:error, errors} =
             Vm.cast(base(), %{"name" => "", "cpus" => "0", "forwards" => "ssh"})

    assert errors[:name]
    assert errors[:cpus]
    assert errors[:forwards]
  end

  test "aarch64 always boots UEFI on its own board" do
    assert {:ok, vm} =
             Vm.cast(base(), %{"arch" => "aarch64", "uefi" => "false", "machine" => "q35"})

    assert vm.uefi
    assert vm.machine == "virt"
  end

  test "parse_forward" do
    assert Vm.parse_forward("tcp:2222:22") == {:ok, {"tcp", 2222, 22}}
    assert Vm.parse_forward("udp:53:53") == {:ok, {"udp", 53, 53}}
    assert Vm.parse_forward("tcp:0:22") == :error
    assert Vm.parse_forward("http:80:80") == :error
  end

  test "a stable MAC with QEMU's prefix" do
    mac = Vm.mac(%Vm{id: "abc"})
    assert mac =~ ~r/^52:54:00(:[0-9a-f]{2}){3}$/
    assert mac == Vm.mac(%Vm{id: "abc"})
    refute mac == Vm.mac(%Vm{id: "abd"})
  end

  test "JSON round trip" do
    {:ok, vm} = Vm.cast(base(), %{"disks" => %{"0" => %{"path" => "d.qcow2"}}})
    back = vm |> Jason.encode!() |> Jason.decode!() |> Vm.from_map()
    assert back == vm
  end

  test "relative paths live in the VM's folder" do
    vm = base()
    assert Vm.resolve(vm, "disk0.qcow2") == Path.join(Vm.dir(vm), "disk0.qcow2")
    assert Vm.resolve(vm, "C:/isos/a.iso") == "C:/isos/a.iso"
    assert Vm.resolve(vm, "") == nil
  end
end
