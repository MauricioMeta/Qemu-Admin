---
tags: [qemu-admin, operacao, qmp, hmp]
atualizado: 2026-10-25
---
# Catálogo de comandos do QEMU

`priv/terminal/commands.json` lista todos os comandos do QEMU, para o [[Terminal]] sugerir enquanto se digita (servido em `/terminal/commands.json`). Gerado por `tools/gen_qemu_catalog.py` (Python 3, sem dependências):

```bash
python tools/gen_qemu_catalog.py
```

## O que tem (QEMU 11.1.0; o do ESP32 é o 9.2.2)
| Lista | Itens | O que é |
| --- | --- | --- |
| `tools` | 65 | as **ferramentas** que não precisam da VM: os 15 comandos do `qemu-img` (uso e descrição vêm do próprio `--help`), o `qemu-io` e, para cada emulador, `qemu-system-<arq> -machine help`, `-cpu help`, `-device help`, `-accel help`, `-display help`, `-netdev help`, `-object help` e `-version` (descrições em português, escritas no gerador) |
| `hmp` | 179 | comandos do **monitor**, digitados como estão (`info registers`, `stop`, `drive_add`…). 70 são do grupo `info`. Cada um com `usage`, `description` e `aliases` (`stop` → `s`) |
| `qmp` | 240 | comandos do **protocolo de máquina**, enviados em JSON `{"execute": nome, "arguments": {...}}`. Cada um com `description`, `since`, `returns` e `arguments` (`name`, `type`, `required`, `description`, `values` nos enums) |
| `qmp_events` | 57 | eventos que o QEMU envia (`STOP`, `SHUTDOWN`…), com os campos de `data` |

Cada item traz `emulators`: em quais dos emuladores o comando existe (`x86_64`, `i386`, `aarch64`, `arm`, `avr` e o `xtensa` da Espressif). A lista é a união de todos.

## De onde vem
- **O QEMU instalado** responde sobre si mesmo: `help` e `help info` (comandos do monitor, com uso e descrição) e `query-qmp-schema` (comandos QMP, argumentos e tipos). O script abre cada `qemu-system-*` com `-machine none -qmp stdio`.
- **Os textos dos comandos QMP** o QEMU não dá: vêm dos comentários da documentação do próprio QEMU, os arquivos `qapi/*.json` da tag `v11.1.0` do repositório oficial (46 arquivos, ~750 KB, baixados com `curl` em `tmp/qapi`, que o git ignora). O script os procura de novo se faltarem. Quando os argumentos de um comando são um tipo nomeado, a descrição vem do comentário desse tipo.
- Resultado: 533 dos 541 argumentos QMP têm descrição; todos os comandos do monitor e todos os eventos têm; só 2 comandos QMP ficam sem texto, porque o próprio QEMU não os documenta (`query-migrationthreads`, `x-query-opcount`).

## Para atualizar
Depois de trocar de versão do QEMU, rode o script de novo: ele lê a versão do QEMU instalado e baixa os fontes dessa tag. O teste `test/qemu_admin/terminal_catalog_test.exs` confere a forma do arquivo.

## A página Catálogo
O ícone **Catálogo** (`hero-book-open`, `nav-catalog`) da barra lateral abre os 541 comandos numa **tabela**, como a tabela de tags do Rockwell Viewer (`Pages.Catalog`, dados e busca em `QemuAdmin.Terminal.Catalog`):

- **Busca em todo o catálogo** (`#cat-search`, no topo): FTS no nome, nos argumentos e nas descrições. Cada palavra digitada casa o *começo* de um termo, o comando precisa ter **todas** as palavras, acentos e maiúsculas não contam, e o nome vale mais que o argumento, que vale mais que a descrição (nome exato vai primeiro). O resultado cai numa lista (`#cat-results`); escolher um (clique ou Enter no primeiro) seleciona o comando na tabela. Escape fecha.
- **Filtro da tabela** (`#cat-filter`): por nome ou descrição, com as abas Todos / Monitor / QMP / Eventos / Ferramentas e a contagem "N de 541". A tabela mostra até 200 linhas.
- **Editor de argumentos**: clicar numa linha abre, embaixo dela, um campo por argumento (tipo, "obrigatório" e descrição vêm do schema do QEMU; no monitor, dos termos do `usage`; numa ferramenta, um campo livre). A linha resultante aparece na hora (`#cat-line`): `qmp: eject {"id":"cd0","force":true}`, `hmp: balloon 512`, `cli: qemu-img info disco.qcow2`. Números e booleanos QMP saem com o tipo certo.
- **Enviar ao Terminal** executa a linha na VM selecionada (aparece no histórico com a origem "catálogo"); **Adicionar como passo** acrescenta a linha a um comando salvo escolhido ou abre o formulário de um novo na página Comandos. Eventos não são enviáveis.

## Pendente
- [x] Sugestões ao digitar no terminal (nome, uso e descrição de cada comando).
- [x] Comandos salvos (ex.: `start`): ver [[Terminal]].
- [x] Página Catálogo com busca FTS, tabela e editor de argumentos.
- [ ] Setas ↑/↓ e atalho Ctrl+F na busca do Catálogo.
