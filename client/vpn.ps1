# Windows-клиент: скачивает Xray-core, строит конфиг из vless:// ссылки и запускает.
# Использование (PowerShell):
#   .\vpn.ps1 -Link "vless://..." [-SystemProxy]
#   .\vpn.ps1 -Stop
param(
    [string]$Link,
    [switch]$SystemProxy,   # включить системный прокси Windows (HTTP 127.0.0.1:10809)
    [switch]$Stop
)
$ErrorActionPreference = 'Stop'
$dir = Join-Path $env:LOCALAPPDATA 'myvpn'
$null = New-Item -ItemType Directory -Force $dir
$exe = Join-Path $dir 'xray.exe'
$reg = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'

function Set-Proxy($on) {
    Set-ItemProperty $reg ProxyEnable ([int]$on)
    if ($on) { Set-ItemProperty $reg ProxyServer '127.0.0.1:10809' }
}

if ($Stop) {
    Get-Process xray -ErrorAction SilentlyContinue | Stop-Process -Force
    Set-Proxy $false
    Write-Host 'Остановлено.'; return
}
if (-not $Link) { throw 'Укажите -Link "vless://..."' }

if (-not (Test-Path $exe)) {
    Write-Host 'Скачиваю Xray-core...'
    $zip = Join-Path $dir 'xray.zip'
    Invoke-WebRequest 'https://github.com/XTLS/Xray-core/releases/latest/download/Xray-windows-64.zip' -OutFile $zip
    Expand-Archive $zip -DestinationPath $dir -Force
    Remove-Item $zip
}

$u = [Uri]$Link
if ($u.Scheme -ne 'vless') { throw 'Нужна ссылка vless://' }
$q = [System.Web.HttpUtility]::ParseQueryString($u.Query)
Add-Type -AssemblyName System.Web
$q = [System.Web.HttpUtility]::ParseQueryString($u.Query)

$cfg = @{
    log = @{ loglevel = 'warning' }
    inbounds = @(
        @{ tag='socks'; port=10808; listen='127.0.0.1'; protocol='socks'; settings=@{ udp=$true }
           sniffing=@{ enabled=$true; destOverride=@('http','tls') } },
        @{ tag='http'; port=10809; listen='127.0.0.1'; protocol='http' }
    )
    outbounds = @(
        @{ tag='proxy'; protocol='vless'
           settings=@{ vnext=@(@{ address=$u.Host; port=$u.Port
                users=@(@{ id=$u.UserInfo; encryption='none'; flow=$q['flow'] }) }) }
           streamSettings=@{ network='tcp'; security='reality'
                realitySettings=@{ serverName=$q['sni']; fingerprint=$q['fp']
                    publicKey=$q['pbk']; shortId=$q['sid']; spiderX='/' } } },
        @{ tag='direct'; protocol='freedom' }
    )
    routing = @{ rules = @(
        @{ type='field'; ip=@('geoip:private'); outboundTag='direct' }
    ) }
}
$cfgPath = Join-Path $dir 'config.json'
$cfg | ConvertTo-Json -Depth 12 | Set-Content $cfgPath -Encoding UTF8

Get-Process xray -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Process $exe -ArgumentList 'run','-c',$cfgPath -WindowStyle Hidden
if ($SystemProxy) { Set-Proxy $true }
Write-Host 'Запущено. SOCKS5 127.0.0.1:10808, HTTP 127.0.0.1:10809'
if ($SystemProxy) { Write-Host 'Системный прокси Windows включён.' }
Write-Host 'Остановить: .\vpn.ps1 -Stop'
