---
feature_number: 6
name: cli_edit
title: Comando edit
status: done
created_at: 2026-07-25T07:00:27.000Z
updated_at: 2026-07-25T07:00:27.000Z
---

## Description
Permite modificar el título y/o cuerpo de una nota existente por id.

## Acceptance
- [ ] `python -m src.cli edit <id> --title 'nuevo'` actualiza solo el título
- [ ] `python -m src.cli edit <id> --body 'nuevo'` actualiza solo el cuerpo
- [ ] Pasar ambos flags actualiza ambos campos en la misma llamada
- [ ] Si no se pasa ningún flag, exit code != 0 y mensaje claro
- [ ] Si el id no existe, exit code != 0 y mensaje en stderr
- [ ] tests/test_cli.py cubre éxito (cada flag y combinado), id inexistente y ausencia de flags
