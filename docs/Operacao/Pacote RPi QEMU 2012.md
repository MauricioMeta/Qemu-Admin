---
tags: [qemu-admin, operacao, raspberry-pi]
atualizado: 2026-10-25
---
# Pacote RPi QEMU 2012

Baixado do SourceForge (`rpiqemuwindows`) como `qemu.zip` (529 MB) e extraído em `Workspace_Qemu/qemu` (1,9 GB; a imagem fica em `qemu/qemu/`).

- Conteúdo: QEMU antigo (`qemu-system-arm.exe`, `-i386`, `-ppc`, `-sparc`, `-x86_64`), `2012-07-15-wheezy-raspbian.img`, `kernel-qemu`, `run.bat`.
- Comando do `run.bat`: `qemu-system-arm.exe -M versatilepb -cpu arm1176 -hda 2012-07-15-wheezy-raspbian.img -kernel kernel-qemu -m 192 -append "root=/dev/sda2"`.
- Roda rápido (desktop LXDE em 2026-10-25), mas é uma placa ARM genérica, **não** um Pi. Roda fora do app.
- **Pendente:** mover `vms/qemu` para fora do workspace (ex.: `D:\MINHAS_COISAS\PROJETOS_DE_SOFTWARES\RPi_QEMU_2012`); dentro de `vms/` a pasta não é uma VM (falta `vm.json`) e o app a ignora. O pacote é de terceiros: conferir procedência antes de reutilizar.

Ver [[Raspberry Pi 32 bits e desktop]].

## Como rodar no app (2026-10-25)
O app roda o pacote com o **QEMU embutido** (o de 2012 não é usado), como uma VM comum:
- Máquina `versatilepb` (agora na lista da arquitetura `arm`) criada em **Nova VM**: "Raspbian 2012 (desktop)".
- **Linha de partida** editada (Comandos › Linhas de partida): `-machine versatilepb -cpu arm1176 -m 192 -kernel …/kernel-qemu -hda …/2012-07-15-wheezy-raspbian.img -append "root=/dev/sda2"` mais as portas do app (`-vnc 127.0.0.1:{vnc},websocket=127.0.0.1:{ws}` e `-qmp … {qmp}`). A imagem é usada onde está, e o que se faz no sistema grava nela.
- A tela aparece no **Console** da VM (VNC no app). O boot chega ao `raspberrypi login:`; o README do pacote diz usar `pi` / `raspberry` e `startx` para o desktop.
- Limite: uma VM do tipo PC no app (a aba Configuração mostra os campos de PC, que a linha editada ignora).
- **Mouse que não chega à borda de baixo (2026-10-25):** a `versatilepb` só tem mouse PS/2, que é *relativo*; pelo VNC o ponteiro do convidado anda menos que o do mouse e para antes da barra de tarefas. Por isso a linha de partida leva `-usb -device usb-tablet` (um ponteiro absoluto). Se o sistema de 2012 não tiver o driver USB HID, o mouse continua relativo; o jeito é, no LXTerminal do convidado, `xset m 1 1` (tira a aceleração do ponteiro).
