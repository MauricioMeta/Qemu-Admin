---
tags: [qemu-admin, operacao, raspberry-pi]
atualizado: 2026-10-25
---
# Pacote RPi QEMU 2012

Baixado do SourceForge (`rpiqemuwindows`) como `qemu.zip` (529 MB) e extraído em `Workspace_Qemu/vms/qemu` (1,9 GB).

- Conteúdo: QEMU antigo (`qemu-system-arm.exe`, `-i386`, `-ppc`, `-sparc`, `-x86_64`), `2012-07-15-wheezy-raspbian.img`, `kernel-qemu`, `run.bat`.
- Comando do `run.bat`: `qemu-system-arm.exe -M versatilepb -cpu arm1176 -hda 2012-07-15-wheezy-raspbian.img -kernel kernel-qemu -m 192 -append "root=/dev/sda2"`.
- Roda rápido (desktop LXDE em 2026-10-25), mas é uma placa ARM genérica, **não** um Pi. Roda fora do app.
- **Pendente:** mover `vms/qemu` para fora do workspace (ex.: `D:\MINHAS_COISAS\PROJETOS_DE_SOFTWARES\RPi_QEMU_2012`); dentro de `vms/` a pasta não é uma VM (falta `vm.json`) e o app a ignora. O pacote é de terceiros: conferir procedência antes de reutilizar.

Ver [[Raspberry Pi 32 bits e desktop]].
