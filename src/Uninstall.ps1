<#
.SYNOPSIS
    Removes SamsungTV-Companion: scheduled task, shutdown script entry and installed files.
    Other shutdown scripts in the local group policy are left untouched.
#>
[CmdletBinding()]
param([switch]$KeepFiles)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'SamsungTV.Setup.ps1')

$pt = (Get-UICulture).Name -like 'pt*'
function T([string]$En, [string]$Pt) { if ($script:pt) { $Pt } else { $En } }

if (-not (Test-IsAdmin)) {
    Write-Host (T 'Run as administrator (use Uninstall.cmd).' 'Execute como administrador (use o Uninstall.cmd).') -ForegroundColor Red
    exit 1
}

Unregister-PowerOnTask
Write-Host (T '   OK  scheduled task removed' '   OK  tarefa agendada removida') -ForegroundColor Green

Set-ShutdownHook -Remove
Write-Host (T '   OK  shutdown script removed' '   OK  script de desligamento removido') -ForegroundColor Green

if (-not $KeepFiles -and (Test-Path -LiteralPath $script:InstallDir)) {
    Set-Location $env:SystemRoot      # in case we are running from inside the folder
    Remove-Item -LiteralPath $script:InstallDir -Recurse -Force
    Write-Host ((T '   OK  {0} deleted' '   OK  {0} apagada') -f $script:InstallDir) -ForegroundColor Green
}

Write-Host ''
Write-Host (T 'Optional: remove this PC from the TV list (Device Connection Manager > Device List).' 'Opcional: tire este PC da lista da TV (Gerenciador de conexao de dispositivos > Lista de dispositivos).')
