---
tags: [qemu-admin, arquitetura]
---
# Como uma VM roda

1. `Vm.Args` gera os argumentos: aceleração `-accel whpx,kernel-irqchip=off -accel tcg` (automático), discos `-drive if=none` + `-device` com `bootindex`, CD-ROM sempre presente, UEFI pelo edk2, rede NAT com portas redirecionadas, tablet USB.
2. `VmServer` abre o QEMU como port e conversa **QMP** por TCP em loopback (status, pausar, reset, ACPI, `quit`, troca de CD, `screendump` a cada 5 s).
3. Tela: `-vnc 127.0.0.1:N,websocket=127.0.0.1:PORTA`; o hook `VncConsole` liga o noVNC.
4. Placas: UART em socket TCP com `wait=on`; gdbstub com `-S -gdb` para o GPIO.

**WHPX:** usado se o QEMU e o recurso do Windows existirem; senão TCG. Guests aarch64 em x86 são sempre TCG.
