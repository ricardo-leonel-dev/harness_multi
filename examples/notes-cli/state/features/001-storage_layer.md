---
feature_number: 1
name: storage_layer
title: Capa de almacenamiento JSON
status: done
created_at: 2026-07-25T07:00:26.000Z
updated_at: 2026-07-25T07:00:26.000Z
---

## Description
Lectura/escritura atómica de notas en un archivo JSON. Crea el archivo si no existe.

## Acceptance
- [ ] Existe src/storage.py con funciones load() y save(notes)
- [ ] save() es atómico (escritura a archivo temporal + rename)
- [ ] load() devuelve [] si el archivo no existe
- [ ] tests/test_storage.py cubre los 3 casos anteriores
