---
feature_number: 8
name: cli_export
title: Comando export
status: spec_ready
created_at: 2026-08-18T08:24:43.000Z
updated_at: 2026-08-18T08:25:14.000Z
---

## Description
Exporta todas las notas a un archivo JSON en la ruta indicada.

## Acceptance
- [ ] python -m src.cli export <path> escribe todas las notas como un array JSON en <path>
- [ ] Si <path> ya existe, exit code != 0 y no sobreescribe el archivo
- [ ] tests/test_cli.py cubre: export exitoso y export contra un path existente
