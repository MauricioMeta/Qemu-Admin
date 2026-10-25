---
tags: [qemu-admin, placas, stm32, pendencia]
atualizado: 2026-10-25
---
# STM32 e Cortex-M (não suportado ainda)

## O que o QEMU 11.1 do app oferece (`qemu-system-arm -M help`)
`netduino2` (Cortex-M3), `netduinoplus2` (M4, STM32F405), `olimex-stm32-h405` (M4), `stm32vldiscovery` (M3), `b-l475e-iot01a` (M4, STM32L4), além de `microbit` e as `mps2-*`/`mps3-*`.

## Por que o app não lista
1. A lista de máquinas é fixa em `QemuAdmin.Vm` (`@machines`, ~linha 68). Para `arm` só existem `raspi2b` e `raspi0`.
2. Falta um caminho em `Vm.Args` para Cortex-M: sem disco/CD/rede/tela; carrega `.elf`/`.bin` com `-kernel`, serial e `-nographic`.

## Feito
- A página **QEMU** lista todas as máquinas de cada emulador (`Qemu.machines/1`, lê `-machine help`), marcando as que o app configura. Só leitura: elas ainda não aparecem em "Nova VM".

## Plano (quando for implementado)
- [ ] Máquinas Cortex-M na lista de `arm` (ou ler `-M help` do QEMU).
- [ ] Novo tipo de placa em `QemuAdmin.Board` com abas Serial + Firmware (modelo: [[Arduino]]).
- [ ] Montador de argumentos para Cortex-M.
- [ ] (Grande) GPIO e desenho da placa — ver [[GPIO e aba Placa]].
- Começar por `netduinoplus2`; o BSP `stm32f4` do RTEMS mira a mesma família (não confirmado qual BSP roda em qual máquina).

Ver também [[RTOS e imagens de firmware]].
