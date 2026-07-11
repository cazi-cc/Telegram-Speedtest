param(
    [Parameter(Position = 0)]
    [string]$Command = ""
)

$ErrorActionPreference = "Stop"

$AppName = "telegram-speedtest"
$AppVersion = "0.6.0"
$RepoUrl = "https://github.com/cazi-cc/Telegram-Speedtest"
$RawUrl = "https://raw.githubusercontent.com/cazi-cc/Telegram-Speedtest/main/telegram-speedtest.ps1"
$TdlInstallUrl = "https://docs.iyear.me/tdl/install.ps1"
$ShortcutName = "tst"
$Namespace = "tst"

$StateDir = Join-Path $env:APPDATA "Telegram-Speedtest"
$ConfigFile = Join-Path $StateDir "config.json"
$TdlDataDir = Join-Path $StateDir "tdl-data"
$ResultFile = Join-Path $env:USERPROFILE "telegram-speedtest-result.txt"
$TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("telegram-speedtest-" + $PID)

$State = [ordered]@{
    ResourceUrl = ""
    ProxyUrl = ""
    ProfileName = "推荐低资源"
    TestSeconds = 20
    MultiThreads = 4
    MultiPool = 4
    LimitMiB = 128
    KeepTdl = $false
    LastSingleMiBs = ""
    LastSingleMbps = ""
    LastMultiMiBs = ""
    LastMultiMbps = ""
}

$Script:CurrentProcess = $null
$Script:TdlInstalledByThisRun = $false
$Script:TdlInstalledPath = ""

function Initialize-Dirs {
    New-Item -ItemType Directory -Force -Path $StateDir, $TdlDataDir, $TempRoot | Out-Null
}

function Load-Config {
    Initialize-Dirs
    if (Test-Path -LiteralPath $ConfigFile) {
        try {
            $json = Get-Content -LiteralPath $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($key in @($State.Keys)) {
                if ($json.PSObject.Properties.Name -contains $key) {
                    $State[$key] = $json.$key
                }
            }
        } catch {
            Write-Warning "配置读取失败，将使用默认配置。"
        }
    }
}

function Save-Config {
    Initialize-Dirs
    $json = ConvertTo-Json -InputObject $State -Depth 4
    $encoding = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllText($ConfigFile, $json, $encoding)
}

function Stop-CurrentProcess {
    if ($Script:CurrentProcess -and -not $Script:CurrentProcess.HasExited) {
        try {
            Stop-Process -Id $Script:CurrentProcess.Id -Force -ErrorAction SilentlyContinue
        } catch {}
    }
    $Script:CurrentProcess = $null
}

function Cleanup {
    Save-Config
    Stop-CurrentProcess
    Remove-Item -LiteralPath $TempRoot -Recurse -Force -ErrorAction SilentlyContinue
    if ($Script:TdlInstalledByThisRun -and -not [bool]$State.KeepTdl -and $Script:TdlInstalledPath) {
        $installDir = Split-Path -Parent $Script:TdlInstalledPath
        if ($installDir -and (Test-Path -LiteralPath $installDir) -and $installDir.TrimEnd('\') -ieq (Join-Path $env:SystemDrive "tdl").TrimEnd('\')) {
            Remove-Item -LiteralPath $installDir -Recurse -Force -ErrorAction SilentlyContinue
        } else {
            Remove-Item -LiteralPath $Script:TdlInstalledPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Write-Origin {
    Write-Host ""
    Write-Host "Telegram-Speedtest" -NoNewline -ForegroundColor Cyan
    Write-Host " v$AppVersion" -ForegroundColor DarkGray
    Write-Host "基于 iyear/tdl 的 Telegram 资源测速封装，不是 Telegram 或 tdl 官方项目。" -ForegroundColor DarkGray
    Write-Host $RepoUrl -ForegroundColor DarkGray
}

function Write-Rule {
    Write-Host ("─" * 60) -ForegroundColor DarkGray
}

function Write-MenuItem([string]$Number, [string]$Text) {
    Write-Host ("  {0,2}  {1}" -f $Number, $Text) -ForegroundColor Green
}

function Write-StatusLine([string]$Name, [string]$Value) {
    Write-Host ("  {0,-10} {1}" -f $Name, $Value)
}

function Default-Text($Value, [string]$Fallback = "--") {
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return $Fallback
    }
    return [string]$Value
}

function Pause-Menu {
    Write-Host ""
    Read-Host "按 Enter 返回" | Out-Null
}

function Format-Bytes([double]$Bytes) {
    $units = @("B", "KiB", "MiB", "GiB", "TiB")
    $value = [double]$Bytes
    $idx = 0
    while ($value -ge 1024 -and $idx -lt $units.Count - 1) {
        $value = $value / 1024
        $idx++
    }
    "{0:N2} {1}" -f $value, $units[$idx]
}

function Get-DirBytes([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return 0 }
    $sum = 0L
    Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue | ForEach-Object {
        $sum += $_.Length
    }
    return $sum
}

function Redact-Proxy([string]$Proxy) {
    if ([string]::IsNullOrWhiteSpace($Proxy)) { return "直连" }
    return ($Proxy -replace '(://)[^/@:]+(:[^/@]+)?@', '$1***:***@')
}

function Install-Shortcut {
    $binDir = Join-Path $env:LOCALAPPDATA "Microsoft\WindowsApps"
    if (-not (Test-Path -LiteralPath $binDir)) {
        $binDir = Join-Path $env:USERPROFILE "bin"
    }
    New-Item -ItemType Directory -Force -Path $binDir | Out-Null

    $cmdPath = Join-Path $binDir "$ShortcutName.cmd"
    $cmd = @"
@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "`$u='$RawUrl'; `$p=Join-Path `$env:TEMP 'telegram-speedtest.ps1'; Invoke-WebRequest -UseBasicParsing `$u -OutFile `$p; & `$p %*"
"@
    Set-Content -LiteralPath $cmdPath -Value $cmd -Encoding ASCII

    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $pathParts = @()
    if ($userPath) { $pathParts = $userPath -split ';' }
    if ($pathParts -notcontains $binDir) {
        $newPath = if ($userPath) { "$userPath;$binDir" } else { $binDir }
        [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
        $env:Path = "$env:Path;$binDir"
    }
    Write-Host "已安装联网快捷命令：$cmdPath"
    Write-Host "后续可直接运行：$ShortcutName"
}

function Maybe-InstallShortcut {
    if (Get-Command $ShortcutName -ErrorAction SilentlyContinue) { return }
    Write-Host "正在安装联网快捷命令：$ShortcutName"
    try {
        Install-Shortcut
    } catch {
        Write-Warning "未能自动安装 $ShortcutName：$($_.Exception.Message)"
    }
}

function Ensure-Tdl {
    $existing = Get-Command tdl -ErrorAction SilentlyContinue
    if ($existing) { return $existing.Source }

    Write-Host "未检测到 tdl，将调用官方 Windows 安装脚本。"
    Write-Host "来源：$TdlInstallUrl" -ForegroundColor DarkGray
    $script = Invoke-WebRequest -UseBasicParsing $TdlInstallUrl
    Invoke-Expression $script.Content

    $cmd = Get-Command tdl -ErrorAction SilentlyContinue
    if (-not $cmd) {
        $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
        $cmd = Get-Command tdl -ErrorAction SilentlyContinue
    }
    if (-not $cmd) {
        throw "tdl 安装后仍不可用，请重新打开 PowerShell 或检查 PATH。"
    }
    $Script:TdlInstalledByThisRun = $true
    $Script:TdlInstalledPath = $cmd.Source
    return $cmd.Source
}

function Get-TdlBaseArgs {
    $args = @("-n", $Namespace, "--storage", "type=bolt,path=$TdlDataDir", "--disable-progress-ps")
    if (-not [string]::IsNullOrWhiteSpace([string]$State.ProxyUrl)) {
        $args += @("--proxy", [string]$State.ProxyUrl)
    }
    return $args
}

function Run-TdlLogin([string]$Mode) {
    $tdl = Ensure-Tdl
    Initialize-Dirs
    Write-Host ""
    Write-Host "登录方式：$Mode"
    Write-Host "登录数据目录：$TdlDataDir"
    & $tdl @(Get-TdlBaseArgs) login -T $Mode
}

function Set-ResourceUrl {
    Write-Host ""
    $value = Read-Host "粘贴 Telegram 频道/群组中具体资源消息链接（建议使用较大的视频或文件）"
    $State.ResourceUrl = $value
    Save-Config
}

function Set-ProxyMenu {
    Clear-Host
    Write-Origin
    Write-Host ""
    Write-Host "当前连接方式：$(Redact-Proxy $State.ProxyUrl)"
    Write-Host ""
    Write-MenuItem 1 "VPS/本机直连 Telegram"
    Write-MenuItem 2 "SOCKS5：127.0.0.1:1080"
    Write-MenuItem 3 "SOCKS5：127.0.0.1:10808"
    Write-MenuItem 4 "SOCKS5：127.0.0.1:7891"
    Write-MenuItem 5 "HTTP：127.0.0.1:7890"
    Write-MenuItem 6 "自定义代理地址"
    Write-MenuItem 0 "返回"
    $choice = Read-Host "请选择"
    switch ($choice) {
        "1" { $State.ProxyUrl = "" }
        "2" { $State.ProxyUrl = "socks5://127.0.0.1:1080" }
        "3" { $State.ProxyUrl = "socks5://127.0.0.1:10808" }
        "4" { $State.ProxyUrl = "socks5://127.0.0.1:7891" }
        "5" { $State.ProxyUrl = "http://127.0.0.1:7890" }
        "6" { $State.ProxyUrl = Read-Host "输入代理，例如 socks5://user:pass@127.0.0.1:1080" }
        "0" { return }
        default { Write-Host "无效选择。"; Pause-Menu; return }
    }
    Save-Config
}

function Login-Menu {
    Clear-Host
    Write-Origin
    Write-Host ""
    Write-Host "Telegram 登录管理"
    Write-Host ""
    Write-StatusLine "当前代理" (Redact-Proxy $State.ProxyUrl)
    Write-StatusLine "登录数据" $TdlDataDir
    Write-Host ""
    Write-MenuItem 1 "二维码登录"
    Write-MenuItem 2 "手机号验证码登录"
    Write-MenuItem 3 "删除本脚本的 Telegram 登录数据"
    Write-MenuItem 0 "返回"
    $choice = Read-Host "请选择"
    switch ($choice) {
        "1" { Run-TdlLogin "qr"; Pause-Menu }
        "2" { Run-TdlLogin "code"; Pause-Menu }
        "3" {
            Remove-Item -LiteralPath $TdlDataDir -Recurse -Force -ErrorAction SilentlyContinue
            New-Item -ItemType Directory -Force -Path $TdlDataDir | Out-Null
            Write-Host "已删除登录数据。"
            Pause-Menu
        }
        "0" { return }
        default { Write-Host "无效选择。"; Pause-Menu }
    }
}

function Set-Profile([string]$Name) {
    switch ($Name) {
        "tiny" {
            $State.ProfileName = "极低资源"
            $State.TestSeconds = 12
            $State.MultiThreads = 2
            $State.MultiPool = 2
            $State.LimitMiB = 64
        }
        "low" {
            $State.ProfileName = "推荐低资源"
            $State.TestSeconds = 20
            $State.MultiThreads = 4
            $State.MultiPool = 4
            $State.LimitMiB = 128
        }
        "standard" {
            $State.ProfileName = "标准测试"
            $State.TestSeconds = 30
            $State.MultiThreads = 8
            $State.MultiPool = 8
            $State.LimitMiB = 256
        }
    }
    Save-Config
}

function Choose-CustomValue([string]$Prompt, [int[]]$Values, [int]$Default) {
    Write-Host ""
    Write-Host $Prompt
    for ($i = 0; $i -lt $Values.Count; $i++) {
        Write-Host ("{0}. {1}" -f ($i + 1), $Values[$i])
    }
    $choice = Read-Host "请选择，默认 $Default"
    if ([string]::IsNullOrWhiteSpace($choice)) { return $Default }
    $idx = 0
    if ([int]::TryParse($choice, [ref]$idx) -and $idx -ge 1 -and $idx -le $Values.Count) {
        return $Values[$idx - 1]
    }
    return $Default
}

function Profile-Menu {
    Clear-Host
    Write-Origin
    Write-Host ""
    Write-Host "选择测速强度"
    Write-Host ""
    Write-MenuItem 1 "极低资源：12秒，多连接2线程，64MiB上限"
    Write-MenuItem 2 "推荐低资源：20秒，多连接4线程，128MiB上限"
    Write-MenuItem 3 "标准测试：30秒，多连接8线程，256MiB上限"
    Write-MenuItem 4 "自定义"
    Write-MenuItem 0 "返回"
    $choice = Read-Host "请选择"
    switch ($choice) {
        "1" { Set-Profile "tiny"; Start-Benchmark }
        "2" { Set-Profile "low"; Start-Benchmark }
        "3" { Set-Profile "standard"; Start-Benchmark }
        "4" {
            $State.ProfileName = "自定义"
            $State.TestSeconds = Choose-CustomValue "每轮测速时长（秒）" @(10, 20, 30, 60) 20
            $State.MultiThreads = Choose-CustomValue "多连接线程数" @(2, 4, 8, 12) 4
            $State.MultiPool = $State.MultiThreads
            $State.LimitMiB = Choose-CustomValue "每轮最大下载占用（MiB）" @(64, 128, 256, 512) 128
            Save-Config
            Start-Benchmark
        }
        "0" { return }
        default { Write-Host "无效选择。"; Pause-Menu }
    }
}

function Confirm-Ready {
    if ([string]::IsNullOrWhiteSpace([string]$State.ResourceUrl)) {
        Set-ResourceUrl
    }
    if ([string]::IsNullOrWhiteSpace([string]$State.ResourceUrl)) { return $false }
    Clear-Host
    Write-Origin
    Write-Host ""
    Write-Host "即将开始测速"
    Write-Host ""
    Write-StatusLine "资源链接" $State.ResourceUrl
    Write-StatusLine "连接方式" (Redact-Proxy $State.ProxyUrl)
    Write-StatusLine "方案" $State.ProfileName
    Write-StatusLine "单连接" ("1线程 / 1连接池 / {0}秒" -f $State.TestSeconds)
    Write-StatusLine "多连接" ("{0}线程 / {1}连接池 / {2}秒" -f $State.MultiThreads, $State.MultiPool, $State.TestSeconds)
    Write-StatusLine "磁盘上限" ("{0}MiB / 轮" -f $State.LimitMiB)
    Write-Host ""
    Write-MenuItem 1 "开始"
    Write-MenuItem 0 "取消"
    return ((Read-Host "请选择") -eq "1")
}

function Run-OneTest([string]$Label, [int]$Threads, [int]$Pool, [int]$Seconds, [int]$LimitMiB) {
    $tdl = Ensure-Tdl
    $runDir = Join-Path $TempRoot $Label
    $logFile = Join-Path $TempRoot "$Label.log"
    $errFile = Join-Path $TempRoot "$Label.err.log"
    $limitBytes = [int64]$LimitMiB * 1024 * 1024
    Remove-Item -LiteralPath $runDir -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $runDir | Out-Null

    $args = @(Get-TdlBaseArgs) + @("--pool", "$Pool", "dl", "-u", [string]$State.ResourceUrl, "-d", $runDir, "-t", "$Threads", "-l", "1", "--restart")
    $start = Get-Date
    $Script:CurrentProcess = Start-Process -FilePath $tdl -ArgumentList $args -WorkingDirectory $runDir -RedirectStandardOutput $logFile -RedirectStandardError $errFile -PassThru -WindowStyle Hidden

    while (-not $Script:CurrentProcess.HasExited) {
        Start-Sleep -Seconds 1
        $elapsed = [int]((Get-Date) - $start).TotalSeconds
        $size = Get-DirBytes $runDir
        $timePct = [Math]::Min(100, [int](($elapsed * 100) / $Seconds))
        $sizePct = [Math]::Min(100, [int](($size * 100) / $limitBytes))
        $pct = [Math]::Max($timePct, $sizePct)
        Write-Progress -Activity $Label -Status ("{0} / {1}, {2}s / {3}s" -f (Format-Bytes $size), (Format-Bytes $limitBytes), $elapsed, $Seconds) -PercentComplete $pct
        if ($elapsed -ge $Seconds -or $size -ge $limitBytes) {
            Stop-CurrentProcess
            break
        }
    }
    Write-Progress -Activity $Label -Completed
    if ($Script:CurrentProcess) {
        try { $Script:CurrentProcess.WaitForExit() } catch {}
    }
    $elapsedFinal = [Math]::Max(1, [int]((Get-Date) - $start).TotalSeconds)
    $bytes = Get-DirBytes $runDir
    Remove-Item -LiteralPath $runDir, $logFile, $errFile -Recurse -Force -ErrorAction SilentlyContinue

    $mibs = $bytes / 1024 / 1024 / $elapsedFinal
    $mbps = $bytes * 8 / 1000 / 1000 / $elapsedFinal
    return [pscustomobject]@{
        MiBs = "{0:N2}" -f $mibs
        Mbps = "{0:N2}" -f $mbps
        Bytes = $bytes
        Seconds = $elapsedFinal
    }
}

function Start-Benchmark {
    try {
        Ensure-Tdl | Out-Null
        if (-not (Confirm-Ready)) { return }
        Initialize-Dirs
        Remove-Item -LiteralPath $TempRoot -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Force -Path $TempRoot | Out-Null

        Write-Host ""
        Write-Host "开始单连接敏感性测试..."
        $single = Run-OneTest "single" 1 1 ([int]$State.TestSeconds) ([int]$State.LimitMiB)
        $State.LastSingleMiBs = $single.MiBs
        $State.LastSingleMbps = $single.Mbps

        Write-Host ""
        Write-Host "开始多连接总吞吐测试..."
        $multi = Run-OneTest "multi" ([int]$State.MultiThreads) ([int]$State.MultiPool) ([int]$State.TestSeconds) ([int]$State.LimitMiB)
        $State.LastMultiMiBs = $multi.MiBs
        $State.LastMultiMbps = $multi.Mbps
        Save-Config

        Show-Result
        Pause-Menu
    } catch {
        Write-Host ""
        Write-Host "测速失败：$($_.Exception.Message)" -ForegroundColor Red
        Pause-Menu
    }
}

function Get-ResultJudgement {
    $s = 0.0
    $m = 0.0
    [double]::TryParse(([string]$State.LastSingleMbps), [ref]$s) | Out-Null
    [double]::TryParse(([string]$State.LastMultiMbps), [ref]$m) | Out-Null
    if ($s -lt 1 -and $m -lt 1) { return "几乎没有有效下载，优先检查登录、链接权限、代理或 Telegram 连通性。" }
    if ($s -lt 10 -and $m -ge 50) { return "总吞吐能跑起来，但单连接弱，容易表现为资源打开慢、视频首开慢、拖动后缓冲久。" }
    if ($s -lt 10 -and $m -lt 20) { return "VPS/本机到 Telegram 文件方向整体偏弱，普通 Speedtest 快也不能排除此问题。" }
    if ($m -gt $s * 2.5) { return "线路明显依赖并发，实际 Telegram 客户端体验可能低于多连接结果。" }
    return "到 Telegram 的文件下载方向没有明显单连接瓶颈。"
}

function Show-Result {
    Clear-Host
    Write-Origin
    Write-Host ""
    Write-Host "测速结果"
    Write-Rule
    Write-StatusLine "单连接" ("{0} MiB/s    {1} Mbps" -f (Default-Text $State.LastSingleMiBs), (Default-Text $State.LastSingleMbps))
    Write-StatusLine "多连接" ("{0} MiB/s    {1} Mbps" -f (Default-Text $State.LastMultiMiBs), (Default-Text $State.LastMultiMbps))
    Write-Host ""
    Write-Host ("判断：{0}" -f (Get-ResultJudgement))
}

function Result-Menu {
    Show-Result
    Write-Host ""
    Write-MenuItem 1 "导出到 $ResultFile"
    Write-MenuItem 0 "返回"
    $choice = Read-Host "请选择"
    if ($choice -eq "1") {
        $content = @"
Telegram-Speedtest v$AppVersion
资源链接：$($State.ResourceUrl)
连接方式：$(Redact-Proxy $State.ProxyUrl)
方案：$($State.ProfileName)
单连接敏感性：$($State.LastSingleMiBs) MiB/s    $($State.LastSingleMbps) Mbps
多连接总吞吐：$($State.LastMultiMiBs) MiB/s    $($State.LastMultiMbps) Mbps
"@
        $content | Set-Content -LiteralPath $ResultFile -Encoding UTF8
        Write-Host "已导出。"
        Pause-Menu
    }
}

function Status-Menu {
    Clear-Host
    Write-Origin
    Write-Host ""
    Write-Host "资源与状态"
    Write-Rule
    Write-StatusLine "临时目录" ("{0} ({1})" -f $TempRoot, (Format-Bytes (Get-DirBytes $TempRoot)))
    Write-StatusLine "配置目录" ("{0} ({1})" -f $StateDir, (Format-Bytes (Get-DirBytes $StateDir)))
    Write-StatusLine "登录数据" ("{0} ({1})" -f $TdlDataDir, (Format-Bytes (Get-DirBytes $TdlDataDir)))
    $tdl = Get-Command tdl -ErrorAction SilentlyContinue
    Write-StatusLine "tdl" ($(if ($tdl) { $tdl.Source } else { "未安装" }))
    Write-StatusLine "资源链接" ($(if ($State.ResourceUrl) { $State.ResourceUrl } else { "未设置" }))
    Write-StatusLine "连接方式" (Redact-Proxy $State.ProxyUrl)
    Write-StatusLine "测试方案" $State.ProfileName
    Pause-Menu
}

function Clean-Menu {
    Clear-Host
    Write-Origin
    Write-Host ""
    Write-Host "清理与空间设置"
    Write-Host ""
    Write-MenuItem 1 "立即清理临时下载文件、残片和日志"
    Write-MenuItem 2 "删除已导出的轻量结果文件"
    Write-MenuItem 3 "删除本脚本的 Telegram 登录数据"
    Write-MenuItem 4 "切换退出时是否保留本次临时安装的 tdl"
    Write-MenuItem 0 "返回"
    $choice = Read-Host "请选择"
    switch ($choice) {
        "1" { Remove-Item -LiteralPath $TempRoot -Recurse -Force -ErrorAction SilentlyContinue; New-Item -ItemType Directory -Force -Path $TempRoot | Out-Null; Write-Host "已清理临时目录。"; Pause-Menu }
        "2" { Remove-Item -LiteralPath $ResultFile -Force -ErrorAction SilentlyContinue; Write-Host "已删除结果文件。"; Pause-Menu }
        "3" { Remove-Item -LiteralPath $TdlDataDir -Recurse -Force -ErrorAction SilentlyContinue; New-Item -ItemType Directory -Force -Path $TdlDataDir | Out-Null; Write-Host "已删除登录数据。"; Pause-Menu }
        "4" { $State.KeepTdl = -not [bool]$State.KeepTdl; Save-Config; Write-Host ("当前设置：退出时{0}删除本次临时安装的 tdl。" -f ($(if ($State.KeepTdl) { "不" } else { "会" }))); Pause-Menu }
        "0" { return }
        default { Write-Host "无效选择。"; Pause-Menu }
    }
}

function Main-Menu {
    Maybe-InstallShortcut
    while ($true) {
        Clear-Host
        Write-Origin
        Write-Rule
        Write-StatusLine "资源" ($(if ($State.ResourceUrl) { $State.ResourceUrl } else { "未设置" }))
        Write-StatusLine "连接" (Redact-Proxy $State.ProxyUrl)
        Write-StatusLine "方案" $State.ProfileName
        Write-StatusLine "结果" ("单 {0} Mbps / 多 {1} Mbps" -f ($(if ($State.LastSingleMbps) { $State.LastSingleMbps } else { "--" })), ($(if ($State.LastMultiMbps) { $State.LastMultiMbps } else { "--" })))
        Write-Rule
        Write-MenuItem 1 "一键开始推荐低资源测速"
        Write-MenuItem 2 "选择测速强度并开始"
        Write-MenuItem 3 "设置/更换 Telegram 资源消息链接"
        Write-MenuItem 4 "设置直连或代理"
        Write-MenuItem 5 "Telegram 登录管理"
        Write-MenuItem 6 "查看或导出本次结果"
        Write-MenuItem 7 "查看 RAM、硬盘和占用状态"
        Write-MenuItem 8 "清理与空间设置"
        Write-MenuItem 0 "自动清理并退出"
        Write-Host ""
        $choice = Read-Host "请选择"
        switch ($choice) {
            "1" { Set-Profile "low"; Start-Benchmark }
            "2" { Profile-Menu }
            "3" { Set-ResourceUrl }
            "4" { Set-ProxyMenu }
            "5" { Login-Menu }
            "6" { Result-Menu }
            "7" { Status-Menu }
            "8" { Clean-Menu }
            "0" { Save-Config; Write-Host "正在清理并退出..."; return }
            default { Write-Host "无效选择。"; Pause-Menu }
        }
    }
}

function Show-Usage {
    Write-Origin
    Write-Host ""
    Write-Host "Windows PowerShell 一键运行："
    Write-Host "powershell -NoProfile -ExecutionPolicy Bypass -Command `" `$p=Join-Path `$env:TEMP 'telegram-speedtest.ps1'; iwr -UseBasicParsing '$RawUrl' -OutFile `$p; & `$p`""
    Write-Host ""
    Write-Host "安装联网快捷命令后：$ShortcutName"
}

Initialize-Dirs
Load-Config

try {
    switch ($Command) {
        "setup" { Install-Shortcut }
        "install" { Install-Shortcut }
        "--version" { Write-Origin }
        "-v" { Write-Origin }
        "version" { Write-Origin }
        "--help" { Show-Usage }
        "-h" { Show-Usage }
        "help" { Show-Usage }
        default { Main-Menu }
    }
} finally {
    Cleanup
}


