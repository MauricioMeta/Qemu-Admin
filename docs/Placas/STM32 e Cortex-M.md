---
tags: [qemu-admin, placas, stm32]
atualizado: 2026-10-25
---
# STM32 e Cortex-M

## Estado (2026-10-25)
**Netduino Plus 2** (`netduinoplus2`, STM32F405, Cortex-M4) é uma placa do app: aparece em **Nova VM** ("Netduino Plus 2 (STM32)") e tem as abas **Visão geral · Serial · Firmware · Configuração · Log**.

- Tipo `:cortexm` em `QemuAdmin.Vm` (arquitetura `arm`); catálogo em `QemuAdmin.Board` (sem desenho e sem pinos: `headers: []`, `io: nil`).
- Linha de comando (`Vm.Args.build_cortexm/2`): `-machine netduinoplus2 -kernel <firmware> -display none -serial tcp:…,wait=on -qmp …`. Sem `-S/-gdb`, sem disco, sem rede (o QEMU não modela a Ethernet da placa), TCG.
- O primeiro `-serial` é a **USART1**, que vira a aba Serial.
- Firmware (`QemuAdmin.CortexM.Firmware`): `.elf` (mantido), `.bin` cru (carregado no início da flash) ou `.hex` (vira `.bin` a partir do menor endereço; a flash do STM32 fica em `0x08000000`). Fica na pasta da VM como `firmware.elf` / `firmware.bin`. Só com a placa desligada.
- O rastreador de GPIO (`QemuAdmin.Gpio`) só sobe para placas com `io` (`VmServer`).

## Testado
- Testes: `test/qemu_admin/cortexm_test.exs` (catálogo, VM, linha de comando, firmware, e um com QEMU real: um programa em Thumb escreve `hello from stm32` na USART1 e o texto chega na serial).
- Na interface: criar a VM pelo preset, gravar `.bin` pelo seletor, ligar e ver o texto na aba Serial. A VM de demonstração ficou em `Workspace_Qemu/vms/netduino-stm32`.
- **Firmware real (2026-10-25):** o FreeRTOS V11.3.2 (port `ARM_CM3`, `heap_4`, duas tarefas e uma fila) compilado com `arm-none-eabi-gcc` 16.2 rodou na VM, gravado como `.elf` pela aba Firmware: a aba Serial mostrou `consumer: got N at tick …` a cada ~500 ticks (1000 Hz). Fonte e `firmware.bin` em `examples/stm32-freertos/`.
- **Não testado:** Zephyr e RTEMS.

## O que o QEMU 11.1 oferece (`qemu-system-arm -M help`)
`netduino2` (M3), `netduinoplus2` (M4), `olimex-stm32-h405` (M4), `stm32vldiscovery` (M3), `b-l475e-iot01a` (M4, STM32L4), além de `microbit` e as `mps2-*`/`mps3-*`. A página QEMU do app lista todas as máquinas de cada emulador.

## Pendente
- [ ] As outras máquinas Cortex-M: acrescentar a `@cortexm` em `Vm` e uma entrada em `Board` (`cortexm/3`). Cada uma pode ter a UART em outro `-serial` (confirmar).
- [ ] GPIO e desenho da placa (hoje só a serial) — ver [[GPIO e aba Placa]].
- [x] Testar com um firmware real — FreeRTOS, ver acima. Zephyr e RTEMS ainda não ([[RTOS e imagens de firmware]]).
- [ ] A biblioteca de Imagens trata `.elf`/`.hex` como firmware de Arduino; não oferece "Nova VM STM32".
