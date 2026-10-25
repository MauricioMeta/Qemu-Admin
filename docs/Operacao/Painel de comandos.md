---
tags: [qemu-admin, operacao, qmp]
atualizado: 2026-10-25
---
# Painel de comandos

Painel recolhível no rodapé de **toda página de VM** (`Vm.Commands`), pensado para quem quer aprender a mexer no QEMU: mostra o que o app manda ao QEMU e deixa o usuário mandar os seus comandos.

## O que aparece
Linhas com a hora local, um prefixo e o texto:

| Prefixo | Significa |
| --- | --- |
| `$` | a linha de comando com que a execução começou |
| `›` | comando QMP (JSON) enviado, seja por um botão da página (pausar, reset, desligar…) ou digitado |
| `(qemu)` | comando do monitor (HMP) digitado, como `info registers` |
| `‹` | a resposta |
| `·` | evento do QMP (`STOP`, `RESUME`, `SHUTDOWN`, `RESET`…) |
| `!` | erro |

Não entram as consultas internas do app (a miniatura da tela a cada 5 s e a consulta de estado) nem os `STOP`/`RESUME` do gdbstub das placas ESP32/Arduino.

## Enviar
- Texto que **não** começa com `{` é um comando do monitor (vai pelo QMP `human-monitor-command`): `info status`, `info registers`, `info qtree`, `info mtree`…
- Texto que começa com `{` é uma mensagem QMP: `{"execute": "query-status"}`, com `"arguments"` opcional.
- **↑ / ↓** percorrem o que foi enviado antes, para editar e mandar de novo (hook `CmdInput`).
- Só com a VM ligada. Desligada, o painel mostra o histórico da última execução.

## Editar a linha de partida
O botão **Editar linha de partida** (no cabeçalho do painel) abre um editor com os argumentos que o app montaria para esta VM. Vale a partir do **próximo boot**.

- No lugar das portas que o app escolhe a cada início, a linha tem **marcadores**: `{qmp}`, `{serial}`, `{ws}`, `{vnc}` (o número do display VNC) e `{gdb}`. O app os troca por portas livres a cada execução.
- **Salvar** guarda a linha no `vm.json` (campo `command`). Se o texto for igual ao padrão, nada é guardado e a VM continua seguindo as suas configurações. Um selo "linha de partida editada" aparece enquanto houver uma linha própria.
- **Restaurar a padrão** apaga a linha própria.
- O app **recusa** a linha sem o que ele precisa para controlar a VM: `{qmp}` sempre, `{serial}` nas placas (ESP32, Arduino, STM32, Raspberry Pi) e `{gdb}` no ESP32 e no Arduino. Também recusa aspas sem fechar e linha vazia.
- Enquanto houver linha própria, mudar a placa, a memória, os discos etc. na aba Configuração **não** altera os argumentos: restaure a padrão (ou edite a linha) para voltar a segui-las.
- O cartão "Linha de comando" da Visão geral mostra a linha própria como a da próxima execução.
- Os argumentos são separados como num shell (aspas respeitadas); em caminhos do Windows use `/`.

## Onde fica
- `VmServer.commands/1` e `VmServer.console/2`; cada entrada vira `{:vm_cmd, id, entry}` no PubSub.
- O histórico é gravado em `commands.log` na pasta da VM (um JSON por linha, recomeçado a cada execução); guarda as últimas 500 entradas.
- Para aprender: a linha `$` mostra os argumentos reais; `Configuração → Argumentos extras do QEMU` aplica novos argumentos no próximo boot.

## Pendente
- [x] Editar a linha de partida direto no painel.
- [ ] Completar/ajudar comandos (lista de `query-*` e dos `info` mais úteis).
- [ ] Teste do app aberto em janela larga: o painel ocupa ~11 rem e aperta a página em janelas baixas (dá para recolher).
