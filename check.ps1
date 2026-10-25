# check.ps1 — есть ли работа в почте агента. Модель не вызывает.
#
#   powershell -File check.ps1 -Agent bot-agent
#
# Код 0 — EMPTY: писем нет.
# Код 1 — PENDING n: есть непрочитанное (печатает имена).
# Код 2 — ошибка конфигурации (нет агента в mailbox-rules.json или нет каталога).
#
# Ящик каждого агента лежит в его собственном репозитории: <repo>/mailbox/inbox.
# Агент не ходит по системе — он читает только свою папку.

param(
    [Parameter(Mandatory = $true)][string]$Agent,
    [string]$Config = ''
)

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($here)) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path }
if ([string]::IsNullOrWhiteSpace($Config)) { $Config = Join-Path $here 'mailbox-rules.json' }

if (-not (Test-Path $Config)) {
    Write-Output "NO-CONFIG $Config"
    exit 2
}
$rules = Get-Content -Raw -LiteralPath $Config | ConvertFrom-Json
$repo = $rules.repos.$Agent
if ([string]::IsNullOrWhiteSpace($repo)) {
    Write-Output "NO-AGENT $Agent"
    exit 2
}
$inbox = Join-Path (Join-Path $repo 'mailbox') 'inbox'
if (-not (Test-Path $inbox)) {
    Write-Output "NO-INBOX $inbox"
    exit 2
}

$files = @(Get-ChildItem -LiteralPath $inbox -Filter '*.md' -File -ErrorAction SilentlyContinue)
if ($files.Count -eq 0) {
    Write-Output 'EMPTY'
    exit 0
}

Write-Output ("PENDING {0}" -f $files.Count)
$files | Sort-Object LastWriteTime | Select-Object -First 20 | ForEach-Object { Write-Output ("  " + $_.Name) }
if ($files.Count -gt 20) { Write-Output ("  ... ещё {0}" -f ($files.Count - 20)) }
exit 1
