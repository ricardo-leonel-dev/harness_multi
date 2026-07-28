---
feature_number: 7
name: cli_recent
title: Comando recent
status: pending
created_at: 2026-07-25T07:00:27.000Z
updated_at: 2026-07-25T07:00:27.000Z
---

## Description
Lista las N notas más recientes, ordenadas por created_at descendente.

## Acceptance
- [ ] `python -m src.cli recent` lista las 5 notas más recientes por defecto
- [ ] `python -m src.cli recent --limit 10` permite cambiar el número
- [ ] El orden es por `created_at` de más reciente a más antigua
- [ ] Cada línea sigue el formato `<id>\t<created_at>\t<title>` (mismo que `list`)
- [ ] Si no hay notas, exit code 0 y no imprime nada (consistente con `list`)
- [ ] Si `--limit` es <= 0, exit code != 0 y mensaje claro en stderr
- [ ] tests/test_cli.py cubre: orden por defecto, límite custom, archivo vacío, límite inválido
