defmodule QemuAdmin.Qemu.InstallerTest do
  use ExUnit.Case, async: true

  alias QemuAdmin.Qemu.Installer

  @targets ~w(x86_64 i386 aarch64)

  test "keeps the chosen emulators and drops their console-less twins" do
    assert Installer.keep?("qemu-system-x86_64.exe", @targets)
    assert Installer.keep?("qemu-system-aarch64.exe", @targets)
    refute Installer.keep?("qemu-system-x86_64w.exe", @targets)
    refute Installer.keep?("qemu-system-riscv64.exe", @targets)
    refute Installer.keep?("qemu-system-x86_64.exe", ["aarch64"])
  end

  test "keeps the tools and DLLs, drops docs and the installer's own files" do
    assert Installer.keep?("qemu-img.exe", @targets)
    assert Installer.keep?("libglib-2.0-0.dll", @targets)
    assert Installer.keep?("share\\bios-256k.bin", @targets)
    refute Installer.keep?("share\\doc\\qemu\\index.html", @targets)
    refute Installer.keep?("$PLUGINSDIR\\modern-wizard.bmp", @targets)
    refute Installer.keep?("uninstall.exe", @targets)
  end

  test "UEFI images only for the kept architectures" do
    assert Installer.keep?("share\\edk2-x86_64-code.fd", @targets)
    assert Installer.keep?("share\\edk2-i386-vars.fd", @targets)
    assert Installer.keep?("share\\edk2-aarch64-code.fd", @targets)
    assert Installer.keep?("share\\edk2-arm-vars.fd", @targets)
    assert Installer.keep?("share\\edk2-licenses.txt", @targets)
    refute Installer.keep?("share\\edk2-arm-code.fd", @targets)
    refute Installer.keep?("share\\edk2-riscv-code.fd", @targets)
    refute Installer.keep?("share\\edk2-aarch64-code.fd", ["x86_64"])
  end

  test "sha512 of a file" do
    path = Path.join(System.tmp_dir!(), "qa_sha_#{System.unique_integer([:positive])}")
    File.write!(path, "abc")

    assert Installer.sha512(path) ==
             "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a" <>
               "2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f"

    File.rm!(path)
  end
end
