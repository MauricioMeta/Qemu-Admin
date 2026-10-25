---
tags: [qemu-admin, operacao, tauri]
---
# Build Desktop (Tauri)

`mix desktop.build`: `qemu.fetch` (se faltar) → digest dos assets → release com ERTS + QEMU → `src-tauri/resources/rel` → bundler Tauri → NSIS em `src-tauri/target/release/bundle/nsis/`.

Requisitos: Rust estável, MSVC C++ build tools; CLI Tauri via `npx`. O `build.rs` falha se a release staged for mais velha que os fontes.

**Estado:** o instalador atual (18:53, 2026-10-24) é anterior ao código — refazer ([[Pendencias]]). O último build levou ~8,5 min.
