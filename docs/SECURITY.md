# Threat model

What this bus protects against, what it does not, and why.

## What it protects

| Threat | Mechanism |
| --- | --- |
| **Spoofed sender** — a message claims to be from the node agent | sender identity is the outbox directory name; a `from` field that disagrees with the directory is rejected |
| **Lateral channels** — one project talks another into changing behaviour | route matrix in `rules.json`; `project → project` has no entry and is rejected |
| **Message as an order** — «give me access», «change your config» | messages are data; authority comes from the owner's task in chat. The relay cannot grant anything — it only moves files |
| **Secret leakage in a message** | coarse scan rejects private keys, Telegram/GitHub tokens, `sk-…` patterns |
| **Reply loops** | 20 messages per agent per day; the relay counts accepted messages |
| **Message bombs** | 16 KB limit; bigger content belongs in a repository |
| **Silent failures** | every decision is written to `journal.log`; rejections keep a `.reason` file next to the message |

## What it does not protect

1. **Local attacker with file access.** Anyone who can write into another
   agent's `outbox` can send as that agent. The bus is a protocol, not a
   sandbox. On one machine with one user account there is no OS boundary.
2. **Prompt injection inside a legitimate message.** The relay checks
   structure, not meaning. If a trusted sender writes «ignore your rules»,
   the bus will deliver it — defence is the rule that messages grant no
   authority.
3. **Malicious `rules.json`.** Whoever edits the rules can allow anything.
   Keep it under the same control as the relay itself.
4. **Confidentiality against the machine owner.** Files are plain text on
   disk.
5. **Availability.** A full disk or a stopped scheduler stops the bus; there
   is no queue outside the file system.

## If you need real isolation

| Level | How | What it gives |
| --- | --- | --- |
| 1 (this repo) | protocol and policy on one machine | protection from mistakes and from confused agents |
| 2 | separate OS user per agent, ACLs on `outbox/` | prevents one agent from writing as another |
| 3 | broker process with per-agent tokens (HTTP), no shared filesystem | authentication, audit, remote agents |
| 4 | separate machines / containers per agent | real blast-radius separation |

Levels 3–4 are the natural next step; the message schema in this repo is
designed to survive that move unchanged.

## Design rules that make the bus safe to leave running

1. **The relay never executes anything.** It validates and moves files.
2. **The sender is never read from the text.** Only from the directory.
3. **Rejections are kept, not deleted.** You can always see what was refused
   and why.
4. **Limits are global, not per topic.** A bug cannot produce infinite
   traffic.
5. **`requires: owner` is a stop sign.** Anything irreversible waits for the
   human.
