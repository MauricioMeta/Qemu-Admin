---
tags: [qemu-admin, operacao, qmp]
atualizado: 2026-10-25
---
# Terminal

Terminal recolhível no rodapé de **toda página de VM** (`Vm.Terminal`), pensado para quem quer aprender a mexer no QEMU: mostra o que o app manda ao QEMU e deixa o usuário mandar os seus comandos.

## O que aparece
Cada comando é **uma linha que se abre** (como o histórico de comandos do editor do NBSim): fechada, mostra a hora local, o comando como o usuário o conhece, **como chega ao QEMU** (`QMP`, `monitor (HMP)`, `linha de comando`, `app`), **de onde veio** (`digitado`, `botão`, `salvo: start (passo 2/4)`, `app`), o começo da resposta e `ok`/`erro`. Aberta, mostra o que de fato aconteceu:

| Legenda | Significa |
| --- | --- |
| **enviado ao QEMU** | a mensagem QMP exata que desceu pelo socket, com o `id` (`{"id":6,"arguments":{"command-line":"cont"},"execute":"human-monitor-command"}`) |
| **processo** | para as ferramentas: o executável e os argumentos que rodaram, e a pasta (`"…/qemu-img.exe" info disk0.qcow2`) |
| **resposta** | o que o QEMU devolveu: a mensagem QMP inteira (`{"id":5,"return":{}}`) ou, no monitor, o texto |
| **evento** | evento do QMP que veio logo após (`STOP`, `RESUME`, `SHUTDOWN`…, até 1,5 s depois) |
| **erro** | o motivo, quando falhou |

Assim se vê, por exemplo, que `stop` digitado no monitor chega como `human-monitor-command` com `"command-line": "stop"`, enquanto o botão Pausar manda `{"execute":"stop"}` direto: são caminhos diferentes para a mesma coisa. Uma linha aberta continua aberta quando chegam outras.

Ficam soltas, sem se abrir: `$` (a linha de comando com que a execução começou), `▶` (início e fim de um comando salvo) e os eventos que ninguém pediu.

Não entram as consultas internas do app (a miniatura da tela a cada 5 s, a consulta de estado, a leitura dos pinos do Raspberry Pi) nem os `STOP`/`RESUME` do gdbstub das placas ESP32/Arduino. O botão Pausar/Retomar de uma placa com gdbstub aparece com o `via` `gdbstub` e a explicação de que não passa pelo QMP.

**Como é gravado** (`commands.log`, um JSON por linha): `seq`, `at`, `dir` (`launch`, `cmd`, `sent`, `tool`, `received`, `event`, `error`, `macro`) e `text`, mais, no que pertence a um comando, `x` (o `seq` da linha `cmd` que o abre), `src` e `via` (só na `cmd`). A dobra em linhas é feita por `QemuAdmin.Terminal.Groups`; históricos antigos, sem `x`, aparecem como linhas soltas.

## Tamanho
O Terminal tem altura fixa (18 rem por padrão), que se **arrasta pela borda de cima** (a faixa fina com uma linha que acende ao passar o mouse; duplo clique volta ao padrão). A altura fica em `--terminal-h` no `<html>`, é guardada no navegador (`qa:terminal-h`) e aplicada antes do primeiro desenho (`root.html.heex`), como a largura do painel lateral. Hook `DockResizer` (`assets/js/hooks/dock_resizer.js`), mínimo de 120 px e máximo de 80% da janela.

Dentro dele, o histórico ocupa o que sobra; os painéis de comandos salvos e da linha de partida rolam sozinhos, com até 45% da altura cada. A página da VM (a Serial, o Console, a Visão geral…) fica com o resto da janela, então arrastar a borda também redimensiona a Serial. Na **Visão geral**, a divisão entre a caixa da serial/tela e o cartão da placa também se arrasta (a faixa entre as duas colunas, só em janelas largas, ≥ 1280 px; abaixo disso as colunas empilham e a faixa some). A proporção fica em `--overview-split` (em `fr`: a coluna da esquerda contra 1fr da direita), guardada em `qa:overview-split` e aplicada antes do primeiro desenho; cada coluna mantém pelo menos uns 28% da largura; duplo clique volta ao padrão (1,3 : 1). Hook `SplitResizer` (`assets/js/hooks/split_resizer.js`), que serve para qualquer faixa entre duas colunas (`data-var` e `data-key`).

O **painel lateral** (a lista de VMs) já se redimensiona pela borda direita (`PanelResizer`, duplo clique volta aos 18 rem); a faixa agora tem 8 px e uma linha visível para ser encontrada.

## Enviar
O prompt está **sempre ativo**, com a VM ligada ou desligada. O que se digita vai para um destes lugares (`QemuAdmin.Terminal.route/1`):

| O que é | Exemplo | Precisa da VM ligada? |
| --- | --- | --- |
| **Ferramenta do QEMU** (primeira palavra `qemu-img`, `qemu-io` ou `qemu-system-<arq>`) | `qemu-img info disk0.qcow2`, `qemu-system-arm -machine help` | **não** |
| **Comando do monitor** (texto que não começa com `{`; vai pelo QMP `human-monitor-command`) | `info status`, `info registers`, `stop` | sim |
| **Mensagem QMP** (texto que começa com `{`) | `{"execute": "query-status"}`, com `"arguments"` opcional | sim |

Um **prefixo** escolhe o caminho em vez de deixar o Terminal adivinhar (e é o que os comandos salvos usam): `qmp: stop` (nome do comando, com argumentos em JSON se houver: `qmp: block_resize {"device": "d0", "size": 1048576}`, ou a mensagem inteira), `hmp: info status` (monitor, mesmo que comece com `{`) e `cli: qemu-img info disk0.qcow2` (ferramenta do QEMU como processo; **só** `qemu-img`, `qemu-io` e `qemu-system-*` com `help`/`-version`: o app não roda programas quaisquer).

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

## Comandos salvos
Um **comando salvo** é um nome (como `start`) que executa uma sequência de comandos na VM selecionada. Ficam em **`terminal.json`, na raiz do workspace** (`Workspace_Qemu/terminal.json`), um arquivo que também dá para editar à mão; o app o lê toda vez que precisa.

```json
{
  "version": 1,
  "commands": [
    {
      "name": "start",
      "description": "Liga a placa, espera e mostra o estado",
      "vm": null,
      "steps": ["@start", "@wait 1", "info status", "{\"execute\": \"query-status\"}"],
      "continue_on_error": false
    }
  ]
}
```

- **`name`**: uma palavra (letras, números, `.`, `_`, `-`; até 40). Digitar o nome no Terminal e dar Enter executa o comando. **Um nome salvo vale antes de um comando do monitor igual** (um `stop` salvo esconde o `stop` do monitor nessa VM).
- **`vm`**: o id de uma VM (o comando só existe para ela) ou `null` (todas).
- **`steps`**: o que executar, em ordem; cada passo é como se digita no Terminal (ferramenta do QEMU, comando do monitor, mensagem QMP), de preferência com um prefixo que diz **como chega ao QEMU**: `qmp: stop`, `hmp: info status` ou `cli: qemu-img info {dir}/disk0.qcow2` (ver [[#Enviar]]). Sem prefixo, o Terminal descobre sozinho. Linhas em branco e as que começam com `#` são ignoradas. O formulário recusa, com o motivo, um QMP com argumentos que não são JSON, um `hmp:` vazio ou um `cli:` que não é ferramenta do QEMU. Do app, só estes dois:
  - `@start`: liga a VM e **espera** até o QEMU estar rodando (até 30 s); se já está ligada, não faz nada;
  - `@wait N`: espera N segundos (até 120).
  - `{vm}`, `{name}` e `{dir}` num passo viram o id, o nome e a pasta da VM (`qemu-img info {dir}/disk0.qcow2`).
- **`continue_on_error`**: por padrão a execução **para no primeiro passo que falha** (ferramenta com código de saída diferente de 0, comando que o QEMU recusou, monitor/QMP com a VM desligada); com `true` segue para o próximo.
- No histórico: `▶ start — 4 passos`, cada passo como uma linha que se abre, com a origem `salvo: start (passo 2/4)`, e `▶ start — concluído` (ou `interrompido no passo N de M`). Roda fora da página: dá para continuar usando o app.

Exemplo de um comando salvo que **só** manda um QMP, para ter `parar` e `retomar` à mão:

```json
{"name": "parar",   "description": "Pausa a VM (QMP stop)",  "vm": null, "steps": ["qmp: stop"], "continue_on_error": false}
{"name": "retomar", "description": "Retoma a VM (QMP cont)", "vm": null, "steps": ["qmp: cont"], "continue_on_error": false}
```

**Cadastrar e editar: a página Comandos.** O ícone **Comandos** da barra lateral (`hero-command-line`, `nav-commands`) abre a página com **todos** os comandos do workspace: cada um mostra o nome, a que VM vale, a descrição e os passos numerados, cada passo com a etiqueta de como chega ao QEMU (`QMP`, `monitor`, `processo`, `app`, `auto`). **Novo comando**, **Editar** e **Excluir** ficam ali; o formulário (nome, "vale para" qualquer VM do workspace, descrição, passos, seguir se falhar) traz a explicação dos prefixos e recusa um passo inválido com o motivo, sem gravar nada. Se o arquivo não for um JSON válido, a página mostra o erro e **não o sobrescreve**. Componente `Pages.Commands`; eventos `cp_new`, `cp_edit`, `cp_change`, `cp_cancel`, `cp_save`, `cp_delete`.

No Terminal de uma VM, o botão **Comandos salvos** continua como **atalho para executar**: lista os comandos que valem para aquela VM, com **Executar**, e **Editar comandos** leva à página. Os comandos salvos também aparecem nas sugestões ao digitar, primeiro, com a etiqueta `salvo` e a lista de passos.

Código: `QemuAdmin.Terminal.Saved` (arquivo, validação), `QemuAdmin.Terminal.Macro` (execução) e `QemuAdmin.Terminal.execute/3` (cada passo; o terceiro argumento é a origem).

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
- `VmServer.commands/1` e `VmServer.console/3`; cada linha vira `{:vm_cmd, id, entry}` no PubSub e a página a coloca de volta na linha do comando (`Groups.add/2`, idempotente: uma linha que chega duas vezes conta uma).
- O que **a página** guarda do que estava aberto (abas, tela de cada aba, Terminal recolhido) é outra coisa: ver [[Sessao e abas]].
- O histórico é gravado em `commands.log` na pasta da VM (um JSON por linha); guarda as últimas 500 entradas, de uma execução para a outra: a linha `$` marca onde cada execução começou.
- Para aprender: a linha `$` mostra os argumentos reais; `Configuração → Argumentos extras do QEMU` aplica novos argumentos no próximo boot.

## Pendente
- [x] Editar a linha de partida direto no terminal.
- [x] **Sugestões ao digitar**: nome, uso e descrição de cada comando, a partir do [[Catalogo de comandos]].
- [ ] Traduzir as descrições do catálogo (hoje em inglês, como o QEMU as escreve).
- [ ] Sugerir também os argumentos dos comandos do monitor e os valores dos enums dentro de uma mensagem QMP.
- [x] **Comandos salvos** em `terminal.json`.
- [x] Histórico em linhas que se abrem, com a mensagem real enviada ao QEMU, a origem e o caminho (QMP, monitor, processo).
- [x] Passos `qmp:`, `hmp:` e `cli:` nos comandos salvos.
- [x] Página **Comandos** na barra lateral para cadastrar, editar e excluir.
- [x] Recolher o Terminal derrubava a página (o `style` ficava `nil`); corrigido e coberto por teste.
- [ ] Salvar a partir do histórico (um botão que transforma o que foi digitado num comando salvo).
- [ ] Um menu "copiar" na linha aberta: a mensagem QMP pronta para colar num `curl`/script, ou a linha de comando do processo.
- [ ] Entregar `parar`/`retomar`/`desligar` já cadastrados num `terminal.json` novo (hoje o usuário os cria).
- [ ] Um passo `@stop`/`@desligar` e argumentos nos comandos salvos (`start 3`)?
- [ ] Teste do app aberto em janela larga: o painel ocupa ~11 rem e aperta a página em janelas baixas (dá para recolher).
