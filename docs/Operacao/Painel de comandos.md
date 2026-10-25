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

## Onde fica
- `VmServer.commands/1` e `VmServer.console/2`; cada entrada vira `{:vm_cmd, id, entry}` no PubSub.
- O histórico é gravado em `commands.log` na pasta da VM (um JSON por linha, recomeçado a cada execução); guarda as últimas 500 entradas.
- Para aprender: a linha `$` mostra os argumentos reais; `Configuração → Argumentos extras do QEMU` aplica novos argumentos no próximo boot.

## Pendente
- [ ] Editar a linha de partida direto no painel (hoje só pelos argumentos extras da Configuração).
- [ ] Completar/ajudar comandos (lista de `query-*` e dos `info` mais úteis).
- [ ] Teste do app aberto em janela larga: o painel ocupa ~11 rem e aperta a página em janelas baixas (dá para recolher).
