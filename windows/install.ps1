<#
.SYNOPSIS
    Builds Wispr Faux for Windows and installs it for everyday use.

.DESCRIPTION
    1. Checks for the .NET SDK (8 or later) and the Visual C++ runtime, and installs them with
       winget if they're missing.
    2. Builds a Release copy of Wispr Faux.
    3. Quits any running Wispr Faux (cleanly, so it puts your clipboard back).
    4. Installs it in %LOCALAPPDATA%\Programs\Wispr Faux (no administrator rights needed).
    5. Downloads the Whisper large-v3 turbo speech model (574 MB) unless it's already there.
    6. Adds Wispr Faux to the Start menu and has it open when you sign in.
    7. Starts it.

    Run it again after pulling or changing code: it rebuilds and replaces the installed copy.
    Your settings, history, models and API keys (in %LOCALAPPDATA%\Wispr Faux) are kept.

.PARAMETER WithLocalCleanup
    Also download Qwen3 1.7B (1.1 GB), the model that cleans up stumbles on this PC.
    (It can also be downloaded later from Settings.)

.PARAMETER NoLogin
    Don't open Wispr Faux when you sign in (and turn it off if it was on).

.PARAMETER SkipModelDownload
    Don't download the speech model now (Settings has a Download button).

.PARAMETER NoLaunch
    Don't start Wispr Faux at the end.

.EXAMPLE
    .\install.ps1
.EXAMPLE
    .\install.ps1 -WithLocalCleanup
#>
[CmdletBinding()]
param(
    [switch]$WithLocalCleanup,
    [switch]$NoLogin,
    [switch]$SkipModelDownload,
    [switch]$NoLaunch
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # Invoke-WebRequest is very slow with the progress bar.
Set-Location -LiteralPath $PSScriptRoot

$InstallDir = Join-Path $env:LOCALAPPDATA 'Programs\Wispr Faux'
$DataDir    = Join-Path $env:LOCALAPPDATA 'Wispr Faux'
$ModelsDir  = Join-Path $DataDir 'Models'
$Exe        = Join-Path $InstallDir 'WisprFaux.exe'
$Staging    = Join-Path $env:TEMP 'WisprFaux-build'
$Shortcut   = Join-Path ([Environment]::GetFolderPath('Programs')) 'Wispr Faux.lnk'
$RunKey     = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'

function Step([string]$Message) { Write-Host "==> $Message" -ForegroundColor Cyan }
function Note([string]$Message) { Write-Host "    $Message" }

# --- 1. Windows and .NET -----------------------------------------------------------------------

if (-not [Environment]::Is64BitOperatingSystem) {
    throw 'Wispr Faux needs 64-bit Windows 10 or 11.'
}
if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') {
    Write-Warning 'This is an ARM PC. Wispr Faux is built for x64 and will run under emulation, more slowly.'
}

function Test-DotNetSdk {
    $dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
    if (-not $dotnet) { return $false }
    # In Windows PowerShell 5.1, stderr from a native command under 'Stop' is a terminating error.
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $sdks = & dotnet --list-sdks 2>$null } finally { $ErrorActionPreference = $previous }
    foreach ($line in $sdks) {
        if ($line -match '^(\d+)\.' -and [int]$Matches[1] -ge 8) { return $true }
    }
    return $false
}

if (-not (Test-DotNetSdk)) {
    Step 'Installing the .NET 8 SDK (needed to build Wispr Faux)'
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        winget install --id Microsoft.DotNet.SDK.8 --exact --source winget --accept-package-agreements --accept-source-agreements
        # Pick up the PATH change without opening a new window.
        $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
    }
    if (-not (Test-DotNetSdk)) {
        throw 'The .NET SDK is missing. Install the .NET 8 SDK (x64) from https://dotnet.microsoft.com/download/dotnet/8.0, open a new PowerShell window, and run this script again.'
    }
}
Note ("Using .NET SDK " + (& dotnet --version))

# whisper.cpp and llama.cpp need the Visual C++ 2015-2022 runtime, which a fresh Windows may lack.
function Test-VCRuntime {
    $system = [Environment]::GetFolderPath('System')
    foreach ($dll in 'msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll', 'vcomp140.dll') {
        if (-not (Test-Path -LiteralPath (Join-Path $system $dll))) { return $false }
    }
    return $true
}

if (-not (Test-VCRuntime)) {
    Step 'Installing the Microsoft Visual C++ runtime (needed by the speech model)'
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        winget install --id Microsoft.VCRedist.2015+.x64 --exact --source winget --accept-package-agreements --accept-source-agreements
    }
    if (-not (Test-VCRuntime)) {
        throw 'The Visual C++ runtime is missing. Install "Visual C++ Redistributable for Visual Studio 2015-2022 (x64)" from https://aka.ms/vs/17/release/vc_redist.x64.exe, then run this script again.'
    }
}

# --- 2. Build ----------------------------------------------------------------------------------

Step 'Building Wispr Faux (Release). The first build downloads packages and takes a few minutes'
if (Test-Path -LiteralPath $Staging) { Remove-Item -LiteralPath $Staging -Recurse -Force }
# Self-contained: carries its own .NET runtime, so it runs whatever runtimes are installed.
& dotnet publish 'src\WisprFaux\WisprFaux.csproj' -c Release -r win-x64 --self-contained true -o $Staging --nologo -v quiet
if ($LASTEXITCODE -ne 0) { throw "The build failed (exit code $LASTEXITCODE). Scroll up for the error." }

# --- 3. Quit the running copy ------------------------------------------------------------------

# Only this Windows session's copy: other signed-in users' copies are theirs.
$session = (Get-Process -Id $PID).SessionId
function Get-OurCopy { Get-Process -Name 'WisprFaux' -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $session } }

$running = Get-OurCopy
if ($running) {
    Step 'Quitting the running Wispr Faux'
    if (Test-Path -LiteralPath $Exe) {
        # Asks it to quit the normal way, so a clipboard backup is put back first.
        Start-Process -FilePath $Exe -ArgumentList '--quit' -Wait -WindowStyle Hidden
    }
    $running | Wait-Process -Timeout 10 -ErrorAction SilentlyContinue
    Get-OurCopy | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500
}

# --- 4. Install --------------------------------------------------------------------------------

Step "Installing to $InstallDir"
if (Test-Path -LiteralPath $InstallDir) { Remove-Item -LiteralPath $InstallDir -Recurse -Force }
New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
Copy-Item -Path (Join-Path $Staging '*') -Destination $InstallDir -Recurse -Force
Remove-Item -LiteralPath $Staging -Recurse -Force

# --- 5. Models ---------------------------------------------------------------------------------

function Get-Model([string]$Name, [string]$Url, [string]$FileName, [long]$MinimumBytes) {
    New-Item -ItemType Directory -Path $ModelsDir -Force | Out-Null
    $target = Join-Path $ModelsDir $FileName
    if ((Test-Path -LiteralPath $target) -and ((Get-Item -LiteralPath $target).Length -ge $MinimumBytes)) {
        Note "$Name is already downloaded"
        return
    }
    Step "Downloading $Name"
    $part = "$target.part"
    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($curl) {
        # -C - resumes an interrupted download.
        & $curl.Source --location --fail --retry 3 --continue-at - --output $part $Url
        if ($LASTEXITCODE -ne 0) { throw "Downloading $Name failed (curl exit code $LASTEXITCODE). Run the script again to resume." }
    } else {
        Invoke-WebRequest -Uri $Url -OutFile $part -UseBasicParsing
    }
    if ((Get-Item -LiteralPath $part).Length -lt $MinimumBytes) { throw "The $Name download is incomplete. Run the script again." }
    Move-Item -LiteralPath $part -Destination $target -Force
}

if (-not $SkipModelDownload) {
    Get-Model 'Whisper large-v3 turbo (574 MB)' `
        'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin' `
        'ggml-large-v3-turbo-q5_0.bin' 287000000
}
if ($WithLocalCleanup) {
    Get-Model 'Qwen3 1.7B cleanup model (1.1 GB)' `
        'https://huggingface.co/unsloth/Qwen3-1.7B-GGUF/resolve/main/Qwen3-1.7B-Q4_K_M.gguf' `
        'Qwen3-1.7B-Q4_K_M.gguf' 555000000
}

# --- 6. Start menu and sign-in -----------------------------------------------------------------

Step 'Adding Wispr Faux to the Start menu'
$shell = New-Object -ComObject WScript.Shell
$link = $shell.CreateShortcut($Shortcut)
$link.TargetPath = $Exe
$link.WorkingDirectory = $InstallDir
$link.Description = 'Hold Ctrl, speak, release: push-to-talk dictation'
$link.Save()

if ($NoLogin) {
    Remove-ItemProperty -Path $RunKey -Name 'Wispr Faux' -ErrorAction SilentlyContinue
    Note 'Wispr Faux will not open at sign-in'
} else {
    Set-ItemProperty -Path $RunKey -Name 'Wispr Faux' -Value ('"{0}" --background' -f $Exe)
    Note 'Wispr Faux will open when you sign in (turn it off in its Settings or in Task Manager > Startup apps)'
}

# --- 7. Launch ---------------------------------------------------------------------------------

if (-not $NoLaunch) {
    Step 'Starting Wispr Faux'
    Start-Process -FilePath $Exe
}

Write-Host ''
Write-Host 'Done. Look for the microphone icon in the system tray (click ^ next to the clock if it is hidden).' -ForegroundColor Green
Write-Host 'Hold Ctrl, speak, and let go: the text appears where your cursor is.' -ForegroundColor Green
