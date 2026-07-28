---
feature_number: 3
name: cli_add_list
title: Comandos add y list en el CLI
status: done
created_at: 2026-07-25T07:00:26.000Z
updated_at: 2026-07-25T07:00:26.000Z
---

## Description
Permite añadir una nota y listar todas las notas existentes.

## Acceptance
- [ ] `python -m src.cli add 'titulo' --body 'texto'` imprime el id creado
- [ ] `python -m src.cli list` imprime una línea por nota: `<id>  <created_at>  <title>`
- [ ] tests/test_cli.py cubre ambos comandos con un archivo temporal
