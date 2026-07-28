---
feature_number: 2
name: note_model
title: Modelo de Nota
status: done
created_at: 2026-07-25T07:00:26.000Z
updated_at: 2026-07-25T07:00:26.000Z
---

## Description
Estructura inmutable que representa una nota con id, title, body, created_at.

## Acceptance
- [ ] Existe src/notes.py con la clase/dataclass Note
- [ ] Note.new(title, body) genera id incremental y created_at en ISO 8601
- [ ] tests/test_notes.py valida creación y serialización
