---
tags: [qemu-admin, arquitetura, modulos]
---
# Módulos (`lib/qemu_admin`)

| Módulo | Papel |
| --- | --- |
| `Vm` | Definição da VM (o `vm.json`), pura |
| `Vm.Args` | Monta a linha de comando do QEMU, pura e testada |
| `VmStore` | VMs em disco, uma pasta por id |
| `VmServer` | Um processo por VM: port do QEMU, QMP, screendump, serial |
| `VmSupervisor` | Sobe os VmServers; tabela ETS de runtime |
| `Workspace`, `Paths`, `Settings` | Onde as coisas moram e preferências |
| `Qemu`, `Qemu.Img`, `Qemu.Installer`, `Qemu.Esp`, `Qemu.InstallJob` | Localizar/baixar o QEMU e o da Espressif; `qemu-img` |
| `Images` | Biblioteca e catálogo de imagens (SHA-256) |
| `Board` | Placas (ESP32, Arduino, Raspberry Pi) |
| `Gpio`, `Gpio.Esp32`, `Gpio.Avr`, `Gpio.Raspi`, `Gdb` | Pinos ao vivo via gdbstub/QMP — [[GPIO e aba Placa]] |
| `Esp32.Flash`, `Esp32.Atomvm` | Flash do ESP32 e AtomVM — [[ESP32 e AtomVM]] |
| `Avr.Firmware` | Hex/ELF do Arduino — [[Arduino]] |
| `Raspi.Image`, `Raspi.Fat`, `Raspi.Crypt` | Cartão SD do Pi, leitor FAT, hash `$6$` — [[Raspberry Pi]] |

Web: `lib/qemu_admin_web` (componentes Surface por página/aba, `AdminLive`, `ScreenController`).
Tasks Mix: `qemu.fetch`, `desktop.stage`, `desktop.build`.
