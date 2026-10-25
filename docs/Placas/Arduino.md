---
tags: [qemu-admin, placas, arduino]
---
# Arduino (AVR)

`qemu-system-avr`. Grave o `.hex`/`.elf` do sketch na aba **Firmware**. O QEMU não tem o Timer0; o app o simula entrando na interrupção de overflow pelo gdbstub (ritmo aproximado). PWM e ADC não são emulados. Placas: Uno, Mega, Mega 2560. Pinos: [[GPIO e aba Placa]].
