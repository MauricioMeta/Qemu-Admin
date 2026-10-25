---
tags: [qemu-admin, status]
verificado: 2026-10-24
---
# Estado do Projeto

Verificação feita em 2026-10-24 (índice: [[Home]]).

## Verificado agora
| Item | Resultado |
| --- | --- |
| `mix compile --warnings-as-errors` | sem avisos |
| `mix test` | **70 testes, 0 falhas** (~5 s) |
| Servidor de dev | responde **HTTP 200** em http://localhost:4010 |
| VMs ligadas | nenhuma (nenhum `qemu-system-*` em execução; só os `erl.exe` do servidor) |
| QEMU portátil | `qemu/` versão 11.1.0 (x86_64, i386, aarch64, arm, avr) |
| QEMU Espressif | `qemu-esp/bin/qemu-system-xtensa.exe` presente |

## VMs existentes (`~/.qemu_admin/vms`)
- `esp32-atomvm` — ESP32 (xtensa, TCG, flash `flash.bin`, AtomVM v0.6.6 Elixir; o campo `app` aponta para um `.avm` de teste em pasta temporária)
- `teste-bios` — x86_64 q35, 2 GiB, disco qcow2 virtio, VNC

O `settings.json` aponta o workspace para uma pasta temporária (`scratchpad/Workspace Placas`) — resto de uma sessão de teste, não é o padrão.

## Instalador Tauri — desatualizado
O NSIS `src-tauri/target/release/bundle/nsis/QEMU Admin_0.1.0_x64-setup.exe` (81 MB) foi gerado às 18:53 de 2026-10-24 e `resources/staged_at` marca a release em 18:48. Os fontes em `lib/` têm data posterior (trabalho de placas/Pi), então ele **não reflete o código atual**. É preciso rodar `mix desktop.build` de novo — ver [[Build Desktop Tauri]].

## Em aberto
Ver [[Pendencias]]: rede do Raspberry Pi, login pela serial do Pi, teste do ESP32-S3 e refazer o instalador.

## Tamanho
O código versionável é pequeno (72 arquivos em `lib/`, 12 em `test/`). Fora do git (ver `.gitignore`): `deps/`, `_build/`, `qemu/`, `qemu-esp/`, `.cache/`, `src-tauri/target/`.
