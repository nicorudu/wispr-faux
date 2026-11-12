<#
.SYNOPSIS
    Removes Wispr Faux from this PC.

.PARAMETER RemoveData
    Also delete %LOCALAPPDATA%\Wispr Faux: downloaded models, history, settings and saved API keys.
#>
[CmdletBinding()]
param([switch]$RemoveData)

$ErrorActionPreference = 'Stop'
$InstallDir = Join-Path $env:LOCALAPPDATA 'Programs\Wispr Faux'
$DataDir    = Join-Path $env:LOCALAPPDATA 'Wispr Faux'
$Exe        = Join-Path $InstallDir 'WisprFaux.exe'
$Shortcut   = Join-Path ([Environment]::GetFolderPath('Programs')) 'Wispr Faux.lnk'

$session = (Get-Process -Id $PID).SessionId
function Get-OurCopy { Get-Process -Name 'WisprFaux' -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $session } }

$running = Get-OurCopy
if ($running) {
    Write-Host '==> Quitting Wispr Faux'
    if (Test-Path -LiteralPath $Exe) { Start-Process -FilePath $Exe -ArgumentList '--quit' -Wait -WindowStyle Hidden }
    $running | Wait-Process -Timeout 10 -ErrorAction SilentlyContinue
    Get-OurCopy | Stop-Process -Force -ErrorAction SilentlyContinue
}

Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'Wispr Faux' -ErrorAction SilentlyContinue
if (Test-Path -LiteralPath $Shortcut) { Remove-Item -LiteralPath $Shortcut -Force }
if (Test-Path -LiteralPath $InstallDir) { Remove-Item -LiteralPath $InstallDir -Recurse -Force }
Write-Host '==> Removed the app, its Start menu entry and its sign-in entry'

if ($RemoveData) {
    if (Test-Path -LiteralPath $DataDir) { Remove-Item -LiteralPath $DataDir -Recurse -Force }
    Write-Host "==> Removed $DataDir (models, history, settings, API keys)"
} else {
    Write-Host "    Kept $DataDir (models, history, settings). Run with -RemoveData to delete it too."
}
