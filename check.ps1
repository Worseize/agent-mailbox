# Проверка почты без модели
#
#   powershell -File check.ps1 -Agent bot-agent
#
# Код 0  — в inbox ничего нет (EMPTY). Агент может ответить «idle» и не тратить
#          токены на чтение сообщений.
# Код 1  — есть непрочитанное: печатает имена файлов, агент читает.
# Код 2  — ошибка запуска (нет каталога и т.п.).
#
# Этот скрипт не вызывает модель и ничего не отправляет: он только отвечает
# на вопрос «есть ли работа». Ставится первым шагом в расписании агента.

param(
    [Parameter(Mandatory = $true)][string]$Agent,
    [string]$Root = ''
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($Root)) {
    $Root = $PSScriptRoot
    if ([string]::IsNullOrWhiteSpace($Root)) { $Root = Split-Path -Parent $MyInvocation.MyCommand.Path }
}
$inbox = Join-Path $Root (Join-Path $Agent 'inbox')

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
