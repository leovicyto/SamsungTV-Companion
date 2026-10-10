<#
  SamsungTV.Core.ps1 - functions shared by the CLI, the installer and the uninstaller.
  Dot-source it:  . "$PSScriptRoot\SamsungTV.Core.ps1"

  Protocol notes
  - Info / power state : GET http://<tv>:8001/api/v2/  ->  device.PowerState = on | standby
  - Remote keys        : WebSocket wss://<tv>:8002/api/v2/channels/samsung.remote.control
                         (first connection shows an "Allow" prompt on the TV and returns a token)
  - Power on           : Wake-on-LAN. In standby the TV keeps the network up ("Power On with
                         Mobile") but ignores WebSocket commands, so only the magic packet works.
#>

$script:TvLogPath = $null
$script:TvLogTag = ''

function Write-TvLog([string]$Message) {
    $line = '{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}' -f (Get-Date), $script:TvLogTag, $Message
    Write-Host $line
    if (-not $script:TvLogPath) { return }
    try {
        Add-Content -LiteralPath $script:TvLogPath -Value $line
        $all = @(Get-Content -LiteralPath $script:TvLogPath)
        if ($all.Count -gt 500) { $all | Select-Object -Last 300 | Set-Content -LiteralPath $script:TvLogPath }
    } catch {}
}

# ---------------------------------------------------------------------------- config

function Get-TvConfig([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { throw "Config not found: $Path (run the installer first)" }
    $c = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    foreach ($k in 'name', 'ip', 'mac', 'token') {
        if (-not ($c.PSObject.Properties.Name -contains $k)) { $c | Add-Member -NotePropertyName $k -NotePropertyValue '' }
    }
    $defaults = @{ keepOnRestart = $true; wakeOnInput = $false; wakeOnInputGraceSeconds = 15; keepOffAfterRemote = $false }
    foreach ($k in $defaults.Keys) {
        if (-not ($c.PSObject.Properties.Name -contains $k)) { $c | Add-Member -NotePropertyName $k -NotePropertyValue $defaults[$k] }
    }
    $c | Add-Member -NotePropertyName _path -NotePropertyValue $Path -Force
    $c
}

function Save-TvConfig($Config) {
    $out = [ordered]@{
        name          = $Config.name
        ip            = $Config.ip
        mac           = $Config.mac
        token         = $Config.token
        keepOnRestart = [bool]$Config.keepOnRestart
        wakeOnInput   = [bool]$Config.wakeOnInput
        wakeOnInputGraceSeconds = [int]$Config.wakeOnInputGraceSeconds
        keepOffAfterRemote = [bool]$Config.keepOffAfterRemote
    }
    $out | ConvertTo-Json | Set-Content -LiteralPath $Config._path -Encoding ASCII
}

# ---------------------------------------------------------------------------- discovery / state

function Get-TvInfo([string]$Ip, [int]$TimeoutSec = 2) {
    if (-not $Ip) { return $null }
    try { (Invoke-RestMethod "http://${Ip}:8001/api/v2/" -TimeoutSec $TimeoutSec -UseBasicParsing).device } catch { $null }
}

function Get-TvPowerState([string]$Ip) {
    # 'on', 'standby' or $null (unreachable). Models without PowerState report 'on' while reachable.
    $d = Get-TvInfo $Ip
    if (-not $d) { return $null }
    if ($d.PSObject.Properties.Name -contains 'PowerState' -and $d.PowerState) { return [string]$d.PowerState }
    'on'
}

function Get-MacFromArp([string]$Ip) {
    $n = Get-NetNeighbor -IPAddress $Ip -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($n -and $n.LinkLayerAddress -and $n.LinkLayerAddress -ne '00-00-00-00-00-00') {
        return ($n.LinkLayerAddress -replace '-', ':').ToUpper()
    }
    $null
}

function Get-LocalSubnets {
    # /24 around every active IPv4 address that has a default gateway
    Get-NetIPConfiguration -ErrorAction SilentlyContinue |
        Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' } |
        ForEach-Object { $_.IPv4Address } |
        ForEach-Object { (($_.IPAddress -split '\.')[0..2]) -join '.' } |
        Select-Object -Unique
}

function Find-TvDevices([string[]]$Subnets = (Get-LocalSubnets)) {
    $probes = foreach ($net in $Subnets) {
        foreach ($i in 1..254) {
            $c = New-Object Net.Sockets.TcpClient
            [pscustomobject]@{ Ip = "$net.$i"; Client = $c; Task = $c.ConnectAsync("$net.$i", 8001) }
        }
    }
    try { [void][Threading.Tasks.Task]::WaitAll(@($probes.Task), 2500) } catch {}
    $open = @($probes | Where-Object { $_.Task.Status -eq 'RanToCompletion' -and $_.Client.Connected } | ForEach-Object { $_.Ip })
    $probes | ForEach-Object { $_.Client.Close() }

    foreach ($ip in $open) {
        $d = Get-TvInfo $ip
        if (-not $d -or [string]$d.OS -ne 'Tizen') { continue }
        $mac = Get-MacFromArp $ip
        if (-not $mac -and $d.PSObject.Properties.Name -contains 'wifiMac') { $mac = ([string]$d.wifiMac).ToUpper() }
        [pscustomobject]@{
            Name       = [string]$d.name
            Model      = [string]$d.modelName
            Ip         = $ip
            Mac        = $mac
            Network    = [string]$d.networkType
            PowerState = $(if ($d.PSObject.Properties.Name -contains 'PowerState') { [string]$d.PowerState } else { 'on' })
            TokenAuth  = [string]$d.TokenAuthSupport
        }
    }
}

function Resolve-TvAddress($Config) {
    # Returns the TV IP if it answers, following it by MAC if the router gave it a new address.
    if (Get-TvInfo $Config.ip) { return $Config.ip }
    foreach ($tv in @(Find-TvDevices)) {
        if ($tv.Mac -and $tv.Mac -eq ([string]$Config.mac).ToUpper()) {
            if ($tv.Ip -ne $Config.ip) {
                Write-TvLog "TV moved from $($Config.ip) to $($tv.Ip)"
                $Config.ip = $tv.Ip
                try { Save-TvConfig $Config } catch { Write-TvLog "could not save new IP: $($_.Exception.Message)" }
            }
            return $tv.Ip
        }
    }
    $null
}

# ---------------------------------------------------------------------------- Wake-on-LAN

function Send-WakeOnLan([string]$Mac, [string]$Ip) {
    $bytes = [byte[]]($Mac -split '[:-]' | ForEach-Object { [Convert]::ToByte($_, 16) })
    if ($bytes.Count -ne 6) { throw "Invalid MAC address: $Mac" }
    $packet = [byte[]](@(0xFF) * 6 + ($bytes * 16))
    $targets = @('255.255.255.255')
    if ($Ip) { $targets += ((($Ip -split '\.')[0..2]) -join '.') + '.255'; $targets += $Ip }
    $udp = New-Object Net.Sockets.UdpClient
    $udp.EnableBroadcast = $true
    try {
        foreach ($t in $targets) {
            foreach ($port in 9, 7) { try { [void]$udp.Send($packet, $packet.Length, $t, $port) } catch {} }
        }
    } finally { $udp.Close() }
}

# ---------------------------------------------------------------------------- WebSocket (hand-rolled)
# .NET Framework's ClientWebSocket loses the first frame when the TV sends it in the same
# TCP segment as the HTTP 101 response, so the connection looked "silent" forever.
# A minimal RFC 6455 client over SslStream avoids that.

if (-not ('SamsungTvTls' -as [type])) {
    Add-Type @'
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;
public static class SamsungTvTls {
    // The TV uses a self-signed certificate on port 8002.
    static bool Accept(object s, X509Certificate c, X509Chain ch, SslPolicyErrors e) { return true; }
    public static readonly RemoteCertificateValidationCallback Callback = Accept;
}
'@
}

function Read-Exact($Stream, [int]$Count) {
    $buf = New-Object byte[] $Count
    $read = 0
    while ($read -lt $Count) {
        $n = $Stream.Read($buf, $read, $Count - $read)
        if ($n -le 0) { throw 'connection closed by the TV' }
        $read += $n
    }
    , $buf
}

function Read-WsFrame($Stream) {
    $h = Read-Exact $Stream 2
    $op = $h[0] -band 0x0F
    $len = [int64]($h[1] -band 0x7F)
    if ($len -eq 126) { $e = Read-Exact $Stream 2; $len = ([int64]$e[0] -shl 8) -bor $e[1] }
    elseif ($len -eq 127) { $e = Read-Exact $Stream 8; $len = [int64]0; foreach ($x in $e) { $len = ($len -shl 8) -bor $x } }
    [byte[]]$data = if ($len -gt 0) { Read-Exact $Stream ([int]$len) } else { @() }
    [pscustomobject]@{ Opcode = $op; Text = [Text.Encoding]::UTF8.GetString($data) }
}

function Send-WsFrame($Stream, [byte[]]$Data, [int]$Opcode = 1) {
    $f = New-Object Collections.Generic.List[byte]
    $f.Add([byte](0x80 -bor $Opcode))
    if ($Data.Length -lt 126) { $f.Add([byte](0x80 -bor $Data.Length)) }
    else { $f.Add([byte](0x80 -bor 126)); $f.Add([byte]($Data.Length -shr 8)); $f.Add([byte]($Data.Length -band 0xFF)) }
    $mask = [byte[]](1..4 | ForEach-Object { Get-Random -Maximum 256 })
    $f.AddRange($mask)
    for ($i = 0; $i -lt $Data.Length; $i++) { $f.Add([byte]($Data[$i] -bxor $mask[$i % 4])) }
    $a = $f.ToArray()
    $Stream.Write($a, 0, $a.Length)
    $Stream.Flush()
}

function Connect-TvRemote($Config, [string]$Ip, [int]$TimeoutSec = 8) {
    $tcp = New-Object Net.Sockets.TcpClient
    if (-not $tcp.ConnectAsync($Ip, 8002).Wait(4000)) { $tcp.Close(); throw 'TV did not answer on port 8002' }
    try {
        $tcp.ReceiveTimeout = 5000
        $ssl = New-Object Net.Security.SslStream($tcp.GetStream(), $false, [SamsungTvTls]::Callback)
        $ssl.AuthenticateAsClient($Ip, $null, [Security.Authentication.SslProtocols]::Tls12, $false)

        $name = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Config.name))
        $path = "/api/v2/channels/samsung.remote.control?name=$name"
        if ($Config.token) { $path += "&token=$($Config.token)" }
        $key = [Convert]::ToBase64String([byte[]](1..16 | ForEach-Object { Get-Random -Maximum 256 }))
        $req = "GET $path HTTP/1.1`r`nHost: ${Ip}:8002`r`nUpgrade: websocket`r`nConnection: Upgrade`r`n" +
               "Sec-WebSocket-Key: $key`r`nSec-WebSocket-Version: 13`r`n`r`n"
        $b = [Text.Encoding]::ASCII.GetBytes($req)
        $ssl.Write($b, 0, $b.Length); $ssl.Flush()

        # HTTP headers byte by byte, so the first WebSocket frame is not swallowed
        $hdr = New-Object Text.StringBuilder
        while (-not $hdr.ToString().EndsWith("`r`n`r`n")) { [void]$hdr.Append([char](Read-Exact $ssl 1)[0]) }
        if ($hdr.ToString() -notmatch '^HTTP/1\.1 101') { throw "handshake refused: $(($hdr.ToString() -split "`r`n")[0])" }

        $tcp.ReceiveTimeout = $TimeoutSec * 1000
        while ($true) {
            try { $fr = Read-WsFrame $ssl } catch { throw 'no answer from the TV (was the "Allow" prompt accepted?)' }
            if ($fr.Opcode -eq 8) { throw 'TV closed the connection' }
            if ($fr.Opcode -ne 1) { continue }
            $msg = $fr.Text | ConvertFrom-Json
            if ($msg.event -eq 'ms.channel.connect') { break }
            if ($msg.event -eq 'ms.channel.unauthorized') { throw 'TV refused the connection (PC denied in the TV device list?)' }
        }
        if ($msg.PSObject.Properties.Name -contains 'data' -and $msg.data -and
            $msg.data.PSObject.Properties.Name -contains 'token' -and $msg.data.token -and
            [string]$msg.data.token -ne $Config.token) {
            $Config.token = [string]$msg.data.token
            Save-TvConfig $Config
            Write-TvLog 'pairing token saved'
        }
        [pscustomobject]@{ Tcp = $tcp; Stream = $ssl }
    } catch {
        $tcp.Close()
        throw
    }
}

function Disconnect-TvRemote($Connection) {
    try { Send-WsFrame $Connection.Stream ([byte[]](0x03, 0xE8)) 8 } catch {}
    $Connection.Tcp.Close()
}

function Send-TvKey($Config, [string]$Ip, [string]$Key) {
    $cx = Connect-TvRemote $Config $Ip 8
    try {
        $cmd = @{ method = 'ms.remote.control'; params = @{ Cmd = 'Click'; DataOfCmd = $Key; Option = 'false'; TypeOfRemote = 'SendRemoteKey' } } |
               ConvertTo-Json -Compress
        # A key sent right after "connect" is sometimes ignored; give the TV a moment,
        # and keep the connection open a little after sending.
        Start-Sleep -Milliseconds 1000
        Send-WsFrame $cx.Stream ([Text.Encoding]::UTF8.GetBytes($cmd))
        Start-Sleep -Milliseconds 1500
    } finally { Disconnect-TvRemote $cx }
}

# ---------------------------------------------------------------------------- high level

function Invoke-TvPair($Config, [int]$TimeoutSec = 90) {
    $ip = Resolve-TvAddress $Config
    if (-not $ip) { throw 'TV not found on the network - it must be ON to pair' }
    Disconnect-TvRemote (Connect-TvRemote $Config $ip $TimeoutSec)
}

function Invoke-TvOff($Config) {
    $ip = Resolve-TvAddress $Config
    if ((Get-TvPowerState $ip) -ne 'on') { Write-TvLog 'TV already off'; return $true }
    # Over Wi-Fi a key press is occasionally lost, so confirm and retry once. Wait long enough
    # first: KEY_POWER toggles, and a second press on a TV that is already going off turns it on.
    for ($try = 1; $try -le 2; $try++) {
        Send-TvKey $Config $ip 'KEY_POWER'
        for ($s = 0; $s -lt 6; $s++) {
            Start-Sleep -Seconds 1
            if ((Get-TvPowerState $ip) -ne 'on') { Write-TvLog 'TV off'; return $true }
        }
        if ($try -eq 1) { Write-TvLog 'TV still on after 6 s, sending power-off again' }
    }
    Write-TvLog 'TV did not turn off'
    $false
}

function Set-WakeMarker($Config) {
    # Tells the watcher "this wake-up was on purpose", so it does not take it for the TV turning
    # itself back on (keep-off mode). The watcher reads the file's timestamp.
    try { Set-Content -LiteralPath (Join-Path (Split-Path -Parent $Config._path) 'last-wake.txt') -Value (Get-Date -Format o) } catch {}
}

function Invoke-TvOn($Config, [int]$TimeoutSec = 60) {
    if ((Get-TvPowerState $Config.ip) -eq 'on') { Write-TvLog 'TV already on'; return $true }
    Set-WakeMarker $Config
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $i = 0
    while ((Get-Date) -lt $deadline) {
        Send-WakeOnLan $Config.mac $Config.ip
        Start-Sleep -Seconds 2
        $state = Get-TvPowerState $Config.ip
        if (-not $state -and (++$i % 5) -eq 0) { [void](Resolve-TvAddress $Config); $state = Get-TvPowerState $Config.ip }
        if ($state -eq 'on') { Write-TvLog 'TV on'; return $true }
    }
    Write-TvLog "TV did not turn on within $TimeoutSec s"
    $false
}

function Test-RestartInProgress {
    # Windows logs event 1074 (User32) with the shutdown type before running shutdown scripts.
    # The type text is localized, so match the common languages; unknown means "shutdown".
    $ev = Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 1074; StartTime = (Get-Date).AddMinutes(-10) } -MaxEvents 1 -ErrorAction SilentlyContinue
    if (-not $ev) { return $false }
    $type = [string]$ev.Properties[4].Value
    $restart = 'restart|reinic|neustart|red\u00e9marr|redemarr|riavvi|herstart|ponownie|\u043f\u0435\u0440\u0435\u0437\u0430\u0433\u0440\u0443\u0437|\u518d\u8d77\u52d5|\u91cd\u65b0\u542f\u52a8|\u91cd\u65b0\u555f\u52d5|\ub2e4\uc2dc \uc2dc\uc791'
    $type -match $restart
}
