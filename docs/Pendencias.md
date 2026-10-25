---
tags: [qemu-admin, pendencias]
atualizado: 2026-10-24
---
# Pendências

Combinadas em 2026-10-24. Nenhuma foi resolvida nesta verificação.

- [ ] **Rede do Raspberry Pi** — o app liga `-netdev user` + `usb-net` (ver `QemuAdmin.Vm.Args`, trecho de rede dos Pi). Falta validar de ponta a ponta dentro do guest. Ver [[Raspberry Pi]].
- [ ] **Login pela serial do Pi** — a console vai para tela e UART (`ttyAMA1`/`ttyAMA0`, `QemuAdmin.Raspi.Image.append/2`); o login pela aba Serial ainda não foi fechado. Ver [[Raspberry Pi]].
- [ ] **Teste do ESP32-S3** — a placa existe (`esp32s3`, AtomVM gravado em 0x0), mas só o `esp32` foi exercitado numa VM real. Ver [[ESP32 e AtomVM]].
- [ ] **Refazer o instalador Tauri** — o NSIS atual é anterior às mudanças de código ([[Estado do Projeto]]). Rodar `mix desktop.build`. Ver [[Build Desktop Tauri]].

## Contexto
- Servidor de dev em http://localhost:4010 ([[Desenvolvimento]]).
- Nenhuma VM ligada.
