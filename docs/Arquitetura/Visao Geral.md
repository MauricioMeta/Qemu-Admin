---
tags: [qemu-admin, arquitetura]
---
# Visão geral

- **Stack:** Elixir ~> 1.17, Phoenix 1.8, LiveView 1.2, Surface 0.12, DaisyUI/Tailwind, Bandit, Req, Jason.
- **UI:** uma LiveView (`AdminLive`) com trilha de ícones, painel lateral redimensionável, abas e rodapé; hooks JS em `assets/js/hooks` (noVNC, xterm serial, tail de log, resizer, controles de janela).
- **Backend:** um processo por VM (`VmServer`) sob `VmSupervisor`, falando QMP com o QEMU; definições em disco por `VmStore`.
- **Desktop:** shell Tauri (`src-tauri`) que sobe a release Elixir numa porta de loopback.
- **Workspace:** pasta com `vms/` e `images/` (padrão `~/.qemu_admin`).

Detalhes: [[Modulos]], [[Como uma VM roda]], [[Build Desktop Tauri]].
