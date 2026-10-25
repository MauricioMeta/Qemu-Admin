---
tags: [qemu-admin, placas, rtos, pesquisa]
atualizado: 2026-10-25
---
# RTOS e imagens de firmware

Pedido: imagens de ESP32 com RTEMS e de STM32. **Nada foi baixado** — não há imagem pronta.

## ESP32 + RTEMS
- ESP32 e ESP32-S3 são Xtensa; o RTEMS não tem BSP Xtensa e a comunidade diz que provavelmente não terá ([fórum RTEMS](https://users.rtems.org/t/rtems-support-for-esp32-xtensa-existing-bsp-work/660); opinião, não decisão formal).
- O RTEMS tem **ESP32-C3 (RISC-V)**: [MR !1160](https://lists.rtems.org/pipermail/bugs/2026-April/058435.html), integrado em abril de 2026.
- O QEMU da Espressif embutido (`qemu-esp/`) só tem `qemu-system-xtensa` (`esp32`, `esp32s3`); não emula o C3.
- Alternativas no Xtensa: FreeRTOS pelo ESP-IDF, Zephyr, [[ESP32 e AtomVM]].

## STM32 + RTEMS
- Há BSPs `stm32f4` e `stm32h7` na [documentação](https://docs.rtems.org/docs/main/user/bsps/index.html).
- O RTEMS é distribuído como fonte: é preciso toolchain + build do BSP + a aplicação. Sem imagem pronta (busca em 2026-10-25).
- Máquinas no QEMU: ver [[STM32 e Cortex-M]].

## Caminhos possíveis
1. Firmware pronto para `netduino2` (Zephyr/FreeRTOS).
2. Montar o ambiente de build do RTEMS.
3. RTOS no ESP32 Xtensa via ESP-IDF/Zephyr.
