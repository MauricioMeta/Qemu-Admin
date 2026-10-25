---
tags: [qemu-admin, placas, gpio]
---
# GPIO e aba Placa

A aba **Placa** desenha a placa em SVG: saídas vermelhas (alta) ou escuras (baixa), entradas azuis; clicar numa entrada inverte o nível.

- **ESP32/Arduino:** o GPIO emulado não guarda nada. A VM sobe pausada (`-S -gdb`) e `QemuAdmin.Gpio` para a CPU a cada acesso (watchpoints no ESP32, breakpoints no AVR), decodifica a instrução e injeta o valor.
- **Raspberry Pi:** GPIO do BCM2835 lido por QMP (`xp`: GPFSEL, GPLEV); entradas não acionáveis de fora.
