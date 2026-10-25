---
tags: [qemu-admin, operacao, workspace]
atualizado: 2026-10-25
---
# Sessão e abas

O app **lembra o que estava aberto**: as abas das VMs, a que estava na tela, a tela de cada aba (Visão geral, Serial, Placa, Log…) e se o [[Terminal]] estava recolhido. Reabrir a página, reiniciar o app ou voltar a um workspace traz tudo como foi deixado. A ideia vem do `.workspace` do Rockwell Viewer (um JSON com as abas abertas e o estado de cada uma).

## Onde fica
`session.json`, na **raiz do workspace** (ao lado de `terminal.json` e `settings.json`): como o arquivo mora na pasta, ele **acompanha o workspace** quando a pasta é movida, e cada workspace tem a sua sessão. O Rockwell guarda no diretório de dados porque não pode escrever na pasta do cliente; aqui a pasta é do próprio usuário.

```json
{
  "version": 1,
  "view": "vms",
  "selected": "netduino-stm32",
  "tabs": ["esp32-atomvm", "netduino-stm32"],
  "views": {"esp32-atomvm": "io", "netduino-stm32": "console"},
  "terminal_open": true
}
```

| Campo | O que é |
| --- | --- |
| `view` | a página: `vms`, `disks`, `images`, `qemu` ou `settings` |
| `selected` | a VM na tela (só vale com `view` = `vms`) |
| `tabs` | as abas abertas, em ordem |
| `views` | a tela de cada aba (`overview`, `console` = a aba Serial, `io` = Placa, `flash`, `config`, `log`, `firmware`) |
| `terminal_open` | o Terminal expandido ou recolhido |

## Como funciona
- **Gravar**: um gancho `after_render` do LiveView (`save_session/1` em `AdminLive`) compara o estado de depois de cada desenho com o último gravado e só escreve se mudou (gravação atômica: `.tmp` e rename). Nada é gravado na renderização sem conexão.
- **Restaurar**: `restore_session/1`, em `mount/3` e ao trocar de workspace. Abas de VMs que não existem mais são descartadas; uma aba sem tela, ou com uma que a VM não tem (`flash` é só do ESP32), abre na Visão geral. Um arquivo ilegível vale como "sem sessão".
- **Cada aba tem a sua tela** (`tab_views`): ao voltar para a aba da Raspberry que estava na Serial, ela abre na Serial, mesmo que a outra aba esteja na Visão geral. Antes a tela era uma só, a da última aba.
- Código: `QemuAdmin.Session` (arquivo) e `AdminLive` (`restore_session`, `save_session`, `remember_tab_view`).

## O que fica no navegador, não aqui
A largura do painel lateral, a altura do Terminal e a divisão da Visão geral continuam no `localStorage` (`qa:side-panel-w`, `qa:terminal-h`, `qa:overview-split`): são do **navegador/janela**, não do workspace, e precisam valer antes do primeiro desenho.

## Pendente
- [ ] Guardar também o que está aberto dentro de cada aba: a linha do histórico do Terminal que o usuário abriu, o painel de comandos salvos, a rolagem.
- [ ] O estado das seções do menu/configurações (`settings_section`).
