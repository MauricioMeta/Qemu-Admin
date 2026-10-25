# FreeRTOS no Netduino Plus 2 (STM32F405)

Firmware de exemplo para a placa `netduinoplus2` do QEMU Admin: o FreeRTOS com duas tarefas
(produtor e consumidor ligados por uma fila) que imprimem na **USART1**, a aba Serial do app.

Saída esperada:

```
FreeRTOS on STM32F405 (netduinoplus2)
consumer: got 1 at tick 4
consumer: got 2 at tick 503
...
```

`firmware.bin` é o resultado já compilado (5 KB); grave-o na aba **Firmware** da VM.

## Compilar

Precisa do `arm-none-eabi-gcc` (no MSYS2: `pacman -S mingw-w64-ucrt-x86_64-arm-none-eabi-gcc
mingw-w64-ucrt-x86_64-arm-none-eabi-binutils mingw-w64-ucrt-x86_64-arm-none-eabi-newlib`) e do
[FreeRTOS-Kernel](https://github.com/FreeRTOS/FreeRTOS-Kernel) (testado com a V11.3.2) ao lado desta
pasta ou apontado por `K`:

```bash
git clone --depth 1 https://github.com/FreeRTOS/FreeRTOS-Kernel.git ../FreeRTOS-Kernel
make            # gera firmware.elf e firmware.bin
```

Usa o port `ARM_CM3` em um Cortex-M4 com ponto flutuante por software (sem FPU), `heap_4` e o
`nano.specs` do newlib. O ELF aceita-se na aba Firmware como está; o `.bin` é carregado no início
da flash (`0x08000000`).
