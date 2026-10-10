<#
.SYNOPSIS
    SamsungTV-Companion installer: finds the TV, pairs, tests power on/off and installs the hooks.

.PARAMETER TvAddress
    IP of the TV (skips network discovery).
.PARAMETER OnRestart
    Keep (default) leaves the TV on when Windows restarts; TurnOff turns it off on restarts too.
.PARAMETER SkipPowerTest
    Do not turn the TV off/on during installation.
#>
[CmdletBinding()]
param(
    [string]$TvAddress,
    [ValidateSet('Keep', 'TurnOff', '')][string]$OnRestart = '',
    [switch]$SkipPowerTest
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'SamsungTV.Core.ps1')
. (Join-Path $PSScriptRoot 'SamsungTV.Setup.ps1')

$pt = (Get-UICulture).Name -like 'pt*'
function T([string]$En, [string]$Pt) { if ($script:pt) { $Pt } else { $En } }
function Step([string]$Text) { Write-Host "`n>> $Text" -ForegroundColor Cyan }
function Ok([string]$Text) { Write-Host "   OK  $Text" -ForegroundColor Green }
function Warn([string]$Text) { Write-Host "   !!  $Text" -ForegroundColor Yellow }
function Ask([string]$Text, [bool]$Default = $true) {
    $hint = if ($Default) { T '[Y/n]' '[S/n]' } else { T '[y/N]' '[s/N]' }
    $a = Read-Host "   $Text $hint"
    if (-not $a) { return $Default }
    $a -match '^(y|s)'
}
function Fail([string]$Text) { Write-Host "`n   $Text" -ForegroundColor Red; exit 1 }

Write-Host ''
Write-Host '  SamsungTV-Companion' -ForegroundColor White
Write-Host (T '  Your Samsung TV turns on and off together with your PC.' '  Sua TV Samsung liga e desliga junto com o PC.')

if (-not (Test-IsAdmin)) { Fail (T 'Run as administrator (use Install.cmd).' 'Execute como administrador (use o Install.cmd).') }
if ((Get-CimInstance Win32_ComputerSystem).PartOfDomain) {
    Warn (T 'This PC is in a domain: domain policies may override the local shutdown script.' 'Este PC esta em um dominio: politicas do dominio podem sobrepor o script de desligamento local.')
}

# --------------------------------------------------------------------------- 1. TV settings
Step (T 'Before you start, on the TV:' 'Antes de comecar, na TV:')
Write-Host (T @'
   - Settings > General > Network > Expert Settings > Power On with Mobile = On
   - Settings > General > Network > Expert Settings > IP Remote = On (if present)
   - Settings > General > External Device Manager > Device Connection Manager
       > Access Notification = First Time Only
   - The TV must be ON and on the same network as this PC (cable is more reliable than Wi-Fi).
'@ @'
   - Configuracoes > Geral > Rede > Configuracoes especialistas > Ligar com dispositivo movel = Ativado
   - Configuracoes > Geral > Rede > Configuracoes especialistas > IP Remote = Ativado (se existir)
   - Configuracoes > Geral > Gerenciador de dispositivos externos > Gerenciador de conexao de dispositivos
       > Notificacao de acesso = Somente na primeira vez
   - A TV precisa estar LIGADA e na mesma rede do PC (cabo e mais confiavel que Wi-Fi).
'@)
[void](Read-Host (T '   Press Enter when ready' '   Aperte Enter quando estiver pronto'))

# --------------------------------------------------------------------------- 2. find the TV
Step (T 'Looking for Samsung TVs on the network...' 'Procurando TVs Samsung na rede...')
if ($TvAddress) {
    $tvs = @(Find-TvDevices -Subnets ((($TvAddress -split '\.')[0..2]) -join '.') | Where-Object { $_.Ip -eq $TvAddress })
} else {
    $tvs = @(Find-TvDevices)
}
if (-not $tvs) { Fail (T 'No TV found. Check that it is on, on the same network, and try -TvAddress <ip>.' 'Nenhuma TV encontrada. Confira se ela esta ligada e na mesma rede, ou use -TvAddress <ip>.') }
for ($i = 0; $i -lt $tvs.Count; $i++) {
    Write-Host ('   [{0}] {1}  {2}  {3}  {4}  ({5})' -f ($i + 1), $tvs[$i].Name, $tvs[$i].Model, $tvs[$i].Ip, $tvs[$i].Mac, $tvs[$i].Network)
}
$tv = $tvs[0]
if ($tvs.Count -gt 1) {
    $n = Read-Host (T '   Which one? (number)' '   Qual delas? (numero)')
    $tv = $tvs[[int]$n - 1]
}
if (-not $tv.Mac) { Fail (T 'Could not read the TV MAC address (needed for Wake-on-LAN).' 'Nao consegui ler o endereco MAC da TV (necessario para o Wake-on-LAN).') }
if ($tv.Network -eq 'wireless') { Warn (T 'TV is on Wi-Fi: power on works, but a network cable is more reliable.' 'A TV esta no Wi-Fi: ligar funciona, mas cabo de rede e mais confiavel.') }
Ok "$($tv.Name) - $($tv.Ip)"

# --------------------------------------------------------------------------- 3. files + config
New-Item -ItemType Directory -Path $script:InstallDir -Force | Out-Null
foreach ($f in 'SamsungTV.ps1', 'SamsungTV.Core.ps1', 'SamsungTV.Setup.ps1', 'Uninstall.ps1') {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $f) -Destination $script:InstallDir -Force
}
$cfgPath = Join-Path $script:InstallDir 'config.json'
$old = if (Test-Path -LiteralPath $cfgPath) { Get-TvConfig $cfgPath } else { $null }
$cfg = [pscustomobject]@{
    name          = "SamsungTV-Companion ($env:COMPUTERNAME)"
    ip            = $tv.Ip
    mac           = $tv.Mac
    token         = $(if ($old -and $old.mac -eq $tv.Mac) { $old.token } else { '' })
    keepOnRestart = $true
    _path         = $cfgPath
}
Save-TvConfig $cfg
Protect-InstallDir
$script:TvLogPath = Join-Path $script:InstallDir 'SamsungTV.log'
$script:TvLogTag = 'Install'

# --------------------------------------------------------------------------- 4. pair
Step (T 'Pairing: accept the prompt on the TV ("Allow")...' 'Pareando: aceite o aviso na TV ("Permitir")...')
try { Invoke-TvPair $cfg 90; Ok (T 'paired' 'pareado') }
catch {
    $hint = T 'If the PC is listed as denied in the TV Device Connection Manager, allow or delete it and run again.' 'Se o PC aparecer como negado no Gerenciador de conexao de dispositivos da TV, permita ou apague e rode de novo.'
    Fail ((T 'Pairing failed: ' 'O pareamento falhou: ') + $_.Exception.Message + "`n   " + $hint)
}

# --------------------------------------------------------------------------- 5. power test
if (-not $SkipPowerTest -and (Ask (T 'Test now? The TV will turn OFF and back ON by itself (~1 min, do not use the remote).' 'Testar agora? A TV vai DESLIGAR e LIGAR sozinha (~1 min, nao use o controle).'))) {
    [void](Invoke-TvOff $cfg)
    $t0 = Get-Date
    while (((Get-Date) - $t0).TotalSeconds -lt 30 -and (Get-TvPowerState $cfg.ip) -eq 'on') { Start-Sleep 2 }
    Start-Sleep -Seconds 15      # let the TV settle into network standby
    $t1 = Get-Date
    if (Invoke-TvOn $cfg 90) { Ok ((T 'TV turned on by itself in {0:N0} s' 'A TV ligou sozinha em {0:N0} s') -f ((Get-Date) - $t1).TotalSeconds) }
    else {
        Warn (T 'The TV did not turn on. Check "Power On with Mobile" on the TV; on Wi-Fi it may also need the router to forward broadcasts.' 'A TV nao ligou. Confira "Ligar com dispositivo movel" na TV; no Wi-Fi o roteador tambem precisa repassar broadcast.')
        if (-not (Ask (T 'Install anyway?' 'Instalar mesmo assim?') $false)) { Fail (T 'Cancelled. Turn the TV on with the remote.' 'Cancelado. Ligue a TV pelo controle.') }
    }
}

# --------------------------------------------------------------------------- 6. restart behaviour
if (-not $OnRestart) {
    $keep = Ask (T 'Keep the TV ON when Windows RESTARTS (only turn off on shutdown)?' 'Manter a TV LIGADA quando o Windows REINICIAR (so desligar no desligamento)?')
} else { $keep = $OnRestart -eq 'Keep' }
$cfg.keepOnRestart = $keep
Save-TvConfig $cfg

# --------------------------------------------------------------------------- 7. hooks
Step (T 'Installing...' 'Instalando...')
Set-ShutdownHook
if (Test-ShutdownHook) { Ok (T 'shutdown script registered (turns the TV off)' 'script de desligamento registrado (desliga a TV)') }
else { Warn (T 'shutdown script not visible in the registry yet - it may apply after a reboot' 'script de desligamento ainda nao aparece no registro - pode valer depois de reiniciar') }
Register-PowerOnTask
Ok ((T 'scheduled task "{0}" (turns the TV on at boot, logon and resume)' 'tarefa agendada "{0}" (liga a TV ao iniciar, no login e ao voltar da suspensao)') -f $script:TaskName)

Write-Host ''
Write-Host (T '  Done. Files and log: ' '  Pronto. Arquivos e log: ') -NoNewline; Write-Host $script:InstallDir -ForegroundColor White
Write-Host (T '  Manual control:      ' '  Controle manual:       ') -NoNewline; Write-Host "powershell -File `"$script:InstallDir\SamsungTV.ps1`" On|Off|Status" -ForegroundColor White
Write-Host (T '  Uninstall:           ' '  Desinstalar:           ') -NoNewline; Write-Host "powershell -File `"$script:InstallDir\Uninstall.ps1`"" -ForegroundColor White
Write-Host ''
