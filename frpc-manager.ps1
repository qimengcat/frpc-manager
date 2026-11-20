$ErrorActionPreference = "Stop"

$dir     = Split-Path -Parent $MyInvocation.MyCommand.Path
$nssm    = Join-Path $dir "nssm.exe"
$frpc    = Join-Path $dir "frpc.exe"
$conf    = Join-Path $dir "frpc.toml"
$logs    = Join-Path $dir "logs"
$tmpDir  = Join-Path $dir "tmp_update"
$svcName = "frpc"

# ========== 用户配置区 ==========
$LogRetentionDays = 3   # 日志保留天数，默认 3 天

# 下载源，按顺序尝试；"" 表示 GitHub 直连，其余为加速镜像前缀（会拼在 GitHub 下载地址前面）
# 国内网络建议把镜像放到前面；镜像可用性会变化，失效了可自行替换
$DownloadMirrors = @(
    "",
    "https://ghfast.top/",
    "https://gh-proxy.com/"
)
$DownloadTimeoutSec = 300   # 单个下载源超时（秒）

# 手动指定 frpc 版本，如 "v0.61.1"；留空则自动获取最新版本
# GitHub 完全无法访问、拿不到版本号时，填上版本号即可直接走镜像下载
$FrpcVersionOverride = ""
# ================================

# PS 5.1 访问 GitHub 需要 TLS 1.2；关闭进度条可明显加快 Invoke-WebRequest 下载
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$ProgressPreference = "SilentlyContinue"

if (-not (Test-Path $logs)) { New-Item -ItemType Directory -Path $logs | Out-Null }

function Invoke-Nssm {
    $old = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        & $nssm @args 2>$null
    } finally {
        $ErrorActionPreference = $old
    }
}

function Get-FrpcVersion {
    if (-not (Test-Path $frpc)) { return "" }
    try {
        $rawVersion = & $frpc --version 2>$null
        if ($rawVersion -match '\d+\.\d+\.\d+') {
            return "v" + $Matches[0]
        }
    } catch {
        return ""
    }
    return ""
}

function Test-ServiceInstalled {
    $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
    return [bool]$svc
}

# ========== 下载相关 ==========

# 获取要下载的版本信息，失败返回 $null
# 返回对象: Tag / PkgName / ZipName / Url
function Get-LatestFrpRelease {
    $tag  = $null
    $url  = $null
    $resp = $null

    if ($FrpcVersionOverride) {
        $tag = $FrpcVersionOverride.Trim()
        Write-Host "使用手动指定的版本: $tag"
    } else {
        # 方式一：GitHub API
        try {
            $resp = Invoke-RestMethod -Uri "https://api.github.com/repos/fatedier/frp/releases/latest" -TimeoutSec 15 -Headers @{
                Accept       = "application/vnd.github.v3+json"
                "User-Agent" = "frpc-manager"
            }
            $tag = $resp.tag_name
        } catch {
            Write-Host "GitHub API 访问失败，尝试备用方式获取版本号..." -ForegroundColor DarkYellow
        }

        # 方式二：读取 releases/latest 跳转后的地址 (.../releases/tag/vX.Y.Z)
        if (-not $tag) {
            try {
                $req = [System.Net.HttpWebRequest]::Create("https://github.com/fatedier/frp/releases/latest")
                $req.Method            = "HEAD"
                $req.UserAgent         = "frpc-manager"
                $req.Timeout           = 15000
                $req.AllowAutoRedirect = $true
                $res   = $req.GetResponse()
                $final = $res.ResponseUri.AbsoluteUri
                $res.Close()
                if ($final -match '/tag/(v?\d+\.\d+\.\d+)') { $tag = $Matches[1] }
            } catch {
                Write-Host "备用方式也失败: $($_.Exception.Message)" -ForegroundColor DarkYellow
            }
        }
    }

    if (-not $tag) {
        Write-Host "获取最新版本失败。可在脚本配置区填写 `$FrpcVersionOverride 手动指定版本后重试。"
        return $null
    }
    if (-not $tag.StartsWith("v")) { $tag = "v$tag" }

    $version = $tag.TrimStart("v")
    $pkgName = "frp_${version}_windows_amd64"
    $zipName = "$pkgName.zip"

    # 优先使用 API 返回的资源地址，拿不到时按 GitHub 标准规则拼接
    if ($resp -and $resp.assets) {
        $field = "browser_" + "down" + "load" + "_url"
        $asset = $resp.assets | Where-Object { $_.name -eq $zipName } | Select-Object -First 1
        if ($asset) { $url = $asset.$field }
    }
    if (-not $url) {
        $url = "https://github.com/fatedier/frp/releases/" + "down" + "load/$tag/$zipName"
    }

    return [pscustomobject]@{
        Tag     = $tag
        PkgName = $pkgName
        ZipName = $zipName
        Url     = $url
    }
}

# 在同一行刷新显示下载进度
function Write-DownloadProgress {
    param([long]$Done, [long]$Total, [double]$Seconds)

    $mb    = $Done / 1MB
    $speed = if ($Seconds -gt 0) { $mb / $Seconds } else { 0 }

    if ($Total -gt 0) {
        $pct   = $Done * 100.0 / $Total
        $width = 30
        $fill  = [int][math]::Floor($pct / 100 * $width)
        $bar   = ('#' * $fill).PadRight($width, '-')
        $line  = "  [{0}] {1,5:N1}%  {2:N1}/{3:N1} MB  {4:N2} MB/s" -f $bar, $pct, $mb, ($Total / 1MB), $speed
    } else {
        # 服务器没返回文件大小时，只显示已下载量
        $line = "  已下载 {0:N1} MB  {1:N2} MB/s" -f $mb, $speed
    }
    Write-Host -NoNewline ("`r" + $line.PadRight(75))
}

# 带进度显示的下载，失败抛异常
function Save-FileWithProgress {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$OutFile,
        [int]$TimeoutSec = 300
    )

    $req = [System.Net.HttpWebRequest]::Create($Url)
    $req.UserAgent         = "frpc-manager"
    $req.AllowAutoRedirect = $true
    $req.Timeout           = 15000   # 连接超时 15 秒，连不上尽快换下一个下载源
    $req.ReadWriteTimeout  = 30000   # 30 秒收不到数据视为卡死

    $res = $null; $in = $null; $out = $null
    try {
        $res   = $req.GetResponse()
        $total = $res.ContentLength          # 未知时为 -1
        $in    = $res.GetResponseStream()
        $out   = [System.IO.File]::Create($OutFile)
        $buf   = New-Object byte[] 81920
        $done  = 0L
        $sw    = [System.Diagnostics.Stopwatch]::StartNew()
        $lastMs = -1000

        while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
            $out.Write($buf, 0, $n)
            $done += $n
            if ($sw.Elapsed.TotalSeconds -gt $TimeoutSec) { throw "下载超过 $TimeoutSec 秒，已中止" }
            if ($sw.ElapsedMilliseconds - $lastMs -ge 200) {
                $lastMs = $sw.ElapsedMilliseconds
                Write-DownloadProgress $done $total $sw.Elapsed.TotalSeconds
            }
        }
        Write-DownloadProgress $done $total $sw.Elapsed.TotalSeconds
        Write-Host ""

        if ($total -gt 0 -and $done -ne $total) { throw "文件不完整 ($done / $total 字节)" }
    } finally {
        if ($out) { $out.Dispose() }
        if ($in)  { $in.Dispose() }
        if ($res) { $res.Close() }
    }
}

# 解压 zip 到临时目录，成功返回 frpc.exe 路径，失败返回 $null
function Expand-FrpcPackage {
    param([Parameter(Mandatory)][string]$ZipPath, [Parameter(Mandatory)]$Release)

    if (Test-Path $tmpDir) { Remove-Item $tmpDir -Recurse -Force }
    New-Item -ItemType Directory -Path $tmpDir | Out-Null

    try {
        # 解压同时校验文件有效性（镜像出错时可能返回 HTML 页面）
        Expand-Archive -Path $ZipPath -DestinationPath $tmpDir -Force
    } catch {
        Write-Host "  解压失败: $($_.Exception.Message)" -ForegroundColor DarkYellow
        return $null
    }

    $newFrpc = Join-Path (Join-Path $tmpDir $Release.PkgName) "frpc.exe"
    if (Test-Path $newFrpc) { return $newFrpc }

    Write-Host "  压缩包内未找到 frpc.exe" -ForegroundColor DarkYellow
    return $null
}

# 获取 frpc 安装包：优先复用本地 zip，否则依次尝试各下载源
# 成功返回解压出的 frpc.exe 路径，全部失败返回 $null；zip 保留在脚本目录
function Get-FrpcPackage {
    param([Parameter(Mandatory)]$Release)

    $zipPath  = Join-Path $dir $Release.ZipName
    $partPath = "$zipPath.part"

    # 本地已有同版本压缩包，直接复用
    if (Test-Path $zipPath) {
        Write-Host "发现本地已有 $($Release.ZipName)，跳过下载..."
        $newFrpc = Expand-FrpcPackage -ZipPath $zipPath -Release $Release
        if ($newFrpc) { return $newFrpc }
        Write-Host "  本地压缩包无效，删除后重新下载" -ForegroundColor DarkYellow
        Remove-Item $zipPath -Force
    }

    foreach ($prefix in $DownloadMirrors) {
        $url   = $prefix + $Release.Url
        $label = if ($prefix) { "镜像 $prefix" } else { "GitHub 直连" }

        Write-Host "正在通过 [$label] 下载 $($Release.ZipName) ..."
        if (Test-Path $partPath) { Remove-Item $partPath -Force }

        try {
            Save-FileWithProgress -Url $url -OutFile $partPath -TimeoutSec $DownloadTimeoutSec
        } catch {
            Write-Host ""
            Write-Host "  失败: $($_.Exception.Message)" -ForegroundColor DarkYellow
            Remove-Item $partPath -Force -ErrorAction SilentlyContinue
            continue
        }

        # 下载完整后再改成正式文件名，避免中断时留下半截 zip 被误复用
        Move-Item -Path $partPath -Destination $zipPath -Force

        $newFrpc = Expand-FrpcPackage -ZipPath $zipPath -Release $Release
        if ($newFrpc) {
            Write-Host "  下载成功 [$label]" -ForegroundColor Green
            Write-Host "  安装包已保留: $zipPath"
            return $newFrpc
        }

        Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
        Write-Host "  文件无效，尝试下一个下载源..." -ForegroundColor DarkYellow
    }

    Write-Host "所有下载源均失败。可在配置区调整 `$DownloadMirrors，或手动下载 frpc.exe 放到 $dir"
    if (Test-Path $tmpDir) { Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue }
    return $null
}

# 确保 frpc.exe 存在：不存在时询问是否下载最新版。存在或下载成功返回 $true
function Confirm-FrpcExe {
    if (Test-Path $frpc) { return $true }

    Write-Host "未找到 frpc.exe: $frpc" -ForegroundColor Yellow
    $ans = Read-Host "是否下载最新版本的 frpc.exe？(y/n)"
    if ($ans -notmatch '^[yY]') {
        Write-Host "已取消。你也可以手动把 frpc.exe 放到 $dir 后重试。"
        return $false
    }

    $release = Get-LatestFrpRelease
    if (-not $release) { return $false }

    $newFrpc = Get-FrpcPackage -Release $release
    if (-not $newFrpc) { return $false }

    Copy-Item -Path $newFrpc -Destination $frpc -Force
    Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue

    Write-Host "frpc.exe 下载完成，版本: $($release.Tag)" -ForegroundColor Green
    return (Test-Path $frpc)
}

# ========== 服务管理 ==========

function Install-Service {
    if (-not (Test-Path $nssm)) { Write-Host "缺少 nssm.exe"; return }
    if (-not (Confirm-FrpcExe)) { return }
    if (-not (Test-Path $conf)) {
        Write-Host "缺少 frpc.toml，正在创建默认配置..."
        Edit-Config
    }

    Invoke-Nssm stop $svcName
    Invoke-Nssm remove $svcName confirm

    Invoke-Nssm install $svcName $frpc
    Invoke-Nssm set $svcName AppDirectory $dir
    Invoke-Nssm set $svcName AppParameters "-c `"$conf`""

    Invoke-Nssm set $svcName AppStdout  (Join-Path $logs "frpc.out.log")
    Invoke-Nssm set $svcName AppStderr  (Join-Path $logs "frpc.err.log")

    # 按大小轮转：活动日志超 10MB 即切出带时间戳历史文件，
    # 历史文件不再被写，配合每日 cleanlogs 删除 N 天前文件，体积可控
    Invoke-Nssm set $svcName AppRotateFiles 1
    Invoke-Nssm set $svcName AppRotateBytes 10485760

    Invoke-Nssm set $svcName AppRestartDelay 5000
    Invoke-Nssm set $svcName AppExit Default Restart
    Invoke-Nssm set $svcName Start SERVICE_AUTO_START

    Invoke-Nssm start $svcName

    Register-CleanLogsTask

    Write-Host "frpc 服务已安装并启动！(单文件超 10MB 自动轮转，每日清理 $LogRetentionDays 天前的历史日志)"
}

function Uninstall-Service {
    if (-not (Test-ServiceInstalled)) {
        Write-Host "服务尚未安装，无需卸载。"
        return
    }

    $confirm = Read-Host "确认卸载 frpc 服务？(y/n)"
    if ($confirm -notmatch '^[yY]') {
        Write-Host "已取消卸载。"
        return
    }

    Invoke-Nssm stop $svcName
    Invoke-Nssm remove $svcName confirm

    $taskName = "frpc-manager-cleanlogs"
    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        Write-Host "已删除日志清理计划任务。"
    }

    Write-Host "frpc 服务已卸载。"
    Write-Host "提示：如需彻底清理，可手动删除当前文件夹。"
}

function Show-Status {
    Invoke-Nssm status $svcName
}

function Start-FrpcService {
    if (-not (Confirm-FrpcExe)) { return }
    Invoke-Nssm start $svcName
    Write-Host "frpc 服务已启动。"
}

function Stop-FrpcService {
    Invoke-Nssm stop $svcName
    Write-Host "frpc 服务已停止。"
}

function Restart-FrpcService {
    if (-not (Confirm-FrpcExe)) { return }
    Invoke-Nssm restart $svcName
    Write-Host "frpc 服务已重启。"
}

function Update-Frpc {
    # frpc.exe 不存在时，走首次下载流程
    if (-not (Test-Path $frpc)) { [void](Confirm-FrpcExe); return }

    $current = Get-FrpcVersion
    if (-not $current) { Write-Host "无法获取当前 frpc 版本，请确认 frpc.exe 正常"; return }

    $release = Get-LatestFrpRelease
    if (-not $release) { return }
    $latest = $release.Tag

    if ($current.ToLower() -eq $latest.ToLower()) {
        Write-Host "当前已是最新版本: $latest，无需升级。"
        return
    }

    Write-Host "发现新版本: $latest，当前: $current"
    $newFrpc = Get-FrpcPackage -Release $release
    if (-not $newFrpc) { return }

    $wasInstalled = Test-ServiceInstalled
    if ($wasInstalled) {
        Write-Host "正在停止 frpc 服务..."
        Stop-FrpcService
    }

    Copy-Item -Path $frpc -Destination "$frpc.bak" -Force
    Write-Host "当前版本已备份至: $frpc.bak"
    Copy-Item -Path $newFrpc -Destination $frpc -Force

    if ($wasInstalled) {
        Write-Host "正在重启 frpc 服务..."
        Start-FrpcService
    }

    Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue

    Write-Host "升级成功！当前版本: $latest"
    Write-Host "旧版本备份: $frpc.bak"
}

# ========== 配置文件 ==========

function Show-Config {
    if (-not (Test-Path $conf)) { Write-Host "配置文件不存在: $conf"; return }
    Write-Host "===== $conf ====="
    Get-Content $conf -Encoding UTF8 | ForEach-Object { Write-Host $_ }
}

function Get-ConfigValue {
    param([string]$key)
    if (-not (Test-Path $conf)) { Write-Host "配置文件不存在: $conf"; return }
    $lines = Get-Content $conf -Encoding UTF8
    $found = $false
    $pattern = "^" + [regex]::Escape($key) + "\s*=\s*(.+)$"
    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        if ($trimmed -match $pattern) {
            Write-Host "$key = $($Matches[1].Trim())"
            $found = $true
        }
    }
    if (-not $found) { Write-Host "未找到配置项: $key" }
}

function Edit-Config {
    if (-not (Test-Path $conf)) {
        Write-Host "配置文件不存在，正在创建默认配置..."
        $tomlContent = @"
# === 服务端连接信息 ===
serverAddr = "your.server.com"    # 远程服务器地址，改为实际IP或域名
serverPort = 7000    # 服务器端口，默认7000

# === 必须的安全认证 (需与服务端 auth.token 完全一致) ===
auth.method = "token"
auth.token = "your-token"    # 认证令牌， [核心] 必须与服务端一致才能连接

# === 必须开启：TLS 传输加密 (配合服务端的 transport.tls.force = true) ===
transport.tls.enable = true

# === 性能与连接优化 ===
transport.tcpMux = true    # 开启 TCP 多路复用，显著减少连接握手开销

# === 日志配置 ===
log.to = "./logs/frpc.log"    # 日志存储位置
log.level = "info"    # 日志级别
log.maxDays = 3    # 日志保留天数

# 端口映射配置，可添加多个[[proxies]]
# [[proxies]]
# name = "ssh"                           # 规则名称
# type = "tcp"                          # 协议类型
# localIP = "127.0.0.1"                 # 本地地址
# localPort = 22                        # 本地端口
# remotePort = 6000                    # 远程端口

# 示例：添加更多映射
# [[proxies]]
# name = "web"
# type = "http"
# localIP = "127.0.0.1"
# localPort = 8080
# customDomains = ["your-domain.com"]

[[proxies]]
name = "rdp"
type = "tcp"
localIP = "127.0.0.1"
localPort = 3389      # Windows远程桌面默认端口
remotePort = 6000      # 远程端口，向管理员获取
"@
        [System.IO.File]::WriteAllText($conf, $tomlContent, [System.Text.UTF8Encoding]::new($false))
    }
    Write-Host "正在用记事本打开 $conf ..."
    Write-Host "修改后请保存并关闭记事本，然后执行 restart 重启服务生效。"
    Start-Process notepad.exe -ArgumentList "`"$conf`"" -Wait
    Write-Host "记事本已关闭。如已修改配置，请执行 restart 重启服务。"
}

function Invoke-ConfigCommand {
    $subCmd = $args[0]
    $key    = $args[1]
    switch ($subCmd) {
        "show" { Show-Config }
        "get"  {
            if (-not $key) { Write-Host "用法: config get <key>"; return }
            Get-ConfigValue $key
        }
        "edit" { Edit-Config }
        default { Write-Host "用法: config <show|get|edit>"; return }
    }
}

# ========== 日志 ==========

function Show-Logs {
    $channel = "frpc"
    $tail    = 30
    $follow  = $false

    if ($args.Count -ge 1) {
        $first = $args[0].ToString().ToLower()
        if ($first -in @("frpc", "out", "err")) {
            $channel = $first
            if ($args.Count -ge 2) { $tail = [int]$args[1] }
            if ($args.Count -ge 3 -and $args[2].ToString().ToLower() -eq "follow") { $follow = $true }
        } else {
            $tail = [int]$first
        }
    }

    $logFile = switch ($channel) {
        "out"  { Join-Path $logs "frpc.out.log" }
        "err"  { Join-Path $logs "frpc.err.log" }
        default { Join-Path $logs "frpc.log" }
    }

    if (-not (Test-Path $logFile)) {
        Write-Host "日志文件不存在: $logFile"
        Write-Host "提示：请先启动 frpc 服务后再查看日志。"
        return
    }

    $content = @(Get-Content -LiteralPath $logFile -Tail $tail -Encoding UTF8)
    if ($content.Count -eq 0) {
        Write-Host "日志文件为空: $logFile"
        Write-Host "提示：frpc 尚未产生日志输出，请稍后再试。"
        return
    }

    Write-Host "===== $logFile (最后 $tail 行) ====="
    $content | ForEach-Object { Write-Host $_ }
    Write-Host "======================================="

    if ($follow) {
        Write-Host "--- 持续跟踪中，按 Ctrl+C 返回菜单 ---"
        try {
            Get-Content -LiteralPath $logFile -Tail 0 -Wait -Encoding UTF8
        } catch {}
    }
}

function Remove-OldLogs {
    param([int]$days = 0)

    if ($days -le 0) { $days = $LogRetentionDays }

    if (-not (Test-Path $logs)) { return }

    $cutoff = (Get-Date).AddDays(-$days)
    $removed = 0

    Get-ChildItem -Path $logs -File |
        Where-Object { $_.LastWriteTime -lt $cutoff } |
        ForEach-Object {
            Remove-Item $_.FullName -Force
            $removed++
            Write-Host "已删除旧日志: $($_.Name)"
        }

    if ($removed -eq 0) {
        Write-Host "没有超过 $days 天的旧日志需要清理。"
    } else {
        Write-Host "已清理 $removed 个旧日志文件。"
    }
}

function Register-CleanLogsTask {
    $taskName = "frpc-manager-cleanlogs"
    $exists   = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue

    if ($exists) {
        Write-Host "清理日志计划任务已存在: $taskName"
        return
    }

    $scriptPath = $MyInvocation.ScriptName
    if (-not $scriptPath) { $scriptPath = Join-Path $dir "frpc-manager.ps1" }

    $action = New-ScheduledTaskAction `
        -Execute "powershell.exe" `
        -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" cleanlogs"

    $trigger = New-ScheduledTaskTrigger -Daily -At "03:00"

    $principal = New-ScheduledTaskPrincipal `
        -UserId "SYSTEM" `
        -LogonType ServiceAccount `
        -RunLevel Highest

    Register-ScheduledTask `
        -TaskName $taskName `
        -Action $action `
        -Trigger $trigger `
        -Principal $principal `
        -Force | Out-Null

    Write-Host "已创建每日清理日志计划任务: $taskName (每天 03:00 执行)"
}

# ========== 帮助与菜单 ==========

function Show-Help {
    Write-Host "用法: .\frpc-manager.ps1 <命令>"
    Write-Host ""
    Write-Host "命令:"
    Write-Host "  install                          安装并启动 frpc 服务"
    Write-Host "  uninstall                        停止并卸载 frpc 服务"
    Write-Host "  status                           查看服务状态"
    Write-Host "  start                            启动服务"
    Write-Host "  stop                             停止服务"
    Write-Host "  restart                          重启服务"
    Write-Host "  update                           检查并更新 frpc (frpc.exe 不存在时下载最新版)"
    Write-Host "  config show                      显示当前配置"
    Write-Host "  config get <key>                 查看配置项"
    Write-Host "  config edit                      用记事本编辑配置"
    Write-Host "  logs [frpc|out|err] [行数] [follow]  显示最后 N 行日志(默认 frpc.log 30 行)，加 follow 持续跟踪"
    Write-Host "  cleanlogs                        手动清理过期日志"
    Write-Host "  menu                             打开交互菜单"
    Write-Host "  help                             显示本帮助"
}

function Show-Menu {
    while ($true) {
        Clear-Host
        Write-Host "========================================"
        Write-Host "       frpc 服务管理菜单"
        Write-Host "========================================"
        Write-Host ""

        $ver = Get-FrpcVersion
        if (-not (Test-Path $frpc)) { $ver = "未找到 frpc.exe" }
        elseif (-not $ver)          { $ver = "未知" }
        $isInstalled = Test-ServiceInstalled

        Write-Host "  版本: $ver"

        if (-not $isInstalled) {
            Write-Host "  状态: 未安装" -ForegroundColor Yellow
            Write-Host ""
            Write-Host "  提示: 服务尚未安装！请先配置，确认无误后再安装服务。" -ForegroundColor Cyan
            Write-Host ""
            Write-Host "  --- 配置文件 ---"
            Write-Host "  1. 编辑配置文件 (记事本)"
            Write-Host "  2. 查看当前配置"
            Write-Host ""
            Write-Host "  --- 服务管理 ---"
            Write-Host "  3. 安装并启动服务"
            Write-Host ""
            Write-Host "  --- 维护 ---"
            Write-Host "  4. 检查更新 / 下载 frpc"
            Write-Host "  0. 退出"
        } else {
            $st = Invoke-Nssm status $svcName
            Write-Host "  状态: $st"
            Write-Host ""

            Write-Host "  --- 服务管理 ---"
            Write-Host "  1. 启动服务"
            Write-Host "  2. 停止服务"
            Write-Host "  3. 重启服务"
            Write-Host "  4. 查看服务状态"
            Write-Host "  5. 卸载 frpc 服务"
            Write-Host ""

            Write-Host "  --- 配置文件 ---"
            Write-Host "  6. 编辑配置文件 (记事本)"
            Write-Host "  7. 查看当前配置"
            Write-Host ""

            Write-Host "  --- 日志查看 ---"
            Write-Host "  8. 查看主日志 (frpc.log)"
            Write-Host "  9. 查看标准输出 (frpc.out.log)"
            Write-Host "  10. 查看错误日志 (frpc.err.log)"
            Write-Host ""

            Write-Host "  --- 维护 ---"
            Write-Host "  11. 检查更新 / 下载 frpc"
            Write-Host "  12. 手动清理过期日志"
            Write-Host "  0. 退出"
        }

        Write-Host ""
        Write-Host "========================================"

        $choice = Read-Host "请选择"
        Write-Host ""

        if (-not $isInstalled) {
            switch ($choice) {
                "1" { Edit-Config }
                "2" { Show-Config }
                "3" { Install-Service }
                "4" { Update-Frpc }
                "0" { return }
                default { Write-Host "无效选项，请重新选择。" }
            }
        } else {
            switch ($choice) {
                "1"  { Start-FrpcService }
                "2"  { Stop-FrpcService }
                "3"  { Restart-FrpcService }
                "4"  { Show-Status }
                "5"  { Uninstall-Service }
                "6"  { Edit-Config }
                "7"  { Show-Config }
                "8"  { Show-Logs "frpc" 30 }
                "9"  { Show-Logs "out" 30 }
                "10" { Show-Logs "err" 30 }
                "11" { Update-Frpc }
                "12" { Remove-OldLogs }
                "0"  { return }
                default { Write-Host "无效选项，请重新选择。" }
            }
        }

        Write-Host ""
        Read-Host "按回车键返回菜单"
    }
}

# ========== 路由命令 ==========
$cmd  = $args[0]
$rest = @()
if ($args.Count -gt 1) { $rest = @($args[1..($args.Count - 1)]) }

switch ($cmd) {
    "install"    { Install-Service }
    "uninstall"  { Uninstall-Service }
    "status"     { Show-Status }
    "start"      { Start-FrpcService }
    "stop"       { Stop-FrpcService }
    "restart"    { Restart-FrpcService }
    "update"     { Update-Frpc }
    "config"     { Invoke-ConfigCommand @rest }
    "logs"       { Show-Logs @rest }
    "cleanlogs"  { Remove-OldLogs }
    "help"       { Show-Help }
    "menu"       { Show-Menu }
    default      { Show-Menu }
}