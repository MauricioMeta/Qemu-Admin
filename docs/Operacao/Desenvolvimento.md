---
tags: [qemu-admin, operacao]
---
# Desenvolvimento

```bash
mix setup
mix qemu.fetch      # QEMU portátil (~400 MB) e o da Espressif (~70 MB)
mix phx.server      # http://localhost:4010
```

Preview configurado em `.claude/launch.json` (`qemu_admin`, porta 4010). `QEMU_ADMIN_DESKTOP=1 mix phx.server` mostra a barra de título do desktop.
Dados: `~/.qemu_admin` (settings.json, vms/, isos/, firmware/).
