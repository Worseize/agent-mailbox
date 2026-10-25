# Owner desk: questions that must be answered, not lost

A decision desk for one operator: questions arrive in a messenger with buttons,
answers go back to the agent that asked. Python standard library only, Telegram
Bot API via long polling, JSON storage on the server. No webhook, no database,
no external packages.

## Why

Messages between agents are data; decisions are not. A question addressed to
the human needs three things a chat cannot give:

1. **A number and a status** — so it cannot be lost between two other topics.
2. **A recorded answer** — who asked, what was decided, when, and why.
3. **A way back** — the decision must reach the agent that waits for it.

## What it does

| Step | Behaviour |
| --- | --- |
| Question arrives | created with an id and status `open` |
| Shown in messenger | choice question — inline buttons; text question — plain message |
| Answer | a button, or **your own text** (the button «Свой ответ» works even on a choice question) |
| Problem | the button «Проблема»: describe what is wrong with the bot or the question; it becomes a task for the operator, not a forced choice |
| Details | a separate message with id, source, topic, type, status, text, options, answer, comments |
| Delete | soft: status `deleted`, the record stays in the journal |
| Answer goes back | posted to the bus as a decision from the operator to the source agent |
| Listing | `/list`, `/list all`, `/show <id>`, `/ans <id> text`, `/del <id>` |

## Security model

| Risk | Mitigation |
| --- | --- |
| Someone else uses the bot | every message and button is filtered by `OWNER_ID`; others are ignored silently |
| Forged button press | `callback_data` carries only the question id and option index; the option text is taken from storage |
| Agent answers for the operator | agents have no access to the bot; only the operator's messenger account can answer |
| Token leak | token file is `600 root`, outside the repository |
| Double answer | a second answer to an answered question is refused |
| Flood | max 30 questions per day; answered ones are pruned after 90 days |

## Configuration

Environment (or `--key value`):

| Variable | Meaning |
| --- | --- |
| `DESK_TOKEN_FILE` | file with the bot token, default `/etc/owner-desk/token` |
| `DESK_OWNER_ID` | the only messenger id allowed to answer |
| `DESK_STORE` | JSON storage, default `/var/lib/owner-desk/questions.json` |
| `DESK_MAILBOX` | bus root; answers are written to `<mailbox>/conductor/outbox` |

## Commands

```bash
python3 owner-desk.py ask --source project-a --topic deploy \
    --text "Deploy now?" --options "Yes|No|Later"
python3 owner-desk.py list
python3 owner-desk.py show 7
python3 owner-desk.py ans 7 "Yes"
python3 owner-desk.py comment 7 "Deploy after the backup finishes"
python3 owner-desk.py del 7
python3 owner-desk.py export --out decisions.md
python3 owner-desk.py import-mailbox      # questions with requires: owner
python3 owner-desk.py selftest            # no network, no token
python3 owner-desk.py serve               # long polling service
```

## Tests

`selftest` needs neither network nor token: storage, answering, buttons,
soft delete, refusal of a second answer, free-text answer on a choice question,
problem reporting, import from the bus without duplicates.

## What it deliberately does not do

- No multiple operators: one owner id, one queue.
- No encryption: files are plain JSON on the server.
- No webhook: long polling only, so no public endpoint is needed.
- No auto-execution of anything: an answer is a message, not a command.

## What to keep out of a public deployment

The bot username, the owner id, the token, real questions and answers,
screenshots of the conversation, server addresses and paths.
