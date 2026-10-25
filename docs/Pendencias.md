---
tags: [qemu-admin, pendencias]
atualizado: 2026-10-25
---
# Pendências

Nada foi implementado em 2026-10-25 além do que está em [[Estado do Projeto]]; o resto ficou registrado aqui.

## Em aberto desde 2026-10-24
- [ ] **Rede do Raspberry Pi** — o guest fica com IP link-local (`169.254.x.x`), sem DHCP. O app liga `-netdev user` + `usb-net` (`QemuAdmin.Vm.Args`). Teste sugerido no guest: `ip a` e `ping 10.0.2.2`. Ver [[Raspberry Pi]].
- [ ] **Login pela serial do Pi** — o login pela aba **Tela** (tty1) funciona com `pi` / `raspberry` (confirmado em 2026-10-25). Falta fechar o login pela aba **Serial** (`ttyAMA1`/`ttyAMA0`). Ver [[Raspberry Pi]].
- [ ] **Teste do ESP32-S3** — a placa existe (`esp32s3`, AtomVM em 0x0); só o `esp32` foi exercitado. Ver [[ESP32 e AtomVM]].
- [ ] **Refazer o instalador Tauri** — o NSIS é anterior às mudanças de código. Rodar `mix desktop.build`. Ver [[Build Desktop Tauri]].

## Novas (2026-10-25)
- [x] **Suporte a Cortex-M / STM32** — feito para o `netduinoplus2` (Nova VM, Serial, Firmware). Faltam as outras máquinas, GPIO e um teste com firmware real. Ver [[STM32 e Cortex-M]].
- [ ] **RTOS nas placas** — RTEMS não existe para ESP32 Xtensa; ver [[RTOS e imagens de firmware]].
- [ ] **Pi mais leve** — testar `raspi0` (ARM1176, 32 bits) com imagem armhf. Ver [[Raspberry Pi 32 bits e desktop]].
- [ ] **Desktop gráfico para o Pi** — depende da rede do Pi. Ver [[Raspberry Pi 32 bits e desktop]].
- [ ] **Organizar o pacote de 2012** — `Workspace_Qemu/vms/qemu` (QEMU antigo + Wheezy) está dentro de `vms/`; mover para fora do workspace. Ver [[Pacote RPi QEMU 2012]].
- [x] **Terminal** — o painel de comandos passou a se chamar Terminal; catálogo de todos os comandos do QEMU gerado ([[Catalogo de comandos]]).
- [x] **Terminal: sugestões ao digitar** — feito; ver [[Terminal]].
- [ ] **Terminal: comandos salvos** (ex.: `start`, em um arquivo JSON) — ver [[Terminal]].
- [ ] **Limpar settings** — o `settings.json` da pasta de dados pode guardar workspaces temporários na lista de recentes.

## Contexto
- Servidor de dev em http://localhost:4010 ([[Desenvolvimento]]).
- Workspace ativo: `D:\MINHAS_COISAS\PROJETOS_DE_SOFTWARES\Workspace_Qemu`.
