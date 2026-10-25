---
tags: [qemu-admin, placas, raspberry-pi, pesquisa]
atualizado: 2026-10-25
---
# Raspberry Pi: 32 bits e desktop

## Fatos (2026-10-25)
- A imagem usada é a Raspberry Pi OS **Lite** (trixie, arm64): sem desktop.
- O Pi 3 roda em TCG (aarch64 em x86), sem aceleração de CPU. A GPU VideoCore IV não é emulada: só framebuffer por VNC. Busca: sem emulador de VideoCore IV utilizável; o firmware (`start.elf`, ThreadX) é fechado.
- O `versatilepb` + `arm1176` do pacote de 2012 roda rápido por ser 32 bits, 1 núcleo e sistema leve — ver [[Pacote RPi QEMU 2012]]. Não é um Pi (sem GPIO, USB, SD do BCM).

## Ideias (não testadas)
- [ ] `raspi0` (Pi Zero, ARM1176) com imagem armhf do Raspberry Pi OS: provavelmente bem mais leve que o Pi 3. Incertezas: RAM aceita pelo `raspi0` e se o kernel sobe.
- [ ] Desktop remoto: `xrdp` ou `x11vnc` no guest + porta redirecionada (3389/5901). Renderiza na CPU emulada; ganha resolução, clipboard e compressão. Depende da rede ([[Pendencias]]).
- [ ] Renderização fora da VM: X11 forwarding (`ssh -X`) ou `waypipe`; virgl exigiria máquina `virt` aarch64 e janela SDL/GTK com `gl=on` (o app usa VNC, que não carrega a saída do virgl). O QEMU do app traz `libvirglrenderer-1.dll`.
- Para desktop Linux rápido: VM x86_64 com WHPX e `virtio`/`qxl`.

## Desligar por dentro
`sudo poweroff`. No Pi emulado o processo do QEMU pode continuar após o `poweroff` — não verificado; usar **Desligar** no app depois.
