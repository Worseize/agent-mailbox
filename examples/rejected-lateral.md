---
id: 20260101T121000-9b3c
from: project-a
to: project-b
kind: request
topic: lateral
requires: none
created: 2026-01-01T12:10:00+03:00
---

Этот файл нужен, чтобы увидеть отказ: проекты не пишут друг другу.

Положи его в `project-a/outbox/` и запусти `relay.ps1` — сообщение уйдёт
в `project-a/rejected/` вместе с файлом `.reason`, где будет причина:
маршрут `project-a -> project-b` запрещён таблицей.
