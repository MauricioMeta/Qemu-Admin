# Renode e a árvore de firmwares

O app tem dois motores: o **QEMU** e o **Renode** (https://renode.io, da Antmicro), que simula placas de microcontroladores inteiras (STM32, nRF52, i.MX RT, RISC-V…) com os periféricos. Uma VM do Renode aparece na lista como qualquer outra, no grupo **Renode**, e tem Serial, Log, Configuração e o Terminal.

## Instalar
O Renode portátil fica na pasta `renode/` ao lado do app (`RELEASE_ROOT/renode` numa release), como o `qemu/`: baixe o zip `renode-X.Y.Z.windows-portable.zip` do GitHub oficial (https://github.com/renode/renode/releases) e descompacte lá, o que cria `renode/renode_X.Y.Z-portable/renode.exe`. Se não houver, o app procura `renode` no PATH. A pasta é ignorada pelo git. Sem o Renode, a opção "Renode" do formulário aparece como indisponível. (Testado com a 1.17.0.)

## Criar uma VM do Renode
**Nova VM › Renode (outras placas)**: a **Placa** lista as descrições de `platforms/boards/*.repl` do Renode (62 na 1.17.0; a padrão é `stm32f4_discovery`) e **UART do console** escolhe em qual UART a placa imprime (as UARTs são lidas do `.repl` e dos arquivos que ele inclui com `using`; sem escolha, a primeira). Internamente a VM tem `arch` = `renode` (`Vm.kind` → `:renode`), `machine` = a placa, `uart` e `program` (o firmware).

## Firmwares na árvore da lateral
A lista de VMs é uma **árvore**: o motor (QEMU, Renode) → a VM → os seus **firmwares**. Uma placa que roda um programa (Arduino, Cortex-M, Renode) tem uma seta; abri-la mostra os arquivos que a placa carrega (módulo `QemuAdmin.Firmwares`): o `firmware.elf|bin|hex` antigo da pasta da VM e tudo o que estiver em `vms/<id>/firmware/` (`.elf`, `.hex`, `.axf` no Renode; `.elf`, `.bin` no QEMU).

- **Clicar no firmware** o faz o **programa** da VM (marca ✓, grava `program` no `vm.json`) e abre a VM. Só com a VM desligada.
- **▶ ao lado do firmware** faz o mesmo e **liga** a VM com ele: escolher uma VM e um firmware e simular é um clique.
- **adicionar firmware…** copia um arquivo para `firmware/` da VM (pelo seletor de arquivos).
- No QEMU, o programa de um Arduino ou de uma placa Cortex-M é o mesmo `program` (`Vm.Args.avr_firmware/1` → `Firmwares.path/1`).

## Como roda
`QemuAdmin.RenodeServer` ocupa o lugar do `VmServer`: o mesmo registro por id, as mesmas chamadas (log, serial, histórico de comandos) e as mesmas mensagens no PubSub, então a página não distingue os dois.

1. Gera `vms/<id>/run.resc`: `mach create`, `LoadPlatformDescription` (a placa), `CreateServerSocketTerminal <porta> "uart_term" false` e `connector Connect sysbus.<uart> uart_term` (a UART vira um socket TCP local, como no QEMU), `LoadELF`/`LoadHEX` do firmware. Caminhos com espaços vão entre aspas (a forma `@"…"` não funciona no Renode).
2. Abre `renode.exe --disable-xwt --plain --port <monitor> run.resc` (sem janelas; o monitor do Renode numa porta local).
3. Conecta na UART e no monitor e só então manda `start`, para não perder o que o firmware imprime ao ligar.

Os botões da página viram comandos do monitor: desligar/forçar → `quit`, pausar → `pause`, retomar → `start`, reiniciar → `machine Reset`. O que se digita no Terminal vai ao monitor do Renode como está (por exemplo `sysbus WhatIsAt 0x40011000`) e aparece no histórico com a etiqueta "monitor (Renode)"; a resposta do monitor entra como "resposta". Não há QMP no Renode: outros comandos QMP são recusados.

Se a UART ou o monitor não aparecem em 20 s (script com erro, placa sem aquela UART), o Renode é encerrado e o motivo fica no Log.

## Verificado
Uma VM `stm32f4_discovery` com o `firmware.elf` da Netduino (FreeRTOS) imprimiu na aba Serial: `FreeRTOS on STM32F405 … consumer: got 4 at tick 1500`; trocar de firmware pela árvore, ▶, desligar pelo botão e um comando do monitor digitado no Terminal funcionaram.

## Pendente
- [ ] `mix renode.fetch` (baixar o Renode como o `mix qemu.fetch` faz com o QEMU) e instalação pela página QEMU.
- [ ] Arquivos `.bin` no Renode (precisam do endereço de carga), `.resc` próprios e placas além de `platforms/boards`.
- [ ] Desenho da placa e pinos (GPIO) das placas do Renode; hoje só a Serial.
- [ ] Salvar quais nós da árvore estão abertos na sessão.
