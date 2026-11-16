# Сборщик логов MeruDevTools для Xiaomi Mi 12 Lite (taoyao), версия 0.20
# SPDX-License-Identifier: LicenseRef-MeruDevTools
# © 2026 Meddax (meru_ii) и команда MeruDevTools. Лицензия: LICENSE.txt
# Windows part, started by run-check.bat: finds adb, waits for the phone,
# checks root, pushes taoyao-check.sh to /data/local/tmp, runs it, waits for a
# check that goes on in the background on the phone, then fetches and
# verifies the archive. Windows PowerShell 5.1 (no PowerShell 7 syntax),
# UTF-8 with BOM, CRLF line ends.
# adb runs through System.Diagnostics.Process with our own Windows argument
# quoting (PowerShell 5.1 does not escape quotes for native commands). Every
# argument is ASCII; local files are relative names in the process working
# directory, so the folder may hold spaces, ( ) & [ ] and Cyrillic. Commands
# sent to the phone hold no quote character except the su -c '...' wrapper.
# Exit codes: 0 done, 10 failure (explained on screen), 11 cancelled.
#Requires -Version 5.1
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$Ver = '0.20'
$Brand = 'Сборщик логов MeruDevTools для Xiaomi Mi 12 Lite (taoyao)'
$RC_OK = 0; $RC_FAIL = 10; $RC_CANCEL = 11
$Launcher = 'run-check.bat'
$PtUrl = 'https://developer.android.com/tools/releases/platform-tools'
$PtTerms = 'https://developer.android.com/studio/terms'
$PtBase = 'https://dl.google.com/android/repository'
$Dlt = '/data/local/tmp'
$Utf8 = New-Object System.Text.UTF8Encoding($false)
$IsWin = ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT)
# (PowerShell 7 outside Windows: only for tests)
$IsMac = $false
if (-not $IsWin) { try { $IsMac = [bool](Get-Variable -Name IsMacOS -ValueOnly -ErrorAction SilentlyContinue) } catch { } }
$Here = $PSScriptRoot
if (-not $Here) { try { $Here = Split-Path -Parent $MyInvocation.MyCommand.Path } catch { $Here = (Get-Location).ProviderPath } }
$Argv = @($args)

$Script:LogPath = $null
$Script:LogBuf = New-Object System.Text.StringBuilder
$Script:Serials = New-Object 'System.Collections.Generic.List[string]'
$Script:MaskRules = @()
$Script:Out = $null; $Script:Base = $null
$Script:Adb = $null; $Script:AdbVer = ''
$Script:Serial = $null; $Script:AdbRoot = $false; $Script:AdbProc = $null
$Script:Phase = ''; $Script:Menu = $false; $Script:KeysOk = $false
$Script:Mode = ''; $Script:Words = ''; $Script:ChgMin = 0; $Script:Bg = $false
$Script:Start = [long]0; $Script:BootId = ''
$Script:RunIds = New-Object 'System.Collections.Generic.List[string]'
$Script:RemoteRc = $null; $Script:RunSecs = 0
$Script:Fetched = $false; $Script:Extra = ''; $Script:ShownPhone = $false
$Script:Archive = ''; $Script:ArchSize = ''; $Script:ArchMtime = [long]0
$Script:ExitCode = 0; $Script:Lock = $null; $Script:LockPath = $null
$Script:OldOutEnc = $null; $Script:CtrlCSet = $false
$Script:EnterPressed = $false; $Script:Dc = $null; $Script:VWhat = ''
$Script:DState = 'none'; $Script:DList = ''; $Script:DSer = $null; $Script:MultiPick = $false
$Script:BusyChk = ''; $Script:BusyChkT = [long]0; $Script:ChgAlive = $false; $Script:ChgPidV = ''
$Script:ChgStart = [long]0; $Script:ChgM = ''; $Script:ChgPf = $false; $Script:PNow = [long]0
$Script:DoneNote = ''; $Script:PrevSeen = $false
$Script:FRes = ''; $Script:FReason = ''; $Script:Rebooted = $false
$Script:PtStage = $null; $Script:PtStage2 = $null; $Script:PtJob = $null; $Script:PtErr = ''; $Script:PtVer = ''; $Script:PtZip = ''
$Script:PtOld = $null; $Script:PtDst = $null; $Script:PtKind = ''; $Script:PtWhere = ''; $Script:PtKilled = $false; $Script:PtMoved = 0

########################################################################
# masking for run-check.log: serials, profile folder, user and computer
# name, MAC and IP addresses, e-mail and user@host
function Update-Mask {
  $rules = New-Object System.Collections.ArrayList
  foreach ($s in $Script:Serials) { [void]$rules.Add(@([regex]::Escape($s), '<serial>')) }
  $prof = $env:USERPROFILE
  if (-not $prof) { $prof = $env:HOME }
  if ($prof -and $prof.Length -gt 3) { [void]$rules.Add(@(('(?i)' + [regex]::Escape($prof)), '%USERPROFILE%')) }
  $skip = @('root', 'user', 'admin', 'guest', 'shell', 'home', 'localhost')
  foreach ($n in @($env:USERNAME, $env:USER, $env:COMPUTERNAME, [Environment]::MachineName)) {
    if ($n -and $n.Length -ge 3 -and ($skip -notcontains $n.ToLowerInvariant())) {
      $rep = '<user>'
      if ($n -eq $env:COMPUTERNAME -or $n -eq [Environment]::MachineName) { $rep = '<host>' }
      [void]$rules.Add(@(('(?i)(?<![A-Za-z0-9_])' + [regex]::Escape($n) + '(?![A-Za-z0-9_])'), $rep))
    }
  }
  # (also an address the phone masked only in part, e.g. aa:bb:cc:**:**:ff)
  [void]$rules.Add(@('([0-9A-Fa-f*]{2}:){5}[0-9A-Fa-f*]{2}', 'xx:xx:xx:xx:xx:xx'))
  [void]$rules.Add(@('[A-Za-z0-9._%+-]+@[A-Za-z0-9._-]+', '<user@host>'))
  [void]$rules.Add(@('([0-9]{1,3}\.){3}[0-9]{1,3}', 'ipv4'))
  [void]$rules.Add(@('(?<![0-9A-Za-z:.])[0-9a-fA-F]{1,4}(:[0-9a-fA-F]{0,4}){3,7}(?![0-9A-Za-z:])', 'ipv6'))
  $Script:MaskRules = $rules.ToArray()
}
function Mask-Text([string]$t) {
  if ($null -eq $t) { return '' }
  foreach ($r in $Script:MaskRules) { $t = [regex]::Replace($t, $r[0], $r[1]) }
  return $t
}
function Add-Serial([string]$s) {
  if (-not $s) { return }
  if (-not $Script:Serials.Contains($s)) { $Script:Serials.Add($s); Update-Mask }
}

# Write-Log <text>: into run-check.log only (masked, with the time)
function Write-Log([string]$t, [bool]$raw = $false) {
  $ts = (Get-Date).ToString('HH:mm:ss')
  $sb = New-Object System.Text.StringBuilder
  foreach ($l in ($t -split "`r?`n")) {
    if (-not $raw) { $l = Mask-Text $l }
    [void]$sb.Append($ts + ' ' + $l + "`r`n")
  }
  if ($Script:LogPath) {
    try { [IO.File]::AppendAllText($Script:LogPath, $sb.ToString(), $Utf8) } catch { }
  } else { [void]$Script:LogBuf.Append($sb.ToString()) }
}
# on the screen and in the log
function Say([string]$t) { Write-Host $t; Write-Log $t }
function Step([string]$t) { Write-Host $t -ForegroundColor Cyan; Write-Log $t }
function WarnM([string]$t) { Write-Host $t -ForegroundColor Yellow; Write-Log $t }
function ErrM([string]$t) { Write-Host $t -ForegroundColor Red; Write-Log $t }
function GoodM([string]$t) { Write-Host $t -ForegroundColor Green; Write-Log $t }

########################################################################
# texts
function Show-Help {
  Write-Host ('Использование: {0} [режим]' -f $Launcher)
  Write-Host '  без параметров     меню'
  Write-Host '  prep               подготовка: запись журналов в фоне; потом повторите проблему'
  Write-Host ('                     и запустите {0} ещё раз (пункт 1 меню)' -f $Launcher)
  Write-Host '  hotspot            проверка точки доступа (по подсказке включить и выключить её)'
  Write-Host '  mic                проверка микрофона (по подсказкам)'
  Write-Host '  deep               глубокая проверка (15–40 минут); можно вместе: deep hotspot, deep mic'
  Write-Host '  charge [минуты]    журнал зарядки, по умолчанию 40 минут (от 1 до 1440)'
  Write-Host '  charge-pull        забрать журнал зарядки'
  Write-Host '  help               эта справка'
  Write-Host 'Результаты сохраняются рядом со скриптом, в папке taoyao-check-<дата-время>.'
}
function Show-Menu {
  Write-Host ''
  Write-Host 'Что сделать? Нажмите цифру:'
  Write-Host ''
  Write-Host '  1  Обычная проверка — 5–7 минут. Лучше всего в первые минуты после включения телефона.'
  Write-Host '  2  Подготовка (prep) — включает запись журналов; потом вы повторяете проблему,'
  Write-Host '     и сразу запускается обычная проверка.'
  Write-Host '  3  Точка доступа (hotspot) — проверка раздачи Wi-Fi: по подсказке включить и выключить её.'
  Write-Host '  4  Микрофон (mic) — проверка микрофона по подсказкам.'
  Write-Host '  5  Зарядка (charge) — журнал зарядки; после запуска телефон отключают от компьютера.'
  Write-Host '  6  Забрать журнал зарядки (charge-pull) — когда зарядка закончилась.'
  Write-Host '  7  Глубокая проверка (deep) — 15–40 минут, читает все параметры драйверов.'
  Write-Host ''
  Write-Host '  0  Выход'
}
$T_WaitNone = @'
Телефон не найден. Проверьте:
  • телефон включён и разблокирован;
  • кабель подключён прямо к компьютеру и передаёт данные (некоторые кабели только заряжают);
  • на телефоне включена «Отладка по USB». Как включить: Настройки → «О телефоне» → 7 раз нажмите на «Версия ОС» (HyperOS) или «Номер сборки» (crDroid, Evolution X); затем откройте «Для разработчиков» (HyperOS: «Расширенные настройки» → «Для разработчиков»; crDroid, Evolution X: «Система» → «Для разработчиков») и включите «Отладка по USB»;
  • если телефон всё равно не виден — установите драйвер USB: https://developer.android.com/studio/run/win-usb
'@
$T_Unauth = 'Телефон подключён, но этот компьютер ещё не разрешён. На экране телефона появится вопрос «Разрешить отладку по USB?»: поставьте галочку «Всегда разрешать с этого компьютера» и нажмите «Разрешить» (или «OK»). Если вопроса нет — разблокируйте экран, отключите и снова подключите кабель. Не помогло — в разделе «Для разработчиков» отзовите разрешения отладки по USB (пункт называется примерно «Отозвать авторизацию отладки по USB») и подключите кабель снова.'
$T_Offline = 'Телефон виден, но не отвечает. Отключите и снова подключите кабель. Если не поможет — выключите и снова включите «Отладку по USB».'
$T_Recovery = 'Телефон загружен в режим восстановления (recovery). Перезагрузите его в обычную систему и запустите скрипт снова.'
$T_Sideload = 'Телефон в режиме установки прошивки (sideload). Дождитесь конца установки, перезагрузите телефон в систему и запустите скрипт снова.'
$T_Fastboot = 'Телефон в режиме fastboot. Перезагрузите его в систему: удерживайте кнопку питания около 15 секунд.'
$T_NoPerm = 'Нет прав на доступ к телефону по USB. Отключите и снова подключите кабель и запустите скрипт снова.'
$T_RootHow = @'
  • SukiSU-Ultra или KernelSU: откройте приложение-менеджер → вкладка «Суперпользователь» → в меню ⋮ включите показ системных приложений → найдите «Shell» (com.android.shell) → включите доступ.
  • Magisk: Magisk → Настройки → «Доступ суперпользователя» → «Приложения и ADB».
  • Если root на телефоне нет совсем, собрать логи не получится.
'@
$T_RootNoSu = "Нет прав root для adb (команда su недоступна).`r`n" + $T_RootHow
$T_Priv = 'В архиве скрыты серийные номера, IMEI и ICCID, номера телефонов, MAC- и IP-адреса, имена сетей Wi-Fi, адреса e-mail, имена устройств и номера сотовых вышек, а названия установленных вами приложений заменены на app1, app2… Перед отправкой архив можно просмотреть.'
# the licence notice (clause 2.4 of LICENSE.txt): the first lines of every
# run, before any question and any adb command; on the screen and in
# run-check.log
$T_Lic1 = 'Лицензия MeruDevTools — LICENSE.txt рядом со скриптом. Продолжая, вы принимаете её условия.'
$T_Lic2 = 'License: LICENSE.txt (MeruDevTools License). By continuing you accept it.'
function Show-License {
  Say $T_Lic1; Say $T_Lic2
  if (-not [IO.File]::Exists((Join-Path $Here 'LICENSE.txt'))) { WarnM 'ВНИМАНИЕ: нет файла лицензии LICENSE.txt: архив неполный, скачайте его заново.' }
}

function Get-ModeRu {
  $w = ' ' + $Script:Words + ' '
  if ($w.Contains(' hotspot ')) { return 'точки доступа' }
  if ($w.Contains(' mic ')) { return 'микрофона' }
  return ''
}
function Get-BusyName([string]$m) {
  if ($m -match 'hotspot') { return 'проверка точки доступа' }
  if ($m -match 'mic') { return 'проверка микрофона' }
  if ($m -match 'deep') { return 'глубокая проверка' }
  if ($m -match 'prep') { return 'подготовка' }
  return 'проверка'
}
function Get-Cap([string]$s) { if ($s.Length -gt 0) { return $s.Substring(0, 1).ToUpperInvariant() + $s.Substring(1) } return $s }
function Format-Elapsed([int]$s) {
  if ($s -ge 60) { return ('{0} мин {1} с' -f [int][Math]::Floor($s / 60), ($s % 60)) }
  return ('{0} с' -f $s)
}
function Format-PhoneTime([long]$t, [string]$fmt) {
  try { return [DateTimeOffset]::FromUnixTimeSeconds($t).ToLocalTime().ToString($fmt) } catch { return '?' }
}
function Get-HHmmIn([int]$sec) { return (Get-Date).AddSeconds($sec).ToString('HH:mm') }

########################################################################
# exit, keys, Ctrl-C
function Stop-Run([int]$code) { $Script:ExitCode = $code; throw 'MERUDEV-EXIT' }

function Clear-Keys {
  if (-not $Script:KeysOk) { return }
  try { while ([Console]::KeyAvailable) { [void][Console]::ReadKey($true) } } catch { }
}
function Test-CtrlC($k) {
  return ((($k.Key -eq [ConsoleKey]::C) -and (($k.Modifiers -band [ConsoleModifiers]::Control) -ne 0)) -or ([int]$k.KeyChar -eq 3))
}
# Read-KeyX: ENTER, ESC, INT or the character
function Read-KeyX {
  if (-not $Script:KeysOk) { return 'ESC' }
  $k = [Console]::ReadKey($true)
  if ($k.Key -eq [ConsoleKey]::Enter) { return 'ENTER' }
  if ($k.Key -eq [ConsoleKey]::Escape) { return 'ESC' }
  if (Test-CtrlC $k) { return 'INT' }
  return [string]$k.KeyChar
}
# Get-AnsKind <key from Read-KeyX>: YES (Enter, Д/д, or L/l: the Д key in
# the Latin layout), NO (Esc, Н/н, N/n), AGAIN (Y/y: on a Russian keyboard it
# shares its key with Н, so it could mean either), INT (Ctrl+C) or OTHER
function Get-AnsKind([string]$k) {
  if ($k -eq 'ENTER' -or @('Д', 'д', 'L', 'l') -ccontains $k) { return 'YES' }
  if ($k -eq 'ESC' -or @('Н', 'н', 'N', 'n') -ccontains $k) { return 'NO' }
  if ($k -eq 'INT') { return 'INT' }
  if (@('Y', 'y') -ccontains $k) { return 'AGAIN' }
  return 'OTHER'
}
# Read-Answer <default> [yes word] [no word]: 'yes', 'no' or 'int' (Ctrl+C);
# Y and other keys ask again; without a console: the default
function Read-Answer([bool]$default, [string]$y = 'да', [string]$n = 'нет') {
  if (-not $Script:KeysOk) { if ($default) { return 'yes' }; return 'no' }
  while ($true) {
    $k = Read-KeyX
    $a = Get-AnsKind $k
    if ($a -eq 'YES') { Write-Log ('answer: {0} (yes)' -f $k); return 'yes' }
    if ($a -eq 'NO') { Write-Log ('answer: {0} (no)' -f $k); return 'no' }
    if ($a -eq 'INT') { Write-Log 'answer: Ctrl+C'; return 'int' }
    if ($a -eq 'AGAIN') { Say ('Непонятно: на этой клавише и Y, и Н. Нажмите Enter — {0}, Esc — {1}.' -f $y, $n) }
    else { Say ('Нажмите Д или Enter — {0}, Н или Esc — {1}.' -f $y, $n) }
  }
}
# Read-YesNo <default> [yes word] [no word]: $true yes, $false no; Ctrl+C
# stops the run
function Read-YesNo([bool]$default, [string]$y = 'да', [string]$n = 'нет') {
  $a = Read-Answer $default $y $n
  if ($a -eq 'int') { Invoke-Cancel }
  return ($a -eq 'yes')
}
# Ask-Yes <text> <default> [yes word] [no word]: keys pressed before are
# dropped, then the question, then Read-YesNo
function Ask-Yes([string]$t, [bool]$default, [string]$y = 'да', [string]$n = 'нет') { Clear-Keys; WarnM $t; return (Read-YesNo $default $y $n) }
# (the keys of every yes/no question: see Get-AnsKind)
$T_YN = '(Д или Enter — да, Н или Esc — нет)'

# Stop-PhoneCheck: ask the phone to stop a check that runs in the background:
# TERM to its worker (lock/wpid; lock/pid, hotspot and mic pid files for
# older phone scripts), which packs what it has; after 5 s its process group
# too (a command that hangs), unless it is packing already; then up to 30 s
# for it to end. 0: stopped, 2: told to stop but still packing, 1: nothing
# was running (or the phone did not answer)
function Stop-PhoneCheck {
  if (-not $Script:Serial) { return 1 }
  $c = 'set -f; d=/data/local/tmp; s=; for f in $d/taoyao-check.lock/wpid $d/taoyao-check.lock/pid $d/taoyao-check-hotspot.pid $d/taoyao-check-mic.pid; do p=$(cat $f 2>/dev/null); case " $s " in *" $p "*) continue;; esac; [ x$p != x ] && kill -0 $p 2>/dev/null && xargs -0 < /proc/$p/cmdline 2>/dev/null | grep -q taoyao-check && kill $p 2>/dev/null && s="$s $p"; done; [ "x$s" = x ] && exit 0; echo SENT; i=0; a=1; while [ $i -lt 30 ]; do a=; for p in $s; do [ -d /proc/$p ] && ! grep -q State:.Z /proc/$p/status 2>/dev/null && a=1; done; [ x$a = x ] && break; [ $i = 5 ] && [ ! -d $d/taoyao-check.lock/packing ] && for p in $s; do kill -s TERM -- -$p 2>/dev/null; done; sleep 1; i=$((i + 1)); done; [ x$a = x ] && echo STOPPED; exit 0'
  try {
    $r = Invoke-Dev $c $true 45 $true
    if ($r.Out -match 'STOPPED') { return 0 }
    if ($r.Out -match 'SENT') { return 2 }
    return 1
  } catch { if ("$_" -eq 'MERUDEV-EXIT') { throw }; return 1 }
}
function Invoke-Cancel {
  if ($null -ne $Script:AdbProc) { try { $Script:AdbProc.Kill(); [void]$Script:AdbProc.WaitForExit(5000) } catch { }; $Script:AdbProc = $null }
  Write-Host ''
  switch ($Script:Phase) {
    'run' {
      Say 'Останавливаю проверку на телефоне…'
      $sr = Stop-PhoneCheck
      if ($sr -eq 0) { WarnM 'Остановлено. Проверка на телефоне тоже остановлена.' }
      elseif ($sr -eq 2) { WarnM 'Остановлено. Проверка на телефоне останавливается и запишет то, что успела собрать.' }
      else { WarnM 'Остановлено. Если проверка на телефоне ещё идёт, она закончится сама и запишет результат.' }
    }
    'hs' {
      try { [IO.File]::WriteAllText((Join-Path $Script:Base '.run-check-pending'), ('check {0} {1}' -f $Script:Start, $Script:BootId), $Utf8) } catch { }
      WarnM ('Скрипт больше не ждёт. Проверка продолжается на телефоне и через пару минут сама запишет результат. Чтобы забрать его, запустите {0} ещё раз (без параметров) — он предложит забрать результат.' -f $Launcher)
    }
    'chg' { WarnM 'Скрипт больше не ждёт. Журнал зарядки продолжает записываться на телефоне; заберите его позже (пункт 6).' }
    default { WarnM 'Остановлено.' }
  }
  Write-Log ('cancelled by the user (phase {0})' -f $Script:Phase)
  Stop-Run $RC_CANCEL
}
function Invoke-CancelAsk {
  Write-Host ''
  switch ($Script:Phase) {
    'run' { $q = 'Остановить проверку? ' + $T_YN }
    'hs' { $q = 'Не ждать окончания проверки? Она продолжится на телефоне. ' + $T_YN }
    'chg' { $q = 'Не ждать конца записи зарядки? Она продолжится на телефоне. ' + $T_YN }
    default { $q = 'Остановить сбор логов? ' + $T_YN }
  }
  if (Ask-Yes $q $true) { Invoke-Cancel }
  Say 'Продолжаю.'
}
# Test-Interrupt: in every wait; Ctrl+C asks, Enter is remembered
function Test-Interrupt {
  if (-not $Script:KeysOk) { return }
  $hit = $false
  try {
    while ([Console]::KeyAvailable) {
      $k = [Console]::ReadKey($true)
      if (Test-CtrlC $k) { $hit = $true; break }
      if ($k.Key -eq [ConsoleKey]::Enter) { $Script:EnterPressed = $true }
    }
  } catch { return }
  if ($hit) { Invoke-CancelAsk }
}
function Wait-Sec([double]$sec) {
  $sw = [Diagnostics.Stopwatch]::StartNew()
  while ($sw.Elapsed.TotalSeconds -lt $sec) { Start-Sleep -Milliseconds 200; Test-Interrupt }
}

function Open-Folder([string]$dir, [string]$file) {
  if (-not $Script:Menu -or -not $IsWin) { return }
  try {
    $ex = Join-Path $env:SystemRoot 'explorer.exe'
    if ($file) { Start-Process -FilePath $ex -ArgumentList ('/select,"' + $file + '"') }
    else { Start-Process -FilePath $ex -ArgumentList ('"' + $dir + '"') }
  } catch { Write-Log ('explorer: ' + $_) }
}
function Show-Failed {
  Write-Host ''
  if ($Script:LogPath) {
    ErrM ("Не получилось. Прикрепите к сообщению на форуме файл:`r`n  {0}`r`nВ нём нет серийного номера телефона и имени пользователя компьютера." -f $Script:LogPath)
    Open-Folder $Script:Out ''
  } else { ErrM 'Не получилось.' }
}
function Fail([string]$t) { if ($t) { ErrM $t }; Show-Failed; Stop-Run $RC_FAIL }

########################################################################
# adb processes
function Quote-WinArg([string]$a) {
  if ($a.Length -gt 0 -and $a -notmatch '[\s"]') { return $a }
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.Append('"')
  $bs = 0
  foreach ($ch in $a.ToCharArray()) {
    if ($ch -eq [char]92) { $bs++; continue }
    if ($ch -eq [char]34) {
      [void]$sb.Append((New-Object string ([char]92), (2 * $bs + 1)))
      [void]$sb.Append('"'); $bs = 0; continue
    }
    if ($bs -gt 0) { [void]$sb.Append((New-Object string ([char]92), $bs)); $bs = 0 }
    [void]$sb.Append($ch)
  }
  [void]$sb.Append((New-Object string ([char]92), (2 * $bs)))
  [void]$sb.Append('"')
  return $sb.ToString()
}
function Start-AdbProc([string[]]$A, [string]$Dir, [bool]$NoSerial, [string]$Exe) {
  $all = New-Object 'System.Collections.Generic.List[string]'
  if (-not $NoSerial -and $Script:Serial) { $all.Add('-s'); $all.Add($Script:Serial) }
  foreach ($x in $A) { $all.Add($x) }
  $q = New-Object 'System.Collections.Generic.List[string]'
  foreach ($x in $all) { $q.Add((Quote-WinArg $x)) }
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  if ($Exe) { $psi.FileName = $Exe } else { $psi.FileName = $Script:Adb }
  $psi.Arguments = [string]::Join(' ', $q.ToArray())
  if ($Dir) { $psi.WorkingDirectory = $Dir } else { $psi.WorkingDirectory = $Here }
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.RedirectStandardInput = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.StandardOutputEncoding = $Utf8
  $psi.StandardErrorEncoding = $Utf8
  $p = New-Object System.Diagnostics.Process
  $p.StartInfo = $psi
  $tag = 'adb'; if ($Exe) { $tag = [IO.Path]::GetFileName($Exe) }
  Write-Log ('> ' + $tag + ' ' + $psi.Arguments)
  [void]$p.Start()
  try { $p.StandardInput.Close() } catch { }
  return $p
}
# Invoke-Adb: a captured adb call with a time limit; Code 124 after it
function Invoke-Adb([string[]]$A, [int]$TimeoutSec = 20, [string]$Dir = '', [bool]$NoSerial = $false, [string]$Exe = '', [bool]$NoLog = $false) {
  $p = Start-AdbProc $A $Dir $NoSerial $Exe
  $Script:AdbProc = $p
  $to = $p.StandardOutput.ReadToEndAsync()
  $te = $p.StandardError.ReadToEndAsync()
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $timedOut = $false
  while (-not $p.WaitForExit(200)) {
    Test-Interrupt
    if ($sw.Elapsed.TotalSeconds -ge $TimeoutSec) {
      try { $p.Kill() } catch { }
      $timedOut = $true; break
    }
  }
  try { [void][Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($to, $te), 2000) } catch { }
  $o = ''; $e = ''
  if ($to.IsCompleted -and -not $to.IsFaulted) { $o = $to.Result }
  if ($te.IsCompleted -and -not $te.IsFaulted) { $e = $te.Result }
  $code = 124
  if (-not $timedOut) { try { $code = $p.ExitCode } catch { $code = 1 } }
  $Script:AdbProc = $null
  try { $p.Dispose() } catch { }
  $txt = ($o + $e)
  if ($txt.Length -gt 3000) { $txt = $txt.Substring(0, 3000) }
  if ($NoLog) { $txt = '(output below)' }
  Write-Log ('< rc={0} {1}' -f $code, $txt.TrimEnd())
  return [pscustomobject]@{ Code = $code; Out = $o; Err = $e; TimedOut = $timedOut }
}
# Invoke-Dev <command> <root> <seconds>: adb shell, as root through su -c
function Invoke-Dev([string]$cmd, [bool]$root, [int]$TimeoutSec = 20, [bool]$quiet = $false) {
  if ($cmd.Contains("'")) { throw 'кавычка в команде для телефона' }
  $full = $cmd
  if ($root -and -not $Script:AdbRoot) { $full = "su -c '" + $cmd + "'" }
  $r = Invoke-Adb @('shell', $full) $TimeoutSec
  $Script:Dc = $r
  return $r
}
function Test-Lost($r) {
  if ($null -eq $r) { return $false }
  return (($r.Out + $r.Err) -match "(?i)device '.*' not found|no devices/emulators found|device offline|device unauthorized|error: closed|protocol fault|connection reset|failed to get feature set|no device")
}
function Get-KV([string]$text, [string]$key) {
  foreach ($l in ($text -split "`r?`n")) {
    if ($l.StartsWith($key + '=')) { return $l.Substring($key.Length + 1).TrimEnd("`r") }
  }
  return ''
}

########################################################################
# arguments
function Read-Args([string[]]$a) {
  $Script:Mode = ''; $Script:Words = ''; $Script:ChgMin = 0; $Script:Bg = $false
  $deep = $false; $hs = $false; $mic = $false; $prep = $false; $chg = $false; $pull = $false
  $min = ''; $prev = ''
  # ("deep hotspot" typed in quotes is two words)
  $words = @($a | ForEach-Object { ([string]$_).Trim() -split '\s+' } | Where-Object { $_ })
  foreach ($w0 in $words) {
    $w = ([string]$w0).Trim().ToLowerInvariant()
    if ($w.StartsWith('--')) { $w = $w.Substring(2) }
    if (@('help', '-h', 'h', '/?', '-?', '?', '/h', 'справка') -contains $w) { $Script:Mode = 'help'; return 'ok' }
    switch -regex ($w) {
      '^prep$' { $prep = $true; break }
      '^deep$' { $deep = $true; break }
      '^hotspot$' { $hs = $true; break }
      '^mic$' { $mic = $true; break }
      '^charge$' { $chg = $true; break }
      '^charge-?pull$' { $pull = $true; break }
      '^[0-9]+$' {
        if ($prev -eq 'charge' -and -not $min) { $min = $w; break }
        return ('bad:' + $w0)
      }
      default { return ('bad:' + $w0) }
    }
    $prev = $w
  }
  $n = 0
  if ($prep) { $n++ }; if ($chg) { $n++ }; if ($pull) { $n++ }
  if ($deep -or $hs -or $mic) { $n++ }
  if ($n -gt 1) { return 'combo' }
  if ($hs -and $mic) { return 'hsmic' }
  if ($chg) {
    if (-not $min) { $min = '40' }
    $min = $min.TrimStart('0')
    if (-not $min -or $min.Length -gt 4 -or [int]$min -gt 1440) { return 'minutes' }
    $Script:Mode = 'charge'; $Script:ChgMin = [int]$min; $Script:Words = 'charge ' + $min; return 'ok'
  }
  if ($min) { return 'minutes' }
  if ($prep) { $Script:Mode = 'prep'; $Script:Words = 'prep'; return 'ok' }
  if ($pull) { $Script:Mode = 'charge-pull'; return 'ok' }
  $ws = New-Object 'System.Collections.Generic.List[string]'
  if ($deep) { $ws.Add('deep') }; if ($hs) { $ws.Add('hotspot') }; if ($mic) { $ws.Add('mic') }
  $Script:Words = [string]::Join(' ', $ws.ToArray())
  $Script:Mode = 'check'
  $Script:Bg = ($hs -or $mic)
  return 'ok'
}
# Read-Minutes: the number typed key by key (digits, Backspace); Enter (or
# Д, L) takes it, empty: 40; Esc, Н, N or Ctrl+C: $false (leave)
function Read-Minutes {
  Clear-Keys
  Write-Host 'Сколько минут записывать зарядку? Введите число от 1 до 1440 и нажмите Enter (просто Enter — 40 минут):'
  while ($true) {
    Write-Host -NoNewline '> '
    $s = ''
    while ($true) {
      $k = [Console]::ReadKey($true)
      $kx = [string]$k.KeyChar
      if ($k.Key -eq [ConsoleKey]::Enter) { $kx = 'ENTER' } elseif ($k.Key -eq [ConsoleKey]::Escape) { $kx = 'ESC' } elseif (Test-CtrlC $k) { $kx = 'INT' }
      $a = Get-AnsKind $kx
      if ($a -eq 'YES') { Write-Host ''; break }
      if ($a -eq 'NO' -or $a -eq 'INT') { Write-Host ''; Write-Log ('answer: {0} (no minutes)' -f $kx); return $false }
      if ($a -eq 'AGAIN') { Write-Host ''; Say 'Непонятно: на этой клавише и Y, и Н. Введите число и нажмите Enter, Esc — выйти.'; Write-Host -NoNewline ('> ' + $s); continue }
      if ($k.Key -eq [ConsoleKey]::Backspace) {
        if ($s.Length -gt 0) { $s = $s.Substring(0, $s.Length - 1); Write-Host -NoNewline "`b `b" }
        continue
      }
      if ($k.KeyChar -ge [char]'0' -and $k.KeyChar -le [char]'9' -and $s.Length -lt 4) { $s += [string]$k.KeyChar; Write-Host -NoNewline ([string]$k.KeyChar) }
    }
    if (-not $s) { $s = '40' }
    $v = 0
    if ([int]::TryParse($s, [ref]$v) -and $v -ge 1 -and $v -le 1440) { $Script:ChgMin = $v; Write-Log ('minutes: ' + $v); return $true }
    Say 'Нужно число от 1 до 1440.'
  }
}
# Show-MenuChoice: a digit; Esc (or Н, N) and Ctrl+C leave
function Show-MenuChoice {
  Show-Menu
  :menu while ($true) {
    $k = Read-KeyX
    $a = Get-AnsKind $k
    if ($a -eq 'NO' -or $a -eq 'INT') { $k = '0' }
    switch -exact ($k) {
      '1' { $Script:Mode = 'check'; $Script:Words = ''; $Script:Bg = $false }
      '2' { $Script:Mode = 'prep'; $Script:Words = 'prep'; $Script:Bg = $false }
      '3' { $Script:Mode = 'check'; $Script:Words = 'hotspot'; $Script:Bg = $true }
      '4' { $Script:Mode = 'check'; $Script:Words = 'mic'; $Script:Bg = $true }
      '5' {
        if (-not (Read-Minutes)) { $Script:Mode = 'exit'; return }
        $Script:Mode = 'charge'; $Script:Words = 'charge ' + $Script:ChgMin; $Script:Bg = $false
      }
      '6' { $Script:Mode = 'charge-pull'; $Script:Words = ''; $Script:Bg = $false }
      '7' {
        Write-Host ''
        Clear-Keys
        WarnM ('Глубокая проверка займёт 15–40 минут. Телефон может зависнуть или перезагрузиться — это тоже нужный результат. Начать? ' + $T_YN)
        $ans = Read-Answer $false
        if ($ans -eq 'yes') { $Script:Mode = 'check'; $Script:Words = 'deep'; $Script:Bg = $false }
        elseif ($ans -eq 'int') { $Script:Mode = 'exit' }
        else { Show-Menu; continue menu }
      }
      '0' { $Script:Mode = 'exit' }
      default { Say 'Нажмите цифру от 0 до 7.'; continue menu }
    }
    Write-Log ('menu: {0} -> {1} {2}' -f $k, $Script:Mode, $Script:Words)
    return
  }
}

########################################################################
# adb discovery
function Test-AdbVer([string]$v) {
  $m = [regex]::Match($v, '^(\d+)\.(\d+)\.(\d+)')
  if (-not $m.Success) { return $false }
  $a = [int]$m.Groups[1].Value; $b = [int]$m.Groups[2].Value; $c = [int]$m.Groups[3].Value
  if ($a -ne 1) { return ($a -gt 1) }
  if ($b -ne 0) { return ($b -gt 0) }
  return ($c -ge 39)
}
function Find-Adb {
  $cand = New-Object 'System.Collections.Generic.List[string]'
  if ($env:ADB) { $cand.Add($env:ADB) }
  if ($IsWin) {
    $cand.Add((Join-Path $Here 'adb.exe'))
    $cand.Add((Join-Path $Here 'platform-tools\adb.exe'))
    $cand.Add((Join-Path $Here 'platform-tools-latest-windows\platform-tools\adb.exe'))
  } else {
    $cand.Add((Join-Path $Here 'adb'))
    $cand.Add((Join-Path $Here 'platform-tools/adb'))
  }
  $ud = Get-PtUserDir
  if ($ud) { if ($IsWin) { $cand.Add((Join-Path $ud 'adb.exe')) } else { $cand.Add((Join-Path $ud 'adb')) } }
  Remove-PtStale $Here
  if ($ud) { Remove-PtStale ([IO.Path]::GetDirectoryName($ud)) }
  try {
    $gc = @(Get-Command -Name adb -CommandType Application -ErrorAction SilentlyContinue)
    foreach ($g in $gc) { if ($g.Path) { $cand.Add($g.Path) } }
  } catch { }
  if ($IsWin) {
    foreach ($b in @($env:LOCALAPPDATA)) { if ($b) { $cand.Add((Join-Path $b 'Android\Sdk\platform-tools\adb.exe')) } }
    foreach ($b in @($env:ANDROID_HOME, $env:ANDROID_SDK_ROOT)) { if ($b) { $cand.Add((Join-Path $b 'platform-tools\adb.exe')) } }
    if ($env:USERPROFILE) {
      $cand.Add((Join-Path $env:USERPROFILE 'platform-tools\adb.exe'))
      $cand.Add((Join-Path $env:USERPROFILE 'Downloads\platform-tools\adb.exe'))
      $cand.Add((Join-Path $env:USERPROFILE 'Downloads\platform-tools-latest-windows\platform-tools\adb.exe'))
    }
    if ($env:LOCALAPPDATA) {
      $cand.Add((Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links\adb.exe'))
      $pk = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'
      if ([IO.Directory]::Exists($pk)) {
        try {
          foreach ($d in @(Get-ChildItem -LiteralPath $pk -Directory -Filter 'Google.PlatformTools*' -ErrorAction SilentlyContinue)) {
            $cand.Add((Join-Path $d.FullName 'platform-tools\adb.exe'))
          }
        } catch { }
      }
    }
    $cand.Add('C:\platform-tools\adb.exe'); $cand.Add('C:\adb\adb.exe')
  }
  $seen = @{}
  $oldV = ''; $oldP = ''; $dllP = ''
  foreach ($p in $cand) {
    if (-not $p) { continue }
    $key = $p.ToLowerInvariant()
    if ($seen.ContainsKey($key)) { continue }
    $seen[$key] = 1
    if (-not [IO.File]::Exists($p)) { continue }
    # (an adb.exe without its DLLs is tried all the same: Scoop and
    # Chocolatey shims start the real one; the DLL hint is only for one that
    # then fails to start)
    $nodll = $false
    if ([IO.Path]::GetFileName($p).ToLowerInvariant() -eq 'adb.exe') {
      $dir = [IO.Path]::GetDirectoryName($p)
      if (-not ([IO.File]::Exists((Join-Path $dir 'AdbWinApi.dll')) -and [IO.File]::Exists((Join-Path $dir 'AdbWinUsbApi.dll')))) {
        $nodll = $true
        Write-Log ('adb candidate without its DLLs next to it: ' + $p)
      }
    }
    try { $r = Invoke-Adb @('version') 10 '' $true $p }
    catch {
      if ("$_" -eq 'MERUDEV-EXIT') { throw }
      Write-Log ('adb candidate does not start: {0} ({1})' -f $p, $_)
      if ($nodll -and -not $dllP) { $dllP = $p }
      continue
    }
    if ($r.Code -ne 0) {
      Write-Log ('adb candidate failed: ' + $p)
      if ($nodll -and -not $dllP) { $dllP = $p }
      continue
    }
    $m = [regex]::Match($r.Out, 'Android Debug Bridge version ([0-9][0-9.]*)')
    $v = ''; if ($m.Success) { $v = $m.Groups[1].Value }
    $inst = ''
    $mi = [regex]::Match($r.Out, '(?m)^Installed as (.+?)\s*$')
    if ($mi.Success) { $inst = $mi.Groups[1].Value }
    if (Test-AdbVer $v) {
      $Script:Adb = $p
      if ($inst -and [IO.File]::Exists($inst)) { $Script:Adb = $inst }
      $Script:AdbVer = $v
      Write-Log ('adb: {0} (version {1})' -f $Script:Adb, $v)
      return
    }
    Write-Log ('adb candidate too old ({0}): {1}' -f $v, $p)
    if (-not $oldV) { $oldV = $v; $oldP = $p }
  }
  # (no usable adb: offer SDK Platform-Tools from Google; when the user says
  # no, the manual way, and the run ends as cancelled, not failed)
  $got = Get-PlatformTools $oldV $oldP
  if ($got -eq 'ok') { return }
  $em = 'ErrM'; if ($got -eq 'no') { $em = 'WarnM' }
  Write-Host ''
  if ($oldV) {
    & $em ('Найден только старый adb (версия {0}: {1}). С ним сбор логов работает ненадёжно. Скачайте свежий: {2} — и распакуйте папку platform-tools рядом со скриптом: тогда будет использован он.' -f $oldV, $oldP, $PtUrl)
  } elseif ($dllP) {
    & $em ('{0} не запустится: рядом с ним нет файлов AdbWinApi.dll и AdbWinUsbApi.dll. Распакуйте папку platform-tools целиком, со всеми файлами.' -f $dllP)
  } else {
    & $em 'Не найдена программа adb (Android Platform Tools) — без неё компьютер не может работать с телефоном.'
    Say (' 1. Скачайте «SDK Platform-Tools for Windows»: {0}' -f $PtUrl)
    Say (' 2. Распакуйте архив так, чтобы папка platform-tools оказалась рядом с run-check.bat (должен получиться файл {0}).' -f (Join-Path $Here 'platform-tools\adb.exe'))
    Say ' 3. Запустите run-check.bat снова.'
  }
  if ($got -eq 'no') {
    Write-Host ''
    WarnM 'adb не скачан — поставьте его, как написано выше, и запустите скрипт снова.'
    Write-Log 'cancelled: the adb download was declined'
    Stop-Run $RC_CANCEL
  }
  Fail ''
}
function Start-AdbServer {
  $r = Invoke-Adb @('start-server') 30 '' $true
  $txt = $r.Out + $r.Err
  if ($txt -match "doesn't match this client") {
    WarnM 'Другая программа на компьютере запускает свою версию adb, и они мешают друг другу. Если телефон будет «пропадать», закройте программы для работы с телефоном и запустите скрипт снова.'
  }
  if ($r.Code -ne 0) {
    $first = ''
    foreach ($l in ($txt -split "`r?`n")) { if ($l -and -not $l.StartsWith('*')) { $first = $l; break } }
    Fail ('Не удалось запустить службу adb ({0}). Закройте другие программы, которые работают с телефоном по USB, и запустите скрипт снова. Не помогло — перезагрузите компьютер.' -f $first)
  }
}

########################################################################
# adb from Google: with no usable adb, SDK Platform-Tools are downloaded
# from dl.google.com on this computer once the user agrees to Google's terms
# (Google's adb is not part of our ZIP), checked (Windows: the Authenticode
# signature of adb.exe must be Valid and Google LLC's), and put into
# platform-tools next to the script, or into a per-user folder when the
# script folder is read-only or its platform-tools folder cannot be
# replaced. TAOYAO_ADB_DOWNLOAD=1 downloads without the question, =0 never;
# TAOYAO_PT_URL replaces the download folder for tests (https://dl.google.com
# only, or a local server on 127.0.0.1 or localhost).
function Get-PtUserDir {
  if ($IsWin) {
    if ($env:LOCALAPPDATA) { return (Join-Path $env:LOCALAPPDATA 'MeruDevTools\platform-tools') }
    return ''
  }
  $h = $env:HOME
  if (-not $h -or $h -eq '/') { return '' }
  if ($IsMac) { return ($h + '/Library/Application Support/MeruDevTools/platform-tools') }
  $x = $env:XDG_DATA_HOME
  if (-not ($x -and $x.StartsWith('/'))) { $x = $h + '/.local/share' }
  return ($x + '/MeruDevTools/platform-tools')
}
# Get-PtUrl: the archive for this computer in $Script:PtZip; 1 a bad
# TAOYAO_PT_URL, 2 nothing for this computer ($Script:PtErr)
function Get-PtUrl {
  $b = $PtBase
  if ($env:TAOYAO_PT_URL) { $b = [string]$env:TAOYAO_PT_URL }
  $b = $b.TrimEnd('/')
  if ($b -cnotmatch '^https://dl\.google\.com(/[^@\s]*)?$' -and $b -cnotmatch '^https?://(127\.0\.0\.1|localhost)(:[0-9]+)?(/[^@\s]*)?$') {
    $Script:PtErr = 'TAOYAO_PT_URL: можно указать только адрес на https://dl.google.com (или на 127.0.0.1 для проверки)'
    return 1
  }
  if ($IsWin) { $os = 'windows' }
  elseif ($IsMac) { $os = 'darwin' }
  else {
    $arch = '?'
    try { $arch = [string][Runtime.InteropServices.RuntimeInformation]::OSArchitecture } catch { }
    if ($arch -ne 'X64') {
      $Script:PtErr = ('Google выпускает SDK Platform-Tools для Linux только для x86-64 (этот компьютер: {0})' -f $arch)
      return 2
    }
    $os = 'linux'
  }
  $Script:PtZip = $b + '/platform-tools-latest-' + $os + '.zip'
  return 0
}
# Get-PtAuto: TAOYAO_ADB_DOWNLOAD as '1' (download without the question),
# '0' (never) or '' (ask)
function Get-PtAuto {
  $v = [string]$env:TAOYAO_ADB_DOWNLOAD
  if (-not $v) { return '' }
  $l = $v.Replace(' ', '').ToLowerInvariant()
  if (@('1', 'yes', 'true', 'on', 'да') -contains $l) { return '1' }
  if (@('0', 'no', 'false', 'off', 'нет') -contains $l) { return '0' }
  if ($v.Length -gt 40) { $v = $v.Substring(0, 40) }
  WarnM ('Непонятное значение TAOYAO_ADB_DOWNLOAD=«{0}»: нужно 1 (скачивать adb) или 0 (не скачивать).' -f $v)
  return ''
}
# Read-PtAnswer <old version> <auto>: 'yes', 'no', or 'off' (no console for
# the question); Ctrl+C stops the run
function Read-PtAnswer([string]$oldV, [string]$auto) {
  Write-Host ''
  if ($auto -eq '1') {
    Say ('TAOYAO_ADB_DOWNLOAD=1: скачиваю adb без вопроса (условия Google: {0}).' -f $PtTerms)
    return 'yes'
  }
  if (-not $Script:KeysOk) {
    Write-Log 'adb download: no console for the question'
    WarnM ('Чтобы скачать adb с сайта Google без вопроса, задайте переменную TAOYAO_ADB_DOWNLOAD=1 (этим вы принимаете условия Google: {0}).' -f $PtTerms)
    return 'off'
  }
  if ($oldV) {
    $q = 'Найденный adb слишком старый (версия {0}). Скачать свежий Android SDK Platform-Tools с сайта Google (около 7–15 МБ, нужен интернет)? Нажимая Д, вы принимаете условия Google: {1} [Д/н]' -f $oldV, $PtTerms
  } else {
    $q = 'adb не найден. Скачать Android SDK Platform-Tools с сайта Google (около 7–15 МБ, нужен интернет)? Нажимая Д, вы принимаете условия Google: {0} [Д/н]' -f $PtTerms
  }
  if (Ask-Yes $q $false 'скачать' 'не скачивать') { return 'yes' }
  return 'no'
}
# Wait-PtDone <process or IAsyncResult> <seconds> <file>: 'done', 'time'
# after the limit, 'stall' when the file has not grown for 60 s, 'idle' when
# nothing has come in 60 s; a line every 15 s with what has come; Ctrl+C asks
function Wait-PtDone($w, [int]$lim, [string]$file) {
  $sw = [Diagnostics.Stopwatch]::StartNew(); $next = 15; $last = [long]-1; $lastT = 0.0
  while ($true) {
    if ($w -is [Diagnostics.Process]) { if ($w.WaitForExit(200)) { return 'done' } }
    elseif ($w.AsyncWaitHandle.WaitOne(200)) { return 'done' }
    Test-Interrupt
    $t = $sw.Elapsed.TotalSeconds
    $len = [long]0
    try { $fi = New-Object IO.FileInfo $file; if ($fi.Exists) { $len = $fi.Length } } catch { }
    if ($len -ne $last) { $last = $len; $lastT = $t }
    elseif (($t - $lastT) -ge 60) { if ($len -gt 0) { return 'stall' }; return 'idle' }
    if ($t -ge $lim) { return 'time' }
    if ($t -ge $next) {
      $mb = ''
      if ($len -ge 104858) { $mb = (', скачано {0:0.0} МБ' -f ($len / 1048576.0)).Replace('.', ',') }
      elseif ($len -gt 0) { $mb = ', скачано {0} КБ' -f [int][Math]::Ceiling($len / 1024.0) }
      Say ('… скачиваю, прошло ' + (Format-Elapsed ([int]$t)) + $mb)
      $next += 15
    }
  }
}
# (in a runspace of its own, so that the wait above shows the time and
# reacts to Ctrl+C; the system proxy, with the Windows logon for a proxy
# that asks for one; a plain file name in the download folder, which may
# hold [ ] and Cyrillic)
$PtIwr = {
  param($u, $d, $n)
  $ProgressPreference = 'SilentlyContinue'
  $ErrorActionPreference = 'Stop'
  try { $wp = [Net.WebRequest]::DefaultWebProxy; if ($null -ne $wp) { $wp.Credentials = [Net.CredentialCache]::DefaultNetworkCredentials } } catch { }
  Set-Location -LiteralPath $d
  Invoke-WebRequest -Uri $u -OutFile $n -UseBasicParsing -TimeoutSec 60
}
# Stop-PtJob <PowerShell>: stop the download runspace, waiting 5 s at most
# (Windows PowerShell 5.1 may take its time to abort a transfer); $true
# when it stopped
function Stop-PtJob($ps) {
  try {
    $ar = $ps.BeginStop($null, $null)
    if ($ar.AsyncWaitHandle.WaitOne(5000)) { try { $ps.EndStop($ar) } catch { }; return $true }
    Write-Log 'the download did not stop within 5 s'
  } catch { Write-Log ('stop: ' + $_) }
  return $false
}
# Get-PtKindText <kind> <message> <code>: the reason in Russian;
# $Script:PtKind net (no internet, DNS, proxy, timeout, TLS) or disk
function Get-PtKindText([string]$k, [string]$raw, [int]$rc) {
  $t = ''
  switch ($k) {
    'proxy' { $t = 'не удаётся найти прокси-сервер' }
    'dns' { $t = 'не удаётся найти сервер: нет интернета или не работает DNS' }
    'conn' { $t = 'не удаётся подключиться к серверу' }
    'time' { $t = 'сервер не отвечает' }
    'slow' { $t = 'сервер перестал присылать данные' }
    'cut' { $t = 'соединение прервалось' }
    'tls' { $t = 'не удаётся установить защищённое соединение' }
    'disk' { $Script:PtKind = 'disk'; return 'не удаётся записать файл, возможно, нет места на диске' }
    'access' { return 'нет доступа к временной папке' }
    'redir' { return 'слишком много перенаправлений' }
    'big' { return 'файл слишком большой' }
    'proto' { return 'сервер перенаправил загрузку на незащищённый адрес http://' }
  }
  if ($t) { $Script:PtKind = 'net'; return $t }
  $r = ([string]$raw).Trim().TrimEnd('.')
  if ($r.Length -gt 200) { $r = $r.Substring(0, 200) }
  if (-not $r) { $r = 'код ' + $rc }
  return $r
}
# Get-PtCurlErr <exit code> <message>: the reason curl failed, in Russian
function Get-PtCurlErr([int]$rc, [string]$text) {
  $Script:PtKind = ''
  $last = ''
  foreach ($l in ($text -split "`r?`n")) { if ($l.Trim()) { $last = $l.Trim() } }
  if ($rc -eq 22) {
    $m = [regex]::Match($text, 'error: ([0-9]{3})')
    if ($m.Success) {
      $c = [int]$m.Groups[1].Value
      if ($c -eq 407) { $Script:PtKind = 'net'; return 'прокси-сервер требует пароль (ошибка 407)' }
      return ('сервер ответил ошибкой {0}' -f $c)
    }
  }
  $k = ''
  switch ($rc) {
    1 { if ($text -match 'not supported|disabled') { $k = 'proto' } }
    5 { $k = 'proxy' }
    6 { $k = 'dns' }
    7 { $k = 'conn' }
    23 { $k = 'disk' }
    28 { if ($text -match 'too slow') { $k = 'slow' } else { $k = 'time' } }
    47 { $k = 'redir' }
    63 { $k = 'big' }
  }
  if (@(35, 51, 53, 54, 58, 59, 60, 64, 66, 77, 80, 82, 83, 90, 91) -contains $rc) { $k = 'tls' }
  if (@(16, 18, 52, 55, 56, 92) -contains $rc) { $k = 'cut' }
  return (Get-PtKindText $k $last $rc)
}
# Get-PtWebErr <exception>: the reason Invoke-WebRequest failed, in Russian
# (the exceptions themselves go to run-check.log)
function Get-PtWebErr($root) {
  $Script:PtKind = ''
  $list = New-Object 'System.Collections.Generic.List[object]'
  $todo = New-Object 'System.Collections.Generic.Queue[object]'
  if ($null -ne $root) { $todo.Enqueue($root) }
  while ($todo.Count -gt 0 -and $list.Count -lt 12) {
    $e = $todo.Dequeue()
    if ($null -eq $e -or $list.Contains($e)) { continue }
    $list.Add($e)
    try { if ($null -ne $e.InnerException) { $todo.Enqueue($e.InnerException) } } catch { }
    $rp = $e.PSObject.Properties['ErrorRecord']
    if ($null -ne $rp) { try { if ($null -ne $rp.Value -and $null -ne $rp.Value.Exception) { $todo.Enqueue($rp.Value.Exception) } } catch { } }
  }
  $raw = ''
  $x = $root
  while ($null -ne $x) { $raw = $x.Message; $x = $x.InnerException }
  $code = 0; $k = ''; $txt = New-Object 'System.Collections.Generic.List[string]'
  foreach ($e in $list) {
    $txt.Add($e.GetType().Name + ': ' + $e.Message)
    if (-not $code) {
      $rp = $e.PSObject.Properties['Response']
      if ($null -ne $rp) { try { if ($null -ne $rp.Value) { $code = [int]$rp.Value.StatusCode } } catch { } }
    }
    if (-not $code -and $e.GetType().Name -eq 'HttpRequestException') {
      $sp = $e.PSObject.Properties['StatusCode']
      if ($null -ne $sp) { try { if ($null -ne $sp.Value) { $code = [int]$sp.Value } } catch { } }
    }
    $kk = ''
    if ($e -is [Net.WebException]) {
      switch ([string]$e.Status) {
        'NameResolutionFailure' { $kk = 'dns' }
        'ProxyNameResolutionFailure' { $kk = 'proxy' }
        'ConnectFailure' { $kk = 'conn' }
        'Timeout' { $kk = 'time' }
        'RequestCanceled' { $kk = 'time' }
        'TrustFailure' { $kk = 'tls' }
        'SecureChannelFailure' { $kk = 'tls' }
        'ReceiveFailure' { $kk = 'cut' }
        'SendFailure' { $kk = 'cut' }
        'ConnectionClosed' { $kk = 'cut' }
        'KeepAliveFailure' { $kk = 'cut' }
      }
    } elseif ($e -is [Net.Sockets.SocketException]) {
      switch ([string]$e.SocketErrorCode) {
        'HostNotFound' { $kk = 'dns' }
        'TryAgain' { $kk = 'dns' }
        'NoData' { $kk = 'dns' }
        'ConnectionRefused' { $kk = 'conn' }
        'NetworkUnreachable' { $kk = 'conn' }
        'HostUnreachable' { $kk = 'conn' }
        'NetworkDown' { $kk = 'conn' }
        'TimedOut' { $kk = 'time' }
        'ConnectionReset' { $kk = 'cut' }
        'ConnectionAborted' { $kk = 'cut' }
      }
    } elseif ($e -is [TimeoutException] -or $e -is [OperationCanceledException]) { $kk = 'time' }
    elseif ($e -is [Security.Authentication.AuthenticationException]) { $kk = 'tls' }
    elseif ($e -is [IO.IOException] -and ($e.HResult -eq -2147024784 -or $e.HResult -eq -2147024857 -or $e.Message -match 'No space left|not enough space')) { $kk = 'disk' }
    elseif ($e -is [UnauthorizedAccessException]) { $kk = 'access' }
    # (the most telling one: a full disk, else the first, but a timeout
    # gives way to what caused it)
    if ($kk -and (-not $k -or $kk -eq 'disk' -or $k -eq 'time')) { $k = $kk }
  }
  $s = [string]::Join(' | ', $txt.ToArray())
  if ($s.Length -gt 600) { $s = $s.Substring(0, 600) }
  Write-Log ('< ' + $s)
  if ($k -eq 'disk') { return (Get-PtKindText $k $raw 0) }
  if ($code -eq 407) { $Script:PtKind = 'net'; return 'прокси-сервер требует пароль (ошибка 407)' }
  if ($code -ge 300) { return ('сервер ответил ошибкой {0}' -f $code) }
  return (Get-PtKindText $k $raw 0)
}
# Invoke-PtGet <url> <folder> <file name> <curl>: one download attempt with
# Invoke-WebRequest, or with curl when its path is given; $Script:PtErr,
# $Script:PtKind
function Invoke-PtGet([string]$url, [string]$dir, [string]$name, [string]$curl) {
  $path = Join-Path $dir $name
  try { if ([IO.File]::Exists($path)) { [IO.File]::Delete($path) } } catch { }
  $lim = 900; $err = ''; $res = ''; $Script:PtKind = ''
  if ($curl) {
    $pr = '=https'; if ($url.StartsWith('http://')) { $pr = '=http' }
    try { $p = Start-AdbProc @('-fsSL', '--proto', $pr, '--proto-redir', $pr, '--connect-timeout', '30', '--speed-limit', '1024', '--speed-time', '60', '--max-filesize', '209715200', '-o', $name, $url) $dir $true $curl }
    catch { Write-Log ('curl does not start: ' + $_); $Script:PtErr = 'не удаётся запустить curl'; return $false }
    $Script:AdbProc = $p
    $to = $p.StandardOutput.ReadToEndAsync(); $te = $p.StandardError.ReadToEndAsync()
    try {
      $res = Wait-PtDone $p $lim $path
      if ($res -eq 'done') {
        try { [void][Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($to, $te), 2000) } catch { }
        $e = ''; if ($te.IsCompleted -and -not $te.IsFaulted) { $e = $te.Result.Trim() }
        Write-Log ('< rc={0} {1}' -f $p.ExitCode, $e)
        if ($p.ExitCode -ne 0) { $err = Get-PtCurlErr $p.ExitCode $e }
      } else { try { $p.Kill(); [void]$p.WaitForExit(5000) } catch { } }
    } finally { $Script:AdbProc = $null; try { $p.Dispose() } catch { } }
  } else {
    Write-Log ('> Invoke-WebRequest ' + $url)
    $ps = [PowerShell]::Create()
    $Script:PtJob = $ps
    $stopped = $true
    try {
      [void]$ps.AddScript($PtIwr).AddArgument($url).AddArgument($dir).AddArgument($name)
      $h = $ps.BeginInvoke()
      $res = Wait-PtDone $h $lim $path
      if ($res -eq 'done') {
        try { [void]$ps.EndInvoke($h) } catch { $err = Get-PtWebErr $_.Exception }
        if (-not $err -and $ps.Streams.Error.Count -gt 0) { $err = Get-PtWebErr $ps.Streams.Error[0].Exception }
        if (-not $err) { Write-Log '< done' }
      }
    } finally {
      if ($res -ne 'done') { $stopped = Stop-PtJob $ps }
      if ($stopped) { try { $ps.Dispose() } catch { } }
      $Script:PtJob = $null
    }
  }
  if ($res -eq 'time') { $err = 'загрузка не закончилась за 15 мин'; $Script:PtKind = 'net' }
  elseif ($res -eq 'stall') { $err = 'сервер перестал присылать данные'; $Script:PtKind = 'net'; Write-Log 'no more data for 60 s' }
  elseif ($res -eq 'idle') { $err = 'сервер не отвечает'; $Script:PtKind = 'net'; Write-Log 'no data for 60 s' }
  if (-not $err) {
    $len = 0; try { $len = (New-Object IO.FileInfo $path).Length } catch { }
    if ($len -le 0) { $err = 'сервер прислал пустой файл' }
  }
  if ($err) {
    try { [IO.File]::Delete($path) } catch { }
    $Script:PtErr = $err
    return $false
  }
  return $true
}
# Expand-PtZip <zip> <folder>: the archive opens, holds platform-tools/adb
# (Windows: adb.exe, AdbWinApi.dll and AdbWinUsbApi.dll) and nothing outside
# platform-tools/; then it is extracted; $Script:PtErr, $Script:PtWhere
# (check: a bad archive; unpack: it could not be extracted here; long: the
# path is too long for Windows PowerShell 5.1)
function Expand-PtZip([string]$zip, [string]$dir) {
  $Script:PtWhere = 'check'
  try { Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop } catch { Write-Log ('System.IO.Compression.FileSystem: ' + $_) }
  $need = @('platform-tools/adb')
  if ($IsWin) { $need = @('platform-tools/adb.exe', 'platform-tools/AdbWinApi.dll', 'platform-tools/AdbWinUsbApi.dll') }
  $names = New-Object 'System.Collections.Generic.List[string]'
  try {
    $z = [IO.Compression.ZipFile]::OpenRead($zip)
    try { foreach ($e in $z.Entries) { $names.Add($e.FullName) } } finally { $z.Dispose() }
  } catch { Write-Log ('zip: ' + $_); $Script:PtErr = 'архив не открывается'; return $false }
  foreach ($n in $names) {
    $m = $n.Replace('\', '/')
    if (-not $m.StartsWith('platform-tools/', [StringComparison]::Ordinal) -or ('/' + $m + '/').Contains('/../') -or $m.Contains(':') -or $n.Contains('\')) {
      Write-Log ('archive entry outside platform-tools/: ' + $n)
      $Script:PtErr = 'в архиве есть файлы вне папки platform-tools'
      return $false
    }
  }
  foreach ($x in $need) {
    $found = $false
    foreach ($n in $names) { if ([string]::Equals($n, $x, [StringComparison]::OrdinalIgnoreCase)) { $found = $true; break } }
    if (-not $found) { $Script:PtErr = ('в архиве нет {0}' -f $x); return $false }
  }
  try { [IO.Compression.ZipFile]::ExtractToDirectory($zip, $dir) }
  catch {
    # (the real reason: a damaged archive, a full disk, an antivirus, a path
    # too long)
    $ex = $_.Exception.GetBaseException()
    Write-Log ('extract: {0}: {1}' -f $ex.GetType().FullName, $ex.Message)
    if ($ex -is [IO.InvalidDataException]) { $Script:PtErr = 'архив повреждён' }
    elseif ($ex -is [IO.PathTooLongException]) { $Script:PtWhere = 'long'; $Script:PtErr = 'слишком длинный путь к папке со скриптами' }
    elseif ($ex.HResult -eq -2147024784 -or $ex.HResult -eq -2147024857 -or $ex.Message -match 'No space left') { $Script:PtWhere = 'unpack'; $Script:PtErr = 'нет места на диске' }
    else {
      $Script:PtWhere = 'unpack'
      $Script:PtErr = ([string]$ex.Message).Trim().TrimEnd('.')
      if ($Script:PtErr.Length -gt 200) { $Script:PtErr = $Script:PtErr.Substring(0, 200) }
    }
    return $false
  }
  return $true
}
# Test-PtSig <file> <adb>: '' or the reason. adb must be Valid and signed by
# Google LLC (the O= or CN= part of the signer, as a whole); its DLLs fail
# only with a broken signature or another signer (an unsigned one is logged)
function Test-PtSig([string]$f, [bool]$main) {
  $n = [IO.Path]::GetFileName($f); if ($main) { $n = 'adb' }
  $sig = $null; $subj = ''
  try { $sig = Get-AuthenticodeSignature -LiteralPath $f } catch { Write-Log ('Get-AuthenticodeSignature: ' + $_) }
  if ($null -eq $sig) {
    if ($main) { return 'не удалось проверить цифровую подпись adb' }
    Write-Log ('no signature information: ' + $n); return ''
  }
  $st = [string]$sig.Status
  if ($null -ne $sig.SignerCertificate) { $subj = [string]$sig.SignerCertificate.Subject }
  Write-Log ('{0} signature: {1}; {2}' -f $n, $st, $subj)
  if ($main) {
    if ($st -ne 'Valid') { return ('цифровая подпись adb недействительна ({0})' -f $st) }
    if ($subj -cnotmatch '(^|,)\s*(O|CN)="?Google LLC"?\s*(,|$)') { return 'adb подписан не Google LLC' }
    return ''
  }
  if ($st -eq 'HashMismatch') { return ('файл {0} изменён после подписи' -f $n) }
  if ($st -eq 'Valid' -and $subj -cnotmatch '(^|,)\s*(O|CN)="?Google (LLC|Inc\.?)"?\s*(,|$)') { return ('{0} подписан не Google' -f $n) }
  return ''
}
# Test-PtAdb <platform-tools folder>: adb there is signed by Google
# (Windows: Authenticode, macOS: codesign) and prints its version (1.0.39 or
# newer); $Script:PtVer, $Script:PtErr
function Test-PtAdb([string]$d) {
  $exe = Join-Path $d 'adb'; if ($IsWin) { $exe = Join-Path $d 'adb.exe' }
  if (-not $IsWin) {
    foreach ($f in @(Get-ChildItem -LiteralPath $d -File -ErrorAction SilentlyContinue)) {
      if (-not $f.Name.Contains('.')) { try { & chmod '+x' $f.FullName } catch { } }
    }
  }
  # (on Windows the cmdlet is always there, if need be after loading its
  # module; it is missing only outside Windows, e.g. PowerShell 7 on Linux)
  $gas = Get-Command -Name Get-AuthenticodeSignature -ErrorAction SilentlyContinue
  if (-not $gas -and $IsWin) {
    try { Import-Module Microsoft.PowerShell.Security -ErrorAction Stop } catch { Write-Log ('Microsoft.PowerShell.Security: ' + $_) }
    $gas = Get-Command -Name Get-AuthenticodeSignature -ErrorAction SilentlyContinue
  }
  if ($gas) {
    $e = Test-PtSig $exe $true
    if (-not $e) {
      foreach ($dll in @('AdbWinApi.dll', 'AdbWinUsbApi.dll')) {
        $f = Join-Path $d $dll
        if ([IO.File]::Exists($f)) { $e = Test-PtSig $f $false; if ($e) { break } }
      }
    }
    if ($e) { $Script:PtErr = $e; return $false }
  } elseif ($IsWin) {
    Write-Log 'Get-AuthenticodeSignature is missing'
    $Script:PtErr = 'не удалось проверить цифровую подпись adb (в PowerShell нет команды Get-AuthenticodeSignature)'
    return $false
  } else { Write-Log 'Get-AuthenticodeSignature is not available here: the signature of adb is not checked' }
  if ($IsMac) {
    if ([IO.File]::Exists('/usr/bin/xattr')) {
      $r = Invoke-Adb @('-p', 'com.apple.quarantine', $exe) 10 '' $true '/usr/bin/xattr'
      if ($r.Code -eq 0) { [void](Invoke-Adb @('-r', '-d', 'com.apple.quarantine', $d) 30 '' $true '/usr/bin/xattr'); Write-Log 'quarantine attribute removed' }
    }
    if ([IO.File]::Exists('/usr/bin/codesign')) {
      $r = Invoke-Adb @('--verify', '--strict', $exe) 30 '' $true '/usr/bin/codesign'
      if ($r.Code -ne 0) { $Script:PtErr = 'цифровая подпись adb недействительна'; return $false }
      $r = Invoke-Adb @('-dvv', $exe) 30 '' $true '/usr/bin/codesign'
      # (the signer itself, e.g. "Developer ID Application: Google LLC (TEAMID)")
      $au = [regex]::Match(($r.Out + "`n" + $r.Err), '(?m)^Authority=.*$')
      if (-not $au.Success -or $au.Value.TrimEnd() -cnotmatch '^Authority=[^:]+: Google LLC \([A-Z0-9]+\)$') { $Script:PtErr = 'adb подписан не Google LLC'; return $false }
    } else { Write-Log 'codesign not found: the signature of adb is not checked' }
  }
  $r = $null
  try { $r = Invoke-Adb @('version') 10 '' $true $exe }
  catch { if ("$_" -eq 'MERUDEV-EXIT') { throw }; Write-Log ('downloaded adb does not start: ' + $_) }
  $v = ''
  if ($null -ne $r -and $r.Code -eq 0) {
    $m = [regex]::Match($r.Out, 'Android Debug Bridge version ([0-9][0-9.]*)')
    if ($m.Success) { $v = $m.Groups[1].Value }
  }
  if (-not $v) { $Script:PtErr = 'adb не запускается'; return $false }
  if (-not (Test-AdbVer $v)) { $Script:PtErr = ('в архиве старый adb (версия {0})' -f $v); return $false }
  $Script:PtVer = $v
  return $true
}
# New-PtStage <folder>: a fresh temporary folder that can be written to
# (hidden on Windows)
function New-PtStage([string]$st) {
  try {
    if ([IO.Directory]::Exists($st)) { [IO.Directory]::Delete($st, $true) }
    [void][IO.Directory]::CreateDirectory($st)
    if ($IsWin) { try { $di = New-Object IO.DirectoryInfo $st; $di.Attributes = $di.Attributes -bor [IO.FileAttributes]::Hidden } catch { } }
    $t = Join-Path $st 'probe'
    [IO.File]::WriteAllText($t, '', $Utf8); [IO.File]::Delete($t)
    return $true
  } catch {
    Write-Log ('cannot use {0}: {1}' -f $st, $_.Exception.Message)
    try { [IO.Directory]::Delete($st, $true) } catch { }
    return $false
  }
}
function Remove-PtTree([string]$p) {
  if ([IO.Directory]::Exists($p)) { [IO.Directory]::Delete($p, $true) }
  elseif ([IO.File]::Exists($p)) { [IO.File]::Delete($p) }
}
# Test-PtAlive <pid>: that process still runs
function Test-PtAlive([string]$n) {
  $i = 0
  if (-not [int]::TryParse($n, [ref]$i)) { return $false }
  try { $p = [Diagnostics.Process]::GetProcessById($i); $p.Dispose(); return $true } catch { return $false }
}
# Merge-PtDir <old folder> <new folder>: what the old platform-tools folder
# holds and the new one has not (the user's own files, e.g. scrcpy) moves
# into the new one; $Script:PtMoved; $false when something could not be moved
function Merge-PtDir([string]$o, [string]$n) {
  $Script:PtMoved = 0
  if (-not [IO.Directory]::Exists($o) -or -not [IO.Directory]::Exists($n)) { return $true }
  $ok = $true
  try {
    $oi = New-Object IO.DirectoryInfo $o
    if (($oi.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $true }
    foreach ($f in @($oi.GetFileSystemInfos())) {
      $t = Join-Path $n $f.Name
      if ([IO.File]::Exists($t) -or [IO.Directory]::Exists($t)) { continue }
      try {
        if ($f -is [IO.DirectoryInfo]) { [IO.Directory]::Move($f.FullName, $t) } else { [IO.File]::Move($f.FullName, $t) }
        $Script:PtMoved++
        Write-Log ('kept from the old platform-tools folder: ' + $f.Name)
      } catch {
        $ok = $false
        Write-Log ('cannot move from the old platform-tools folder: {0} ({1})' -f $f.Name, $_.Exception.GetBaseException().Message)
      }
    }
  } catch { Write-Log ('merge: ' + $_); return $false }
  return $ok
}
# Remove-PtStale <folder>: what a run that was killed (or whose window was
# closed) during the download left there: its temporary folder goes; a
# platform-tools folder it had moved aside comes back when there is none,
# else what the user had added to it moves into the new one. Not while that
# run still goes (an hour at most)
function Remove-PtStale([string]$par) {
  if (-not $par) { return }
  try {
    if (-not [IO.Directory]::Exists($par)) { return }
    $dst = Join-Path $par 'platform-tools'
    foreach ($d in @(Get-ChildItem -LiteralPath $par -Force -ErrorAction SilentlyContinue)) {
      $nm = $d.Name
      if (-not ($nm.StartsWith('.platform-tools-dl.') -or $nm.StartsWith('.platform-tools-old.'))) { continue }
      $n = $nm.Substring($nm.LastIndexOf('.') + 1)
      if ($n -eq [string]$PID) { continue }
      if ((Test-PtAlive $n) -and $d.LastWriteTime -gt (Get-Date).AddHours(-1)) { continue }
      if ($nm.StartsWith('.platform-tools-old.')) {
        if (-not ([IO.Directory]::Exists($dst) -or [IO.File]::Exists($dst))) {
          try { [IO.Directory]::Move($d.FullName, $dst); Write-Log ('platform-tools folder restored from ' + $nm); continue }
          catch { Write-Log ('cannot restore {0}: {1}' -f $nm, $_.Exception.GetBaseException().Message) }
        } elseif (-not (Merge-PtDir $d.FullName $dst)) { Write-Log ($nm + ' kept: not everything could be moved'); continue }
      }
      try { Remove-PtTree $d.FullName; Write-Log ('old temporary folder removed: ' + $nm) } catch { }
    }
  } catch { }
}
# Remove-PtStage: the temporary folders, a few tries (a curl that was just
# stopped, or an antivirus, may still hold a file there)
function Remove-PtStage {
  foreach ($s in @($Script:PtStage, $Script:PtStage2)) {
    if (-not $s) { continue }
    for ($i = 0; $i -lt 5; $i++) {
      try { if ([IO.Directory]::Exists($s)) { [IO.Directory]::Delete($s, $true) }; break }
      catch {
        if ($i -eq 4) { Write-Log ('temporary folder not removed: ' + $_.Exception.Message) }
        else { Start-Sleep -Milliseconds 400 }
      }
    }
  }
  $Script:PtStage = $null; $Script:PtStage2 = $null
}
# Move-PtDir <from> <to>: '' or the reason; a few tries (an antivirus may
# still be reading the new files). No Ctrl+C here: the swap of the
# platform-tools folders is not cut in the middle
function Move-PtDir([string]$a, [string]$b) {
  $e = ''
  for ($i = 0; $i -lt 5; $i++) {
    if ($i -gt 0) { Start-Sleep -Seconds 1 }
    try { [IO.Directory]::Move($a, $b); return '' }
    catch { $e = $_.Exception.GetBaseException().Message; Write-Log ('move {0} -> {1}: {2}' -f $a, $b, $e) }
  }
  return $e
}
# Install-PtDir <new platform-tools> <folder>: the new folder in place of
# <folder>\platform-tools (an old one goes aside first and comes back if the
# new one cannot be put there); '' or the reason
function Install-PtDir([string]$src, [string]$par) {
  $dst = Join-Path $par 'platform-tools'
  $old = Join-Path $par ('.platform-tools-old.' + $PID)
  $had = ([IO.Directory]::Exists($dst) -or [IO.File]::Exists($dst))
  if ($had) {
    try { Remove-PtTree $old } catch { }
    $e = Move-PtDir $dst $old
    if ($e) { return ('не удаётся заменить старую папку «{0}» ({1})' -f $dst, $e) }
    $Script:PtOld = $old; $Script:PtDst = $dst
  }
  $e = Move-PtDir $src $dst
  if ($e) {
    if ($had -and (Move-PtDir $old $dst)) {
      WarnM ('Старая папка platform-tools сейчас называется «{0}» — переименуйте её обратно в platform-tools.' -f $old)
    }
    $Script:PtOld = $null; $Script:PtDst = $null
    return ('не удаётся положить папку platform-tools в «{0}» ({1})' -f $par, $e)
  }
  $Script:PtOld = $null; $Script:PtDst = $null
  if (-not $had) { return '' }
  if (Merge-PtDir $old $dst) {
    try { Remove-PtTree $old } catch { Write-Log ('old platform-tools folder not removed: ' + $_.Exception.Message) }
  } else {
    $keep = Join-Path $par ('platform-tools.old-' + (Get-Date).ToString('yyyyMMdd-HHmmss'))
    if (Move-PtDir $old $keep) { $keep = $old }
    WarnM ('Не все файлы из старой папки platform-tools удалось перенести в новую — старая папка сохранена как «{0}».' -f $keep)
  }
  if ($Script:PtMoved -gt 0) { Say ('Файлы из старой папки platform-tools, которых нет в новой ({0}), перенесены в неё.' -f $Script:PtMoved) }
  return ''
}
# Install-Pt <zip> <temporary folder> <folder> <old version> <old adb>: the
# archive is unpacked into the temporary folder and checked, an older adb
# server is stopped, and platform-tools goes into <folder>; '' or the
# reason, $Script:PtWhere: check, unpack, long or place
function Install-Pt([string]$zip, [string]$st, [string]$par, [string]$oldV, [string]$oldP) {
  $x = Join-Path $st 'x'
  try { Remove-PtTree $x } catch { }
  if (-not (Expand-PtZip $zip $x)) { return $Script:PtErr }
  $Script:PtWhere = 'check'
  if (-not (Test-PtAdb (Join-Path $x 'platform-tools'))) { return $Script:PtErr }
  # (the new adb restarts an older server anyway; it is stopped here with its
  # own adb, and only when the versions differ)
  if ($oldP -and -not $Script:PtKilled -and $oldV -ne $Script:PtVer) {
    $Script:PtKilled = $true
    try { $r = Invoke-Adb @('kill-server') 15 '' $true $oldP; Write-Log ('old adb server stopped: {0} kill-server, rc {1}' -f $oldP, $r.Code) }
    catch { if ("$_" -eq 'MERUDEV-EXIT') { throw }; Write-Log ('old adb kill-server: ' + $_) }
  }
  $Script:PtWhere = 'place'
  return (Install-PtDir (Join-Path $x 'platform-tools') $par)
}
# Get-PlatformTools <old version> <old adb>: 'ok' when a fresh adb is in
# place ($Script:Adb, $Script:AdbVer); 'no' when the user said no; 'fail'
# (the reason is on the screen)
function Get-PlatformTools([string]$oldV, [string]$oldP) {
  $Script:PtErr = ''; $Script:PtZip = ''; $Script:PtVer = ''; $Script:PtWhere = ''; $Script:PtKilled = $false
  $auto = Get-PtAuto
  if ($auto -eq '0') { Write-Log 'adb download: off (TAOYAO_ADB_DOWNLOAD=0)'; return 'fail' }
  $u = Get-PtUrl
  if ($u -eq 2) { Write-Host ''; WarnM ('Автоматическая загрузка adb недоступна: {0}.' -f $Script:PtErr); return 'fail' }
  if ($u -ne 0) { Write-Host ''; ErrM $Script:PtErr; return 'fail' }
  $curl = ''
  $cn = 'curl'; if ($IsWin) { $cn = 'curl.exe' }
  try { $c = @(Get-Command -Name $cn -CommandType Application -ErrorAction SilentlyContinue); if ($c.Count -gt 0) { $curl = $c[0].Path } } catch { }
  $a = Read-PtAnswer $oldV $auto
  if ($a -eq 'no') { return 'no' }
  if ($a -ne 'yes') { return 'fail' }
  # (next to the script; a folder there that cannot be written: per-user)
  $ud = Get-PtUserDir; $up = ''
  if ($ud) { $up = [IO.Path]::GetDirectoryName($ud) }
  $par = $Here; $ro = $false
  $st = Join-Path $par ('.platform-tools-dl.' + $PID)
  if (-not (New-PtStage $st)) {
    $ok = $false
    if ($up) {
      $par = $up
      $st = Join-Path $par ('.platform-tools-dl.' + $PID)
      $ok = New-PtStage $st
    }
    if (-not $ok) { ErrM 'Не удаётся создать папку для adb ни рядом со скриптом, ни в папке пользователя.'; return 'fail' }
    $ro = $true
    Write-Log 'the script folder is read-only: adb goes to the per-user folder'
  }
  $Script:PtStage = $st
  # (Windows PowerShell 5.1 on an older .NET offers only TLS 1.0 by default)
  try {
    $sp = [Net.ServicePointManager]::SecurityProtocol
    if ([int]$sp -ne 0) { [Net.ServicePointManager]::SecurityProtocol = $sp -bor [Net.SecurityProtocolType]::Tls12 }
  } catch { Write-Log ('TLS 1.2: ' + $_) }
  Step 'Скачиваю Android SDK Platform-Tools с сайта Google…'
  Write-Log ('download: {0} into {1}' -f $Script:PtZip, $st)
  $zip = Join-Path $st 'platform-tools.zip'
  $n = 1; $e1 = ''; $net = $false; $disk = $false
  while ($true) {
    # (the second try with curl.exe, when Windows has it)
    $use = ''; if ($n -ge 2) { $use = $curl }
    if (Invoke-PtGet $Script:PtZip $st 'platform-tools.zip' $use) { break }
    if ($Script:PtKind -eq 'net') { $net = $true } elseif ($Script:PtKind -eq 'disk') { $disk = $true }
    if ($n -ge 2) {
      $two = '2-я'; if ($use) { $two = '2-я (curl)' }
      if ($e1 -eq $Script:PtErr) { $m = $e1 } else { $m = '1-я попытка: {0}; {1}: {2}' -f $e1, $two, $Script:PtErr }
      if ($disk) { $hint = ' Освободите место на диске и запустите скрипт снова.' }
      elseif ($net) { $hint = ' Проверьте подключение к интернету; на рабочем компьютере загрузку может запрещать прокси-сервер или антивирус.' }
      else { $hint = ' Попробуйте позже.' }
      ErrM ('Не удалось скачать Android SDK Platform-Tools ({0}).{1}' -f $m, $hint)
      Remove-PtStage; return 'fail'
    }
    $e1 = $Script:PtErr
    WarnM ('Не удалось скачать ({0}). Пробую ещё раз…' -f $Script:PtErr)
    $n++; Wait-Sec 3
  }
  Say 'Проверяю скачанный архив…'
  $e = Install-Pt $zip $st $par $oldV $oldP
  # (the platform-tools folder next to the script cannot be replaced, e.g. a
  # program still uses it, or the path is too long: the per-user folder,
  # which is searched too)
  if ($e -and $par -eq $Here -and $up -and ($Script:PtWhere -eq 'place' -or $Script:PtWhere -eq 'long')) {
    WarnM ('Не получилось положить adb рядом со скриптом: {0}. Сохраняю его в папку пользователя.' -f $e)
    $st2 = Join-Path $up ('.platform-tools-dl.' + $PID)
    if (New-PtStage $st2) {
      $Script:PtStage2 = $st2
      $e2 = Install-Pt $zip $st2 $up $oldV $oldP
      if ($e2) { $e = $e2 } else { $e = ''; $par = $up }
    }
  }
  if ($e) {
    switch ($Script:PtWhere) {
      'check' { ErrM ('Скачанный архив не прошёл проверку: {0}. Он удалён, ничего не установлено.' -f $e) }
      'place' { ErrM ('Не удаётся установить adb: {0}. Закройте программы, которые используют папку platform-tools, и запустите скрипт снова.' -f $e) }
      default { ErrM ('Не удалось распаковать скачанный архив ({0}). Он удалён, ничего не установлено.' -f $e) }
    }
    Remove-PtStage; return 'fail'
  }
  Remove-PtStage
  $dst = Join-Path $par 'platform-tools'
  if ($IsWin) { $Script:Adb = Join-Path $dst 'adb.exe' } else { $Script:Adb = Join-Path $dst 'adb' }
  $Script:AdbVer = $Script:PtVer
  Write-Log ('adb: {0} (version {1}, downloaded)' -f $Script:Adb, $Script:AdbVer)
  GoodM ('Готово: Android SDK Platform-Tools скачаны и проверены (adb {0}).' -f $Script:AdbVer)
  if ($par -ne $Here -and $ro) {
    Say ('В папку со скриптами нельзя записывать, поэтому adb сохранён в «{0}» — там он найдётся и в следующий раз.' -f $dst)
  } elseif ($par -ne $Here) {
    Say ('adb сохранён в «{0}» — там он найдётся и в следующий раз.' -f $dst)
  }
  return 'ok'
}

########################################################################
# the phone: devices, root, info
function Scan-Devices {
  $Script:DState = 'none'; $Script:DList = ''; $Script:DSer = $null; $Script:MultiPick = $false
  # (logged only after its serials are in the mask list)
  $r = Invoke-Adb @('devices', '-l') 10 '' $true '' $true
  $re = '^(\S+)\s+(no permissions|device|unauthorized|offline|recovery|sideload|bootloader|rescue|authorizing|connecting|host)(\s.*)?$'
  $n = 0; $nt = 0; $tser = $null; $tst = ''; $aser = $null; $ast = ''; $one = $null; $onest = ''
  $sb = New-Object System.Text.StringBuilder
  foreach ($l in ($r.Out -split "`r?`n")) {
    $m = [regex]::Match($l, $re)
    if (-not $m.Success) { continue }
    $s = $m.Groups[1].Value; $st = $m.Groups[2].Value; $rest = $m.Groups[3].Value
    Add-Serial $s
    $model = '?'; $dn = '?'
    $mm = [regex]::Match($rest, 'model:(\S+)'); if ($mm.Success) { $model = $mm.Groups[1].Value }
    $md = [regex]::Match($rest, 'device:(\S+)'); if ($md.Success) { $dn = $md.Groups[1].Value }
    $n++; $one = $s; $onest = $st
    $short = $s; if ($short.Length -gt 2) { $short = $short.Substring(0, 2) }
    [void]$sb.Append(('  {0} ({1}), серийный номер {2}…' -f $model, $dn, $short) + "`r`n")
    if ($env:ANDROID_SERIAL -and $s -eq $env:ANDROID_SERIAL) { $aser = $s; $ast = $st }
    if ($dn -eq 'taoyao') { $nt++; $tser = $s; $tst = $st }
  }
  $Script:DList = $sb.ToString()
  Write-Log ($r.Out + $r.Err).TrimEnd()
  Write-Log ('devices: {0}' -f $n)
  if ($env:ANDROID_SERIAL) {
    if ($aser) { $Script:DSer = $aser; $Script:DState = $ast } else { $Script:DState = 'serialgone' }
    return
  }
  if ($n -eq 0) { $Script:DState = 'none'; return }
  if ($n -eq 1) { $Script:DSer = $one; $Script:DState = $onest; return }
  if ($nt -eq 1) { $Script:DSer = $tser; $Script:DState = $tst; $Script:MultiPick = $true; return }
  $Script:DState = 'multi'
}
# Wait-Device [limit seconds]: until one phone is in state "device"
function Wait-Device([int]$lim = 180) {
  $Script:Phase = 'wait'
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $last = ''; $offT = -1; $rec = $false; $fb = $false; $nextEl = 15
  while ($true) {
    Scan-Devices
    $st = $Script:DState
    if ($st -ne $last) {
      Write-Log ('device state: ' + $st)
      switch ($st) {
        'none' { Write-Host $T_WaitNone; Write-Log 'no phone'; Say ('Жду подключения телефона… (до {0} мин)' -f [int]($lim / 60)) }
        'unauthorized' { WarnM $T_Unauth }
        'authorizing' { Say 'Телефон подключается…' }
        'connecting' { Say 'Телефон подключается…' }
        'host' { Say 'Телефон подключается…' }
        'offline' { WarnM $T_Offline }
        'recovery' { Fail $T_Recovery }
        'rescue' { Fail $T_Recovery }
        'sideload' { Fail $T_Sideload }
        'bootloader' { Fail $T_Fastboot }
        'no permissions' { Fail $T_NoPerm }
        'serialgone' { Fail 'Переменная ANDROID_SERIAL указывает на устройство, которого сейчас нет. Подключите его или удалите эту переменную.' }
        'multi' { Fail ("Подключено несколько Android-устройств (или запущен эмулятор):`r`n" + $Script:DList + 'Оставьте подключённым только Xiaomi Mi 12 Lite и запустите скрипт снова (или задайте переменную ANDROID_SERIAL).') }
      }
      $last = $st
    }
    if ($st -eq 'device') {
      $Script:Serial = $Script:DSer
      if ($Script:MultiPick) { Say 'Подключено несколько устройств; выбран Xiaomi Mi 12 Lite.' }
      $Script:Phase = ''
      return
    }
    $el = [int]$sw.Elapsed.TotalSeconds
    if ($st -eq 'offline') {
      if ($offT -lt 0) { $offT = $el }
      if (-not $rec -and ($el - $offT) -ge 20) { $rec = $true; [void](Invoke-Adb @('reconnect', 'offline') 10 '' $true) }
    } else { $offT = -1 }
    if ($st -eq 'none' -and -not $fb -and $el -ge 20 -and $Script:Adb) {
      $fbx = Join-Path ([IO.Path]::GetDirectoryName($Script:Adb)) 'fastboot.exe'
      if (-not $IsWin) { $fbx = Join-Path ([IO.Path]::GetDirectoryName($Script:Adb)) 'fastboot' }
      $fb = $true
      if ([IO.File]::Exists($fbx)) {
        try {
          $fr = Invoke-Adb @('devices') 5 '' $true $fbx $true
          foreach ($l in ($fr.Out -split "`r?`n")) { $x = @($l -split '\s+'); if ($x.Count -ge 2 -and $x[1] -eq 'fastboot') { Add-Serial $x[0] } }
          Write-Log ('fastboot devices: ' + $fr.Out.Trim())
          if ($fr.Out -match 'fastboot') { Fail $T_Fastboot }
        }
        catch { if ("$_" -eq 'MERUDEV-EXIT') { throw } }
      }
    }
    if ($el -ge $nextEl -and $el -lt $lim) { Say ('… жду ' + (Format-Elapsed $el)); $nextEl += 15 }
    if ($el -ge $lim) {
      if ($Script:KeysOk) {
        if (Ask-Yes ('Телефон так и не подключился за {0} мин. Подождать ещё? (Д или Enter — подождать, Н или Esc — выйти)' -f [int]($lim / 60)) $false 'подождать' 'выйти') {
          $sw.Reset(); $sw.Start(); $nextEl = 15; $last = ''; continue
        }
        Stop-Run $RC_CANCEL
      }
      Fail ('Телефон так и не подключился за {0} мин. Проверьте пункты выше и запустите скрипт снова.' -f [int]($lim / 60))
    }
    Wait-Sec 2
  }
}
function Test-Root {
  $r = Invoke-Dev 'id -u' $false 20
  if ($r.Out.Trim() -eq '0') { $Script:AdbRoot = $true; Say 'Права root: adb уже работает от root.'; return }
  $Script:AdbRoot = $false
  while ($true) {
    $try = 1; $nosu = $false; $outx = ''
    while ($try -le 3) {
      $p = Start-AdbProc @('shell', 'su -c id') '' $false ''
      $Script:AdbProc = $p
      $to = $p.StandardOutput.ReadToEndAsync(); $te = $p.StandardError.ReadToEndAsync()
      $sw = [Diagnostics.Stopwatch]::StartNew(); $shown = $false; $timedOut = $false
      while (-not $p.WaitForExit(200)) {
        Test-Interrupt
        if (-not $shown -and $sw.Elapsed.TotalSeconds -ge 5) { $shown = $true; Say 'Жду ответа на запрос прав root на экране телефона…' }
        if ($sw.Elapsed.TotalSeconds -ge 30) { try { $p.Kill() } catch { }; $timedOut = $true; break }
      }
      try { [void][Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($to, $te), 2000) } catch { }
      $outx = ''
      if ($to.IsCompleted -and -not $to.IsFaulted) { $outx += $to.Result }
      if ($te.IsCompleted -and -not $te.IsFaulted) { $outx += $te.Result }
      $code = 124; if (-not $timedOut) { try { $code = $p.ExitCode } catch { $code = 1 } }
      $Script:AdbProc = $null
      Write-Log ('< rc={0} {1}' -f $code, $outx.Trim())
      if ($outx -match 'uid=0') { Say 'Права root: есть.'; return }
      if ($outx -match "(?i)device '.*' not found|no devices|device offline|error: closed") { Wait-Device; continue }
      if ($code -eq 127 -or $outx -match '(?i)not found|inaccessible|No such file') { $nosu = $true; break }
      if ($try -lt 3) {
        WarnM ('Запрос прав root отклонён или остался без ответа. Если на телефоне появилось окно «Запрос суперпользователя» для Shell — нажмите «Разрешить» (лучше «навсегда»). Пробую ещё раз через 5 секунд… (попытка {0} из 3)' -f ($try + 1))
        Wait-Sec 5
      }
      $try++
    }
    Write-Host ''
    if ($nosu) { ErrM $T_RootNoSu.TrimEnd() }
    else {
      $first = ($outx.Trim() -split "`r?`n")[0]
      if ($first.Length -gt 120) { $first = $first.Substring(0, 120) }
      ErrM ('Не удалось получить права root ({0}). Проверьте настройки root:' -f $first)
      Say $T_RootHow.TrimEnd()
    }
    if ($Script:KeysOk) {
      if (Ask-Yes 'Проверить ещё раз? (Д или Enter — проверить, Н или Esc — выйти)' $false 'проверить' 'выйти') { continue }
      Stop-Run $RC_CANCEL
    }
    Fail ''
  }
}

$I1 = 'set -f; for p in ro.product.device ro.product.vendor.device ro.product.model ro.build.version.release ro.build.display.id sys.boot_completed sys.user.0.ce_available; do echo $p=$(getprop $p); done; echo kr=$(uname -r); echo kv=$(uname -v); echo boot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null); echo now=$(date +%s); echo df=$(df -k /data 2>/dev/null | tail -n 1); [ -d /sdcard/Android ] && echo sd=1; echo end=1'

# Get-KernelLine: build N from "-v0.N" in uname -r (build 18 on), else from
# the build date (builds 15-17 all say 6.12.96-taoyao #1)
function Get-KernelLine([string]$kr, [string]$kv) {
  $b = ''
  $mb = [regex]::Match($kr, '-v0\.(\d+)')
  if ($mb.Success) { $b = $mb.Groups[1].Value }
  $date = ''
  $m = [regex]::Match($kv, '\b(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\s+(\d{1,2})\s+(\d{1,2}):(\d{2}):\d{2}\s+(?:\S+\s+)?(\d{4})')
  if ($m.Success) {
    $mon = 1 + [array]::IndexOf(@('Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'), $m.Groups[1].Value)
    $d = [int]$m.Groups[2].Value; $hh = [int]$m.Groups[3].Value; $mi = [int]$m.Groups[4].Value; $y = [int]$m.Groups[5].Value
    $date = '{0:00}.{1:00}.{2} {3:00}:{4:00} UTC' -f $d, $mon, $y, $hh, $mi
    if (-not $b) {
      # (zip times of builds 15-17; the kernel is built a few minutes before)
      $key = [long]('{0}{1:00}{2:00}{3:00}{4:00}' -f $y, $mon, $d, $hh, $mi)
      if ($key -gt 202611121740 -and $key -le 202611121910) { $b = '15' }
      elseif ($key -gt 202611122043 -and $key -le 202611122213) { $b = '16' }
      elseif ($key -gt 202611130013 -and $key -le 202611130143) { $b = '17' }
    }
  }
  $s = 'Ядро: ' + $kr
  if ($date) { $s += ', собрано ' + $date }
  if ($b) { $s += ' (сборка 0.' + $b + ')' } else { $s += ' (номер сборки не определён)' }
  return $s
}
function Get-PhoneInfo {
  $waited = 0; $shown = ''
  while ($true) {
    $r = Invoke-Dev $I1 $false 20
    if ($r.Code -ne 0 -or -not (Get-KV $r.Out 'end')) {
      if (Test-Lost $r) { Wait-Device; continue }
      $first = (($r.Out + $r.Err).Trim() -split "`r?`n")[0]
      Fail ('Телефон не ответил ({0}).' -f $first)
    }
    $o = $r.Out
    $dev = Get-KV $o 'ro.product.device'; $vdev = Get-KV $o 'ro.product.vendor.device'; $model = Get-KV $o 'ro.product.model'
    $rel = Get-KV $o 'ro.build.version.release'; $rom = Get-KV $o 'ro.build.display.id'
    $bc = Get-KV $o 'sys.boot_completed'; $ce = Get-KV $o 'sys.user.0.ce_available'; $sd = Get-KV $o 'sd'
    $kr = Get-KV $o 'kr'; $kv = Get-KV $o 'kv'; $Script:BootId = Get-KV $o 'boot'; $df = Get-KV $o 'df'
    $now = [long]0; [void][long]::TryParse((Get-KV $o 'now'), [ref]$now); $Script:Start = $now
    if ($bc -ne '1') {
      if (-not $shown) { $shown = 'boot'; Say 'Телефон ещё загружается — жду окончания загрузки… (до 5 минут)' }
    } elseif ($ce -ne 'true' -and $sd -ne '1') {
      if ($shown -ne 'lock') { $shown = 'lock'; WarnM 'Разблокируйте экран телефона (PIN-код, пароль или графический ключ): пока телефон не разблокирован после включения, его память недоступна. Жду… (до 5 минут)' }
    } else { break }
    if ($waited -ge 300) { Fail 'Телефон не загрузился или не был разблокирован за 5 минут.' }
    Wait-Sec 5; $waited += 5
    if (($waited % 30) -eq 0) { Say ('… жду ' + (Format-Elapsed $waited)) }
  }
  if ($dev -ne 'taoyao' -and $vdev -ne 'taoyao' -and $kr -notmatch 'taoyao') {
    if (-not $model) { $model = '?' }; if (-not $dev) { $dev = '?' }
    ErrM ('Подключено устройство «{0}» ({1}), а этот сборщик — только для Xiaomi Mi 12 Lite (taoyao).' -f $model, $dev)
    if ($Script:KeysOk) {
      if (-not (Ask-Yes ('Всё равно продолжить? ' + $T_YN) $false)) { Stop-Run $RC_FAIL }
    } else { Fail 'Остановлено.' }
  }
  if (-not $Script:ShownPhone) {
    $Script:ShownPhone = $true
    if (-not $model) { $model = '?' }; if (-not $rel) { $rel = '?' }; if (-not $rom) { $rom = '?' }
    Say ('Телефон: Xiaomi Mi 12 Lite ({0}), Android {1}, прошивка {2}' -f $model, $rel, $rom)
    Say (Get-KernelLine $kr $kv)
    if (-not $kr.StartsWith('6.12.')) { WarnM ('Внимание: на телефоне ядро {0}, а сборщик рассчитан на ядро 6.12. Проверка всё равно выполнится.' -f $kr) }
  }
  $f = @($df -split '\s+')
  if ($f.Count -ge 4) {
    $av = [long]0
    if ([long]::TryParse($f[3], [ref]$av) -and $av -lt 204800) {
      WarnM ('Внимание: на телефоне свободно всего {0} МБ. Для проверки нужно около 200 МБ — освободите место, иначе архив может не записаться.' -f [int]($av / 1024))
    }
  }
  if ($Script:Serial -match ':|\._adb-tls-connect\.') {
    $w = ' ' + $Script:Words + ' '
    if ($w.Contains(' hotspot ') -or $w.Contains(' deep ')) { WarnM 'Телефон подключён к adb по сети, а не кабелем. Для проверки точки доступа и глубокой проверки лучше подключить кабель.' }
  }
}
function Initialize-Phone { Wait-Device; Test-Root; Get-PhoneInfo }

# busy probe: checks running in the background (lock, hotspot, mic) and the
# charge logger
# (lock: its worker, lock/wpid; lock/pid for an older phone script)
$P1 = 'set -f; d=/data/local/tmp; for k in check.lock check-hotspot check-mic charge; do f=$d/taoyao-$k.pid; [ $k = check.lock ] && { f=$d/taoyao-check.lock/wpid; [ -s $f ] || f=$d/taoyao-check.lock/pid; }; p=$(cat $f 2>/dev/null); a=0; c=; m=; md=; if [ x$p != x ] && kill -0 $p 2>/dev/null && ! grep -q State:.Z /proc/$p/status 2>/dev/null; then a=1; c=$(xargs -0 < /proc/$p/cmdline 2>/dev/null); fi; [ -f $f ] && m=$(stat -c %Y $f 2>/dev/null); [ $k = check.lock ] && md=$(cat $d/taoyao-check.lock/mode 2>/dev/null); echo P:$k:$p:$a:$m:$md:$c; done; echo now=$(date +%s)'
function Invoke-Probe {
  $Script:BusyChk = ''; $Script:BusyChkT = [long]0; $Script:ChgAlive = $false; $Script:ChgPidV = ''
  $Script:ChgStart = [long]0; $Script:ChgM = ''; $Script:ChgPf = $false; $Script:PNow = [long]0
  $r = Invoke-Dev $P1 $true 20
  if ($r.Code -ne 0) { return $false }
  $nowS = Get-KV $r.Out 'now'
  if (-not $nowS) { return $false }
  [void][long]::TryParse($nowS, [ref]$Script:PNow)
  foreach ($l in ($r.Out -split "`r?`n")) {
    if (-not $l.StartsWith('P:')) { continue }
    $f = $l.Split([char[]]@([char]':'), 7)
    if ($f.Count -lt 7) { continue }
    $k = $f[1]; $pid0 = $f[2]; $a = $f[3]; $m = [long]0; [void][long]::TryParse($f[4], [ref]$m); $md = $f[5]
    $c = ' ' + $f[6].TrimEnd() + ' '
    if ($a -eq '1' -and -not $c.Contains('taoyao-check')) { $a = '0' }
    switch ($k) {
      'check.lock' { if ($a -eq '1') { if ($md) { $Script:BusyChk = $md } else { $Script:BusyChk = 'check' }; $Script:BusyChkT = $m } }
      'check-hotspot' { if ($a -eq '1' -and $c.Contains(' hotspot ') -and -not $Script:BusyChk) { $Script:BusyChk = 'hotspot'; $Script:BusyChkT = $m } }
      'check-mic' { if ($a -eq '1' -and $c.Contains(' mic ') -and -not $Script:BusyChk) { $Script:BusyChk = 'mic'; $Script:BusyChkT = $m } }
      'charge' {
        if ($f[4]) { $Script:ChgPf = $true }
        if ($a -eq '1' -and $c.Contains(' charge ')) {
          $Script:ChgAlive = $true; $Script:ChgPidV = $pid0; $Script:ChgStart = $m
          $nums = @([regex]::Matches($c, '(?<=\s)\d+(?=\s)') | ForEach-Object { $_.Value })
          if ($nums.Count -gt 0) { $Script:ChgM = $nums[$nums.Count - 1] }
        }
      }
    }
  }
  $bc = $Script:BusyChk; if (-not $bc) { $bc = 'none' }
  Write-Log ('probe: check={0} charge={1}' -f $bc, $Script:ChgAlive)
  return $true
}
function Get-ChargeLeft {
  $cm = 40; if ($Script:ChgM) { $cm = [int]$Script:ChgM }
  $st = $Script:ChgStart; if ($st -le 0) { $st = $Script:PNow }
  $left = $cm * 60 - ($Script:PNow - $st)
  if ($left -lt 0) { $left = 0 }
  return [int]$left
}
# Wait-Background [limit seconds]: while a check runs on in the background
function Wait-Background([int]$lim = 1200) {
  $Script:Phase = 'hs'
  $sw = [Diagnostics.Stopwatch]::StartNew(); $next = 0
  while ($true) {
    if (-not (Invoke-Probe)) {
      if (Test-Lost $Script:Dc) {
        WarnM 'Связь с телефоном прервалась — проверка продолжается на телефоне. Подключите кабель снова, как только сможете.'
        Wait-Device 600; $Script:Phase = 'hs'; continue
      }
      Wait-Sec 5; continue
    }
    if (-not $Script:BusyChk) { $Script:Phase = ''; return }
    # (deep: the phone's own watchdog allows 60 minutes and the watch window)
    if ($Script:BusyChk -match 'deep' -and $lim -lt 4000) { $lim = 4000 }
    $el = [int]$sw.Elapsed.TotalSeconds
    if ($el -ge $next) {
      Say ('{0} ещё идёт на телефоне ({1}). Жду её окончания…' -f (Get-Cap (Get-BusyName $Script:BusyChk)), (Format-Elapsed $el))
      $next += 30
    }
    if ($el -ge $lim) {
      $Script:Phase = ''
      Fail ('{0} идёт слишком долго. Скрипт перестаёт ждать; запустите его позже — он предложит забрать результат.' -f (Get-Cap (Get-BusyName $Script:BusyChk)))
    }
    Wait-Sec 5
  }
}

########################################################################
# fetch and verify
function Get-F1([string]$k) {
  return ('set -f; r=/data/local/tmp/taoyao-@K@-result.txt; sed -n 1s/^/res=/p $r 2>/dev/null; echo resm=$(stat -c %Y $r 2>/dev/null); x=$(head -n 1 $r 2>/dev/null | cut -f2); for f in $x /sdcard/taoyao-@K@.tar.gz /data/local/tmp/taoyao-check-out/taoyao-@K@.tar.gz; do echo st=$(stat -c %s:%Y $f 2>/dev/null):$f; [ -e $f.part ] && echo part=$f; done; echo now=$(date +%s)').Replace('@K@', $k)
}
function Invoke-Pull([string]$remote, [string]$name) {
  $lp = Join-Path $Script:Out $name
  if ([IO.File]::Exists($lp)) { try { [IO.File]::Delete($lp) } catch { } }
  $r = Invoke-Adb @('pull', $remote, $name) 300 $Script:Out
  if (($r.Out + $r.Err) -match '(?i)Permission denied|Access is denied|Отказано в доступе') {
    if (-not ($remote.StartsWith('/data/'))) {
      WarnM ('Windows не дал adb записать файл в папку «{0}». Возможно, включена защита «Контролируемый доступ к папкам». Перенесите папку со скриптами, например, в C:\MeruDevTools и запустите снова.' -f $Script:Out)
    }
  }
  return ($r.Code -eq 0)
}
function Read-Full($stream, [byte[]]$buf, [int]$count) {
  $off = 0
  while ($off -lt $count) {
    $n = $stream.Read($buf, $off, $count - $off)
    if ($n -le 0) { return $false }
    $off += $n
  }
  return $true
}
function Get-Octal([byte[]]$h, [int]$off, [int]$len) {
  if (($h[$off] -band 0x80) -ne 0) {
    $v = [long]0
    for ($i = $off + 1; $i -lt $off + $len; $i++) { $v = $v * 256 + $h[$i] }
    return $v
  }
  $s = [Text.Encoding]::ASCII.GetString($h, $off, $len).Trim([char[]]@([char]0, [char]32))
  if (-not $s) { return [long]0 }
  return [Convert]::ToInt64($s, 8)
}
# Get-TarList <file>: names in a .tar.gz (managed reader, used when tar.exe
# is missing); throws on a damaged or cut archive
function Get-TarList([string]$path) {
  $names = New-Object 'System.Collections.Generic.List[string]'
  $fs = [IO.File]::OpenRead($path)
  try {
    $gz = New-Object IO.Compression.GZipStream($fs, [IO.Compression.CompressionMode]::Decompress)
    $h = New-Object byte[] 512
    $buf = New-Object byte[] 65536
    $long = $null
    while ($true) {
      if (-not (Read-Full $gz $h 512)) { throw 'архив обрывается' }
      if ($h[0] -eq 0 -and $h[124] -eq 0 -and $h[148] -eq 0) {
        # (the stream to its end: GZipStream checks the CRC and length of the
        # gzip trailer only there)
        try { while ($gz.Read($buf, 0, $buf.Length) -gt 0) { } }
        catch { throw 'архив повреждён (контрольная сумма не сходится)' }
        return ,$names
      }
      $name = [Text.Encoding]::UTF8.GetString($h, 0, 100)
      $z = $name.IndexOf([char]0); if ($z -ge 0) { $name = $name.Substring(0, $z) }
      if ([Text.Encoding]::ASCII.GetString($h, 257, 5) -eq 'ustar') {
        $pre = [Text.Encoding]::UTF8.GetString($h, 345, 155)
        $z = $pre.IndexOf([char]0); if ($z -ge 0) { $pre = $pre.Substring(0, $z) }
        if ($pre) { $name = $pre + '/' + $name }
      }
      $size = Get-Octal $h 124 12
      $type = [char]$h[156]
      $data = $null
      if ($type -eq [char]'L' -or $type -eq [char]'x') {
        if ($size -gt 1048576) { throw 'неверный заголовок' }
        $data = New-Object byte[] ([int]([Math]::Ceiling($size / 512.0) * 512))
        if (-not (Read-Full $gz $data $data.Length)) { throw 'архив обрывается' }
        if ($type -eq [char]'L') {
          $long = [Text.Encoding]::UTF8.GetString($data, 0, [int]$size).TrimEnd([char]0)
        } else {
          $px = [Text.Encoding]::UTF8.GetString($data, 0, [int]$size)
          $pm = [regex]::Match($px, '(?m)^\d+ path=(.*)$')
          if ($pm.Success) { $long = $pm.Groups[1].Value }
        }
        continue
      }
      if ($long) { $name = $long; $long = $null }
      if ($type -ne [char]'g') { $names.Add($name) }
      $left = [long]([Math]::Ceiling($size / 512.0) * 512)
      while ($left -gt 0) {
        $c = $buf.Length; if ($left -lt $c) { $c = [int]$left }
        if (-not (Read-Full $gz $buf $c)) { throw 'архив обрывается' }
        $left -= $c
      }
    }
  } finally { $fs.Dispose() }
}
# Test-Archive <name> <kind> <size>: size, gzip and tar listing, top folder
function Test-Archive([string]$name, [string]$kind, [string]$size) {
  $Script:VWhat = ''
  $lp = Join-Path $Script:Out $name
  if (-not [IO.File]::Exists($lp)) { $Script:VWhat = 'файла нет'; return $false }
  $lsz = (New-Object IO.FileInfo $lp).Length
  if ($size -and [string]$lsz -ne $size) { $Script:VWhat = ('размер {0} вместо {1}' -f $lsz, $size); return $false }
  $list = $null
  $tarx = ''
  if ($IsWin -and $env:SystemRoot) { $tarx = Join-Path $env:SystemRoot 'System32\tar.exe' }
  if ($env:MERUDEV_TAR) { $tarx = $env:MERUDEV_TAR }
  if ($tarx -and [IO.File]::Exists($tarx)) {
    $r = Invoke-Adb @('-tzf', $name) 60 $Script:Out $true $tarx
    if ($r.Code -ne 0) { $Script:VWhat = ('архив не читается: ' + (($r.Err.Trim() -split "`r?`n")[0])); return $false }
    $list = @($r.Out -split "`r?`n" | Where-Object { $_ })
  } else {
    try { $list = @((Get-TarList $lp).ToArray()) }
    catch { $Script:VWhat = ('архив не читается: ' + $_.Exception.Message); return $false }
  }
  if ($list.Count -eq 0) { $Script:VWhat = 'архив пуст'; return $false }
  $top = ($list[0] -replace '^\./', '').Split('/')[0]
  if ($top -notmatch ('^taoyao-' + $kind + '-\d{8}-\d{6}$')) { $Script:VWhat = ('неожиданное содержимое ({0})' -f $top); return $false }
  $want = $top + '/taoyao-' + $kind + '.txt'
  $found = $false
  foreach ($e in $list) { if (($e -replace '^\./', '') -eq $want) { $found = $true; break } }
  if (-not $found) { $Script:VWhat = 'в архиве нет отчёта'; return $false }
  if ($Script:RunIds.Count -gt 0 -and -not $Script:RunIds.Contains($top)) { Write-Log ('archive folder {0} is not among the run ids seen' -f $top) }
  return $true
}
function Test-PrevArchive {
  $pp = Join-Path $Script:Out 'taoyao-check-previous.tar.gz'
  if (-not [IO.File]::Exists($pp)) { return $false }
  try { $n = (Get-TarList $pp).Count; return ($n -gt 0) } catch { Write-Log ('previous archive: ' + $_.Exception.Message); return $false }
}
function Invoke-Fetch([string]$kind, [bool]$fresh) {
  $Script:Phase = 'wait'
  Step 'Забираю результаты…'
  $waited = 0
  $Script:FRes = ''; $Script:FReason = ''
  while ($true) {
    $r = Invoke-Dev (Get-F1 $kind) $true 20
    if ($r.Code -ne 0) { if (Test-Lost $r) { Wait-Device 600; continue }; Fail 'Телефон не ответил.' }
    $o = $r.Out
    $res = Get-KV $o 'res'; $resmS = Get-KV $o 'resm'; $part = Get-KV $o 'part'
    $resm = [long]0; [void][long]::TryParse($resmS, [ref]$resm)
    $rp = ''
    if ($res -and $resm -gt 0 -and ((-not $fresh) -or $resm -ge ($Script:Start - 5))) {
      $rf = @($res.Split("`t"))
      $Script:FRes = $rf[0]; if ($rf.Count -ge 6) { $Script:FReason = $rf[5] }
      foreach ($x in $rf) { if ($x -match '^/.*\.tar\.gz$') { $rp = $x; break } }
      Write-Log ('result file: ' + $res.Replace("`t", ' '))
    }
    $path = ''; $size = ''; $mt = [long]0
    foreach ($pass in @(1, 2)) {
      foreach ($l in ($o -split "`r?`n")) {
        if (-not $l.StartsWith('st=')) { continue }
        $m = [regex]::Match($l, '^st=(\d+):(\d+):(/.*)$')
        if (-not $m.Success) { continue }
        $f = $m.Groups[3].Value
        if ($pass -eq 1 -and $rp -and $f -ne $rp) { continue }
        $mm = [long]$m.Groups[2].Value
        if (-not $path -or $mm -gt $mt) { $path = $f; $size = $m.Groups[1].Value; $mt = $mm }
      }
      if ($path -or -not $rp) { break }
    }
    if ($part -and $waited -lt 120) {
      if ($waited -eq 0) { Say 'Архив ещё записывается на телефоне…' }
      Wait-Sec 5; $waited += 5; continue
    }
    break
  }
  if (-not $path) {
    if ($kind -eq 'charge') { ErrM 'Журнал зарядки не записал архив.' } else { ErrM 'Проверка не записала архив.' }
    if ($Script:FRes -eq 'fail' -and $Script:FReason) { Say ('Причина (сообщение телефона): ' + $Script:FReason + '.') }
    return $false
  }
  if ($fresh -and $Script:Start -gt 0 -and $mt -lt ($Script:Start - 5)) {
    ErrM ('На телефоне только архив от прошлого запуска ({0}) — новый не записан.' -f (Format-PhoneTime $mt 'dd.MM.yyyy HH:mm'))
    return $false
  }
  $name = 'taoyao-' + $kind + '.tar.gz'
  $ok = $false
  foreach ($i in @(1, 2)) {
    if ($i -eq 1) { [void](Invoke-Pull $path $name) }
    else {
      # second try: a copy that adb can read (also from a root-only folder)
      $cp = Invoke-Dev ('rm -f /data/local/tmp/taoyao-check-pull.tar.gz; cp ' + $path + ' /data/local/tmp/taoyao-check-pull.tar.gz && chmod 644 /data/local/tmp/taoyao-check-pull.tar.gz && echo COPIED') $true 30
      if ($cp.Out -match 'COPIED') {
        [void](Invoke-Pull '/data/local/tmp/taoyao-check-pull.tar.gz' $name)
        [void](Invoke-Dev 'rm -f /data/local/tmp/taoyao-check-pull.tar.gz' $true 20)
      } else { [void](Invoke-Pull $path $name) }
    }
    if (Test-Archive $name $kind $size) { $ok = $true; break }
    Write-Log ('verify failed: ' + $Script:VWhat)
    if ($i -eq 1) { WarnM 'Архив скачан не полностью. Пробую ещё раз…' }
  }
  $lp = Join-Path $Script:Out $name
  if (-not $ok) {
    if ([IO.File]::Exists($lp)) { try { [IO.File]::Delete($lp + '.bad') } catch { }; try { [IO.File]::Move($lp, $lp + '.bad') } catch { } }
    ErrM ('Архив скачан, но он повреждён или неполный ({0}).' -f $Script:VWhat)
    return $false
  }
  # the report next to it (one try, no check)
  $rep = $path.Substring(0, $path.LastIndexOf('/')) + '/taoyao-' + $kind + '.txt'
  if (-not (Invoke-Pull $rep ('taoyao-' + $kind + '.txt'))) { try { [IO.File]::Delete((Join-Path $Script:Out ('taoyao-' + $kind + '.txt'))) } catch { } }
  # an unfinished earlier run that the phone kept as taoyao-check-previous:
  # fetched too when the phone said so
  if ($kind -eq 'check' -and $Script:PrevSeen) {
    $prev = $path.Substring(0, $path.LastIndexOf('/')) + '/taoyao-check-previous.tar.gz'
    if ((Invoke-Pull $prev 'taoyao-check-previous.tar.gz') -and (Test-PrevArchive)) {
      $Script:Extra = 'Также приложите архив прошлого (не завершённого) запуска: ' + (Join-Path $Script:Out 'taoyao-check-previous.tar.gz')
    }
  }
  $Script:Archive = $lp; $Script:ArchMtime = $mt; $Script:Fetched = $true
  $len = (New-Object IO.FileInfo $lp).Length
  if ($len -ge 104858) { $Script:ArchSize = ('{0:0.0} МБ' -f ($len / 1048576.0)).Replace('.', ',') }
  else { $Script:ArchSize = ('{0} КБ' -f [int][Math]::Ceiling($len / 1024.0)) }
  $Script:Phase = ''
  return $true
}
function Show-Done([string]$note) {
  Write-Host ''
  GoodM ("Готово.`r`nПрикрепите к сообщению на форуме этот файл:`r`n  {0}  ({1})" -f $Script:Archive, $Script:ArchSize)
  if ($note) { Say $note }
  if ($Script:Extra) { Say $Script:Extra }
  foreach ($k in @('check', 'charge')) {
    $rp = Join-Path $Script:Out ('taoyao-' + $k + '.txt')
    if ([IO.File]::Exists($rp)) { Say ('Отчёт, который можно прочитать: ' + $rp) }
  }
  Say $T_Priv
  Open-Folder $Script:Out $Script:Archive
}

########################################################################
# output folder, log, lock
function Select-Base {
  $probe = Join-Path $Here ('.run-check-probe.' + $PID)
  try { [void][IO.Directory]::CreateDirectory($probe); [IO.Directory]::Delete($probe); $Script:Base = $Here; return } catch { }
  $desk = [Environment]::GetFolderPath('Desktop')
  if (-not $desk) { $desk = [IO.Path]::GetTempPath() }
  $alt = Join-Path $desk 'MeruDevTools'
  try { [void][IO.Directory]::CreateDirectory($alt) } catch { ErrM 'Не удаётся создать папку для результатов.'; Stop-Run $RC_FAIL }
  $Script:Base = $alt
  WarnM ('Не удаётся создать папку для результатов в «{0}»: нет прав на запись. Результаты будут в «{1}». Лучше перенести папку со скриптами, например, на Рабочий стол.' -f $Here, $alt)
}
function Lock-Folder {
  $Script:LockPath = Join-Path $Script:Base 'run-check.lock'
  try {
    $Script:Lock = [IO.File]::Open($Script:LockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
  } catch {
    $Script:LockPath = $null
    ErrM 'Сборщик уже запущен в другом окне. Дождитесь его окончания или закройте то окно.'
    Stop-Run $RC_FAIL
  }
}
function New-OutFolder([string]$prefix) {
  $name = $prefix + '-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
  $Script:Out = Join-Path $Script:Base $name
  try { [void][IO.Directory]::CreateDirectory($Script:Out) } catch { ErrM ('Не удаётся создать папку ' + $Script:Out); Stop-Run $RC_FAIL }
  $Script:LogPath = Join-Path $Script:Out 'run-check.log'
  [IO.File]::WriteAllText($Script:LogPath, '', $Utf8)
  if ($Script:LogBuf.Length -gt 0) {
    # (masked already when it was buffered)
    [IO.File]::AppendAllText($Script:LogPath, $Script:LogBuf.ToString(), $Utf8)
    [void]$Script:LogBuf.Clear()
  }
}

########################################################################
# one run on the phone
function Show-DeviceLine([string]$l) {
  $l = $l.TrimEnd("`r")
  if ($l.StartsWith('MERUDEV_RC=')) { $Script:RemoteRc = $l.Substring(11).Trim(); Write-Log ('| ' + $l); return }
  $t = $l.TrimStart()
  if ($t.StartsWith('>>>')) { Write-Host $l -ForegroundColor Yellow }
  elseif ($t.StartsWith('[ОШИБКА]')) { Write-Host $l -ForegroundColor Red }
  elseif ($t.StartsWith('[ВНИМАНИЕ]')) { Write-Host $l -ForegroundColor Yellow }
  else { Write-Host $l }
  if ($l.Contains('taoyao-check-previous.tar.gz')) { $Script:PrevSeen = $true }
  foreach ($m in [regex]::Matches($l, 'taoyao-(check|charge)-\d{8}-\d{6}')) {
    if (-not $Script:RunIds.Contains($m.Value)) { $Script:RunIds.Add($m.Value) }
  }
  Write-Log ('| ' + $l)
}
function Invoke-Live([int]$lim) {
  # (TAOYAO_DEBUGFS=1 or 0 on the computer, only when the developer asks: 1,
  # the phone mounts debugfs for the run and unmounts it at the end; 0, it
  # never mounts it, also in the modes that do so by themselves)
  $cmd = 'TAOYAO_WRAPPER=1'
  if ($env:TAOYAO_DEBUGFS -eq '1' -or $env:TAOYAO_DEBUGFS -eq '0') { $cmd += ' TAOYAO_DEBUGFS=' + $env:TAOYAO_DEBUGFS }
  $cmd += ' sh /data/local/tmp/taoyao-check.sh'
  if ($Script:Words) { $cmd += ' ' + $Script:Words }
  $cmd += ' 2>&1; echo MERUDEV_RC=$?'
  if (-not $Script:AdbRoot) { $cmd = "su -c '" + $cmd + "'" }
  $Script:Phase = 'run'; $Script:RemoteRc = $null
  $p = Start-AdbProc @('shell', $cmd) '' $false ''
  $Script:AdbProc = $p
  $tOut = $p.StandardOutput.ReadLineAsync()
  $tErr = $p.StandardError.ReadLineAsync()
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $last = 0.0; $next = 60; $exitAt = -1.0; $keyAt = 0.0
  while ($true) {
    $pend = New-Object 'System.Collections.Generic.List[System.Threading.Tasks.Task]'
    $which = New-Object 'System.Collections.Generic.List[string]'
    if ($null -ne $tOut) { $pend.Add($tOut); $which.Add('out') }
    if ($null -ne $tErr) { $pend.Add($tErr); $which.Add('err') }
    if ($pend.Count -eq 0) { break }
    $i = [Threading.Tasks.Task]::WaitAny($pend.ToArray(), 500)
    if ($i -ge 0) {
      $t = $pend[$i]
      $line = $null
      if (-not $t.IsFaulted) { $line = $t.Result }
      if ($which[$i] -eq 'out') {
        if ($null -eq $line) { $tOut = $null } else { Show-DeviceLine $line; $tOut = $p.StandardOutput.ReadLineAsync() }
      } else {
        if ($null -eq $line) { $tErr = $null } else { Show-DeviceLine $line; $tErr = $p.StandardError.ReadLineAsync() }
      }
      $last = $sw.Elapsed.TotalSeconds; $next = 60
      # (keys also while lines keep coming)
      if (($last - $keyAt) -ge 0.5) { $keyAt = $last; Test-Interrupt }
      continue
    }
    Test-Interrupt
    $now = $sw.Elapsed.TotalSeconds; $keyAt = $now
    if (($now - $last) -ge $next) {
      Say ('… проверка идёт ({0}). Не отключайте телефон.' -f (Format-Elapsed ([int]$now)))
      $next += 60
    }
    if ($now -ge $lim) {
      try { $p.Kill() } catch { }
      ErrM ('Проверка идёт уже {0} — намного дольше обычного. Скрипт перестаёт ждать.' -f (Format-Elapsed ([int]$now)))
      [void](Stop-PhoneCheck)
      break
    }
    if ($p.HasExited) {
      if ($exitAt -lt 0) { $exitAt = $now } elseif (($now - $exitAt) -ge 2) { break }
    }
  }
  $code = -1
  try { if ($p.WaitForExit(2000)) { $code = $p.ExitCode } } catch { }
  $Script:AdbProc = $null
  try { $p.Dispose() } catch { }
  $rr = $Script:RemoteRc; if ($null -eq $rr) { $rr = 'unknown' }
  Write-Log ('adb shell ended: rc {0}, remote rc {1}' -f $code, $rr)
  $Script:Phase = ''
  $Script:RunSecs = [int]$sw.Elapsed.TotalSeconds
}
function Push-Script {
  Step 'Отправляю taoyao-check.sh на телефон…'
  $r = Invoke-Adb @('push', 'taoyao-check.sh', '/data/local/tmp/taoyao-check.sh') 60 $Here
  if ($r.Code -eq 0) { return }
  $first = ''
  foreach ($l in (($r.Out + $r.Err) -split "`r?`n")) { if ($l -match '(?i)error') { $first = $l; break } }
  if ($first.Length -gt 150) { $first = $first.Substring(0, 150) }
  Fail ('Не удалось отправить файл на телефон ({0}). Отключите и снова подключите кабель и запустите скрипт ещё раз.' -f $first)
}
# after a run that lost its adb connection: wait for the phone, see if it
# rebooted (boot_id), wait for a background check, fetch
function Invoke-AfterDrop {
  $oldBoot = $Script:BootId
  $deep = (' ' + $Script:Words + ' ').Contains(' deep ')
  $lim = 600; if ($deep) { $lim = 900 }
  $r = Invoke-Adb @('devices') 10 '' $true '' $true
  $present = $false
  foreach ($l in ($r.Out -split "`r?`n")) { $f = @($l -split '\s+'); if ($f.Count -ge 2 -and $f[0] -eq $Script:Serial -and $f[1] -eq 'device') { $present = $true } }
  if (-not $present) {
    if ($Script:Bg) { WarnM ('Связь с телефоном прервалась — проверка {0} продолжается на телефоне. Подключите кабель снова, как только сможете.' -f (Get-ModeRu)) }
    else { WarnM ('Связь с телефоном прервалась. Подключите его снова — жду до {0} минут…' -f [int]($lim / 60)) }
    Wait-Device $lim
  }
  Test-Root
  $keep = $Script:Start
  Get-PhoneInfo
  $Script:Start = $keep
  $rebooted = ($oldBoot -and $Script:BootId -ne $oldBoot)
  if ($rebooted) {
    if ($deep) { WarnM 'Похоже, телефон упал во время глубокой проверки — это важный результат. Заберу архив, который проверка записала перед глубоким чтением.' }
    else { WarnM 'Телефон перезагрузился во время проверки.' }
  } else { Wait-Background }
  if (Invoke-Fetch 'check' $true) {
    if ($rebooted -and $deep) { $Script:DoneNote = '(Этот архив записан перед глубоким чтением: глубокая проверка не закончилась.)' }
    return $true
  }
  # (a check that the reboot cut off writes nothing; the next check packs
  # its files as prev-interrupted/)
  if ($rebooted -and -not $deep) {
    $Script:Rebooted = $true
    Say 'Запустите проверку ещё раз: в её архив попадут и файлы прерванного запуска.'
  }
  return $false
}

########################################################################
# the main flow
function Invoke-Main {
  $pr = Read-Args $Argv
  if ($Script:Mode -eq 'help') { Write-Host ('{0}, версия {1}' -f $Brand, $Ver); Show-License; Write-Host ''; Show-Help; return $RC_OK }
  Update-Mask
  Write-Host ('{0}, версия {1}' -f $Brand, $Ver)
  Write-Log ('{0}, версия {1}' -f $Brand, $Ver)
  Show-License
  Write-Log ('PowerShell {0}, {1}' -f $PSVersionTable.PSVersion, [Environment]::OSVersion.VersionString) $true
  Write-Log ('args: ' + [string]::Join(' ', [string[]]$Argv))
  if ($pr -ne 'ok') {
    if ($pr -eq 'combo') { ErrM 'prep, charge и charge-pull запускаются только по одному.' }
    elseif ($pr -eq 'minutes') { ErrM 'После charge можно указать число минут от 1 до 1440.' }
    elseif ($pr -eq 'hsmic') { ErrM 'hotspot и mic нельзя запускать вместе: запустите их по очереди.' }
    else { ErrM ('Непонятный параметр «{0}».' -f $pr.Substring(4)) }
    Write-Host ''; Show-Help
    return $RC_FAIL
  }
  $Script:Menu = ($Argv.Count -eq 0 -and $Script:KeysOk)
  Say ('Папка со скриптами: ' + $Here)
  # (Explorer runs a script from inside a ZIP after unpacking the whole ZIP
  # into %TEMP%\Temp1_<name>.zip: the results would land there)
  if ($Here -match '(?i)\\Temp\d*_[^\\]+\.zip(\\|$)') {
    ErrM 'Похоже, скрипт запущен прямо из ZIP-архива: Windows распаковала его во временную папку, и результаты потом пропадут. Закройте это окно, щёлкните по ZIP-файлу правой кнопкой → «Извлечь все…», откройте распакованную папку и запустите run-check.bat там.'
    return $RC_FAIL
  }
  if (-not [IO.File]::Exists((Join-Path $Here 'taoyao-check.sh'))) {
    if ($Here -match '(?i)\\Temp\d*_[^\\]+\.zip(\\|$)' -or $Here -match '(?i)\.zip(\\|$)') {
      ErrM 'Похоже, скрипт запущен прямо из ZIP-архива. Закройте это окно, щёлкните по ZIP-файлу правой кнопкой → «Извлечь все…», откройте распакованную папку и запустите run-check.bat там.'
    } else {
      ErrM ('Рядом со скриптом нет файла taoyao-check.sh. Распакуйте весь ZIP-архив в одну папку и запускайте {0} оттуда.' -f $Launcher)
    }
    return $RC_FAIL
  }
  $dver = ''
  try {
    $head = [IO.File]::ReadAllLines((Join-Path $Here 'taoyao-check.sh'), $Utf8)
    for ($i = 0; $i -lt [Math]::Min(5, $head.Length); $i++) {
      $m = [regex]::Match($head[$i], 'Сборщик логов MeruDevTools.*версия\s+([0-9A-Za-z.]+)')
      if ($m.Success) { $dver = $m.Groups[1].Value; break }
    }
  } catch { }
  if ($dver -ne $Ver) {
    $dv = $dver; if (-not $dv) { $dv = 'неизвестна' }
    WarnM ('Внимание: {0} (версия {1}) и taoyao-check.sh (версия {2}) из разных выпусков. Лучше скачать сборщик заново целиком. Продолжаю.' -f $Launcher, $Ver, $dv)
  }
  if ($IsWin -and $Script:KeysOk) { Write-Host 'Не щёлкайте мышью по этому окну во время работы: Windows ставит вывод на паузу. Если вывод «застыл», нажмите Esc.' -ForegroundColor DarkGray }
  if ($Script:Menu) {
    Show-MenuChoice
    # (the user chose to leave: no "press a key" after that)
    if ($Script:Mode -eq 'exit') { $Script:Menu = $false; return $RC_OK }
  }
  $pfx = 'taoyao-check'; if ($Script:Mode -eq 'charge' -or $Script:Mode -eq 'charge-pull') { $pfx = 'taoyao-charge' }
  Select-Base
  Lock-Folder
  New-OutFolder $pfx
  Write-Log ('mode: {0} {1}' -f $Script:Mode, $Script:Words)

  Find-Adb
  Start-AdbServer
  Step ('adb: {0} (версия {1})' -f $Script:Adb, $Script:AdbVer)

  while ($true) {
    Initialize-Phone
    $Script:DoneNote = ''

    # a check whose wait was cancelled earlier: offer its result
    $pend = Join-Path $Script:Base '.run-check-pending'
    if ([IO.File]::Exists($pend)) {
      $pf = @(([IO.File]::ReadAllText($pend)).Trim() -split '\s+')
      try { [IO.File]::Delete($pend) } catch { }
      if ($Script:Menu -and $pf.Count -ge 3 -and $pf[2] -eq $Script:BootId -and (Invoke-Probe) -and -not $Script:BusyChk) {
        $pst = [long]0; [void][long]::TryParse($pf[1], [ref]$pst)
        $r = Invoke-Dev (Get-F1 'check') $true 20
        $m = [regex]::Match($r.Out, '(?m)^st=\d+:(\d+):/sdcard/')
        if ($m.Success -and $pst -gt 0 -and [long]$m.Groups[1].Value -ge ($pst - 5)) {
          if (Ask-Yes ('На телефоне есть результат проверки, которую вы не дождались ({0}). Забрать его? {1}' -f (Format-PhoneTime ([long]$m.Groups[1].Value) 'dd.MM.yyyy HH:mm'), $T_YN) $false) {
            $keep = $Script:Start; $Script:Start = $pst
            if (Invoke-Fetch 'check' $true) { Show-Done ''; return $RC_OK }
            $Script:Start = $keep
            Fail ''
          }
        }
      }
    }

    if (-not (Invoke-Probe)) { Fail 'Телефон не ответил.' }

    # charge-pull: wait for the logger, then fetch
    if ($Script:Mode -eq 'charge-pull') {
      if (-not $Script:ChgAlive) {
        if ($Script:ChgPf) { Fail 'Запись зарядки прервалась (телефон перезагружался или выключался), и её результаты не сохранились. Запустите запись заново (пункт 5).' }
      } else {
        $Script:Phase = 'chg'
        $left = Get-ChargeLeft
        $lim = $left + 600; if (-not $Script:ChgM) { $lim = 900 }
        $hint = ''; if ($Script:KeysOk) { $hint = ' Чтобы остановить запись сейчас, нажмите Enter.' }
        WarnM ('Журнал зарядки ещё записывается: осталось около {0} мин (примерно до {1}). Результат заберётся сам, окно не закрывайте.{2}' -f [int][Math]::Ceiling($left / 60.0), (Get-HHmmIn $left), $hint)
        $sw = [Diagnostics.Stopwatch]::StartNew(); $next = 60
        $Script:EnterPressed = $false
        while ($true) {
          Wait-Sec 5
          if ($Script:EnterPressed) {
            $Script:EnterPressed = $false
            if (Ask-Yes ('Остановить запись зарядки сейчас? Результаты сохранятся. ' + $T_YN) $false) {
              if ($Script:ChgPidV -match '^\d+$') { [void](Invoke-Dev ('kill ' + $Script:ChgPidV) $true 20) }
              Say 'Останавливаю запись…'
            }
          }
          if (-not (Invoke-Probe)) { if (Test-Lost $Script:Dc) { Wait-Device 600; $Script:Phase = 'chg' }; continue }
          if (-not $Script:ChgAlive) { break }
          $el = [int]$sw.Elapsed.TotalSeconds
          if ($el -ge $next) { Say ('… журнал зарядки ещё записывается: осталось около {0} мин.' -f [int][Math]::Ceiling((Get-ChargeLeft) / 60.0)); $next += 60 }
          if ($el -ge $lim) { $Script:Phase = ''; Fail 'Журнал зарядки пишется дольше, чем должен. Скрипт перестаёт ждать; запустите charge-pull позже.' }
        }
        $Script:Phase = ''
        Start-Sleep -Seconds 2
      }
      if (Invoke-Fetch 'charge' $false) {
        $note = ''
        if ($Script:ArchMtime -gt 0) { $note = '(Журнал зарядки записан ' + (Format-PhoneTime $Script:ArchMtime 'dd.MM.yyyy HH:mm') + '.)' }
        Show-Done $note; return $RC_OK
      }
      if (-not $Script:ChgPf -and $Script:FRes -ne 'fail') { Fail 'На телефоне нет журнала зарядки. Сначала запустите запись (пункт 5), а после зарядки — пункт 6.' }
      Fail ''
    }

    # a check still running on the phone (started earlier): wait and fetch
    if ($Script:BusyChk -and $Script:Mode -ne 'charge') {
      $bmin = 0; if ($Script:BusyChkT -gt 0) { $bmin = [int][Math]::Floor(($Script:PNow - $Script:BusyChkT) / 60) }
      if ($Script:KeysOk) {
        if (-not (Ask-Yes ('На телефоне ещё идёт {0}, запущенная раньше (уже {1} мин). Дождаться её и забрать результат? {2}' -f (Get-BusyName $Script:BusyChk), $bmin, $T_YN) $false)) { Stop-Run $RC_CANCEL }
      } else {
        WarnM ('На телефоне ещё идёт {0}, запущенная раньше. Жду её окончания и заберу результат…' -f (Get-BusyName $Script:BusyChk))
      }
      $Script:Start = $Script:BusyChkT
      if ($Script:Start -le 0) { $Script:Start = $Script:PNow }
      Wait-Background
      if (Invoke-Fetch 'check' $true) { Show-Done ''; return $RC_OK }
      Fail ''
    }
    if ($Script:ChgAlive) {
      $left = Get-ChargeLeft
      if ($Script:Mode -eq 'charge') {
        Fail ('Журнал зарядки уже записывается (осталось около {0} мин, примерно до {1}). Когда он закончится, подключите телефон и выберите пункт 6 «Забрать журнал зарядки» (или: {2} charge-pull).' -f [int][Math]::Ceiling($left / 60.0), (Get-HHmmIn $left), $Launcher)
      }
      Say ('На телефоне записывается журнал зарядки (осталось около {0} мин) — он продолжит работу.' -f [int][Math]::Ceiling($left / 60.0))
    }

    Push-Script

    $lim = 1800
    $w = ' ' + $Script:Words + ' '
    if ($Script:Mode -eq 'prep') { Step 'Подготовка: телефон начнёт записывать журнал ядра в фоне и увеличит буферы журналов приложений (ничего не удаляется). Это меньше минуты.'; $lim = 300 }
    elseif ($Script:Mode -eq 'charge') { Step ('Запускаю запись зарядки на {0} мин…' -f $Script:ChgMin); $lim = 120 }
    elseif ($w.Contains(' hotspot ')) {
      Step 'Проверка точки доступа (займёт 6–8 минут).'
      Say 'Разблокируйте телефон и откройте шторку с кнопкой «Точка доступа». Через несколько секунд после начала появится строка, которая начинается с «>>>», — тогда включите точку доступа, дождитесь, пока она включится (или покажет ошибку), и выключите её. На это есть 60 секунд.'
      Say 'Если при этом прервётся связь по USB — ничего страшного: проверка доработает на телефоне, а этот скрипт её дождётся.'
      if ($Script:Menu) { if (-not (Ask-Yes 'Нажмите Enter, когда будете готовы (Esc — отмена).' $false 'начать' 'отмена')) { Stop-Run $RC_CANCEL } }
    }
    elseif ($w.Contains(' mic ')) {
      Step 'Проверка микрофона: следуйте подсказкам ниже — строкам, которые начинаются с «>>>».'
      if ($Script:Menu) { if (-not (Ask-Yes 'Нажмите Enter, когда будете готовы (Esc — отмена).' $false 'начать' 'отмена')) { Stop-Run $RC_CANCEL } }
    }
    elseif ($w.Contains(' deep ')) { Step 'Глубокая проверка. Не отключайте кабель. Если телефон зависнет больше чем на 5 минут, одновременно зажмите «Громкость вниз» и кнопку питания примерно на 10 секунд — он перезагрузится и сохранит журнал сбоя. После загрузки разблокируйте телефон: скрипт заберёт то, что успело записаться.' }
    else { Step 'Обычная проверка займёт 5–7 минут. Не отключайте кабель и не закрывайте это окно. Если проблема со звуком — включите музыку на телефоне до запуска.' }
    if ($w.Contains(' deep ')) { $lim = 7200 }

    $Script:RunIds.Clear(); $Script:PrevSeen = $false
    Invoke-Live $lim
    $rrc = $Script:RemoteRc

    if ($Script:Mode -eq 'prep') {
      if ($rrc -ne '0') { $x = $rrc; if ($null -eq $x) { $x = 'неизвестен' }; Fail ('Подготовка на телефоне не выполнилась (код {0}) — причина в сообщении выше.' -f $x) }
      if ($Script:Menu) {
        Write-Host ''
        Clear-Keys
        GoodM 'Подготовка готова.'
        Say 'Теперь повторите проблему на телефоне (включите звук, откройте камеру, отправьте SMS…). Кабель на это время можно отключить — например, чтобы проверить сон: выключите экран на 10 минут.'
        Say 'Когда закончите, подключите телефон и нажмите здесь Enter — запустится обычная проверка. Esc — выйти (обычную проверку можно запустить позже, пункт 1).'
        if (Read-YesNo $false 'обычная проверка' 'выйти') { $Script:Mode = 'check'; $Script:Words = ''; $Script:Bg = $false; continue }
        return $RC_OK
      }
      GoodM ('Подготовка готова. Теперь повторите проблему на телефоне, затем запустите {0} и выберите пункт 1 «Обычная проверка».' -f $Launcher)
      return $RC_OK
    }
    if ($Script:Mode -eq 'charge') {
      if ($rrc -eq '0' -and (Invoke-Probe) -and $Script:ChgAlive) {
        $e = Get-HHmmIn ($Script:ChgMin * 60)
        Write-Host ''
        GoodM ("Запись зарядки запущена на {0} мин (примерно до {1}).`r`n 1. Отключите кабель от компьютера.`r`n 2. Поставьте телефон на зарядку, которую проверяете (её можно отключать и подключать снова).`r`n 3. После {1} подключите телефон к компьютеру, запустите {2} и выберите пункт 6 «Забрать журнал зарядки» (или: {2} charge-pull).`r`nЭто окно можно закрыть." -f $Script:ChgMin, $e, $Launcher)
        return $RC_OK
      }
      Fail 'Запись зарядки не запустилась — причина в сообщениях выше.'
    }

    # check modes
    if ($null -eq $rrc) {
      if (Invoke-AfterDrop) {
        Show-Done $Script:DoneNote
        if ($w.Contains(' deep ') -and $Script:Menu -and $Script:DoneNote) {
          Write-Host ''
          if (Ask-Yes ('Чтобы в отчёт попал журнал сбоя, сейчас стоит запустить обычную проверку. Запустить? ' + $T_YN) $false) {
            $Script:Extra = 'Также приложите архив глубокой проверки: ' + $Script:Archive
            $Script:Mode = 'check'; $Script:Words = ''; $Script:Bg = $false
            New-OutFolder 'taoyao-check'; $Script:Fetched = $false
            continue
          }
        }
        return $RC_OK
      }
      # (the phone rebooted during a check that is not deep: offer it again)
      if ($Script:Rebooted -and $Script:Menu) {
        Write-Host ''
        if (Ask-Yes ('Запустить проверку ещё раз сейчас? ' + $T_YN) $false) {
          $Script:Rebooted = $false; $Script:Mode = 'check'
          New-OutFolder 'taoyao-check'; $Script:Fetched = $false
          continue
        }
      }
      Fail ''
    }
    if ($rrc -ne '0') {
      if (@('2', '3', '4', '5') -contains $rrc -or $Script:RunIds.Count -eq 0) {
        Fail ('Проверка на телефоне не запустилась (код {0}) — причина в сообщении выше.' -f $rrc)
      }
      $Script:DoneNote = ('(Проверка закончилась с ошибкой (код {0}): архив может быть неполным.)' -f $rrc)
    }
    Wait-Background
    if (Invoke-Fetch 'check' $true) { Show-Done $Script:DoneNote; return $RC_OK }
    Fail ''
  }
}

########################################################################
# console setup, run, restore
try { $Script:OldOutEnc = [Console]::OutputEncoding; [Console]::OutputEncoding = $Utf8 } catch { }
try { $OutputEncoding = $Utf8 } catch { }
try { $Host.UI.RawUI.WindowTitle = ('{0}, версия {1}' -f $Brand, $Ver) } catch { }
try { $Script:KeysOk = -not [Console]::IsInputRedirected } catch { $Script:KeysOk = $false }
if ($Script:KeysOk) { try { [Console]::TreatControlCAsInput = $true; $Script:CtrlCSet = $true } catch { } }
$rc = $RC_FAIL
try {
  $rc = Invoke-Main
} catch {
  if ("$_" -eq 'MERUDEV-EXIT') { $rc = $Script:ExitCode }
  elseif ($_.Exception -is [System.Management.Automation.PipelineStoppedException]) { $rc = $RC_CANCEL }
  else {
    $msg = $_.Exception.Message
    try { Write-Log ('internal error: ' + $_.ToString() + ' at ' + $_.InvocationInfo.PositionMessage) } catch { }
    try { Write-Host ('Внутренняя ошибка сборщика: ' + $msg) -ForegroundColor Red } catch { }
    try { Show-Failed } catch { }
    $rc = $RC_FAIL
  }
} finally {
  if ($null -ne $Script:AdbProc) { try { $Script:AdbProc.Kill(); [void]$Script:AdbProc.WaitForExit(5000) } catch { } }
  if ($null -ne $Script:PtJob) { try { if (Stop-PtJob $Script:PtJob) { $Script:PtJob.Dispose() } } catch { } }
  # (stopped between the two renames of the platform-tools folder: the old
  # one comes back)
  if ($Script:PtOld) { try { if (-not ([IO.Directory]::Exists($Script:PtDst) -or [IO.File]::Exists($Script:PtDst))) { [IO.Directory]::Move($Script:PtOld, $Script:PtDst) } } catch { } }
  try { Remove-PtStage } catch { }
  try { Write-Log ('exit code ' + $rc) } catch { }
  # prep and charge write no archive: a folder with only the log goes
  if ($rc -eq 0 -and $Script:Out -and -not $Script:Fetched) {
    try {
      $items = @([IO.Directory]::GetFileSystemEntries($Script:Out))
      if ($items.Count -eq 1 -and [IO.Path]::GetFileName($items[0]) -eq 'run-check.log') { [IO.Directory]::Delete($Script:Out, $true) }
    } catch { }
  }
  if ($null -ne $Script:Lock) {
    try { $Script:Lock.Close() } catch { }
    try { [IO.File]::Delete($Script:LockPath) } catch { }
  }
  if ($Script:Menu) {
    Write-Host ''
    Clear-Keys
    Write-Host -NoNewline 'Нажмите любую клавишу, чтобы закрыть окно.'
    try { [void][Console]::ReadKey($true) } catch { try { [void](Read-Host) } catch { } }
    Write-Host ''
  }
  if ($Script:CtrlCSet) { try { [Console]::TreatControlCAsInput = $false } catch { } }
  if ($null -ne $Script:OldOutEnc) { try { [Console]::OutputEncoding = $Script:OldOutEnc } catch { } }
}
exit $rc
