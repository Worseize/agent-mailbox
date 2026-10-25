# Local test of the published template

Run before pushing to GitHub, so the repository does not ship broken code.

```powershell
# from the repository root
Copy-Item rules.example.json rules.json
New-Item -ItemType Directory -Force node\outbox, project-a\outbox, project-a\inbox | Out-Null

# accepted case
Copy-Item examples/request.md node\outbox\0001.md
# rejected case: project -> project
Copy-Item examples/rejected-lateral.md project-a\outbox\0002.md

powershell -NoProfile -ExecutionPolicy Bypass -File relay.ps1
Get-ChildItem project-a\inbox
Get-Content journal.log
Get-ChildItem project-a\rejected
```

Expected:

```
project-a\inbox    -> one file (request from node)
journal.log        -> ACCEPT ... topic=deploy ; REJECT ... project-a -> project-b
project-a\rejected -> rejected-lateral.md + .reason
STATUS.md          -> counts per agent
```

Clean up after the check:

```powershell
Remove-Item -Recurse -Force node, project-a, project-b, public-site, journal.log, STATUS.md, rules.json
```

## What is stripped from this template

The original implementation runs a real node with real projects. For
publication the following was removed or replaced:

| Removed | Replaced with |
| --- | --- |
| machine paths (`C:\Users\...`, `/srv/...`) | `C:\path\to\relay.ps1`, relative paths |
| real agent names | `node`, `project-a`, `project-b`, `public-site` |
| domains, IP addresses, bot usernames | none — the template has no network |
| host descriptions, client counts, product data | none |
| tokens and secrets | none — never were in the bus |
| links to private repositories | none |

`relay.ps1` itself contained no personal data: its agent list comes from
`rules.json`, which is now `rules.example.json`.
