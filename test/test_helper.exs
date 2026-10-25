# Tests tagged :qemu boot a real QEMU; they run when one is found (qemu/
# after `mix qemu.fetch`, or a system install) and are skipped otherwise.
# :qemu_esp the same with Espressif's (qemu-esp/), :qemu_avr with an
# emulator for the Arduinos.
exclude =
  if(QemuAdmin.Qemu.available?(), do: [], else: [:qemu]) ++
    if(QemuAdmin.Qemu.Esp.available?(), do: [], else: [:qemu_esp]) ++
    if("avr" in QemuAdmin.Qemu.info().emulators, do: [], else: [:qemu_avr])

ExUnit.start(exclude: exclude)
