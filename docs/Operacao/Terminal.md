---
tags: [qemu-admin, operacao, qmp]
atualizado: 2026-10-25
---
# Terminal

Terminal recolhível no rodapé de **toda página de VM** (`Vm.Terminal`), pensado para quem quer aprender a mexer no QEMU: mostra o que o app manda ao QEMU e deixa o usuário mandar os seus comandos.

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
O prompt está **sempre ativo**, com a VM ligada ou desligada. O que se digita vai para um destes lugares (`QemuAdmin.Terminal.route/1`):

| O que é | Exemplo | Precisa da VM ligada? |
| --- | --- | --- |
| **Ferramenta do QEMU** (primeira palavra `qemu-img`, `qemu-io` ou `qemu-system-<arq>`) | `qemu-img info disk0.qcow2`, `qemu-system-arm -machine help` | **não** |
| **Comando do monitor** (texto que não começa com `{`; vai pelo QMP `human-monitor-command`) | `info status`, `info registers`, `stop` | sim |
| **Mensagem QMP** (texto que começa com `{`) | `{"execute": "query-status"}`, com `"arguments"` opcional | sim |

- Com a VM desligada, um comando do monitor ou QMP vira uma linha de erro no histórico, que explica isso e lembra as ferramentas.
- **↑ / ↓** percorrem o que foi enviado antes, para editar e mandar de novo (hook `CmdInput`).
- Desligada, o terminal mostra o histórico da última execução e o que foi rodado depois dela.

## Ferramentas com a VM desligada
Rodam **na pasta da VM** (um disco é só `disk0.qcow2`), sem shell (nada de `|`, `>` ou `&&`), com limite de **30 s** e de 64 KiB de saída; a saída (junto com o erro) e o código de saída aparecem no histórico. Ao terminar, a página recarrega o que a ferramenta pode ter mudado (a tabela de discos da Visão geral).

- **`qemu-img`**: qualquer comando (`create`, `info`, `convert`, `resize`, `snapshot`, `check`, `map`, `commit`, `rebase`…). Ex.: `qemu-img create -f qcow2 extra.qcow2 8G`.
- **`qemu-io`**: só com `-c` (sem ele seria interativo e ficaria esperando). Ex.: `qemu-io -c "read 0 512" disk0.qcow2`.
- **`qemu-system-<arq>`**: só para **listar o que o QEMU tem** — `-machine help`, `-cpu help`, `-device help` (ou `-device e1000,help`), `-accel help`, `-display help`, `-netdev help`, `-object help`, `-version`. Qualquer outro uso é recusado, com a indicação de usar o botão Ligar: o terminal não inicia VMs.
- Não se abre outro programa: só os executáveis da pasta do QEMU em uso.
- No log (`commands.log`): o comando entra como `tool` (`$`), a saída como `received` (`‹`) e a falha como `error` (`!`); um texto recusado entra como `typed` (`›`) e o erro logo depois.

## Sugestões ao digitar
Enquanto você digita, o prompt sugere comandos do [[Catalogo de comandos]], cada um com o uso e a descrição (o texto vem do próprio QEMU, em inglês):

- **Ferramentas** (`ferramenta` na lista): `qemu-img cre` oferece `qemu-img create [-f FMT] … FILE [SIZE]`; também `qemu-io` e os `qemu-system-<arq> -machine help`, `-cpu help`…
- **Comandos do monitor** (`monitor` na lista): `info reg` → `info registers [-a|vcpu]`, com a descrição completa embaixo. `info ` sozinho lista os 70 `info …`.
- **Comandos QMP** (`QMP`): no prompt comum, digitar `query-sta` oferece `query-status`; ao aceitar, o prompt vira a mensagem pronta, `{"execute": "query-status"}` (com os argumentos obrigatórios em branco, quando há).
- **Dentro de uma mensagem QMP**: em `{"execute": "blockdev-ch…` sugere os nomes dos comandos; em `"arguments": {"fi…` sugere os argumentos daquele comando que ainda faltam (tipo, obrigatório ou opcional, descrição, e os valores possíveis dos enums).
- Com o comando do monitor já completo e os argumentos sendo digitados, o uso e a descrição ficam à vista.
- Teclas: **↑ / ↓** escolhem, **Tab** aceita, **Esc** fecha, **Enter** envia o que está digitado (ou aceita, se você escolheu um item com as setas); o clique também aceita. Sem sugestões abertas, ↑ / ↓ voltam a percorrer o histórico.
- O navegador baixa o catálogo (`GET /terminal/commands.json`, `TerminalController`, com ETag: só baixa de novo se o arquivo mudou) e filtra no próprio navegador; o código está no hook `CmdInput` (`assets/js/hooks/cmd_input.js`).

## Editar a linha de partida
O botão **Editar linha de partida** (no cabeçalho do terminal) abre um editor com os argumentos que o app montaria para esta VM. Vale a partir do **próximo boot**.

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
- [x] Editar a linha de partida direto no terminal.
- [x] **Sugestões ao digitar**: nome, uso e descrição de cada comando, a partir do [[Catalogo de comandos]].
- [ ] Traduzir as descrições do catálogo (hoje em inglês, como o QEMU as escreve).
- [ ] Sugerir também os argumentos dos comandos do monitor e os valores dos enums dentro de uma mensagem QMP.
- [ ] **Comandos salvos**: um arquivo JSON onde o usuário guarda comandos com nome (ex.: `start`), cada um com uma sequência de comandos executada na VM selecionada.
- [ ] Teste do app aberto em janela larga: o painel ocupa ~11 rem e aperta a página em janelas baixas (dá para recolher).
