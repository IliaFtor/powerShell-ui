$sw = [Diagnostics.Stopwatch]::StartNew()
function T($n) { if ($env:PROF) { Write-Host ('{0,6} ms  {1}' -f $sw.ElapsedMilliseconds, $n) -ForegroundColor DarkGray } }

# =================================
# STARTUP DIRECTORY
# =================================
$tmpDir = Join-Path $HOME "tmp"
if (-not (Test-Path $tmpDir)) { New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null }
Set-Location $tmpDir

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

# =================================
# STARSHIP / ZOXIDE / MODULES
# =================================
Invoke-Expression (&starship init powershell)
T 'starship'
Invoke-Expression (& { (zoxide init powershell | Out-String) })
T 'zoxide'
Import-Module Terminal-Icons
T 'Terminal-Icons'
Import-Module PSFzf
T 'PSFzf'

# =================================
# PSREADLINE / FZF
# =================================
Set-PSReadLineOption -PredictionSource History
Set-PSReadLineOption -PredictionViewStyle ListView
Set-PSReadLineOption -EditMode Windows
Set-PSReadLineOption -HistorySearchCursorMovesToEnd
Set-PsFzfOption -PSReadlineChordProvider 'Ctrl+f' -PSReadlineChordReverseHistory 'Ctrl+r'

# =================================
# ALIASES
# =================================
Set-Alias -Name vsc -Value code
function ll   { eza -lah --icons --group-directories-first @args }
function la   { eza -a --icons @args }
function tree { eza --tree --icons @args }
function cat  { bat @args }
function ..   { Set-Location .. }
function ...  { Set-Location ../.. }

function hisvsc {
    $historyPath = (Get-PSReadLineOption).HistorySavePath
    if (Test-Path $historyPath) { code $historyPath }
    else { Write-Host "Файл истории пока не создан: $historyPath" -ForegroundColor Yellow }
}

# =================================
# UI HELPERS (цвета Catppuccin Mocha)
# =================================
$script:E = [char]27
function C([string]$hex) {
    $r=[Convert]::ToInt32($hex.Substring(0,2),16); $g=[Convert]::ToInt32($hex.Substring(2,2),16); $b=[Convert]::ToInt32($hex.Substring(4,2),16)
    "$($script:E)[38;2;${r};${g};${b}m"
}
$script:RST = "$($script:E)[0m"
$script:DIM = C '6c7086'
$script:TXT = C 'cdd6f4'
$script:BLUE = C '89b4fa'

function Bar([double]$pct, [int]$w = 14) {
    $pct = [math]::Max(0, [math]::Min(100, $pct))
    $f = [int][math]::Round($pct / 100 * $w)
    $col = if ($pct -ge 85) { C 'f38ba8' } elseif ($pct -ge 60) { C 'f9e2af' } else { C 'a6e3a1' }
    "$col$('━' * $f)$($script:DIM)$('─' * ($w - $f))$($script:RST)"
}

function Get-GpuInfo {
    if (-not (Get-Command nvidia-smi -ErrorAction SilentlyContinue)) { return $null }
    $o = nvidia-smi --query-gpu=name,utilization.gpu,memory.used,memory.total,temperature.gpu --format=csv,noheader,nounits 2>$null
    if (-not $o) { return $null }
    $p = ($o | Select-Object -First 1) -split ',\s*'
    [PSCustomObject]@{ Name=$p[0]; Util=[double]$p[1]; MemUsed=[double]$p[2]; MemTotal=[double]$p[3]; Temp=[double]$p[4] }
}

function Get-Sys {
    $os  = Get-CimInstance Win32_OperatingSystem
    $cpu = (Get-CimInstance Win32_Processor | Measure-Object LoadPercentage -Average).Average
    $total = $os.TotalVisibleMemorySize / 1MB
    $free  = $os.FreePhysicalMemory / 1MB
    [PSCustomObject]@{
        Cpu = [double]$cpu; RamUsed = $total - $free; RamTotal = $total
        Uptime = (Get-Date) - $os.LastBootUpTime
    }
}

# =================================
# DASHBOARD (мини-панель при старте)
# =================================
function dash {
    $s = Get-Sys; $g = Get-GpuInfo
    $d = Get-PSDrive -Name C
    $dUsed = $d.Used / 1GB; $dTot = ($d.Used + $d.Free) / 1GB
    $up = "{0}d {1}h {2}m" -f $s.Uptime.Days, $s.Uptime.Hours, $s.Uptime.Minutes
    $L = $script:DIM; $R = $script:RST; $T = $script:TXT; $B = $script:BLUE

    $ramPct  = $s.RamUsed / $s.RamTotal * 100
    $diskPct = $dUsed / $dTot * 100

    Write-Host ""
    Write-Host ("$L╭─ $B$env:COMPUTERNAME$L ─ up $T$up$L ─ $T$(Get-Date -Format 'dd.MM HH:mm')$R")
    Write-Host ("$L│$R $B CPU$R $(Bar $s.Cpu)$T {0,3:N0}%$R   $B RAM$R $(Bar $ramPct)$T {1:N1}/{2:N0} GB$R" -f $s.Cpu, $s.RamUsed, $s.RamTotal)
    if ($g) {
        $vp = $g.MemUsed / $g.MemTotal * 100
        Write-Host ("$L│$R $B GPU$R $(Bar $g.Util)$T {0,3:N0}%$R   $B VRM$R $(Bar $vp)$T {1:N1}/{2:N0} GB$R  $L{3}°C$R" -f $g.Util, ($g.MemUsed/1024), ($g.MemTotal/1024), $g.Temp)
    }
    Write-Host ("$L│$R $B C:  $R $(Bar $diskPct)$T {0:N0}/{1:N0} GB$R" -f $dUsed, $dTot)
    Write-Host ("$L╰─ $($L)htop · nvtop · tachki · powhelp$R")
    Write-Host ""
}

# =================================
# HTOP — живой монитор процессов
# =================================
function htop {
    $e = $script:E; $cores = [Environment]::ProcessorCount
    $prev = @{}
    foreach ($p in Get-Process) { try { $prev[$p.Id] = $p.TotalProcessorTime.TotalSeconds } catch { } }
    $t0 = Get-Date
    $global:DashPaused = $true; [Console]::CursorVisible = $false
    Clear-Host
    try {
        while ($true) {
            for ($i = 0; $i -lt 10; $i++) {
                Start-Sleep -Milliseconds 100
                if ([Console]::KeyAvailable) {
                    $k = [Console]::ReadKey($true)
                    if ($k.Key -in 'Q','Escape') { return }
                }
            }
            $now = Get-Date; $dt = ($now - $t0).TotalSeconds; $t0 = $now
            $rows = foreach ($p in Get-Process) {
                $cur = 0; try { $cur = $p.TotalProcessorTime.TotalSeconds } catch { }
                $old = if ($prev.ContainsKey($p.Id)) { $prev[$p.Id] } else { $cur }
                $prev[$p.Id] = $cur
                [PSCustomObject]@{ Id=$p.Id; Name=$p.ProcessName; Cpu=(($cur-$old)/$dt/$cores*100); Mem=$p.WorkingSet64/1MB }
            }
            $s = Get-Sys; $g = Get-GpuInfo
            $h = [Console]::WindowHeight; $w = [Console]::WindowWidth
            $n = [math]::Max(5, $h - 9)

            $out = New-Object System.Text.StringBuilder
            [void]$out.Append("$e[H")
            [void]$out.AppendLine(("$($script:BLUE) CPU$($script:RST) $(Bar $s.Cpu 30) {0,3:N0}%   $($script:BLUE)RAM$($script:RST) $(Bar ($s.RamUsed/$s.RamTotal*100) 30) {1:N1}/{2:N0} GB$e[K" -f $s.Cpu, $s.RamUsed, $s.RamTotal))
            if ($g) {
                [void]$out.AppendLine(("$($script:BLUE) GPU$($script:RST) $(Bar $g.Util 30) {0,3:N0}%   $($script:BLUE)VRM$($script:RST) $(Bar ($g.MemUsed/$g.MemTotal*100) 30) {1:N1}/{2:N0} GB  {3}°C$e[K" -f $g.Util, ($g.MemUsed/1024), ($g.MemTotal/1024), $g.Temp))
            } else { [void]$out.AppendLine("$e[K") }
            [void]$out.AppendLine("$($script:DIM)up $($s.Uptime.Days)d $($s.Uptime.Hours)h · cores: $cores · q/Esc — выход$($script:RST)$e[K")
            [void]$out.AppendLine("$e[K")
            [void]$out.AppendLine("$e[48;2;49;50;68m$e[38;2;205;214;244m$('{0,7} {1,-28} {2,7} {3,10}' -f 'PID','NAME','CPU%','MEM MB')$(' ' * [math]::Max(0,$w-56))$($script:RST)")
            $rows | Sort-Object Cpu -Descending | Select-Object -First $n | ForEach-Object {
                $col = if ($_.Cpu -ge 50) { C 'f38ba8' } elseif ($_.Cpu -ge 15) { C 'f9e2af' } else { $script:TXT }
                [void]$out.AppendLine(("$col{0,7} {1,-28} {2,7:N1} {3,10:N0}$($script:RST)$e[K" -f $_.Id, $_.Name.Substring(0,[math]::Min(28,$_.Name.Length)), $_.Cpu, $_.Mem))
            }
            [void]$out.Append("$e[J")
            [Console]::Write($out.ToString())
        }
    }
    finally { [Console]::CursorVisible = $true; Clear-Host; $global:DashPaused = $false; Restore-LiveHeader }
}


# =================================
# SSH config ui
# =================================
function tachki {
    $configPath = "$HOME\.ssh\config"
    if (-not (Test-Path $configPath)) { Write-Host "Файл $configPath не найден" -ForegroundColor Red; return }

    $lastComment = ""
    $entries = foreach ($line in Get-Content $configPath -Encoding UTF8) {
        $trimmed = ($line -replace '\uFEFF', '').Trim()
        if ($trimmed -match '^#\s*(.+)$') { $lastComment = $matches[1] }
        elseif ($trimmed -match '^Host\s+([^\*\?]+)$') {
            $hostAlias = ($matches[1] -split '\s+')[0]
            if ($lastComment) { "{0,-25} | # {1}" -f $hostAlias, $lastComment } else { "{0,-25} |" -f $hostAlias }
            $lastComment = ""
        }
        elseif ($trimmed -ne "" -and $trimmed -notmatch '^(HostName|User|Port|IdentityFile|ForwardAgent|ProxyJump|LocalForward|RemoteForward|ServerAliveInterval)\b') { $lastComment = "" }
    }
    if (-not $entries) { Write-Host "В $configPath нет настроенных хостов" -ForegroundColor Yellow; return }

    $selected = $entries | fzf --height=40% --layout=reverse --border --prompt="SSH тачка > " --header="Выбери сервер стрелками (или введи имя/комментарий)"
    if ($selected) {
        $target = (($selected -split '\|')[0] -replace '[^\x20-\x7E]', '').Trim()
        Write-Host "Подключаюсь к $target..." -ForegroundColor Green
        ssh $target
    }
}

# =================================
# HELP
# =================================
function powhelp {
    Write-Host "`n  СПРАВКА ПО МОИМ КОМАНДАМ`n" -ForegroundColor Cyan
    @(
        [PSCustomObject]@{ Команда = "dash";     Описание = "Мини-дашборд: CPU / RAM / GPU / диск" }
        [PSCustomObject]@{ Команда = "htop";     Описание = "Живой монитор процессов (q — выход)" }
        [PSCustomObject]@{ Команда = "nvtop";    Описание = "Монитор GPU (WSL nvtop или встроенный)" }
        [PSCustomObject]@{ Команда = "tachki";   Описание = "Меню выбора SSH-сервера (fzf)" }
        [PSCustomObject]@{ Команда = "hisvsc";   Описание = "Открыть историю команд в VS Code" }
        [PSCustomObject]@{ Команда = "vsc";      Описание = "VS Code" }
        [PSCustomObject]@{ Команда = "ll / la";  Описание = "Список файлов с иконками (eza)" }
        [PSCustomObject]@{ Команда = "tree";     Описание = "Дерево каталогов (eza)" }
        [PSCustomObject]@{ Команда = "cat";      Описание = "Просмотр файла с подсветкой (bat)" }
        [PSCustomObject]@{ Команда = ".. / ..."; Описание = "Вверх на 1 или 2 папки" }
        [PSCustomObject]@{ Команда = "Ctrl + R"; Описание = "Поиск по истории (fzf)" }
        [PSCustomObject]@{ Команда = "Ctrl + F"; Описание = "Поиск файлов (fzf)" }
        [PSCustomObject]@{ Команда = "ls";       Описание = "Таблица файлов: права, владелец, размер" }
        [PSCustomObject]@{ Команда = "powhelp";  Описание = "Эта шпаргалка" }
    ) | Format-Table -AutoSize
}

# =================================
# CUSTOM LS TABLE
# =================================
Remove-Item Alias:ls -Force -ErrorAction SilentlyContinue
function ls {
    param([string]$Path = ".")
    Get-ChildItem -Path $Path -Force | Sort-Object { -not $_.PSIsContainer }, Name | ForEach-Object {
        $owner = try { (Get-Acl $_.FullName).Owner -replace '^.*\\', '' } catch { "-" }
        $size = if ($_.PSIsContainer) { "" }
        elseif ($_.Length -ge 1GB) { "{0:N2} GB" -f ($_.Length / 1GB) }
        elseif ($_.Length -ge 1MB) { "{0:N2} MB" -f ($_.Length / 1MB) }
        elseif ($_.Length -ge 1KB) { "{0:N1} KB" -f ($_.Length / 1KB) }
        else { "$($_.Length) B" }
        [PSCustomObject]@{
            Права    = $_.Mode
            Владелец = $owner
            Размер   = $size
            Изменен  = $_.LastWriteTime.ToString("dd.MM.yyyy HH:mm")
            Имя      = if ($_.PSIsContainer) { "$($_.Name)/" } else { $_.Name }
        }
    } | Format-Table -AutoSize
}

# =================================
# LIVE HEADER — закреплённая сверху панель, обновляется сама
# =================================
$global:DashLiveOn  = $false
$global:DashPaused  = $false
$global:DashH       = 5      # высота панели в строках (4 + разделитель)
$global:DashTick    = 0
$global:GpuCache    = $null

function Get-CpuTemp {
    # Читает http://localhost:8085/data.json (LibreHardwareMonitor -> Options -> Remote Web Server -> Run)
    try {
        $r = Invoke-RestMethod -Uri 'http://localhost:8085/data.json' -TimeoutSec 1 -ErrorAction Stop
        $stack = [System.Collections.Generic.Stack[object]]::new(); $stack.Push($r)
        $pkg = $null; $max = $null
        while ($stack.Count -gt 0) {
            $n = $stack.Pop()
            if ($n.Value -match '°C') {
                $m = [regex]::Match($n.Value, '\d+[.,]?\d*')
                if ($m.Success) {
                    $v = [double]::Parse(($m.Value -replace ',', '.'), [Globalization.CultureInfo]::InvariantCulture)
                    if ($n.Text -match '^(CPU Package|Core \(Tctl/Tdie\)|Tdie|Tctl)') { $pkg = $v }
                    elseif ($n.Text -eq 'Core Max') { $max = $v }
                }
            }
            foreach ($c in $n.Children) { $stack.Push($c) }
        }
        if ($null -ne $pkg) { return $pkg }
        if ($null -ne $max) { return $max }
    } catch { }
    return $null
}

function Get-DashLines {
    if (-not $global:CpuCounter) {
        $global:CpuCounter = [System.Diagnostics.PerformanceCounter]::new('Processor','% Processor Time','_Total')
        [void]$global:CpuCounter.NextValue(); Start-Sleep -Milliseconds 150
    }
    $cpu = $global:CpuCounter.NextValue()
    $os  = Get-CimInstance Win32_OperatingSystem
    $tot = $os.TotalVisibleMemorySize / 1MB
    $used = $tot - $os.FreePhysicalMemory / 1MB
    $up  = (Get-Date) - $os.LastBootUpTime
    $d   = Get-PSDrive -Name C
    $dU  = $d.Used / 1GB; $dT = ($d.Used + $d.Free) / 1GB

    $global:DashTick++
    if ($global:DashTick % 2 -eq 1) { $global:GpuCache = Get-GpuInfo; $global:CpuTemp = Get-CpuTemp }   # раз в 4 сек
    $g = $global:GpuCache

    $L = $script:DIM; $R = $script:RST; $T = $script:TXT; $B = $script:BLUE
    $l1 = "$L╭─ $B$env:COMPUTERNAME$L ─ up $T$($up.Days)d $($up.Hours)h $($up.Minutes)m$L ─ $T$(Get-Date -Format 'dd.MM HH:mm:ss')$R"
    $ct = if ($null -ne $global:CpuTemp) { $tc = if ($global:CpuTemp -ge 85) { C "f38ba8" } elseif ($global:CpuTemp -ge 70) { C "f9e2af" } else { $L }; " $tc$([math]::Round($global:CpuTemp))°C$R" } else { "" }
    $l2 = ("$L│$R $B CPU$R $(Bar $cpu)$T {0,3:N0}%$R${ct}   $B RAM$R $(Bar ($used/$tot*100))$T {1:N1}/{2:N0} GB$R" -f $cpu, $used, $tot)
    $l3 = if ($g) {
        ("$L│$R $B GPU$R $(Bar $g.Util)$T {0,3:N0}%$R   $B VRM$R $(Bar ($g.MemUsed/$g.MemTotal*100))$T {1:N1}/{2:N0} GB$R  $L{3}°C$R" -f $g.Util, ($g.MemUsed/1024), ($g.MemTotal/1024), $g.Temp)
    } else { "$L│$R $L нет NVIDIA GPU$R" }
    $l4 = ("$L│$R $B C:$R  $(Bar ($dU/$dT*100))$T {0:N0}/{1:N0} GB$R   $L htop · nvtop · live off$R" -f $dU, $dT)
    $w  = [Console]::WindowWidth
    $l5 = "$L╰" + ('─' * [math]::Max(1, $w - 2)) + $R
    @($l1, $l2, $l3, $l4, $l5)
}

function Update-LiveHeader {
    if (-not $global:DashLiveOn -or $global:DashPaused) { return }
    $e = [char]27; $h = [Console]::WindowHeight
    $lines = Get-DashLines
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append("${e}7$e[$($global:DashH + 1);${h}r")          # сохранить курсор, задать область прокрутки
    for ($i = 0; $i -lt $lines.Count; $i++) {
        [void]$sb.Append("$e[$($i + 1);1H$e[2K$($lines[$i])")
    }
    [void]$sb.Append("${e}8")                                        # вернуть курсор
    [Console]::Write($sb.ToString())
}

function Restore-LiveHeader {
    if (-not $global:DashLiveOn) { return }
    $e = [char]27; $h = [Console]::WindowHeight
    [Console]::Write("$e[$($global:DashH + 1);${h}r$e[$($global:DashH + 1);1H")
    Update-LiveHeader
}

# cls / clear / Clear-Host не должны стирать панель
function Clear-Host {
    $e = [char]27
    [Console]::Write("$e[2J$e[3J$e[H")
    if (-not $global:DashPaused) { Restore-LiveHeader }
}

# Ctrl+L: чистим экран, но панель и промпт остаются на месте
Set-PSReadLineKeyHandler -Chord 'Ctrl+l' -ScriptBlock {
    if (-not $global:DashLiveOn) { [Microsoft.PowerShell.PSConsoleReadLine]::ClearScreen(); return }
    [Console]::Write("$([char]27)[2J$([char]27)[3J")
    Update-LiveHeader
    [Microsoft.PowerShell.PSConsoleReadLine]::InvokePrompt($null, [Console]::WindowTop + $global:DashH)
}

function live {
    param([ValidateSet('on','off')][string]$State = 'on')
    if ($State -eq 'on') {
        if ($global:DashLiveOn) { return }
        $global:DashLiveOn = $true
        $global:DashTimer = [System.Timers.Timer]::new(2000)
        Register-ObjectEvent $global:DashTimer Elapsed -SourceIdentifier DashLive -Action { Update-LiveHeader } | Out-Null
        $global:DashTimer.Start()
        Clear-Host
    } else {
        $global:DashLiveOn = $false
        Unregister-Event DashLive -ErrorAction SilentlyContinue
        if ($global:DashTimer) { $global:DashTimer.Dispose() }
        [Console]::Write("$([char]27)[r")
        Clear-Host
    }
}

Register-EngineEvent PowerShell.Exiting -Action { [Console]::Write("$([char]27)[r") } | Out-Null

# =================================
# START
# =================================
if ($Host.UI.RawUI.WindowSize.Width -ge 70 -and -not $env:NO_DASH) { live on }
T 'live header'