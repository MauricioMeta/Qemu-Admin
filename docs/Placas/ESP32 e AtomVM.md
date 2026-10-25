---
tags: [qemu-admin, placas, esp32]
---
# ESP32 e AtomVM

VM de arquitetura **xtensa** = ESP32, emulado pelo QEMU da Espressif (`qemu-esp/`). Chips: `esp32` e `esp32s3`.

Fluxo: Nova VM → aba **Flash** → AtomVM (baixa, confere SHA-256, grava no bootloader: 0x1000 no ESP32, 0x0 no S3) → **App (.avm)** na partição `main.avm` → Ligar → aba **Serial** (UART0).

Notas:
- Sem `.avm`, o AtomVM tenta WiFi AP e reinicia em loop (esperado).
- Sem ACPI: Desligar encerra o QEMU.
- Estado: a VM `esp32-atomvm` existe e foi usada; **ESP32-S3 sem teste** ([[Pendencias]]).
