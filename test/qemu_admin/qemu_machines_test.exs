defmodule QemuAdmin.QemuMachinesTest do
  use ExUnit.Case, async: true

  alias QemuAdmin.Qemu

  # needs a QEMU found by the app, like the :qemu tests
  @moduletag :qemu

  test "lists the machines of an emulator, with aliases and the default" do
    if "x86_64" in Qemu.info().emulators do
      machines = Qemu.machines("x86_64")
      by_name = Map.new(machines, &{&1.name, &1})

      assert %{alias_of: "pc-q35-" <> _} = by_name["q35"]
      assert Enum.any?(machines, & &1.default?)
      assert by_name["q35"].description =~ "Q35"
      refute Map.has_key?(by_name, "Supported")
    end
  end

  test "an emulator the app does not have lists nothing" do
    assert Qemu.machines("nonexistent") == []
  end
end
