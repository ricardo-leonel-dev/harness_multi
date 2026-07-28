---
feature_number: 4
name: cli_show_delete
title: Comandos show y delete en el CLI
status: done
created_at: 2026-07-25T07:00:26.000Z
updated_at: 2026-07-25T07:00:26.000Z
---

## Description
Permite ver y eliminar notas por id.

## Acceptance
- [ ] `python -m src.cli show <id>` imprime título, fecha y cuerpo
- [ ] `python -m src.cli delete <id>` elimina y confirma con un mensaje
- [ ] Ambos comandos devuelven exit code != 0 si el id no existe
- [ ] tests/test_cli.py cubre éxito y fallo
