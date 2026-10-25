---
tags: [qemu-admin, placas, raspberry-pi]
---
# Raspberry Pi

Modelos: 3 B, 3 A+, 4 B, 2 B, Zero. Aba **Cartão SD**: importa a imagem do Raspberry Pi OS (`.img`, ou `.xz` com 7-Zip), amplia para potência de 2 e extrai kernel, DTB e `cmdline.txt` da partição de boot (leitor FAT em `Raspi.Fat`). O QEMU não emula o firmware de boot: o kernel sobe direto.

- Console para tela e UART (`ttyAMA1` com Bluetooth, `ttyAMA0` no 2 B/Zero).
- Teclado, mouse e rede por USB (`usb-net`); o Pi 4 do QEMU não tem USB.
- Desligar corta a energia; use `sudo poweroff` no guest.

**Pendente:** rede e login pela serial — ver [[Pendencias]].
