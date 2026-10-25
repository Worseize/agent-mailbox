# test-files.ps1 — проверка шины с ящиками в репозиториях.
# Строит временные «репозитории», гоняет relay.ps1 с их конфигом.
# Живую почту не трогает.

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$relay = Join-Path $here 'relay.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) ('bus-repo-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$checks = 0
$failed = 0

function Assert($condition, $message) {
    if ($condition) { $script:checks++; Write-Output "  [ok]   $message" }
    else { $script:failed++; Write-Output "  [FAIL] $message" }
}

function New-Parcel([string]$fromRepo, [string]$from, [string]$to, [string]$name, [int]$size, [hashtable]$opts = @{}) {
    $parcelId = 'p' + ([guid]::NewGuid().ToString('N').Substring(0, 6))
    $dir = Join-Path $fromRepo "mailbox\outbox\files\$parcelId"
    New-Item -ItemType Directory -Force $dir | Out-Null
    $blob = Join-Path $dir $name
    $bytes = New-Object byte[] $size
    (New-Object Random 7).NextBytes($bytes)
    [IO.File]::WriteAllBytes($blob, $bytes)
    if ($opts.ContainsKey('extra')) { [IO.File]::WriteAllBytes((Join-Path $dir 'second.txt'), [byte[]](1, 2, 3)) }
    $sha = if ($opts.ContainsKey('sha')) { $opts['sha'] } else { (Get-FileHash -LiteralPath $blob -Algorithm SHA256).Hash.ToLowerInvariant() }
    $manifestName = if ($opts.ContainsKey('manifestName')) { $opts['manifestName'] } else { $name }
    $manifest = @(
        '---', "id: $parcelId", "from: $from", "to: $to", 'kind: note', 'topic: parcel',
        'requires: none', "created: $((Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK'))",
        "file: $manifestName", "sha256: $sha", "size: $size", '---', '', 'тестовая посылка'
    ) -join "`r`n"
    [IO.File]::WriteAllText((Join-Path $dir 'MANIFEST.md'), $manifest + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
    return $parcelId
}

try {
    $repos = @{}
    foreach ($a in @('node', 'project-a', 'project-b')) {
        $repo = Join-Path $root $a
        $repos[$a] = $repo
        foreach ($d in @('inbox', 'outbox', 'rejected')) { New-Item -ItemType Directory -Force (Join-Path $repo "mailbox\$d") | Out-Null }
    }
    $config = @{
        version = 1
        agents  = @('node', 'project-a', 'project-b')
        repos   = $repos
        limits  = @{ max_bytes = 16384; max_per_day_per_agent = 100; max_replies_per_topic_per_day = 3 }
        routes  = @(
            @{ from = 'node'; to = 'project-a'; kinds = @('note', 'request', 'report') },
            @{ from = 'node'; to = 'project-b'; kinds = @('note', 'request', 'report') },
            @{ from = 'project-a'; to = 'node'; kinds = @('note', 'request', 'report') }
        )
        bus_root = Join-Path $root 'bus'
        files   = @{
            enabled = $true; max_bytes = 1000; quota_bytes = 260; max_age_days = 7
            deny_ext = @('exe', 'ps1', 'sh')
        }
    }
    $configPath = Join-Path $root 'config.json'
    [IO.File]::WriteAllText($configPath, ($config | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))

    function Run-Relay { & $relay -Config $configPath | Out-Null }

    # 1. посылка между репозиториями
    $p1 = New-Parcel $repos['node'] 'node' 'project-a' 'report.pdf' 100
    Run-Relay
    Assert (Test-Path (Join-Path $repos['project-a'] "mailbox\inbox\files\$p1\report.pdf")) 'файл доставлен в репозиторий получателя'
    Assert (Test-Path (Join-Path $repos['project-a'] "mailbox\inbox\file-$p1.md")) 'получатель получил письмо'
    Assert (-not (Test-Path (Join-Path $repos['node'] "mailbox\outbox\files\$p1"))) 'исходная посылка убрана'

    # 2. письмо между репозиториями
    $msg = @('---', 'id: m1', 'from: node', 'to: project-a', 'kind: note', 'topic: hi', 'requires: none',
             "created: $((Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK'))", '---', '', 'привет') -join "`r`n"
    [IO.File]::WriteAllText((Join-Path $repos['node'] 'mailbox\outbox\m1.md'), $msg + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
    Run-Relay
    Assert (@(Get-ChildItem (Join-Path $repos['project-a'] 'mailbox\inbox') -Filter '*hi*' -ErrorAction SilentlyContinue).Count -ge 1) 'письмо доставлено'

    # 3. запрещённый маршрут
    $bad = @('---', 'id: m2', 'from: project-a', 'to: project-b', 'kind: note', 'topic: bad', 'requires: none',
             "created: $((Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK'))", '---', '', 'нельзя') -join "`r`n"
    [IO.File]::WriteAllText((Join-Path $repos['project-a'] 'mailbox\outbox\m2.md'), $bad + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
    Run-Relay
    Assert (Test-Path (Join-Path $repos['project-a'] 'mailbox\rejected\m2.md.reason')) 'боковой маршрут отклонён'

    # 4. exe
    $p4 = New-Parcel $repos['node'] 'node' 'project-a' 'virus.exe' 40
    Run-Relay
    Assert (Test-Path (Join-Path $repos['node'] "mailbox\rejected\files\$p4.reason")) 'exe отклонён'

    # 5. чужой from в манифесте
    $p5 = New-Parcel $repos['node'] 'project-a' 'project-a' 'spoof.txt' 20
    Run-Relay
    Assert ((Get-Content (Join-Path $repos['node'] "mailbox\rejected\files\$p5.reason") -Raw) -match 'не совпадает') 'подделка отправителя отклонена'

    Write-Output ''
    if ($failed -gt 0) { Write-Output "BUS TEST: провалено $failed из $($checks + $failed)"; exit 1 }
    Write-Output "BUS TEST: OK ($checks проверок)"
    exit 0
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
