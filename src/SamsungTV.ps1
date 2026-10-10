<#
.SYNOPSIS
    Turns a Samsung Tizen TV on or off over the network.

.DESCRIPTION
    On       Wake-on-LAN, repeated until the TV reports it is on (up to -Timeout seconds).
    Off      Sends KEY_POWER through the TV remote-control API, only if the TV is on.
    Status   Shows IP, power state and pairing.
    Pair     Connects once so the TV shows the "Allow" prompt and returns a token.
    Discover Lists Samsung TVs on the local network (no config needed).

    Settings are read from config.json next to this script (written by the installer).

.PARAMETER OnShutdown
    Used by the Windows shutdown script. With keepOnRestart=true in config.json the TV is
    left on when Windows is restarting instead of shutting down.

.EXAMPLE
    .\SamsungTV.ps1 Off
.EXAMPLE
    .\SamsungTV.ps1 Discover
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('On', 'Off', 'Status', 'Pair', 'Discover')]
    [string]$Action = 'Status',
    [switch]$OnShutdown,
    [string]$ConfigPath,   # default: config.json next to this script
    [int]$Timeout = 60
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $ConfigPath) { $ConfigPath = Join-Path $here 'config.json' }
. (Join-Path $here 'SamsungTV.Core.ps1')
$script:TvLogTag = $Action
if ($Action -ne 'Discover') { $script:TvLogPath = Join-Path (Split-Path -Parent $ConfigPath) 'SamsungTV.log' }

try {
    switch ($Action) {
        'Discover' {
            $tvs = @(Find-TvDevices)
            if (-not $tvs) { Write-Host 'No Samsung Tizen TV found (it must be on and on the same network).' }
            $tvs | Format-Table Name, Model, Ip, Mac, Network, PowerState -AutoSize
        }
        'Status' {
            $cfg = Get-TvConfig $ConfigPath
            $ip = Resolve-TvAddress $cfg
            $state = if ($ip) { Get-TvPowerState $ip } else { 'unreachable (off)' }
            Write-TvLog ('ip={0} mac={1} state={2} paired={3} keepOnRestart={4} wakeOnInput={5}' -f $cfg.ip, $cfg.mac, $state, [bool]$cfg.token, $cfg.keepOnRestart, $cfg.wakeOnInput)
        }
        'Pair' {
            $cfg = Get-TvConfig $ConfigPath
            Write-TvLog 'connecting - accept the prompt on the TV...'
            Invoke-TvPair $cfg 90
            Write-TvLog 'paired'
        }
        'Off' {
            $cfg = Get-TvConfig $ConfigPath
            if ($OnShutdown -and $cfg.keepOnRestart -and (Test-RestartInProgress)) {
                Write-TvLog 'Windows is restarting - TV stays on'
                break
            }
            [void](Invoke-TvOff $cfg)
        }
        'On' {
            $cfg = Get-TvConfig $ConfigPath
            if (-not (Invoke-TvOn $cfg $Timeout)) { exit 2 }
        }
    }
} catch {
    Write-TvLog "ERROR: $($_.Exception.Message)"
    exit 1
}
