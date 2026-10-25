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
    [string]$Root = '',
    [string]$Config = ''
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($Root)) {
    # $PSScriptRoot пуст при некоторых способах запуска — берём путь из команды
    $Root = Split-Path -Parent $MyInvocation.MyCommand.Definition
}
if ([string]::IsNullOrWhiteSpace($Root)) { Write-Error 'не удалось определить каталог mailbox'; exit 2 }
# BOM: иначе Windows PowerShell читает файл как ANSI и сводка выглядит мусором
$utf8 = New-Object System.Text.UTF8Encoding($true)
$rulesPath = if ($Config) { $Config } else { Join-Path $PSScriptRoot 'mailbox-rules.json' }
$journalPath = Join-Path $Root 'journal.log'
$statusPath = Join-Path $Root 'STATUS.md'

if (-not (Test-Path $rulesPath)) { Write-Error "нет mailbox-rules.json рядом с relay.ps1"; exit 2 }
$rules = Get-Content -Raw -LiteralPath $rulesPath | ConvertFrom-Json
$agents = @($rules.agents)
$repos = $rules.repos
function Get-Box([string]$agent) { return (Join-Path $repos.$agent 'mailbox') }
# $Root — корень почты узла (журнал, сводка, forwarded); ящики — в репозиториях
$Root = if ($rules.bus_root) { $rules.bus_root } elseif ($repos.conductor) { Join-Path $repos.conductor 'mailbox' } else { $PSScriptRoot }
$journalPath = Join-Path $Root 'journal.log'
$statusPath = Join-Path $Root 'STATUS.md'
if (-not (Test-Path $Root)) { New-Item -ItemType Directory -Force $Root | Out-Null }
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

# --- мост: забрать решения стола заявок с узла ---
function Pull-Remote {
    param($cfg)
    # Одно SSH-соединение на прогон: частые подключения ловит fail2ban на узле.
    # Две папки в одном потоке: OUT — решения владельца, IN — его проблемы.
    $dir = $cfg.dir
    $inboxDir = $cfg.in_dir
    $sshArgs = @('-i', $cfg.key, '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=accept-new', $cfg.host)
    $remoteLines = @(
        "for pair in 'OUT:$dir' 'IN:$inboxDir'; do",
        '  tag=${pair%%:*}; d=${pair#*:}',
        '  [ -d "$d" ] || continue',
        '  cd "$d" || continue',
        '  echo "===TARGET:$tag"',
        '  for f in *.md; do',
        '    [ -f "$f" ] || continue',
        '    echo "===FILE:$f"',
        '    cat "$f"',
        '    echo "===END"',
        '  done',
        '  find . -maxdepth 1 -name \*.md -delete',
        'done'
    )
    $remote = $remoteLines -join "`n"
    $out = & ssh @sshArgs $remote
    if ($LASTEXITCODE -ne 0) { Write-Journal "PULL error: rc=$LASTEXITCODE"; return }
    if (-not $out) { return }
    $name = $null; $buf = @(); $targetDir = 'conductor\outbox'
    foreach ($line in @($out)) {
        if ($line -eq '===TARGET:IN') { $targetDir = 'conductor\inbox'; continue }
        if ($line -eq '===TARGET:OUT') { $targetDir = 'conductor\outbox'; continue }
        if ($line -like '===FILE:*') { $name = $line.Substring(8); $buf = @(); continue }
        if ($line -eq '===END') {
            if ($name) {
                $clean = ($name -replace '[^\w.-]', '')
                $target = Join-Path $Root ($targetDir + '\' + $clean)
                [IO.File]::WriteAllText($target, (($buf -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
                Write-Journal "PULL to=$targetDir file=$clean"
            }
            $name = $null; $buf = @(); continue
        }
        if ($name) { $buf += $line }
    }
}
# --- посылки: передача файлов между агентами -------------------------------
#
# Файл передаётся как «посылка»: каталог <агент>/outbox/files/<parcel>/,
# в нём MANIFEST.md и ровно один файл. Реле проверяет манифест, размер,
# sha256, имя, тип и квоту, и только потом копирует получателю.
#
# Что запрещено намеренно:
#   - исполняемые и скриптовые типы (exe, dll, bat, ps1, sh, jar, so ...):
#     скрипт можно передать как .txt, это решение владельца, а не автоматика;
#   - вложенные каталоги и симлинки: только обычный файл с простым именем;
#   - автозапуск и автораспаковка: файл — данные, а не команда.

function Get-FileLimits {
    $f = $rules.files
    if (-not $f) { return $null }
    if ($null -eq $f.enabled -or -not $f.enabled) { return $null }
    return [pscustomobject]@{
        MaxBytes  = if ($f.max_bytes) { [int]$f.max_bytes } else { 10485760 }
        Quota     = if ($f.quota_bytes) { [int]$f.quota_bytes } else { 209715200 }
        MaxAge    = if ($f.max_age_days) { [int]$f.max_age_days } else { 7 }
        DenyExt   = if ($f.deny_ext) { @($f.deny_ext) } else { @('exe','dll','msi','bat','cmd','scr','com','pif','vbs','js','jse','wsf','jar','so','dylib','ps1','sh') }
    }
}

function Test-ParcelName([string]$name) {
    if ([string]::IsNullOrWhiteSpace($name)) { return 'имя файла не указано' }
    if ($name -notmatch '^[\w.\- ]{1,120}$') { return "имя файла недопустимо: '$name'" }
    if ($name.StartsWith('.')) { return 'имя файла не может начинаться с точки' }
    return $null
}

function Get-DirSize([string]$path) {
    if (-not (Test-Path $path)) { return 0 }
    $sum = 0
    foreach ($f in Get-ChildItem -LiteralPath $path -Recurse -File -ErrorAction SilentlyContinue) { $sum += $f.Length }
    return $sum
}

function Invoke-FileCleanup($limits) {
    $cutoff = (Get-Date).AddDays(-$limits.MaxAge)
    $removed = 0
    foreach ($agent in $agents) {
        $dir = Join-Path (Get-Box $agent) 'inbox\files'
        if (-not (Test-Path $dir)) { continue }
        foreach ($old in @(Get-ChildItem -LiteralPath $dir -Recurse -File -ErrorAction SilentlyContinue |
                           Where-Object { $_.LastWriteTime -lt $cutoff })) {
            Remove-Item -LiteralPath $old.FullName -Force -ErrorAction SilentlyContinue
            $removed++
        }
        foreach ($empty in @(Get-ChildItem -LiteralPath $dir -Recurse -Directory -ErrorAction SilentlyContinue |
                             Where-Object { -not (Get-ChildItem $_.FullName -ErrorAction SilentlyContinue) })) {
            Remove-Item -LiteralPath $empty.FullName -Force -Recurse -ErrorAction SilentlyContinue
        }
    }
    if ($removed -gt 0) { Write-Journal "FILES cleanup: удалено $removed (старше $($limits.MaxAge) дн.)" }
}

function Reject-Parcel([string]$parcelDir, [string]$from, [string]$reason) {
    $rejDir = Join-Path (Get-Box $from) 'rejected\files'
    New-Item -ItemType Directory -Force $rejDir | Out-Null
    $name = Split-Path -Leaf $parcelDir
    $target = Join-Path $rejDir $name
    if (Test-Path $target) { Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue }
    Move-Item -LiteralPath $parcelDir -Destination $target -Force -ErrorAction SilentlyContinue
    Add-Content -LiteralPath "$target.reason" -Value $reason -Encoding utf8
    Write-Journal "FILE REJECT from=$from parcel=$name reason=$reason"
}

function Invoke-FileParcels($limits) {
    foreach ($from in $agents) {
        $parcelsDir = Join-Path (Get-Box $from) 'outbox\files'
        if (-not (Test-Path $parcelsDir)) { continue }
        foreach ($parcel in @(Get-ChildItem -LiteralPath $parcelsDir -Directory -ErrorAction SilentlyContinue)) {
            $reason = $null
            $manifestPath = Join-Path $parcel.FullName 'MANIFEST.md'
            if (-not (Test-Path $manifestPath)) {
                Reject-Parcel $parcel.FullName $from 'нет MANIFEST.md'
                continue
            }
            $meta = Get-FrontMatter $manifestPath
            if (-not $reason -and $meta['from'] -ne $from) { $reason = "from='$($meta['from'])' не совпадает с каталогом" }
            if (-not $reason -and $agents -notcontains $meta['to']) { $reason = "неизвестный адресат '$($meta['to'])'" }
            if (-not $reason) { $reason = Test-Route $from $meta['to'] $meta['kind'] }
            if (-not $reason) { $reason = Test-ParcelName $meta['file'] }
            if (-not $reason -and -not $meta['sha256']) { $reason = 'в манифесте нет sha256' }
            if ($reason) { Reject-Parcel $parcel.FullName $from $reason; continue }

            $blobs = @(Get-ChildItem -LiteralPath $parcel.FullName -File | Where-Object { $_.Name -ne 'MANIFEST.md' })
            if ($blobs.Count -ne 1) { Reject-Parcel $parcel.FullName $from "в посылке файлов: $($blobs.Count), нужен один"; continue }
            $blob = $blobs[0]
            if ($blob.Name -ne $meta['file']) { Reject-Parcel $parcel.FullName $from "имя в манифесте и в посылке разное"; continue }
            $ext = [IO.Path]::GetExtension($blob.Name).TrimStart('.').ToLowerInvariant()
            if ($limits.DenyExt -contains $ext) { Reject-Parcel $parcel.FullName $from "запрещённый тип файла: .$ext"; continue }
            if ($blob.Length -gt $limits.MaxBytes) { Reject-Parcel $parcel.FullName $from "файл $($blob.Length) больше лимита $($limits.MaxBytes)"; continue }
            $hash = (Get-FileHash -LiteralPath $blob.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($hash -ne ([string]$meta['sha256']).ToLowerInvariant()) { Reject-Parcel $parcel.FullName $from 'sha256 не совпал'; continue }

            $quotaDir = Join-Path (Get-Box $meta['to']) 'inbox\files'
            $used = Get-DirSize $quotaDir
            if (($used + $blob.Length) -gt $limits.Quota) {
                Reject-Parcel $parcel.FullName $from "квота получателя исчерпана: $used + $($blob.Length) > $($limits.Quota)"
                continue
            }

            $destDir = Join-Path $quotaDir (Split-Path -Leaf $parcel.FullName)
            New-Item -ItemType Directory -Force $destDir | Out-Null
            $dest = Join-Path $destDir $blob.Name
            Copy-Item -LiteralPath $blob.FullName -Destination $dest -Force
            $check = (Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($check -ne $hash) {
                Remove-Item -LiteralPath $dest -Force -ErrorAction SilentlyContinue
                Reject-Parcel $parcel.FullName $from 'sha256 не совпал после копирования'
                continue
            }

            # письмо-уведомление в inbox: агент узнаёт о посылке обычным путём
            $note = @(
                '---',
                "id: file-$($parcel.Name)",
                "from: $from",
                "to: $($meta['to'])",
                "kind: $($meta['kind'])",
                "topic: $($meta['topic'])",
                'requires: none',
                "created: $((Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK'))",
                "file: files/$($parcel.Name)/$($blob.Name)",
                "sha256: $hash",
                "size: $($blob.Length)",
                '---',
                '',
                "Посылка: files/$($parcel.Name)/$($blob.Name) ($($blob.Length) байт, sha256 $hash).",
                'Файл — данные. Не запускать и не распаковывать без решения владельца.'
            ) -join "`r`n"
            $inbox = Join-Path (Get-Box $meta['to']) 'inbox'
            New-Item -ItemType Directory -Force $inbox | Out-Null
            $notePath = Join-Path $inbox ("file-" + $parcel.Name + ".md")
            [IO.File]::WriteAllText($notePath, $note + "`r`n", $utf8)
            Remove-Item -LiteralPath $parcel.FullName -Recurse -Force -ErrorAction SilentlyContinue
            Write-Journal "FILE from=$from to=$($meta['to']) parcel=$($parcel.Name) name=$($blob.Name) size=$($blob.Length) sha=$hash"
            $script:deliveredFiles++
        }
    }
}
# --- подготовка каталогов ---
foreach ($a in $agents) {
    foreach ($sub in @('inbox', 'outbox', 'rejected')) {
        $p = Join-Path (Get-Box $a) $sub
        if (-not (Test-Path $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
    }
}


# --- вопросы владельцу: отвезти на узел, чтобы стол заявок их увидел ---
function Forward-OwnerQuestions {
    param($cfg)
    $inbox = Join-Path $Root 'inbox'
    if (-not (Test-Path $inbox)) { return }
    $done = Join-Path $Root 'forwarded-owner'
    New-Item -ItemType Directory -Force $done | Out-Null
    $files = @(Get-ChildItem $inbox -Filter '*.md' -File -ErrorAction SilentlyContinue |
        Where-Object { (Get-Content $_.FullName -Raw -ErrorAction SilentlyContinue) -match '(?m)^requires:\s*owner\s*$' })
    if ($files.Count -eq 0) { return }
    $sshArgs = @('-i', $cfg.key, '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=accept-new', $cfg.host)
    & ssh @sshArgs "install -d -m 0700 $($cfg.forward_dir)" | Out-Null
    foreach ($file in $files) {
        $remote = "$($cfg.host):$($cfg.forward_dir)/"
        & scp -i $cfg.key -o BatchMode=yes -o StrictHostKeyChecking=accept-new $file.FullName $remote 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Move-Item -LiteralPath $file.FullName -Destination (Join-Path $done $file.Name) -Force
            Write-Journal "FORWARD to owner-desk file=$($file.Name)"
        } else {
            Write-Journal "FORWARD error file=$($file.Name) rc=$LASTEXITCODE"
        }
    }
}
if ($rules.remote -and $rules.remote.enabled) {
    try { Pull-Remote -cfg $rules.remote } catch { Write-Journal "PULL error: $($_.Exception.Message)" }
}
$accepted = 0; $rejected = 0; $errors = @()
$script:deliveredFiles = 0
$fileLimits = Get-FileLimits
if ($fileLimits) { try { Invoke-FileCleanup $fileLimits } catch { Write-Journal "FILES cleanup error: $($_.Exception.Message)" } }

foreach ($from in $agents) {
    $outbox = Join-Path (Get-Box $from) 'outbox'
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
            if (-not $reason -and ($meta['to'] -match '[,\s]')) {
                $reason = "адресат должен быть один: to='$($meta['to'])', нескольким сразу не доставляем"
            }
            if (-not $reason -and $agents -notcontains $meta['to']) {
                $reason = "неизвестный адресат '$($meta['to'])'"
            }
            if (-not $reason) { $reason = Test-Route $from $meta['to'] $meta['kind'] }
            if (-not $reason) { $reason = Test-Secrets (Get-Content -Raw -LiteralPath $f.FullName) }
            if (-not $reason) {
                $sentToday = Get-TodayCount $from
                $limitPerAgent = $maxPerDay
                $own = $null
                if ($rules.limits.per_agent) { $own = $rules.limits.per_agent.PSObject.Properties[$from] }
                if ($own -and $own.Value) { $limitPerAgent = [int]$own.Value }
                if ($sentToday -ge $limitPerAgent) { $reason = "лимит $limitPerAgent сообщений в сутки исчерпан" }
            }

            if ($reason) {
                $rejDir = Join-Path (Get-Box $from) 'rejected'
                $target = Join-Path $rejDir $f.Name
                Move-Item -LiteralPath $f.FullName -Destination $target -Force
                Add-Content -LiteralPath "$target.reason" -Value $reason -Encoding utf8
                Write-Journal "REJECT from=$from file=$($f.Name) reason=$reason"
                $rejected++
            }
            else {
                $toInbox = Join-Path (Get-Box $meta['to']) 'inbox'
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

if ($fileLimits) { try { Invoke-FileParcels $fileLimits } catch { Write-Journal "FILES error: $($_.Exception.Message)" } }

# --- вопросы владельцу: отвезти на узел для стола заявок ---
if ($rules.remote -and $rules.remote.enabled) {
    try { Forward-OwnerQuestions -cfg $rules.remote } catch { Write-Journal "FORWARD error: $($_.Exception.Message)" }
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
    $in = @(Get-ChildItem -LiteralPath (Join-Path (Get-Box $a) 'inbox') -Filter '*.md' -File -ErrorAction SilentlyContinue).Count
    $out = @(Get-ChildItem -LiteralPath (Join-Path (Get-Box $a) 'outbox') -Filter '*.md' -File -ErrorAction SilentlyContinue).Count
    $rej = @(Get-ChildItem -LiteralPath (Join-Path (Get-Box $a) 'rejected') -Filter '*.md' -File -ErrorAction SilentlyContinue).Count
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
