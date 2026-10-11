# Универсальный клиент для всех вариантов (V1..V6). Windows 10/11, PowerShell 5.1+.
#
#   .\myvpn.ps1 -LinksFile .\links.txt [-SystemProxy]   # перебрать ВСЕ ссылки и оставить первую рабочую
#   .\myvpn.ps1 -Link "vless://..." [-SystemProxy]       # запустить одну ссылку
#   .\myvpn.ps1 -Test                                    # проверить, что сейчас идёт через туннель
#   .\myvpn.ps1 -Stop                                    # выключить всё и снять системный прокси
#
# Ссылки (их печатают серверные скрипты, строка = одна ссылка):
#   vless://...     V1-V4 (запускается Xray)
#   hy2blob://...   V5 Hysteria2 (запускается sing-box)
#   ssh://tun@IP:PORT   V6 SSH (нужен -SshKey, по умолчанию %USERPROFILE%\myvpn_key)
#
# Локальные порты: SOCKS5 127.0.0.1:10808, HTTP 127.0.0.1:10809.
param(
    [string]$Link,
    [string]$LinksFile,
    [string]$SshKey = (Join-Path $HOME 'myvpn_key'),
    [string]$Dir,
    [switch]$SystemProxy,
    [switch]$Test,
    [switch]$Stop,
    [switch]$DryRun            # только построить конфиги (для проверки), ничего не скачивать и не запускать
)
$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

if (-not $Dir) {
    $base = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { Join-Path $HOME '.local/share' }
    $Dir = Join-Path $base 'myvpn'
}
$null = New-Item -ItemType Directory -Force $Dir
$SOCKS = 10808; $HTTP = 10809
$InetKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
$SingVerFallback = '1.14.3'
$IsWin = ($env:OS -eq 'Windows_NT')
$Curl = if ($IsWin) { 'curl.exe' } else { 'curl' }

# ---------------------------------------------------------------- утилиты
function Parse-Query([string]$q) {
    $h = @{}
    foreach ($p in $q.TrimStart('?').Split('&', [StringSplitOptions]::RemoveEmptyEntries)) {
        $kv = $p.Split('=', 2)
        $h[$kv[0]] = if ($kv.Count -gt 1) { [Uri]::UnescapeDataString($kv[1].Replace('+', '%20')) } else { '' }
    }
    $h
}

function Save-Json($obj, [string]$path) {
    $obj | ConvertTo-Json -Depth 20 | Set-Content -Path $path -Encoding UTF8
}

function Set-SystemProxy([bool]$on, [string]$server) {
    if (-not $IsWin) { return }
    Set-ItemProperty $InetKey ProxyEnable ([int]$on)
    if ($on) {
        Set-ItemProperty $InetKey ProxyServer $server
        Set-ItemProperty $InetKey ProxyOverride '<local>;localhost;127.*;10.*;192.168.*'
    }
}

function Stop-All {
    foreach ($n in 'xray', 'sing-box') {
        Get-Process -Name $n -ErrorAction SilentlyContinue |
            Where-Object { $_.Path -and $_.Path.StartsWith($Dir) } | Stop-Process -Force
    }
    $pidFile = Join-Path $Dir 'ssh.pid'
    if (Test-Path $pidFile) {
        Get-Process -Id ([int](Get-Content $pidFile)) -ErrorAction SilentlyContinue | Stop-Process -Force
        Remove-Item $pidFile -Force
    }
    Set-SystemProxy $false ''
}

function Download-Zip([string]$url, [string]$dest) {
    $zip = Join-Path $Dir 'dl.zip'
    Write-Host "  скачиваю $url"
    Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
    if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
    Expand-Archive -Path $zip -DestinationPath $dest -Force
    Remove-Item $zip -Force
}

function Get-Xray {
    $dir = Join-Path $Dir 'xray'
    $exe = Join-Path $dir 'xray.exe'
    if (-not (Test-Path $exe)) {
        Download-Zip 'https://github.com/XTLS/Xray-core/releases/latest/download/Xray-windows-64.zip' $dir
    }
    if (-not (Test-Path $exe)) { throw "Не найден $exe. Скачайте Xray-windows-64.zip вручную и распакуйте в $dir" }
    $exe
}

function Get-SingBox {
    $dir = Join-Path $Dir 'sing-box'
    $found = Get-ChildItem $dir -Recurse -Filter 'sing-box.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $found) {
        $ver = $SingVerFallback
        try {
            $r = Invoke-RestMethod 'https://api.github.com/repos/SagerNet/sing-box/releases/latest' -UseBasicParsing
            $ver = $r.tag_name.TrimStart('v')
        } catch {}
        Download-Zip "https://github.com/SagerNet/sing-box/releases/download/v$ver/sing-box-$ver-windows-amd64.zip" $dir
        $found = Get-ChildItem $dir -Recurse -Filter 'sing-box.exe' | Select-Object -First 1
    }
    if (-not $found) { throw "Не найден sing-box.exe. Скачайте sing-box-*-windows-amd64.zip вручную и распакуйте в $dir" }
    $found.FullName
}

# ---------------------------------------------------------------- V1-V4: vless через Xray
function Build-XrayConfig([string]$link) {
    $u = [Uri]$link
    $q = Parse-Query $u.Query
    $type = if ($q['type']) { $q['type'] } else { 'tcp' }
    $sec  = if ($q['security']) { $q['security'] } else { 'none' }

    $stream = @{ network = $type; security = $sec }
    switch ($type) {
        'tcp'   { }
        'grpc'  { $stream.grpcSettings  = @{ serviceName = $q['serviceName'] } }
        'xhttp' { $stream.xhttpSettings = @{ path = $q['path']; mode = $(if ($q['mode']) { $q['mode'] } else { 'auto' }) } }
        'ws'    {
            $ws = @{ path = $q['path'] }
            if ($q['host']) { $ws.headers = @{ Host = $q['host'] } }
            $stream.wsSettings = $ws
        }
        default { throw "Неизвестный транспорт: $type" }
    }
    if ($sec -eq 'reality') {
        $stream.realitySettings = @{
            serverName = $q['sni']; fingerprint = $(if ($q['fp']) { $q['fp'] } else { 'chrome' })
            publicKey = $q['pbk']; shortId = $q['sid']; spiderX = '/'
        }
    } elseif ($sec -eq 'tls') {
        $tls = @{ serverName = $q['sni']; fingerprint = $(if ($q['fp']) { $q['fp'] } else { 'chrome' }) }
        if ($q['alpn']) { $tls.alpn = @($q['alpn'].Split(',')) }
        $stream.tlsSettings = $tls
    }

    $user = @{ id = $u.UserInfo; encryption = 'none' }
    if ($q['flow']) { $user.flow = $q['flow'] }

    @{
        log = @{ loglevel = 'warning' }
        inbounds = @(
            @{ tag = 'socks'; listen = '127.0.0.1'; port = $SOCKS; protocol = 'socks'; settings = @{ udp = $true }
               sniffing = @{ enabled = $true; destOverride = @('http', 'tls') } },
            @{ tag = 'http'; listen = '127.0.0.1'; port = $HTTP; protocol = 'http' }
        )
        outbounds = @(
            @{ tag = 'proxy'; protocol = 'vless'
               settings = @{ vnext = @(@{ address = $u.Host; port = $u.Port; users = @($user) }) }
               streamSettings = $stream },
            @{ tag = 'direct'; protocol = 'freedom' }
        )
    }
}

function Start-Vless([string]$link) {
    $cfgPath = Join-Path $Dir 'xray-config.json'
    Save-Json (Build-XrayConfig $link) $cfgPath
    if ($DryRun) { Write-Host "  [dry] $cfgPath"; return }
    $exe = Get-Xray
    Start-Process -FilePath $exe -ArgumentList 'run', '-c', "`"$cfgPath`"" -WindowStyle Hidden | Out-Null
}

# ---------------------------------------------------------------- V5: Hysteria2 через sing-box
function Build-SingBoxConfig([string]$b64) {
    $c = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64)) | ConvertFrom-Json
    $inb = @(
        @{ type = 'mixed'; tag = 'in-socks'; listen = '127.0.0.1'; listen_port = $SOCKS },
        @{ type = 'mixed'; tag = 'in-http';  listen = '127.0.0.1'; listen_port = $HTTP }
    )
    @{
        log = @{ level = 'warn' }
        inbounds = $inb
        outbounds = @(
            @{ type = 'hysteria2'; tag = 'proxy'; server = $c.server; server_port = [int]$c.port
               password = $c.password
               obfs = @{ type = 'salamander'; password = $c.obfs }
               tls = @{ enabled = $true; server_name = $c.sni; alpn = @('h3'); certificate = @($c.cert) } },
            @{ type = 'direct'; tag = 'direct' }
        )
        route = @{ final = 'proxy' }
    }
}

function Start-Hy2([string]$b64) {
    $cfgPath = Join-Path $Dir 'singbox-config.json'
    Save-Json (Build-SingBoxConfig $b64) $cfgPath
    if ($DryRun) { Write-Host "  [dry] $cfgPath"; return }
    $exe = Get-SingBox
    Start-Process -FilePath $exe -ArgumentList 'run', '-c', "`"$cfgPath`"" -WindowStyle Hidden | Out-Null
}

# ---------------------------------------------------------------- V6: SSH
function Start-Ssh([string]$link) {
    $u = [Uri]$link
    $port = if ($u.Port -gt 0) { $u.Port } else { 22 }
    $sshArgs = @('-N', '-D', "127.0.0.1:$SOCKS", '-i', "`"$SshKey`"", '-p', $port,
        '-o', 'ServerAliveInterval=30', '-o', 'ExitOnForwardFailure=yes', '-o', 'ConnectTimeout=10',
        '-o', 'StrictHostKeyChecking=accept-new', '-o', "UserKnownHostsFile=`"$(Join-Path $Dir 'known_hosts')`"",
        "$($u.UserInfo)@$($u.Host)")
    if ($DryRun) { Write-Host "  [dry] ssh $($sshArgs -join ' ')"; return }
    if (-not (Test-Path $SshKey)) {
        throw "Нет SSH-ключа $SshKey. Скачайте: scp root@$($u.Host):/etc/myvpn/v6/key `"$SshKey`""
    }
    if ($IsWin) {   # OpenSSH отказывается работать с ключом, доступным другим пользователям
        icacls $SshKey /inheritance:r | Out-Null
        icacls $SshKey /grant:r "$($env:USERNAME):(R)" | Out-Null
    }
    $p = Start-Process -FilePath 'ssh.exe' -ArgumentList $sshArgs -WindowStyle Hidden -PassThru
    $p.Id | Set-Content (Join-Path $Dir 'ssh.pid')
}

# ---------------------------------------------------------------- запуск / проверка
function Start-Variant([string]$link) {
    switch -Regex ($link) {
        '^vless://'     { Start-Vless $link; return 'http' }
        '^hy2blob://'   { Start-Hy2 ($link -replace '^hy2blob://', '' -replace '#.*$', ''); return 'http' }
        '^ssh://'       { Start-Ssh $link; return 'socks' }
        default         { throw "Неизвестный тип ссылки: $link" }
    }
}

function Wait-Port([int]$port, [int]$seconds = 6) {
    $end = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $end) {
        try { $c = New-Object Net.Sockets.TcpClient; $c.Connect('127.0.0.1', $port); $c.Close(); return $true }
        catch { Start-Sleep -Milliseconds 300 }
    }
    $false
}

function Test-Tunnel([int]$timeout = 12) {
    # возвращает внешний IP, увиденный через туннель, или $null
    if (-not (Wait-Port $SOCKS)) { return $null }
    foreach ($url in 'https://api.ipify.org', 'https://ifconfig.me/ip', 'https://icanhazip.com') {
        $ip = & $Curl -s -m $timeout -x "socks5h://127.0.0.1:$SOCKS" $url 2>$null
        if ($LASTEXITCODE -eq 0 -and $ip -match '^\d{1,3}(\.\d{1,3}){3}$') { return $ip.Trim() }
    }
    $null
}

function Get-DirectIp {
    $ip = & $Curl -s -m 8 https://api.ipify.org 2>$null
    if ($ip -match '^\d{1,3}(\.\d{1,3}){3}$') { $ip.Trim() } else { $null }
}

function Label([string]$link) { if ($link -match '#(.+)$') { $Matches[1] } else { $link.Substring(0, [Math]::Min(30, $link.Length)) } }

# ================================================================ main
if ($Stop) { Stop-All; Write-Host 'Остановлено, системный прокси снят.'; return }

if ($Test) {
    $ip = Test-Tunnel
    if ($ip) { Write-Host "OK: через туннель виден IP $ip (без туннеля: $(Get-DirectIp))" } else { Write-Host 'Туннель не работает.' }
    return
}

if ($LinksFile) {
    $links = Get-Content $LinksFile | Where-Object { $_.Trim() -and -not $_.StartsWith('#') } | ForEach-Object { $_.Trim() }
    if (-not $links) { throw "В $LinksFile нет ссылок." }
    if ($DryRun) { foreach ($l in $links) { Write-Host "== $(Label $l)"; $null = Start-Variant $l }; return }
    $direct = Get-DirectIp
    $report = @(); $winner = $null; $winnerMode = $null
    foreach ($l in $links) {
        $name = Label $l
        Write-Host "== пробую $name"
        Stop-All
        try {
            $mode = Start-Variant $l
            $ip = Test-Tunnel
            $ok = ($ip -and $ip -ne $direct)
        } catch { Write-Host "  ошибка: $($_.Exception.Message)"; $ok = $false; $ip = $null }
        Write-Host $(if ($ok) { "  РАБОТАЕТ (внешний IP $ip)" } else { '  не работает' })
        $report += [pscustomobject]@{ Вариант = $name; Результат = $(if ($ok) { 'OK' } else { 'нет' }); IP = $ip }
        if ($ok -and -not $winner) { $winner = $l; $winnerMode = $mode }
    }
    Stop-All
    Write-Host; $report | Format-Table -AutoSize
    if ($winner) {
        Write-Host "Оставляю первый рабочий: $(Label $winner)"
        $mode = Start-Variant $winner
        if ($SystemProxy) { Set-SystemProxy $true $(if ($mode -eq 'socks') { "socks=127.0.0.1:$SOCKS" } else { "127.0.0.1:$HTTP" }) }
        Write-Host "SOCKS5 127.0.0.1:$SOCKS  HTTP 127.0.0.1:$HTTP. Выключить: .\myvpn.ps1 -Stop"
    } else {
        Write-Host 'Ни один вариант не прошёл. См. README: раздел «Если не работает ничего».'
    }
    return
}

if (-not $Link) { throw 'Укажите -Link "..." или -LinksFile .\links.txt (см. шапку файла).' }
Stop-All
$mode = Start-Variant $Link
if ($DryRun) { return }
$ip = Test-Tunnel
if ($ip) { Write-Host "Работает, внешний IP: $ip" } else { Write-Host 'Запущено, но проверка не прошла (вариант заблокирован или неверная ссылка).' }
if ($SystemProxy) { Set-SystemProxy $true $(if ($mode -eq 'socks') { "socks=127.0.0.1:$SOCKS" } else { "127.0.0.1:$HTTP" }) }
Write-Host "SOCKS5 127.0.0.1:$SOCKS  HTTP 127.0.0.1:$HTTP. Выключить: .\myvpn.ps1 -Stop"
