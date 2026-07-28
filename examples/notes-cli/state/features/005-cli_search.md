---
feature_number: 5
name: cli_search
title: Comando search
status: done
created_at: 2026-07-25T07:00:27.000Z
updated_at: 2026-07-25T07:00:27.000Z
---

## Description
Búsqueda por substring en título o cuerpo (case-insensitive).

## Acceptance
- [ ] `python -m src.cli search 'palabra'` lista las notas que contienen la palabra
- [ ] Si no hay coincidencias, exit code 1 y mensaje claro
- [ ] tests/test_cli.py cubre coincidencia, no-coincidencia y case-insensitivity
