defmodule QemuAdmin.VmStoreTest do
  # the store writes into the shared test data folder
  use ExUnit.Case, async: false

  alias QemuAdmin.{Paths, Settings, VmStore}

  setup do
    File.rm_rf!(Paths.data_dir())
    Settings.reset()
    on_exit(fn -> File.rm_rf!(Paths.data_dir()) end)
    :ok
  end

  test "create, list, get, delete" do
    assert {:ok, vm} = VmStore.create(%{"name" => "Meu Ubuntu!", "memory" => "1024"})
    assert vm.id == "meu-ubuntu"
    assert File.regular?(Path.join(Paths.vm_dir(vm.id), "vm.json"))

    assert [%{id: "meu-ubuntu", memory: 1024}] = VmStore.list()
    assert {:ok, %{name: "Meu Ubuntu!"}} = VmStore.get("meu-ubuntu")

    assert :ok = VmStore.delete("meu-ubuntu")
    assert VmStore.list() == []
  end

  test "ids stay unique and never climb out of the VMs folder" do
    {:ok, a} = VmStore.create(%{"name" => "Teste"})
    {:ok, b} = VmStore.create(%{"name" => "Teste"})
    assert {a.id, b.id} == {"teste", "teste-2"}
    assert VmStore.unique_id("Ação & Reação") == "acao-reacao"

    assert VmStore.get("../secret") == {:error, :not_found}
    assert VmStore.delete("..") == {:error, :not_found}
  end

  test "invalid params come back as errors, nothing written" do
    assert {:error, errors} = VmStore.create(%{"name" => " "})
    assert Keyword.has_key?(errors, :name)
    assert VmStore.list() == []
  end

  test "clone copies the folder under a new id" do
    {:ok, vm} = VmStore.create(%{"name" => "Base"})
    File.write!(Path.join(Paths.vm_dir(vm.id), "qemu.log"), "old run")
    {:ok, copy} = VmStore.clone(vm, "Base (cópia)")

    assert copy.id == "base-copia"
    assert File.regular?(Path.join(Paths.vm_dir(copy.id), "vm.json"))
    refute File.exists?(Path.join(Paths.vm_dir(copy.id), "qemu.log"))
    assert length(VmStore.list()) == 2
  end
end
