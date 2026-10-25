#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Стол заявок владельца: вопросы, кнопки, хранение, ответы.

Зачем: вопрос, адресованный владельцу, не должен теряться. Здесь он
получает номер, попадает в Telegram, хранится до ответа и уходит обратно
на шину агентов как решение владельца.

Только стандартная библиотека. Телеграм — long polling, без внешних пакетов.

Команды:
    owner-desk.py ask --source S --topic T --text "..." [--options "A,B"]
    owner-desk.py list [--all]
    owner-desk.py show ID
    owner-desk.py ans ID "текст"
    owner-desk.py del ID
    owner-desk.py import-mailbox DIR
    owner-desk.py selftest
    owner-desk.py serve
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path

DEFAULT_STORE = "/var/lib/owner-desk/questions.json"
DEFAULT_MAILBOX = "/srv/app/mailbox"
MAX_PER_DAY = 30
RETENTION_DAYS = 90
STATUS = {"open": "🟡", "answered": "🟢", "deleted": "⚪️"}


# ---------------------------------------------------------------- хранилище

def now() -> str:
    return datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")


def load(store: Path) -> dict:
    if not store.exists():
        return {"version": 1, "items": []}
    with store.open(encoding="utf-8") as fh:
        data = json.load(fh)
    data.setdefault("items", [])
    return data


def save(store: Path, data: dict) -> None:
    store.parent.mkdir(parents=True, exist_ok=True)
    tmp = store.with_suffix(".tmp")
    with tmp.open("w", encoding="utf-8") as fh:
        json.dump(data, fh, ensure_ascii=False, indent=2)
        fh.write("\n")
    os.chmod(tmp, 0o600)
    os.replace(tmp, store)


def log(store: Path, line: str) -> None:
    path = store.parent / "journal.log"
    with path.open("a", encoding="utf-8") as fh:
        fh.write(f"{now()}  {line}\n")


def next_id(data: dict) -> int:
    return max((int(i["id"]) for i in data["items"]), default=0) + 1


def today_count(data: dict) -> int:
    today = datetime.now().astimezone().date().isoformat()
    return sum(1 for i in data["items"] if str(i["created"]).startswith(today))


def prune(data: dict) -> int:
    """Удаляет отвеченные старше RETENTION_DAYS. Возвращает число удалённых."""
    limit = datetime.now().astimezone() - timedelta(days=RETENTION_DAYS)
    keep, dropped = [], 0
    for item in data["items"]:
        if item.get("status") == "answered" and item.get("answered"):
            try:
                when = datetime.fromisoformat(item["answered"])
            except ValueError:
                keep.append(item)
                continue
            if when < limit:
                dropped += 1
                continue
        keep.append(item)
    data["items"] = keep
    return dropped


# ---------------------------------------------------------------- заявки

def add_question(store: Path, source: str, topic: str, text: str,
                 options: list[str] | None = None) -> dict:
    data = load(store)
    if today_count(data) >= MAX_PER_DAY:
        raise SystemExit(f"лимит {MAX_PER_DAY} заявок в сутки исчерпан")
    item = {
        "id": next_id(data),
        "created": now(),
        "source": source or "conductor",
        "topic": topic or "general",
        "kind": "choice" if options else "text",
        "text": text.strip(),
        "options": options or [],
        "status": "open",
        "answer": None,
        "comments": [],
        "answered": None,
        "tg_message_id": None,
    }
    data["items"].append(item)
    save(store, data)
    log(store, f"ASK #{item['id']} source={item['source']} kind={item['kind']}")
    return item


def find(data: dict, item_id: int) -> dict | None:
    for item in data["items"]:
        if int(item["id"]) == int(item_id):
            return item
    return None


def answer(store: Path, item_id: int, value: str,
           mailbox: Path | None = None, allow_free: bool = False) -> dict:
    data = load(store)
    item = find(data, item_id)
    if item is None:
        raise SystemExit(f"заявки #{item_id} нет")
    if item["status"] == "answered":
        raise SystemExit(f"заявка #{item_id} уже отвечена: {item['answer']}")
    if item["status"] == "deleted":
        raise SystemExit(f"заявка #{item_id} удалена")
    if item["kind"] == "choice" and not allow_free and value not in item["options"]:
        raise SystemExit(f"вариант «{value}» не из списка: {item['options']}")
    item["status"] = "answered"
    item["answer"] = value
    item["answered"] = now()
    item["await_comment"] = True
    save(store, data)
    log(store, f"ANSWER #{item_id} value={value!r}")
    if mailbox is not None:
        post_decision(mailbox, item)
    return item


def post_decision(mailbox: Path, item: dict) -> None:
    """Кладёт решение владельца на шину: conductor -> источник."""
    outbox = mailbox / "conductor" / "outbox"
    outbox.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now().strftime("%Y%m%dT%H%M%S")
    body = (
        f"---\n"
        f"id: decision-{item['id']}-{stamp}\n"
        f"from: conductor\n"
        f"to: {item['source']}\n"
        f"kind: decision-needed\n"
        f"topic: {item['topic']}\n"
        f"requires: none\n"
        f"created: {now()}\n"
        f"---\n\n"
        f"Решение владельца по заявке #{item['id']}: «{item['answer']}».\n"
    )
    path = outbox / f"decision-{item['id']}-{stamp}.md"
    path.write_text(body, encoding="utf-8")
    log(mailbox / "conductor", f"POST decision #{item['id']} to={item['source']}")


def add_comment(store: Path, item_id: int, text: str,
                mailbox: Path | None = None) -> dict:
    """Дополнение владельца к решению: причина, что не нравится, что сделать."""
    data = load(store)
    item = find(data, item_id)
    if item is None:
        raise SystemExit(f"заявки #{item_id} нет")
    text = text.strip()
    if not text:
        raise SystemExit("пустой комментарий")
    item.setdefault("comments", []).append({"at": now(), "text": text})
    save(store, data)
    log(store, f"COMMENT #{item_id} text={text[:80]!r}")
    if mailbox is not None:
        post_comment(mailbox, item, text)
    return item


def post_comment(mailbox: Path, item: dict, text: str) -> None:
    outbox = mailbox / "conductor" / "outbox"
    outbox.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now().strftime("%Y%m%dT%H%M%S")
    body = (
        f"---\n"
        f"id: comment-{item['id']}-{stamp}\n"
        f"from: conductor\n"
        f"to: {item['source']}\n"
        f"kind: decision-needed\n"
        f"topic: {item['topic']}\n"
        f"requires: none\n"
        f"created: {now()}\n"
        f"---\n\n"
        f"Уточнение владельца к заявке #{item['id']}"
        f" (решение: «{item.get('answer')}»):\n\n{text}\n"
    )
    (outbox / f"comment-{item['id']}-{stamp}.md").write_text(body, encoding="utf-8")
    log(mailbox / "conductor", f"POST comment #{item['id']} to={item['source']}")


def export_markdown(store: Path) -> str:
    """Журнал решений: что решено, с какой причиной, что осталось сделать."""
    data = load(store)
    lines = ["# Журнал решений владельца", ""]
    for item in data["items"]:
        if item["status"] == "deleted":
            continue
        icon = STATUS.get(item["status"], "•")
        lines.append(f"## {icon} #{item['id']} · {item['source']} · {item['topic']}")
        lines.append("")
        lines.append(f"**Вопрос:** {item['text']}")
        if item.get("answer"):
            lines.append("")
            lines.append(f"**Решение:** {item['answer']} ({item.get('answered')})")
        for comment in item.get("comments", []):
            lines.append("")
            lines.append(f"**Комментарий** ({comment['at']}): {comment['text']}")
        lines.append("")
    return "\n".join(lines) + "\n"

def post_problem(store: Path, mailbox: Path, about: dict | None, text: str) -> dict:
    """Проблема от владельца: заявка-проблема + сообщение узлу в его inbox."""
    item = add_question(store, "owner", "problem", text, None)
    data = load(store)
    target = find(data, item["id"])
    target["kind"] = "problem"
    if about is not None:
        target["about"] = about["id"]
    save(store, data)
    log(store, f"PROBLEM #{item['id']} about={about['id'] if about else '-'}")
    inbox = mailbox / "conductor" / "inbox"
    inbox.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now().strftime("%Y%m%dT%H%M%S")
    about_text = f" по заявке #{about['id']}" if about else ""
    body = (
        "---\n"
        f"id: problem-{item['id']}-{stamp}\n"
        "from: owner\n"
        "to: conductor\n"
        "kind: report\n"
        "topic: problem\n"
        "requires: none\n"
        f"created: {now()}\n"
        "---\n\n"
        f"Владелец сообщает о проблеме{about_text}:\n\n{text}\n"
    )
    (inbox / f"problem-{item['id']}-{stamp}.md").write_text(body, encoding="utf-8")
    return target


def delete(store: Path, item_id: int) -> dict:
    data = load(store)
    item = find(data, item_id)
    if item is None:
        raise SystemExit(f"заявки #{item_id} нет")
    item["status"] = "deleted"
    save(store, data)
    log(store, f"DELETE #{item_id}")
    return item


def import_mailbox(store: Path, mailbox: Path) -> int:
    """Заявки из сообщений шины с requires: owner."""
    inbox = mailbox / "conductor" / "inbox"
    if not inbox.is_dir():
        return 0
    created = 0
    for path in sorted(inbox.glob("*.md")):
        text = path.read_text(encoding="utf-8", errors="replace")
        if not text.startswith("---"):
            continue
        head, _, body = text[3:].partition("\n---")
        meta = {}
        for line in head.splitlines():
            key, sep, value = line.partition(":")
            if sep:
                meta[key.strip()] = value.strip()
        if meta.get("requires") != "owner":
            continue
        data = load(store)
        marker = f"mailbox:{path.name}"
        if any(i.get("origin") == marker for i in data["items"]):
            continue
        raw_options = meta.get("options", "")
        options = [o.strip() for o in raw_options.split("|") if o.strip()]
        item = add_question(store, meta.get("from", "conductor"),
                            meta.get("topic", "general"), body.strip() or "(без текста)",
                            options or None)
        data = load(store)
        find(data, item["id"])["origin"] = marker
        save(store, data)
        created += 1
    return created


def summary(item: dict) -> str:
    icon = STATUS.get(item["status"], "•")
    answer = f" — {item['answer']}" if item.get("answer") else ""
    return f"{icon} #{item['id']} · {item['source']} · {item['topic']}: {item['text']}{answer}"


def render(item: dict) -> str:
    icon = STATUS.get(item["status"], "•")
    lines = [f"{icon} #{item['id']} · {item['source']} · {item['topic']}", "", item["text"]]
    if item["kind"] == "choice":
        lines += ["", "Варианты: " + ", ".join(item["options"])]
    if item["answer"]:
        lines += ["", f"Ответ: {item['answer']} ({item['answered']})"]
    for comment in item.get("comments", []):
        lines += ["", f"Комментарий: {comment['text']}"]
    if not item["answer"]:
        lines += ["", f"Ответ: реплай на это сообщение или /ans {item['id']} <текст>"]
    return "\n".join(lines)


# ---------------------------------------------------------------- telegram

def api(token: str, method: str, **params) -> dict:
    url = f"https://api.telegram.org/bot{token}/{method}"
    payload = urllib.parse.urlencode(
        {k: (json.dumps(v) if isinstance(v, (dict, list)) else v) for k, v in params.items()}
    ).encode()
    req = urllib.request.Request(url, data=payload)
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            return json.load(resp)
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", "replace")
        raise TelegramError(exc.code, method, body) from exc


class TelegramError(Exception):
    """Ошибка Telegram с кодом: «не изменено» — не повод слать дубль."""

    def __init__(self, code: int, method: str, body: str) -> None:
        self.code = code
        self.method = method
        self.body = body
        super().__init__(f"telegram {method}: {code} {body[:200]}")


def keyboard(item: dict) -> dict | None:
    if item["status"] != "open":
        return None
    rows = []
    if item["kind"] == "choice":
        row = []
        for idx, option in enumerate(item["options"]):
            row.append({"text": option[:40], "callback_data": f"ans:{item['id']}:{idx}"})
            if len(row) == 2:
                rows.append(row)
                row = []
        if row:
            rows.append(row)
    rows.append([
        {"text": "✍️ Свой ответ", "callback_data": f"free:{item['id']}"},
        {"text": "⚠️ Проблема", "callback_data": f"problem:{item['id']}"},
    ])
    rows.append([
        {"text": "Подробнее", "callback_data": f"show:{item['id']}"},
        {"text": "Удалить", "callback_data": f"del:{item['id']}"},
    ])
    return {"inline_keyboard": rows}


def details_text(item: dict) -> str:
    """Полная карточка заявки — отдельным сообщением, не вместо вопроса."""
    icon = STATUS.get(item["status"], "•")
    lines = [
        f"{icon} Заявка #{item['id']}",
        f"От: {item['source']} · тема: {item['topic']}",
        f"Создана: {item['created']}",
        f"Тип: {'выбор варианта' if item['kind'] == 'choice' else 'текстовый вопрос'}",
        f"Статус: {item['status']}",
        "",
        item["text"],
    ]
    if item["options"]:
        lines += ["", "Варианты:"] + [f"  {i + 1}. {o}" for i, o in enumerate(item["options"])]
    if item.get("answer"):
        lines += ["", f"Ответ: {item['answer']} ({item.get('answered')})"]
    for comment in item.get("comments", []):
        lines += ["", f"Комментарий ({comment['at']}): {comment['text']}"]
    return "\n".join(lines)


def send_question(token: str, chat_id: str, store: Path, item: dict) -> None:
    resp = api(token, "sendMessage", chat_id=chat_id, text=render(item),
               reply_markup=keyboard(item) or {})
    data = load(store)
    target = find(data, item["id"])
    if target is not None:
        target["tg_message_id"] = resp.get("result", {}).get("message_id")
        save(store, data)


def edit_message(token: str, chat_id: str, item: dict, text: str,
                 markup: dict | None = None) -> None:
    """Правит сообщение заявки. «Не изменено» — успех, а не повод дублировать."""
    if not item.get("tg_message_id"):
        return
    try:
        api(token, "editMessageText", chat_id=chat_id, message_id=item["tg_message_id"],
            text=text, reply_markup=markup or {})
    except TelegramError as exc:
        if "not modified" in exc.body.lower():
            return
        raise


def redraw(token: str, chat_id: str, store: Path, item: dict) -> None:
    if not item.get("tg_message_id"):
        send_question(token, chat_id, store, item)
        return
    edit_message(token, chat_id, item, render(item), keyboard(item))


def handle_callback(token: str, chat_id: str, store: Path, mailbox: Path,
                    owner_id: str, cb: dict) -> None:
    data_part = str(cb.get("data", ""))
    api(token, "answerCallbackQuery", callback_query_id=cb.get("id"))
    kind, _, rest = data_part.partition(":")
    try:
        if kind == "ans":
            item_id, opt = rest.split(":", 1)
            data = load(store)
            item = find(data, int(item_id))
            if item is None:
                return
            value = item["options"][int(opt)]
            item = answer(store, int(item_id), value, mailbox)
            redraw(token, owner_id, store, item)
            api(token, "sendMessage", chat_id=owner_id,
                text=f"Решение по #{item['id']} записано. Хочешь пояснить — пришли одним сообщением; /skip — не нужно.")
        elif kind == "free":
            data = load(store)
            item = find(data, int(rest))
            if item is None:
                api(token, "sendMessage", chat_id=owner_id, text=f"заявки #{rest} нет")
                return
            item["await_free_answer"] = True
            save(store, data)
            api(token, "sendMessage", chat_id=owner_id,
                text=f"✍️ Пришли свой ответ по #{item['id']} одним сообщением — он уйдёт как решение владельца.")
        elif kind == "problem":
            data = load(store)
            item = find(data, int(rest))
            if item is None:
                api(token, "sendMessage", chat_id=owner_id, text=f"заявки #{rest} нет")
                return
            item["await_problem"] = True
            save(store, data)
            api(token, "sendMessage", chat_id=owner_id,
                text="⚠️ Опиши проблему одним сообщением: что не так с ботом или с самой заявкой. Это уйдёт узлу как задача.")
        elif kind == "del":
            item = delete(store, int(rest))
            # гасим кнопки и заменяем текст короткой отметкой: вопрос не перерисовываем
            edit_message(token, owner_id, item, f"⚪️ Заявка #{item['id']} удалена.")
            api(token, "sendMessage", chat_id=owner_id, text=f"⚪️ #{item['id']} удалена")
        elif kind == "show":
            data = load(store)
            item = find(data, int(rest))
            if item is None:
                api(token, "sendMessage", chat_id=owner_id, text=f"заявки #{rest} нет")
                return
            # подробности — новым сообщением; исходный вопрос с кнопками не трогаем
            api(token, "sendMessage", chat_id=owner_id, text=details_text(item))
        else:
            api(token, "sendMessage", chat_id=owner_id, text="неизвестная кнопка")
    except (SystemExit, TelegramError) as exc:
        api(token, "sendMessage", chat_id=owner_id, text=str(exc))
def handle_message(token: str, store: Path, mailbox: Path, owner_id: str, msg: dict) -> None:
    text = (msg.get("text") or "").strip()
    data = load(store)

    # сначала — ответ на «Проблему» и «Свой ответ», иначе текст уйдёт в комментарий
    if text and not text.startswith("/"):
        problems = [i for i in data["items"] if i.get("await_problem")]
        if problems:
            target = problems[-1]
            try:
                post_problem(store, mailbox, target, text)
            except SystemExit as exc:
                api(token, "sendMessage", chat_id=owner_id, text=str(exc))
                return
            fresh = load(store)
            find(fresh, target["id"])["await_problem"] = False
            save(store, fresh)
            api(token, "sendMessage", chat_id=owner_id,
                text="⚠️ Проблема записана и отправлена узлу. Заявка осталась как есть.")
            return
        freed = [i for i in data["items"] if i.get("await_free_answer")]
        if freed:
            target = freed[-1]
            try:
                item = answer(store, target["id"], text, mailbox, allow_free=True)
            except SystemExit as exc:
                api(token, "sendMessage", chat_id=owner_id, text=str(exc))
                return
            fresh = load(store)
            find(fresh, target["id"])["await_free_answer"] = False
            save(store, fresh)
            redraw(token, owner_id, store, item)
            api(token, "sendMessage", chat_id=owner_id,
                text=f"✍️ Ответ по #{item['id']} записан: {item['answer']}")
            return
    # свободный текст = комментарий к последнему отвеченному, если ждём
    if text and not text.startswith("/"):
        waiting = [i for i in data["items"]
                   if i.get("await_comment") and i["status"] == "answered"]
        if waiting:
            target = waiting[-1]
            try:
                item = add_comment(store, target["id"], text, mailbox)
            except SystemExit as exc:
                api(token, "sendMessage", chat_id=owner_id, text=str(exc))
                return
            data = load(store)
            find(data, target["id"])["await_comment"] = False
            save(store, data)
            api(token, "sendMessage", chat_id=owner_id,
                text=f"💬 #{target['id']} комментарий записан и отправлен агенту {target['source']}.")
            return

    reply_to = (msg.get("reply_to_message") or {}).get("message_id")
    data = load(store)
    if reply_to:
        for item in data["items"]:
            if item.get("tg_message_id") == reply_to and item["status"] == "open":
                try:
                    answer(store, item["id"], text, mailbox)
                except SystemExit as exc:
                    api(token, "sendMessage", chat_id=owner_id, text=str(exc))
                    return
                api(token, "sendMessage", chat_id=owner_id,
                    text=f"🟢 #{item['id']} принято: {text}")
                return
    if text.startswith("/start"):
        api(token, "sendMessage", chat_id=owner_id,
            text="Стол заявок. /list — открытые, /list all — все, /show <id>, /del <id>.")
    elif text.startswith("/list"):
        show_all = "all" in text
        items = [i for i in data["items"]
                 if i["status"] != "deleted" and (show_all or i["status"] == "open")]
        body = "\n".join(summary(i) for i in items[-30:]) or "Пусто."
        api(token, "sendMessage", chat_id=owner_id, text=body)
    elif text.startswith("/show "):
        try:
            item_id = int(text.split()[1])
        except (IndexError, ValueError):
            api(token, "sendMessage", chat_id=owner_id, text="Формат: /show <id>")
            return
        item = find(data, item_id)
        api(token, "sendMessage", chat_id=owner_id,
            text=render(item) if item else f"заявки #{item_id} нет")
    elif text.startswith("/comment "):
        parts = text.split(maxsplit=2)
        if len(parts) < 3:
            api(token, "sendMessage", chat_id=owner_id, text="Формат: /comment <id> <текст>")
            return
        try:
            add_comment(store, int(parts[1]), parts[2].strip(), mailbox)
        except SystemExit as exc:
            api(token, "sendMessage", chat_id=owner_id, text=str(exc))
            return
        api(token, "sendMessage", chat_id=owner_id, text="💬 комментарий записан")
    elif text.startswith("/skip"):
        for it in load(store)["items"]:
            it["await_comment"] = False
        d = load(store)
        for it in d["items"]:
            it.pop("await_comment", None)
        save(store, d)
        api(token, "sendMessage", chat_id=owner_id, text="Ок, без комментария.")
    elif text.startswith("/ans "):
        parts = text.split(maxsplit=2)
        if len(parts) < 3:
            api(token, "sendMessage", chat_id=owner_id, text="Формат: /ans <id> <текст>")
            return
        try:
            item = answer(store, int(parts[1]), parts[2].strip(), mailbox)
        except SystemExit as exc:
            api(token, "sendMessage", chat_id=owner_id, text=str(exc))
            return
        redraw(token, owner_id, store, item)
    elif text.startswith("/del "):
        try:
            item = delete(store, int(text.split()[1]))
        except (IndexError, ValueError):
            api(token, "sendMessage", chat_id=owner_id, text="Формат: /del <id>")
            return
        redraw(token, owner_id, store, item)
    else:
        api(token, "sendMessage", chat_id=owner_id,
            text="Не понял. /list · /show <id> · /ans <id> текст · /del <id>")


def serve(args) -> None:
    token = Path(args.token_file).read_text(encoding="utf-8").strip()
    store = Path(args.store)
    mailbox = Path(args.mailbox)
    owner_id = str(args.owner_id)
    offset = 0
    store.parent.mkdir(parents=True, exist_ok=True)
    os.chmod(store.parent, 0o700)
    while True:
        try:
            resp = api(token, "getUpdates", offset=offset, timeout=25)
        except (TelegramError, SystemExit) as exc:
            print(f"getUpdates: {exc}", file=sys.stderr)
            time.sleep(10)
            continue
        for update in resp.get("result", []):
            offset = max(offset, int(update["update_id"]) + 1)
            cb = update.get("callback_query")
            msg = update.get("message")
            try:
                if cb and str((cb.get("from") or {}).get("id")) == owner_id:
                    handle_callback(token, "0", store, mailbox, owner_id, cb)
                    continue
                if msg and str((msg.get("from") or {}).get("id")) == owner_id:
                    handle_message(token, store, mailbox, owner_id, msg)
            except (TelegramError, SystemExit) as exc:
                print(f"update {update.get('update_id')}: {exc}", file=sys.stderr)
        try:
            import_mailbox(store, mailbox)
        except Exception as exc:  # импорт не должен ронять опрос Telegram
            print(f"import-mailbox: {exc}", file=sys.stderr)
        data = load(store)
        if prune(data):
            save(store, data)
        for item in load(store)["items"]:
            if item["status"] == "open" and not item.get("tg_message_id"):
                send_question(token, owner_id, store, item)


# ---------------------------------------------------------------- самопроверка

def selftest() -> int:
    import tempfile

    checks = 0
    with tempfile.TemporaryDirectory() as tmp:
        store = Path(tmp) / "questions.json"
        mailbox = Path(tmp) / "mailbox"
        (mailbox / "conductor" / "inbox").mkdir(parents=True)

        choice = add_question(store, "template-agent", "pr-37", "Слить?", ["A", "B"])
        plain = add_question(store, "bot-agent", "chat", "Что делать?")
        assert choice["kind"] == "choice" and plain["kind"] == "text", "типы заявок"
        checks += 1

        shown = render(choice)
        assert "#1" in shown and "A, B" in shown, "отображение выбора"
        checks += 1

        answered = answer(store, 1, "A", mailbox)
        assert answered["status"] == "answered" and answered["answer"] == "A", "ответ"
        checks += 1

        posted = list((mailbox / "conductor" / "outbox").glob("decision-1-*.md"))
        assert posted and "Решение владельца" in posted[0].read_text(encoding="utf-8"), "решение на шину"
        checks += 1

        try:
            answer(store, 1, "B", mailbox)
        except SystemExit:
            checks += 1
        else:
            raise AssertionError("повторный ответ должен быть отклонён")

        bad = add_question(store, "conductor", "bad-choice", "Выбор?", ["X", "Y"])
        try:
            answer(store, bad["id"], "Z", mailbox)
        except SystemExit:
            checks += 1
        else:
            raise AssertionError("вариант не из списка должен быть отклонён")

        delete(store, 2)
        assert find(load(store), 2)["status"] == "deleted", "мягкое удаление"
        checks += 1

        msg = (mailbox / "conductor" / "inbox" / "20260101-120000-owner-1.md")
        msg.write_text(
            "---\nid: q1\nfrom: project-a\nto: conductor\nkind: decision-needed\n"
            "topic: deploy\nrequires: owner\noptions: A|B\ncreated: 2026-01-01T12:00:00+03:00\n---\n\n"
            "Разрешить выкатку?\n", encoding="utf-8")
        imported = import_mailbox(store, mailbox)
        assert imported == 1, "импорт с шины"
        imported_item = load(store)["items"][-1]
        assert imported_item["kind"] == "choice" and imported_item["options"] == ["A", "B"], "кнопки из шины"
        checks += 1
        assert import_mailbox(store, mailbox) == 0, "повторный импорт не дублирует"
        checks += 1

        keyboard_choice = keyboard(choice)
        assert keyboard_choice["inline_keyboard"], "кнопки есть"
        checks += 1

    # --- кнопки: «Подробнее» новым сообщением, «Удалить» отметкой, без дублей ---
    calls = []
    real_api = api

    def fake_api(token, method, **params):
        calls.append((method, params))
        return {"ok": True, "result": {"message_id": 99}}

    globals()["api"] = fake_api
    try:
        btn = add_question(store, "bot-agent", "buttons", "Вопрос с кнопками?", ["A", "B"])
        # как будто сообщение уже отправлено: иначе править нечего
        seeded = load(store)
        find(seeded, btn["id"])["tg_message_id"] = 555
        save(store, seeded)
        handle_callback("t", "0", store, mailbox, "42", {"id": "cb1", "data": f"show:{btn['id']}"})
        assert calls and calls[-1][0] == "sendMessage" and "Заявка #" in calls[-1][1].get("text", ""), f"подробнее — новым сообщением: {calls}"
        checks += 1
        assert not any(m == "editMessageText" for m, _ in calls), "подробнее не правит вопрос"
        checks += 1
        calls.clear()
        handle_callback("t", "0", store, mailbox, "42", {"id": "cb2", "data": f"del:{btn['id']}"})
        edits = [p for m, p in calls if m == "editMessageText"]
        assert edits and "удалена" in edits[0]["text"], "удаление — отметка в сообщении"
        checks += 1
        calls.clear()
        gone = find(load(store), btn["id"])
        edit_message("t", "42", gone, "один и тот же текст", None)
        edit_message("t", "42", gone, "один и тот же текст", None)
        assert [m for m, _ in calls] == ["editMessageText", "editMessageText"], "«не изменено» не должно давать дубль"
        checks += 1

        # «Свой ответ» на вопрос с выбором: принимается произвольный текст
        free = add_question(store, "bot-agent", "free", "Выбери?", ["A", "B"])
        handle_callback("t", "0", store, mailbox, "42", {"id": "cb3", "data": f"free:{free['id']}"})
        handle_message("t", store, mailbox, "42", {"text": "Ни один вариант не подходит: вопрос неверный"})
        assert find(load(store), free["id"])["answer"].startswith("Ни один вариант"), "свободный ответ"
        checks += 1

        # «Проблема»: заявка-проблема и файл узлу
        handle_callback("t", "0", store, mailbox, "42", {"id": "cb4", "data": f"problem:{free['id']}"})
        handle_message("t", store, mailbox, "42", {"text": "Кнопки не работают, бот сломан"})
        data_after = load(store)
        problem = [i for i in data_after["items"] if i["kind"] == "problem"]
        assert problem and problem[-1]["about"] == free["id"], "заявка-проблема с привязкой"
        checks += 1
        files = list((mailbox / "conductor" / "inbox").glob("problem-*.md"))
        assert files and "владелец сообщает" in files[-1].read_text(encoding="utf-8").lower(), "файл проблемы узлу"
        checks += 1
        checks += 1
    finally:
        globals()["api"] = real_api

    print(f"owner-desk selftest: OK ({checks} проверок)")
    return 0


# ---------------------------------------------------------------- CLI

def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Стол заявок владельца")
    parser.add_argument("--store", default=os.environ.get("DESK_STORE", DEFAULT_STORE))
    parser.add_argument("--mailbox", default=os.environ.get("DESK_MAILBOX", DEFAULT_MAILBOX))
    parser.add_argument("--token-file", default=os.environ.get("DESK_TOKEN_FILE", "/etc/owner-desk/token"))
    parser.add_argument("--owner-id", default=os.environ.get("DESK_OWNER_ID", "0"))
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_ask = sub.add_parser("ask")
    p_ask.add_argument("--source", default="conductor")
    p_ask.add_argument("--topic", default="general")
    p_ask.add_argument("--text", required=True)
    p_ask.add_argument("--options", default="")

    for name in ("list", "show", "ans", "del"):
        p = sub.add_parser(name)
        if name in ("show", "del"):
            p.add_argument("id", type=int)
        if name == "ans":
            p.add_argument("id", type=int)
            p.add_argument("value")
        if name == "list":
            p.add_argument("--all", action="store_true")

    p_comment = sub.add_parser("comment")
    p_comment.add_argument("id", type=int)
    p_comment.add_argument("text")
    p_export = sub.add_parser("export")
    p_export.add_argument("--out", default="")
    sub.add_parser("import-mailbox")
    sub.add_parser("selftest")
    sub.add_parser("serve")

    args = parser.parse_args(argv)
    store = Path(args.store)
    mailbox = Path(args.mailbox)

    if args.cmd == "ask":
        # варианты могут содержать запятые: разделитель "|", а запятая — запасной
        sep = "|" if "|" in args.options else ","
        options = [o.strip() for o in args.options.split(sep) if o.strip()]
        item = add_question(store, args.source, args.topic, args.text, options)
        print(json.dumps(item, ensure_ascii=False, indent=2))
    elif args.cmd == "list":
        data = load(store)
        items = [i for i in data["items"]
                 if i["status"] != "deleted" and (args.all or i["status"] == "open")]
        for item in items:
            print(summary(item))
        if not items:
            print("Пусто.")
    elif args.cmd == "show":
        item = find(load(store), args.id)
        print(render(item) if item else f"заявки #{args.id} нет")
    elif args.cmd == "ans":
        item = answer(store, args.id, args.value, mailbox)
        print(summary(item))
    elif args.cmd == "del":
        print(summary(delete(store, args.id)))
    elif args.cmd == "comment":
        print(summary(add_comment(store, args.id, args.text, mailbox)))
    elif args.cmd == "export":
        text = export_markdown(store)
        if args.out:
            Path(args.out).write_text(text, encoding="utf-8")
            print(f"записано: {args.out}")
        else:
            print(text)
    elif args.cmd == "import-mailbox":
        print(f"импортировано: {import_mailbox(store, mailbox)}")
    elif args.cmd == "selftest":
        return selftest()
    elif args.cmd == "serve":
        serve(args)
    return 0


if __name__ == "__main__":
    sys.exit(main())
