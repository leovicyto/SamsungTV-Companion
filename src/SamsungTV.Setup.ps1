<#
  SamsungTV.Setup.ps1 - Windows integration used by Install.ps1 / Uninstall.ps1 (needs admin).

  Power OFF hook : a machine shutdown script in the LOCAL group policy
                   (%windir%\System32\GroupPolicy\Machine\Scripts\scripts.ini). Windows runs it
                   while the network is still up and waits for it, which a scheduled task
                   triggered by the shutdown event cannot guarantee.
                   Existing shutdown scripts are preserved; only our entry is added/removed.
  Power ON hook  : a scheduled task running as SYSTEM at boot, at logon and on resume.
#>

$script:InstallDir = Join-Path $env:ProgramData 'SamsungTV-Companion'
$script:TaskName = 'SamsungTV-Companion - Power On'
$script:GpoRoot = Join-Path $env:windir 'System32\GroupPolicy'
$script:ScriptsCse = '[{42B5FAAE-6536-11D2-AE5A-0000F87571E3}{40B6664F-4972-11D1-A7CA-0000F87571E3}]'
$script:PsExe = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'

function Test-IsAdmin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ---------------------------------------------------------------------------- scripts.ini

function Read-ScriptsIni {
    # Returns ordered: section name -> list of @{CmdLine; Parameters}
    $path = Join-Path $script:GpoRoot 'Machine\Scripts\scripts.ini'
    $sections = [ordered]@{}
    if (-not (Test-Path -LiteralPath $path)) { return $sections }
    $current = $null
    $raw = [ordered]@{}
    foreach ($line in [IO.File]::ReadAllLines($path)) {      # detects the UTF-16 BOM
        if ($line -match '^\s*\[(.+?)\]\s*$') { $current = $Matches[1]; $raw[$current] = [ordered]@{}; continue }
        if ($current -and $line -match '^\s*(\d+)(CmdLine|Parameters)\s*=(.*)$') {
            $i = $Matches[1]      # string key: an int would index the ordered dictionary by position
            if (-not $raw[$current].Contains($i)) { $raw[$current][$i] = @{ CmdLine = ''; Parameters = '' } }
            $raw[$current][$i][$Matches[2]] = $Matches[3]
        }
    }
    foreach ($s in $raw.Keys) {
        $list = New-Object Collections.Generic.List[object]
        foreach ($i in ($raw[$s].Keys | Sort-Object { [int]$_ })) { $list.Add($raw[$s][$i]) }
        $sections[$s] = $list
    }
    $sections
}

function Write-ScriptsIni($Sections) {
    $dir = Join-Path $script:GpoRoot 'Machine\Scripts'
    $path = Join-Path $dir 'scripts.ini'
    New-Item -ItemType Directory -Path (Join-Path $dir 'Shutdown') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $dir 'Startup') -Force | Out-Null
    $sb = New-Object Text.StringBuilder
    foreach ($s in $Sections.Keys) {
        if ($Sections[$s].Count -eq 0) { continue }
        [void]$sb.Append("`r`n[$s]`r`n")
        $i = 0
        foreach ($e in $Sections[$s]) {
            [void]$sb.Append("${i}CmdLine=$($e.CmdLine)`r`n${i}Parameters=$($e.Parameters)`r`n")
            $i++
        }
    }
    if (Test-Path -LiteralPath $path) { (Get-Item -LiteralPath $path -Force).Attributes = 'Normal' }
    [IO.File]::WriteAllText($path, $sb.ToString(), [Text.Encoding]::Unicode)
    (Get-Item -LiteralPath $path -Force).Attributes = 'Hidden'
}

function Update-GptIni([switch]$RemoveScriptsCse) {
    $path = Join-Path $script:GpoRoot 'gpt.ini'
    New-Item -ItemType Directory -Path $script:GpoRoot -Force | Out-Null
    $lines = if (Test-Path -LiteralPath $path) { @(Get-Content -LiteralPath $path) } else { @('[General]') }

    $extLine = $lines | Where-Object { $_ -match '^gPCMachineExtensionNames=' } | Select-Object -First 1
    $groups = @()
    if ($extLine) { $groups = @([regex]::Matches($extLine, '\[[^\]]*\]') | ForEach-Object { $_.Value }) }
    $groups = @($groups | Where-Object { $_ -ne $script:ScriptsCse })
    if (-not $RemoveScriptsCse) { $groups += $script:ScriptsCse }
    $newExt = 'gPCMachineExtensionNames=' + (($groups | Sort-Object) -join '')

    $out = New-Object Collections.Generic.List[string]
    $seenExt = $false; $seenVer = $false
    foreach ($l in $lines) {
        if ($l -match '^gPCMachineExtensionNames=') { if ($groups.Count) { $out.Add($newExt) }; $seenExt = $true }
        elseif ($l -match '^Version=(\d+)') { $out.Add('Version=' + ([int64]$Matches[1] + 1)); $seenVer = $true }  # +1 = machine version
        else { $out.Add($l) }
    }
    if (-not $seenExt -and $groups.Count) { $out.Add($newExt) }
    if (-not $seenVer) { $out.Add('Version=1') }
    Set-Content -LiteralPath $path -Value $out -Encoding ASCII
}

function Set-ShutdownHook([switch]$Remove) {
    $marker = 'SamsungTV-Companion'
    $sections = Read-ScriptsIni
    if (-not $sections.Contains('Shutdown')) { $sections['Shutdown'] = New-Object Collections.Generic.List[object] }
    $keep = New-Object Collections.Generic.List[object]
    foreach ($e in $sections['Shutdown']) { if ("$($e.CmdLine) $($e.Parameters)" -notmatch [regex]::Escape($marker)) { $keep.Add($e) } }
    if (-not $Remove) {
        $cli = Join-Path $script:InstallDir 'SamsungTV.ps1'
        $keep.Add(@{ CmdLine = $script:PsExe; Parameters = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$cli`" Off -OnShutdown" })
    }
    $sections['Shutdown'] = $keep

    $total = 0; foreach ($s in $sections.Keys) { $total += $sections[$s].Count }
    Write-ScriptsIni $sections
    Update-GptIni -RemoveScriptsCse:($total -eq 0)
    & gpupdate.exe /target:computer /force | Out-Null
}

function Test-ShutdownHook {
    $found = Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Group Policy\Scripts\Shutdown' -Recurse -ErrorAction SilentlyContinue |
             Where-Object { "$($_.GetValue('Parameters'))" -match 'SamsungTV-Companion' }
    [bool]$found
}

# ---------------------------------------------------------------------------- scheduled task

function Register-PowerOnTask {
    $cli = Join-Path $script:InstallDir 'SamsungTV.ps1'
    $xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Author>SamsungTV-Companion</Author>
    <Description>Turns the Samsung TV on at boot, logon and resume. https://github.com/leovicyto/SamsungTV-Companion</Description>
  </RegistrationInfo>
  <Triggers>
    <BootTrigger><Enabled>true</Enabled></BootTrigger>
    <LogonTrigger><Enabled>true</Enabled></LogonTrigger>
    <EventTrigger>
      <Enabled>true</Enabled>
      <Subscription>&lt;QueryList&gt;&lt;Query Id="0" Path="System"&gt;&lt;Select Path="System"&gt;*[System[Provider[@Name='Microsoft-Windows-Power-Troubleshooter'] and EventID=1]]&lt;/Select&gt;&lt;/Query&gt;&lt;/QueryList&gt;</Subscription>
    </EventTrigger>
  </Triggers>
  <Principals><Principal id="Author"><UserId>S-1-5-18</UserId><RunLevel>HighestAvailable</RunLevel></Principal></Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <StartWhenAvailable>true</StartWhenAvailable>
    <ExecutionTimeLimit>PT5M</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$($script:PsExe)</Command>
      <Arguments>-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$cli" On</Arguments>
    </Exec>
  </Actions>
</Task>
"@
    Register-ScheduledTask -TaskName $script:TaskName -Xml $xml -Force | Out-Null
}

function Unregister-PowerOnTask {
    if (Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false
    }
}

# ---------------------------------------------------------------------------- wake-on-input watcher

$script:WatcherTaskName = 'SamsungTV-Companion - Wake on input'
$script:WatcherExe = Join-Path $script:InstallDir 'SamsungTVWatcher.exe'

function Stop-Watcher {
    Get-Process -Name SamsungTVWatcher -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500
}

function Build-Watcher([string]$SourcePath) {
    # Compiled here from source with the C# compiler that ships with Windows (.NET Framework 4.x),
    # so the repository carries no binaries.
    $csc = @("$env:windir\Microsoft.NET\Framework64\v4.0.30319\csc.exe", "$env:windir\Microsoft.NET\Framework\v4.0.30319\csc.exe") |
           Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $csc) { throw 'C# compiler not found (.NET Framework 4.x is missing)' }
    Stop-Watcher
    $out = & $csc /nologo /target:winexe /optimize+ "/out:$script:WatcherExe" $SourcePath 2>&1
    if ($LASTEXITCODE -ne 0) { throw "watcher build failed: $out" }
}

function Register-WatcherTask {
    # Runs in each user's session at logon, with normal (non-admin) rights.
    $xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Author>SamsungTV-Companion</Author>
    <Description>Turns the Samsung TV back on when the mouse or keyboard is used while the TV is off.</Description>
  </RegistrationInfo>
  <Triggers><LogonTrigger><Enabled>true</Enabled></LogonTrigger></Triggers>
  <Principals><Principal id="Author"><GroupId>S-1-5-32-545</GroupId><RunLevel>LeastPrivilege</RunLevel></Principal></Principals>
  <Settings>
    <MultipleInstancesPolicy>Parallel</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author"><Exec><Command>$($script:WatcherExe)</Command></Exec></Actions>
</Task>
"@
    Register-ScheduledTask -TaskName $script:WatcherTaskName -Xml $xml -Force | Out-Null
}

function Start-WatcherNow {
    # Start it for the current user without waiting for the next logon. explorer.exe launches it
    # with the user's normal rights even though the installer itself is elevated.
    if (Get-Process -Name SamsungTVWatcher -ErrorAction SilentlyContinue) { return $true }
    Start-Process -FilePath explorer.exe -ArgumentList "`"$script:WatcherExe`""
    Start-Sleep -Seconds 2
    [bool](Get-Process -Name SamsungTVWatcher -ErrorAction SilentlyContinue)
}

function Unregister-WatcherTask {
    Stop-Watcher
    if (Get-ScheduledTask -TaskName $script:WatcherTaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $script:WatcherTaskName -Confirm:$false
    }
}

# ---------------------------------------------------------------------------- files

function Protect-InstallDir {
    # Runs as SYSTEM, so only SYSTEM and Administrators may change it; users can read.
    & icacls.exe $script:InstallDir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' | Out-Null
}
