# QEMU Admin

Gerenciador local de máquinas virtuais **QEMU**: cria, liga, pausa, desliga e
configura VMs, com a tela de cada uma **dentro do app** (noVNC falando direto
com o VNC/WebSocket do QEMU). Autocontido: traz o **QEMU portátil** junto, e
sai como app desktop pelo **Tauri**.

Mesmo molde do [Rockwell Viewer](../Rockwell-Viewer) — Elixir + Phoenix
LiveView + Surface + DaisyUI, com a trilha de ícones, o painel lateral
redimensionável, a barra da página com abas e o rodapé de status — e o
empacotamento desktop do [Eleuther.IO](../Eleuther.IO) /
[HyperModel](../Eleuther%20HyperModel).

## Uso

```bash
mix setup
mix qemu.fetch     # QEMU portátil em qemu/ (Windows; ~400 MB) e o da Espressif em qemu-esp/ (~70 MB)
mix phx.server     # http://localhost:4010
```

Sem `mix qemu.fetch`, o app procura um QEMU já instalado (PATH,
`C:\Program Files\qemu`) e oferece o download na página **QEMU**.

## O que tem

| Rail | Página |
| --- | --- |
| Máquinas virtuais | O workspace no topo (trocar, abrir ou criar pasta); grade com a tela (ou o desenho da placa) de cada VM; por VM: **Visão geral** (hardware, discos, CD, linha de comando), **Console** (noVNC: Ctrl+Alt+Del, tela cheia, escala), **Configuração** e **Log**. As placas têm também **Serial**, **Placa** (os pinos ao vivo) e onde mora o programa: **Flash** (ESP32), **Firmware** (Arduino), **Cartão SD** (Raspberry Pi) |
| Discos | Todas as imagens (`qemu-img info`), criar disco para uma VM, aumentar |
| Imagens | A biblioteca do workspace (`images/`): ISOs, discos, imagens de cartão SD, firmware de Arduino; cada uma cria a VM do tipo certo; catálogo para baixar (Raspberry Pi OS Lite 64/32-bit, Alpine virt x86_64/aarch64), conferido por SHA-256 |
| QEMU | Versão, origem, emuladores e aceleradores; baixar/atualizar o QEMU portátil e o da Espressif (ESP32) |
| Configurações | Pasta do QEMU, aceleração e tela padrão, pastas, desligamento ao fechar |

Um **workspace** é uma pasta qualquer com `vms/` e `images/`; o menu acima
da lista de VMs troca de workspace, abre ou cria uma pasta e lembra as
recentes. O padrão é a pasta de dados (`~/.qemu_admin` em dev, a pasta de
dados do usuário no app desktop). Trocar exige as VMs desligadas.

Cada VM é uma pasta (`vm.json`, discos, `efivars.fd`, `qemu.log`,
`screen.png`) em `vms/` do workspace. Caminhos relativos de disco ficam
dentro da pasta da VM, então ela pode ser copiada ou movida inteira.

### Como uma VM roda

- `QemuAdmin.Vm.Args` monta a linha de comando (pura, testada):
  `-accel whpx,kernel-irqchip=off -accel tcg` no modo automático (o QEMU
  tenta na ordem), discos como `-drive if=none` + `-device` com `bootindex`,
  CD-ROM sempre presente (troca de mídia ao vivo), UEFI pelos edk2 ao lado
  do QEMU, rede NAT com portas redirecionadas, tablet USB.
- `QemuAdmin.VmServer` (um processo por VM) abre o QEMU como port e fala
  **QMP** por TCP em loopback: status, pausar/continuar, reset, botão de
  desligar (ACPI), `quit`, troca de CD e um `screendump` a cada 5 s (a
  miniatura da grade).
- A tela: `-vnc 127.0.0.1:N,websocket=127.0.0.1:PORTA` e o hook `VncConsole`
  conecta o noVNC nessa porta.

### WHPX (aceleração no Windows)

O modo automático usa o **Windows Hypervisor Platform** quando o QEMU o tem
e o recurso está ativo ("Plataforma do Hipervisor do Windows" em *Recursos
do Windows*); senão cai para TCG (emulação, mais lento). Guests aarch64 em
máquina x86 são sempre TCG.

## ESP32 e AtomVM

Uma VM de arquitetura **xtensa** é um **ESP32** (placas `esp32` e
`esp32s3`), emulado pelo [QEMU da Espressif](https://github.com/espressif/qemu)
— o QEMU oficial não tem esses chips. O fluxo para rodar o
[AtomVM](https://github.com/atomvm/AtomVM):

1. **Nova VM** → Arquitetura `xtensa`: escolha o chip, a PSRAM e o tamanho
   da flash (`flash.bin`, vazia, na pasta da VM).
2. Aba **Flash** → **AtomVM**: escolha a versão (a lista vem das releases no
   GitHub; a estável mais nova vem marcada) e "Elixir + Erlang" ou "Só
   Erlang". O app baixa a imagem, confere o SHA-256, apaga a flash e grava
   no endereço do bootloader do chip (0x1000 no ESP32, 0x0 no S3).
3. **App (.avm)**: grave o seu programa (`mix atomvm.packbeam`, do
   [ExAtomVM](https://github.com/atomvm/ExAtomVM), ou
   `rebar3 atomvm packbeam`) na partição `main.avm` — lida da tabela de
   partições da própria flash.
4. **Ligar**: abre a aba **Serial**, um terminal (xterm.js) ligado à UART0.

Detalhes:

- A UART fica num socket TCP em loopback com `wait=on`: o QEMU só solta o
  chip depois que o `VmServer` conecta, então o log de boot vem inteiro.
  O app guarda os últimos 256 KiB e o `serial.log` da execução; a Visão
  geral mostra as últimas linhas.
- Sem app gravado, o AtomVM tenta subir o WiFi em modo AP, que o QEMU não
  emula, e reinicia em loop — é o comportamento esperado; grave um `.avm`.
- O chip não tem ACPI: "Desligar" encerra o QEMU.
- **Avançado** grava qualquer binário num endereço (uma build do ESP-IDF
  juntada com `esptool merge_bin` vai em 0x0) ou apaga a flash.
- O QEMU da Espressif é procurado em `qemu-esp/` (embutido), na pasta de
  dados (baixado pela página QEMU), na instalação do ESP-IDF
  (`~/.espressif/tools/qemu-xtensa`) e no PATH.

## Placas: Arduino, Raspberry Pi e a aba Placa

A **Nova VM** tem atalhos para cada placa (`QemuAdmin.Board`): ESP32 e
ESP32-S3 DevKitC, Arduino Uno, Mega e Mega 2560, Raspberry Pi 3 B, 3 A+,
4 B, 2 B e Zero.

**Arduino** (`qemu-system-avr`): grave o sketch compilado na aba
**Firmware** — o `.hex` do Arduino IDE (*Sketch › Exportar binário
compilado*) ou do `arduino-cli compile -b arduino:avr:uno --output-dir out`,
ou o `.elf`. A `Serial` sai na aba Serial. O QEMU não tem o Timer0 do
ATmega, de que `millis()` e `delay()` dependem: o app faz o papel dele,
entrando na interrupção de overflow pelo gdbstub (o ritmo é aproximado).
PWM e ADC não são emulados.

**Raspberry Pi**: na aba **Cartão SD**, importe uma imagem do Raspberry Pi
OS (`.img`, ou `.img.xz` com o 7-Zip instalado). Ela é copiada para a VM,
aumentada para uma potência de 2 (exigência do SD do QEMU) e o kernel, o
device tree e o `cmdline.txt` saem da partição de boot (um leitor FAT no
app): o QEMU não emula o firmware de boot do Pi e sobe o kernel direto. A
console vai para a tela e para a UART (`ttyAMA1` nos modelos com Bluetooth,
`ttyAMA0` no 2 B e no Zero). Teclado, mouse e rede vão por USB (o Pi 4 do
QEMU não tem USB). Desligar corta a energia: use `sudo poweroff` dentro
dele para um desligamento limpo.

**Placa** desenha a placa em SVG com os pinos ao vivo: saídas em vermelho
(alta) ou escuro (baixa), entradas em azul. Clicar numa entrada inverte o
nível que chega nela (um botão). Como cada placa é seguida:

- **ESP32 e Arduino**: o GPIO emulado não guarda nada (escritas somem,
  leituras dão 0). A VM sobe pausada com o gdbstub do QEMU (`-S -gdb`) e o
  app (`QemuAdmin.Gpio`) para a CPU a cada acesso às portas — por
  watchpoints no ESP32, por breakpoints nas instruções que acessam portas
  no Arduino —, decodifica a instrução, guarda o que a escrita quis dizer e,
  numa leitura, põe no registrador o valor certo (incluindo as entradas).
- **Raspberry Pi**: o QEMU modela o GPIO do BCM2835; os registradores
  (GPFSEL, GPLEV) são lidos pelo QMP algumas vezes por segundo. As entradas
  não podem ser acionadas de fora.

## QEMU portátil (`mix qemu.fetch`)

Baixa a build mais nova de [qemu.weilnetz.de/w64](https://qemu.weilnetz.de/w64/)
(a de Stefan Weil, indicada em qemu.org), confere o **SHA-512** publicado e
descompacta com 7-Zip — sem instalar nada, sem admin. Só ficam os emuladores
`x86_64`, `i386`, `aarch64`, `arm` (Raspberry Pi 2 e Zero) e `avr`
(Arduino), com os firmwares UEFI (~420 MB em vez de ~1,2 GB); mude com `--targets x86_64,aarch64` ou em
`config :qemu_admin, :qemu_fetch`. O instalador fica em `.cache/`.

Sem 7-Zip, o instalador NSIS roda em modo silencioso (`/S /D=…`), o que pode
pedir UAC. A mesma rotina está no app (página QEMU), instalando na pasta de
dados.

Depois vem o QEMU da Espressif: a release mais nova de
[espressif/qemu](https://github.com/espressif/qemu/releases) para o sistema
(também Linux e macOS), conferida pelo SHA-256 publicado e extraída com
`tar` em `qemu-esp/`. `--no-esp` pula essa parte.

## Aplicativo nativo (Tauri)

```bash
mix desktop.build
```

Um comando faz tudo, como no Eleuther.IO: `qemu.fetch` (se faltar), digere
os assets, monta a release com o **ERTS e o QEMU dentro**, copia para
`src-tauri/resources/rel` e chama o bundler do Tauri. O instalador NSIS sai
em `src-tauri/target/release/bundle/nsis/`. A máquina que roda o app não
precisa de Erlang nem de QEMU.

O shell (`src-tauri/src/main.rs`) sobe a release numa porta de loopback
sorteada, mostra o splash enquanto isso e aponta a janela (sem decoração —
a barra de título é do app, `App.TitleBar`) para ela. **Fechar** passa pela
página: com VMs ligadas ela pergunta e desliga as VMs (ACPI, espera até
`stop_timeout`, depois `quit`) antes de destruir a janela.

Pré-requisitos: Rust estável e as ferramentas de build C++ do MSVC. A CLI do
Tauri vem via `npx` (`TAURI_CLI="cargo tauri" mix desktop.build` para usar
outra). Rodar sem empacotar:

```bash
MIX_ENV=prod mix desktop.stage
cargo run --manifest-path src-tauri/Cargo.toml
```

O `build.rs` falha o build se a release staged for mais velha que os fontes
(ou que `qemu/`). Para ver a barra de título sem o desktop:
`QEMU_ADMIN_DESKTOP=1 mix phx.server`.

## Testes

```bash
mix test
```

Os testes marcados `:qemu` ligam um QEMU de verdade (VM sem disco, headless,
controlada por QMP) e só rodam quando um QEMU é encontrado.
