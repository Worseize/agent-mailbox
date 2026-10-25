<#
  relay.ps1 — шина сообщений между агентами (M1: файлы + правила).

  Что делает:
    1. Читает mailbox/<отправитель>/outbox/*.md
    2. Проверяет шапку сообщения (from, to, kind, topic, requires, created)
    3. Сверяет с rules.json: маршрут разрешён, тип разрешён, размер, лимиты
    4. Переносит в mailbox/<получатель>/inbox/, пишет journal.log
    5. Отклонённые — в mailbox/<отправитель>/rejected/ с причиной
    6. Обновляет STATUS.md для владельца

  Запуск: pwsh -File relay.ps1  (или по расписанию)
  Код возврата: 0 — ошибок нет, 1 — были отклонения.
#>

[CmdletBinding()]
param(
    [string]$Root = ''
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($Root)) {
    # $PSScriptRoot пуст при некоторых способах запуска — берём путь из команды
    $Root = Split-Path -Parent $MyInvocation.MyCommand.Definition
}
if ([string]::IsNullOrWhiteSpace($Root)) { Write-Error 'не удалось определить каталог mailbox'; exit 2 }
# BOM: иначе Windows PowerShell читает файл как ANSI и сводка выглядит мусором
$utf8 = New-Object System.Text.UTF8Encoding($true)
$rulesPath = Join-Path $Root 'rules.json'
$journalPath = Join-Path $Root 'journal.log'
$statusPath = Join-Path $Root 'STATUS.md'

if (-not (Test-Path $rulesPath)) { Write-Error "нет rules.json в $Root"; exit 2 }
$rules = Get-Content -Raw -LiteralPath $rulesPath | ConvertFrom-Json
$agents = @($rules.agents)
$maxBytes = [int]$rules.limits.max_bytes
$maxPerDay = [int]$rules.limits.max_per_day_per_agent

function Write-Journal([string]$line) {
    $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    Add-Content -LiteralPath $journalPath -Value "$stamp  $line" -Encoding utf8
}

function Get-FrontMatter([string]$path) {
    $lines = Get-Content -LiteralPath $path
    if ($lines.Count -lt 3 -or $lines[0].Trim() -ne '---') { return $null }
    $end = -1
    for ($i = 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i].Trim() -eq '---') { $end = $i; break }
    }
    if ($end -lt 0) { return $null }
    $meta = @{}
    for ($i = 1; $i -lt $end; $i++) {
        $line = $lines[$i]
        $idx = $line.IndexOf(':')
        if ($idx -lt 1) { continue }
        $key = $line.Substring(0, $idx).Trim()
        $val = $line.Substring($idx + 1).Trim()
        $meta[$key] = $val
    }
    return $meta
}

function Test-Route([string]$from, [string]$to, [string]$kind) {
    if ($from -eq $to) { return "нельзя писать самому себе" }
    foreach ($r in $rules.routes) {
        if ($r.from -ne $from) { continue }
        if ($r.to -ne '*' -and $r.to -ne $to) { continue }
        if ($r.kinds -notcontains $kind) { continue }
        return $null
    }
    return "маршрут $from -> $to ($kind) запрещён таблицей"
}

function Test-Secrets([string]$text) {
    if ($text -match 'BEGIN [A-Z ]*PRIVATE KEY') { return 'похоже на приватный ключ' }
    if ($text -match '\b\d{8,10}:[A-Za-z0-9_-]{35}\b') { return 'похоже на токен Telegram' }
    if ($text -match '\bgh[pousr]_[A-Za-z0-9]{20,}\b') { return 'похоже на GitHub-токен' }
    if ($text -match '\bsk-[A-Za-z0-9]{20,}\b') { return 'похоже на API-ключ' }
    return $null
}

function Get-TodayCount([string]$from) {
    if (-not (Test-Path $journalPath)) { return 0 }
    $today = (Get-Date).ToString('yyyy-MM-dd')
    $count = 0
    foreach ($l in Get-Content -LiteralPath $journalPath) {
        if ($l -like "$today*" -and $l -like "*ACCEPT from=$from*") { $count++ }
    }
    return $count
}

# --- подготовка каталогов ---
foreach ($a in $agents) {
    foreach ($sub in @('inbox', 'outbox', 'rejected')) {
        $p = Join-Path $Root (Join-Path $a $sub)
        if (-not (Test-Path $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
    }
}

$accepted = 0; $rejected = 0; $errors = @()

foreach ($from in $agents) {
    $outbox = Join-Path $Root (Join-Path $from 'outbox')
    $files = @(Get-ChildItem -LiteralPath $outbox -Filter '*.md' -File -ErrorAction SilentlyContinue | Sort-Object Name)
    foreach ($f in $files) {
        $reason = $null
        try {
            if ($f.Length -gt $maxBytes) { $reason = "размер $($f.Length) больше лимита $maxBytes" }
            if (-not $reason) {
                $meta = Get-FrontMatter $f.FullName
                if ($null -eq $meta) { $reason = 'нет шапки --- ... ---' }
            }
            if (-not $reason) {
                foreach ($k in @('from', 'to', 'kind', 'topic', 'requires', 'created')) {
                    if (-not $meta.ContainsKey($k) -or [string]::IsNullOrWhiteSpace($meta[$k])) {
                        $reason = "не хватает поля $k"
                        break
                    }
                }
            }
            if (-not $reason -and $meta['from'] -ne $from) {
                $reason = "from='$($meta['from'])' не совпадает с каталогом '$from'"
            }
            if (-not $reason -and $agents -notcontains $meta['to']) {
                $reason = "неизвестный адресат '$($meta['to'])'"
            }
            if (-not $reason) { $reason = Test-Route $from $meta['to'] $meta['kind'] }
            if (-not $reason) { $reason = Test-Secrets (Get-Content -Raw -LiteralPath $f.FullName) }
            if (-not $reason) {
                $sentToday = Get-TodayCount $from
                if ($sentToday -ge $maxPerDay) { $reason = "лимит $maxPerDay сообщений в сутки исчерпан" }
            }

            if ($reason) {
                $rejDir = Join-Path $Root (Join-Path $from 'rejected')
                $target = Join-Path $rejDir $f.Name
                Move-Item -LiteralPath $f.FullName -Destination $target -Force
                Add-Content -LiteralPath "$target.reason" -Value $reason -Encoding utf8
                Write-Journal "REJECT from=$from file=$($f.Name) reason=$reason"
                $rejected++
            }
            else {
                $toInbox = Join-Path $Root (Join-Path $meta['to'] 'inbox')
                $name = "$((Get-Date).ToString('yyyyMMdd-HHmmss'))-$($meta['topic'])-$($meta['id']).md"
                $name = $name -replace '[^A-Za-z0-9._-]', '-'
                Move-Item -LiteralPath $f.FullName -Destination (Join-Path $toInbox $name) -Force
                Write-Journal "ACCEPT from=$from to=$($meta['to']) topic=$($meta['topic']) kind=$($meta['kind']) requires=$($meta['requires']) file=$name"
                $accepted++
            }
        }
        catch {
            $errors += "$($f.Name): $($_.Exception.Message)"
            Write-Journal "ERROR from=$from file=$($f.Name) err=$($_.Exception.Message)"
        }
    }
}

# --- сводка для владельца ---
$lines = @()
$lines += "# Почта агентов: статус"
$lines += ""
$lines += "Обновлено: $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))"
$lines += ""
$lines += "| Агент | Входящих | Исходящих | Отклонённых |"
$lines += "| --- | --- | --- | --- |"
foreach ($a in $agents) {
    $in = @(Get-ChildItem -LiteralPath (Join-Path $Root "$a\inbox") -Filter '*.md' -File -ErrorAction SilentlyContinue).Count
    $out = @(Get-ChildItem -LiteralPath (Join-Path $Root "$a\outbox") -Filter '*.md' -File -ErrorAction SilentlyContinue).Count
    $rej = @(Get-ChildItem -LiteralPath (Join-Path $Root "$a\rejected") -Filter '*.md' -File -ErrorAction SilentlyContinue).Count
    $lines += "| $a | $in | $out | $rej |"
}
$lines += ""
$lines += "Принято за прогон: $accepted, отклонено: $rejected"
if ($errors.Count -gt 0) {
    $lines += ""
    $lines += "Ошибки:"
    foreach ($e in $errors) { $lines += "- $e" }
}
$lines += ""
$lines += "Правила: ``rules.json``. Журнал: ``journal.log``."
[IO.File]::WriteAllText($statusPath, ($lines -join "`r`n"), $utf8)

if ($rejected -gt 0 -or $errors.Count -gt 0) { exit 1 }
exit 0
