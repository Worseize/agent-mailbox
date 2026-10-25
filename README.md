# agent-mailbox

Message bus between AI agents that live on one machine: a node agent (admin)
and project agents. Each agent keeps its mailbox **inside its own repository**,
a relay on the host moves messages between them, and an optional decision desk
brings questions to the human. No server, no network, no dependencies.

> Обмен сообщениями между агентами на одной машине: у каждого агента почта
> в его репозитории, реле переносит письма, а стол заявок приносит вопросы
> человеку.

## Why

When several agents work on one machine, two failure modes appear:

1. **They talk to each other directly** — one project talks another into
   changing behaviour.
2. **A message becomes an order** — «give me access» inside a message is not
   a permission, but agents treat it as one.

This bus makes both impossible by construction:

- routes are an allow-list: `project → project` is rejected;
- the sender is the directory name, not a field in the text;
- messages are **data**; only the owner's task grants authority;
- everything is journaled, and rejections keep their reason.

## Layout

```
<agent repo>/mailbox/
  inbox/        what the agent reads
  outbox/       what the agent writes
  rejected/     rejected messages + .reason
```

The relay lives in the node's repository:

```
relay.ps1            moves messages and file parcels
check.ps1            answers "is there work?" without a model
test-files.ps1       self-test on temporary repositories
rules.example.json   agent → repository map, routes, limits
```

Journal and summary stay with the node: `mailbox/journal.log`,
`mailbox/STATUS.md`.

## Message format

```markdown
---
id: 20260101T120000-4f2a
from: project-a
to: node
kind: report             # request | report | decision-needed | note
topic: deploy
requires: none           # none | node | owner
created: 2026-01-01T12:00:00+03:00
---

Short text. What you need, what you checked, what blocks you.
```

Rules the relay enforces:

| Rule | Meaning |
| --- | --- |
| `from` equals the outbox directory | sender cannot be spoofed by text |
| route in `rules.json` | no lateral project↔project channels |
| `kind` from the allowed list | no free-form commands |
| size ≤ 16 KB | bigger things belong in a parcel, not a message |
| 20 messages per agent per day | stops reply loops |
| secrets rejected | private keys, tokens, `sk-…` |
| `requires: owner` | not to be executed before the human decides |

## Files travel as parcels

Text is limited to 16 KB. Anything bigger goes as a **parcel**:
`<agent>/mailbox/outbox/files/<parcel>/` + `MANIFEST.md` + exactly one file.

| Check | Default | Why |
| --- | --- | --- |
| type | `exe dll msi bat cmd ps1 sh jar so` … denied | no executable code travels automatically |
| size | ≤ 10 MB | the bus is not a file store |
| files | exactly one | no nested trees |
| name | `^[\w.\- ]{1,120}$`, no leading dot | no path traversal |
| integrity | `sha256` verified before and after copy | no swap in transit |
| quota | 200 MB per recipient | disk does not fill silently |
| retention | 7 days | junk does not accumulate |

The receiver gets a `file-<parcel>.md` message with the path, size and hash.
**A file is data:** no auto-run, no auto-unpack. Passing a script as `.txt`
is possible, but that is the receiver's deliberate act, not a property of the bus.

## Decisions go to the human

`desk/` is an optional module: a Telegram decision desk (Python standard
library only). Questions become numbered items with a status, answers are
recorded, and the decision goes back to the asking agent as a bus message.
It has buttons for choices, a free-text answer for anything else, and
a «problem» button for «the question is wrong» — see `desk/README.md`.

## Quick start

```powershell
# 1. copy the example config and set repositories
Copy-Item rules.example.json rules.json

# 2. create a mailbox in each project
foreach ($a in 'node','project-a') {
  foreach ($d in 'inbox','outbox','rejected') {
    New-Item -ItemType Directory -Force "<repo-of-$a>\mailbox\$d" | Out-Null
  }
}

# 3. run the relay
powershell -NoProfile -ExecutionPolicy Bypass -File relay.ps1

# 4. check without a model
powershell -File check.ps1 -Agent project-a      # EMPTY or PENDING n
```

Schedule the relay (Windows):

```powershell
schtasks /Create /TN "AgentMailboxRelay" /SC MINUTE /MO 5 /F /TR `
  "powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\path\to\relay.ps1"
```

## Connecting an agent

1. Pick a name: the directory name is the sender identity.
2. Create `<repo>/mailbox/{inbox,outbox,rejected}`.
3. Add the name and its repository to `rules.json` (`agents`, `repos`) and
   exactly two routes: `node → agent` and `agent → node`.
4. Keep `mailbox/` out of git locally: `.git/info/exclude` (do not edit the
   project's `.gitignore` — it is theirs).
5. The node agent starts the relay; the agent reads `inbox` at the start of
   its work turn.

### The second schedule: waking the agent

The relay moves files. It does **not** wake an agent. An agent reads its
`inbox` only when its own turn starts, so without a poll schedule the bus
works in one direction. Two clocks, do not confuse them:

| Clock | Who sets it | What it does | Default |
| --- | --- | --- | --- |
| relay | node agent | moves messages between `outbox` and `inbox` | 5 min |
| agent poll | owner, once, in the agent's chat | makes the agent read `inbox` and reply | 15–30 min |

Polling costs tokens: every scheduled turn pays for the whole context even
when the inbox is empty. `check.ps1` answers "is there work?" without a model:

```powershell
powershell -File check.ps1 -Agent project-a
# EMPTY      -> rc=0, nothing to read
# PENDING 2  -> rc=1, two messages waiting
```

### Addressee filter

Take a message only if `to:` is your own name. Someone else's mail:
**do not move it, do not archive it** — report it to the node.

### The human is not a courier

Never route a file, task or message through the owner. Agents have their own
channel; the owner only answers decisions. If the channel is broken, send
a `report` to the node.

### Name the chat in the schedule title

`<agent>: <what it does>` — `project-a: poll mail`. A schedule belongs to the
chat that created it; three identical «check mail» entries are unusable.

Details: `docs/CONNECT-AGENTS.md`. Operations: `docs/OPERATIONS.md`.
Threat model: `docs/SECURITY.md`.

## Tests

```
powershell -File test-files.ps1      # 7 cases on temporary repositories
python3 desk/owner-desk.py selftest  # desk: storage, buttons, answers
```

## License

MIT. See `LICENSE`.
