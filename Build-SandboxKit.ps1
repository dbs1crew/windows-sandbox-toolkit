#Requires -Version 5.1

<#
.SYNOPSIS
    Builds an offline security toolkit folder for Windows Sandbox.

.DESCRIPTION
    Run this on the HOST, not in the sandbox. It needs internet access but
    not administrator rights.

    It downloads portable builds of each tool into <KitRoot>\Tools, keeps a
    download cache so reruns are quick, and writes three sandbox files:
    SecurityToolkit-Online.wsb (networking on),
    SecurityToolkit-Offline.wsb (networking off) and
    SecurityToolkit-Protected.wsb (networking off, Protected Client mode,
    clipboard off). Double-click one to start a sandbox.

    Keep Build-SandboxKit.ps1 and Start-SandboxKit.ps1 together in one
    folder (for example C:\SandboxKit). Rerun this script whenever you want
    newer versions of the tools.

.PARAMETER KitRoot
    Folder to build the kit in. Defaults to the folder this script is in.

.PARAMETER VSCodeExtensions
    VS Code extensions to preinstall. Defaults to the Python extension
    (which also brings Pylance and the Python debugger).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File C:\SandboxKit\Build-SandboxKit.ps1
#>

# VSCodeExtensions is used inside the Visual Studio Code build step's script
# block, which PSScriptAnalyzer can't follow.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    "PSReviewUnusedParameter", "VSCodeExtensions",
    Justification = "Used inside the Visual Studio Code build step's script block.")]
[CmdletBinding()]
param(
    # Resolved below: $PSScriptRoot can be empty here in Windows PowerShell
    # 5.1 when the script is dot-sourced (e.g. the VS Code/ISE Run button).
    [string]$KitRoot,

    [string[]]$VSCodeExtensions = @("ms-python.python")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Invoke-WebRequest is many times slower in Windows PowerShell with the
# progress bar on.
$ProgressPreference = "SilentlyContinue"

# Windows PowerShell 5.1 may default to TLS versions that GitHub rejects.
[Net.ServicePointManager]::SecurityProtocol =
    [Net.ServicePointManager]::SecurityProtocol -bor
    [Net.SecurityProtocolType]::Tls12

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

if (-not $KitRoot) {
    $KitRoot = $PSScriptRoot
}

if (-not $KitRoot -and $MyInvocation.MyCommand.Path) {
    $KitRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
}

if (-not $KitRoot) {
    throw "Could not determine the kit folder. Pass -KitRoot."
}

$UserAgent     = "SandboxKitBuilder/1.0"
$ToolsDir      = Join-Path $KitRoot "Tools"
$InstallersDir = Join-Path $KitRoot "Installers"
$CacheDir      = Join-Path $KitRoot "Cache"
$WorkDir       = Join-Path $CacheDir "_work"
$WsbOnline     = Join-Path $KitRoot "SecurityToolkit-Online.wsb"
$WsbOffline    = Join-Path $KitRoot "SecurityToolkit-Offline.wsb"
$WsbProtected  = Join-Path $KitRoot "SecurityToolkit-Protected.wsb"
$StartScript   = Join-Path $KitRoot "Start-SandboxKit.ps1"

# Paths inside the sandbox. These must match Start-SandboxKit.ps1.
$SandboxKitPath   = "C:\Kit"
$SandboxPythonExe = "C:\Tools\Python\python.exe"

$script:SevenZip = $null
$Summary = [System.Collections.Generic.List[object]]::new()

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Write-Step {
    param([string]$Message)

    Write-Host ""
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function New-CleanDirectory {
    # Internal helper; -WhatIf support would add nothing.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        "PSUseShouldProcessForStateChangingFunctions", "",
        Justification = "Internal helper, not called by users.")]
    param([string]$Path)

    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Recurse -Force
    }

    New-Item -ItemType Directory -Path $Path -Force | Out-Null
}

function Get-Download {
    <#
        Downloads a file into the cache (or another folder) and returns its
        path. Versioned file names are reused from the cache; files whose
        name never changes (e.g. SysinternalsSuite.zip) use -AlwaysRefresh.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Url,

        [Parameter(Mandatory)]
        [string]$FileName,

        [string]$Destination = $CacheDir,

        [switch]$AlwaysRefresh
    )

    $Path = Join-Path $Destination $FileName

    if (
        -not $AlwaysRefresh -and
        (Test-Path -LiteralPath $Path) -and
        (Get-Item -LiteralPath $Path).Length -gt 0
    ) {
        Write-Host "    Using cached $FileName"
        return $Path
    }

    Write-Host "    Downloading $FileName"

    $Partial = "$Path.partial"

    Invoke-WebRequest `
        -Uri $Url `
        -OutFile $Partial `
        -UseBasicParsing `
        -UserAgent $UserAgent

    Move-Item -LiteralPath $Partial -Destination $Path -Force

    return $Path
}

function Get-GitHubRelease {
    param([string]$Repository)

    return Invoke-RestMethod `
        -Uri "https://api.github.com/repos/$Repository/releases/latest" `
        -Headers @{
            "User-Agent" = $UserAgent
            "Accept"     = "application/vnd.github+json"
        }
}

function Select-GitHubAsset {
    param(
        $Release,
        [string]$Pattern
    )

    $Asset = @($Release.assets | Where-Object { $_.name -match $Pattern }) |
        Select-Object -First 1

    if (-not $Asset) {
        throw "No download matching '$Pattern' in release $($Release.tag_name)."
    }

    return [pscustomobject]@{
        Name = [string]$Asset.name
        Url  = [string]$Asset.browser_download_url
    }
}

function Get-PageVersion {
    <# Returns every version captured by group 1 of $Pattern on a web page. #>
    param(
        [string]$Url,
        [string]$Pattern
    )

    $Content = (Invoke-WebRequest -Uri $Url -UseBasicParsing -UserAgent $UserAgent).Content

    return @(
        [regex]::Matches($Content, $Pattern) |
            ForEach-Object { $_.Groups[1].Value } |
            Sort-Object -Unique
    )
}

function Select-NewestVersion {
    param([string[]]$Versions)

    if (-not $Versions -or $Versions.Count -eq 0) {
        throw "No versions were found."
    }

    return $Versions |
        Sort-Object { [version]$_ } -Descending |
        Select-Object -First 1
}

function Expand-With7Zip {
    param(
        [string]$Archive,
        [string]$Destination
    )

    if (-not (Test-Path -LiteralPath $Destination)) {
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    }

    & $script:SevenZip x $Archive "-o$Destination" -y -bso0 -bsp0

    if ($LASTEXITCODE -ne 0) {
        throw "7-Zip could not extract $(Split-Path $Archive -Leaf) (exit code $LASTEXITCODE)."
    }
}

function Move-DirectoryContent {
    param(
        [string]$Source,
        [string]$Destination
    )

    New-CleanDirectory $Destination

    Get-ChildItem -LiteralPath $Source -Force |
        Move-Item -Destination $Destination -Force
}

function Invoke-KitStep {
    <#
        Runs one tool's build steps. A failure is recorded and the build
        moves on to the next tool. The script block returns the version.
    #>
    param(
        [string]$Name,
        [scriptblock]$Action
    )

    Write-Step $Name

    try {
        $Version = [string](@(& $Action) | Select-Object -Last 1)

        Write-Host "    $Name ready: $Version" -ForegroundColor Green

        $Summary.Add([pscustomobject]@{
            Tool    = $Name
            Version = $Version
            Status  = "OK"
        })
    }
    catch {
        Write-Host "    $Name FAILED: $($_.Exception.Message)" -ForegroundColor Red

        $Summary.Add([pscustomobject]@{
            Tool    = $Name
            Version = ""
            Status  = "Failed: $($_.Exception.Message)"
        })
    }
}

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

foreach ($Directory in @($KitRoot, $ToolsDir, $InstallersDir, $CacheDir)) {
    if (-not (Test-Path -LiteralPath $Directory)) {
        New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    }
}

New-CleanDirectory $WorkDir

# Tools\Other is yours: drop any portable programs in it. The build creates
# it if it's missing and never clears or changes what's inside.
$OtherDir = Join-Path $ToolsDir "Other"

if (-not (Test-Path -LiteralPath $OtherDir)) {
    New-Item -ItemType Directory -Path $OtherDir -Force | Out-Null
}

Write-Host "Building sandbox kit in $KitRoot" -ForegroundColor Cyan

# --- 7-Zip ------------------------------------------------------------------
# Built first and required: it extracts everything else.

Write-Step "7-Zip"

$SevenZipRelease = Get-GitHubRelease "ip7z/7zip"
$SevenZipTag = [string]$SevenZipRelease.tag_name

$SevenZr = Get-Download `
    -Url (Select-GitHubAsset $SevenZipRelease '^7zr\.exe$').Url `
    -FileName "7zr-$SevenZipTag.exe"

$ExtraAsset = Select-GitHubAsset $SevenZipRelease '^7z\d+-extra\.7z$'
$Extra = Get-Download -Url $ExtraAsset.Url -FileName $ExtraAsset.Name

$InstallerAsset = Select-GitHubAsset $SevenZipRelease '^7z\d+-x64\.exe$'
$SevenZipInstaller = Get-Download -Url $InstallerAsset.Url -FileName $InstallerAsset.Name

# 7zr.exe only reads .7z files; use it to unpack 7za.exe from the extra package.
$Bootstrap = Join-Path $WorkDir "7zip-extra"
New-CleanDirectory $Bootstrap

& $SevenZr x $Extra "-o$Bootstrap" -y -bso0 -bsp0

if ($LASTEXITCODE -ne 0) {
    throw "Could not unpack the 7-Zip extra package (exit code $LASTEXITCODE)."
}

$SevenZa = Get-ChildItem -LiteralPath $Bootstrap -Recurse -Filter "7za.exe" |
    Sort-Object { $_.DirectoryName -notlike "*x64*" } |
    Select-Object -First 1

if (-not $SevenZa) {
    throw "7za.exe was not found in the 7-Zip extra package."
}

# Unpack the full 7-Zip (7z.exe, 7z.dll and the 7zFM.exe GUI) from its installer.
$SevenZipDir = Join-Path $ToolsDir "7-Zip"
New-CleanDirectory $SevenZipDir

& $SevenZa.FullName x $SevenZipInstaller "-o$SevenZipDir" -y -bso0 -bsp0

$FullSevenZip = Join-Path $SevenZipDir "7z.exe"

if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $FullSevenZip)) {
    $script:SevenZip = $FullSevenZip
}
else {
    Write-Host "    Could not unpack the 7-Zip GUI; using the command-line 7za.exe only." -ForegroundColor Yellow
    New-CleanDirectory $SevenZipDir
    Copy-Item -LiteralPath $SevenZa.FullName -Destination $SevenZipDir
    $script:SevenZip = Join-Path $SevenZipDir "7za.exe"
}

Write-Host "    7-Zip ready: $SevenZipTag" -ForegroundColor Green
$Summary.Add([pscustomobject]@{ Tool = "7-Zip"; Version = $SevenZipTag; Status = "OK" })

# --- Sysinternals -------------------------------------------------------------

Invoke-KitStep "Sysinternals Suite" {
    $Zip = Get-Download `
        -Url "https://download.sysinternals.com/files/SysinternalsSuite.zip" `
        -FileName "SysinternalsSuite.zip" `
        -AlwaysRefresh

    $Destination = Join-Path $ToolsDir "Sysinternals"
    New-CleanDirectory $Destination
    Expand-With7Zip $Zip $Destination

    "latest as of $(Get-Date -Format yyyy-MM-dd)"
}

# --- HxD ------------------------------------------------------------------------

Invoke-KitStep "HxD" {
    $Zip = Get-Download `
        -Url "https://mh-nexus.de/downloads/HxDPortableSetup.zip" `
        -FileName "HxDPortableSetup.zip" `
        -AlwaysRefresh

    $Extracted = Join-Path $WorkDir "hxd"
    New-CleanDirectory $Extracted
    Expand-With7Zip $Zip $Extracted

    $Setup = Get-ChildItem -LiteralPath $Extracted -Recurse -Filter "*.exe" |
        Select-Object -First 1

    if (-not $Setup) {
        throw "No setup program was found in HxDPortableSetup.zip."
    }

    $Destination = Join-Path $ToolsDir "HxD"
    New-CleanDirectory $Destination

    # The portable edition is an Inno Setup program that only writes to the
    # folder it is given.
    $Process = Start-Process `
        -FilePath $Setup.FullName `
        -ArgumentList @(
            "/VERYSILENT"
            "/SUPPRESSMSGBOXES"
            "/NORESTART"
            "/SP-"
            "/DIR=`"$Destination`""
        ) `
        -PassThru

    if (-not $Process.WaitForExit(180000)) {
        Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue
        throw "The HxD portable setup did not finish within 3 minutes."
    }

    $Exe = Get-ChildItem -LiteralPath $Destination -Recurse -Include "HxD64.exe", "HxD.exe" |
        Sort-Object { $_.Name -ne "HxD64.exe" } |
        Select-Object -First 1

    if (-not $Exe) {
        throw "HxD setup finished (exit code $($Process.ExitCode)) but no HxD executable was found."
    }

    [string]$Exe.VersionInfo.ProductVersion
}

# --- Wireshark ------------------------------------------------------------------

Invoke-KitStep "Wireshark" {
    $Base = "https://www.wireshark.org/download/win64/"

    $Versions = Get-PageVersion $Base 'WiresharkPortable64_(\d+\.\d+\.\d+)\.paf\.exe'

    # Odd minor versions (4.7, 4.9) are development releases.
    $Stable = @($Versions | Where-Object { ([version]$_).Minor % 2 -eq 0 })
    $Version = Select-NewestVersion $Stable

    $FileName = "WiresharkPortable64_$Version.paf.exe"
    $Installer = Get-Download -Url "$Base$FileName" -FileName $FileName

    # The PortableApps.com package is an NSIS installer, which 7-Zip can unpack.
    $Extracted = Join-Path $WorkDir "wireshark"
    New-CleanDirectory $Extracted
    Expand-With7Zip $Installer $Extracted

    $Exe = Get-ChildItem -LiteralPath $Extracted -Recurse -Filter "Wireshark.exe" |
        Select-Object -First 1

    if (-not $Exe) {
        throw "Wireshark.exe was not found in $FileName."
    }

    $Destination = Join-Path $ToolsDir "Wireshark"
    Move-DirectoryContent $Exe.DirectoryName $Destination

    if (-not (Test-Path -LiteralPath (Join-Path $Destination "tshark.exe"))) {
        Write-Host "    Note: tshark.exe is not included in this Wireshark package." -ForegroundColor Yellow
    }

    $Version
}

# --- Nmap ------------------------------------------------------------------------

Invoke-KitStep "Nmap" {
    $Version = Select-NewestVersion (
        Get-PageVersion "https://nmap.org/download.html" 'nmap-(\d+\.\d+)-setup\.exe'
    )

    $FileName = "nmap-$Version-setup.exe"
    $Installer = Get-Download -Url "https://nmap.org/dist/$FileName" -FileName $FileName

    # Also an NSIS installer.
    $Extracted = Join-Path $WorkDir "nmap"
    New-CleanDirectory $Extracted
    Expand-With7Zip $Installer $Extracted

    $Exe = Get-ChildItem -LiteralPath $Extracted -Recurse -Filter "nmap.exe" |
        Select-Object -First 1

    if (-not $Exe) {
        throw "nmap.exe was not found in $FileName."
    }

    $Destination = Join-Path $ToolsDir "Nmap"
    Move-DirectoryContent $Exe.DirectoryName $Destination

    foreach ($Leftover in @('$PLUGINSDIR', "Uninstall.exe")) {
        $Path = Join-Path $Destination $Leftover

        if (Test-Path -LiteralPath $Path) {
            Remove-Item -LiteralPath $Path -Recurse -Force
        }
    }

    $Version
}

# --- Installers (Npcap, Visual C++ runtimes) ----------------------------------------

Invoke-KitStep "Npcap installer" {
    $Version = Select-NewestVersion (
        Get-PageVersion "https://npcap.com/" 'npcap-(\d+\.\d+)\.exe'
    )

    $FileName = "npcap-$Version.exe"

    # Keep only the current Npcap installer in the kit.
    Get-ChildItem -LiteralPath $InstallersDir -Filter "npcap-*.exe" |
        Where-Object { $_.Name -ne $FileName } |
        Remove-Item -Force

    Get-Download `
        -Url "https://npcap.com/dist/$FileName" `
        -FileName $FileName `
        -Destination $InstallersDir |
        Out-Null

    $Version
}

Invoke-KitStep "Visual C++ runtimes" {
    # Nmap and Wireshark need these; a fresh sandbox doesn't have them.
    foreach ($Arch in @("x64", "x86")) {
        Get-Download `
            -Url "https://aka.ms/vs/17/release/vc_redist.$Arch.exe" `
            -FileName "vc_redist.$Arch.exe" `
            -Destination $InstallersDir `
            -AlwaysRefresh |
            Out-Null
    }

    [string](Get-Item -LiteralPath (Join-Path $InstallersDir "vc_redist.x64.exe")).VersionInfo.ProductVersion
}

# --- Git ----------------------------------------------------------------------------

Invoke-KitStep "Git" {
    $Release = Get-GitHubRelease "git-for-windows/git"
    $Asset = Select-GitHubAsset $Release '^PortableGit-[\d.]+-64-bit\.7z\.exe$'
    $Archive = Get-Download -Url $Asset.Url -FileName $Asset.Name

    $Destination = Join-Path $ToolsDir "Git"
    New-CleanDirectory $Destination

    # Run the self-extractor itself (not 7-Zip) so it also runs Git's
    # post-install step.
    $Process = Start-Process `
        -FilePath $Archive `
        -ArgumentList @("-y", "-o`"$Destination`"") `
        -Wait `
        -PassThru

    $GitExe = Join-Path $Destination "cmd\git.exe"

    if (-not (Test-Path -LiteralPath $GitExe)) {
        throw "PortableGit extraction failed (exit code $($Process.ExitCode))."
    }

    [string]$Release.tag_name
}

# --- PowerShell 7 ---------------------------------------------------------------------

Invoke-KitStep "PowerShell 7" {
    $Release = Get-GitHubRelease "PowerShell/PowerShell"
    $Asset = Select-GitHubAsset $Release '^PowerShell-[\d.]+-win-x64\.zip$'
    $Zip = Get-Download -Url $Asset.Url -FileName $Asset.Name

    $Destination = Join-Path $ToolsDir "PowerShell"
    New-CleanDirectory $Destination
    Expand-With7Zip $Zip $Destination

    [string]$Release.tag_name
}

# --- Python ----------------------------------------------------------------------------

Invoke-KitStep "Python" {
    # The NuGet "python" package is a complete, relocatable CPython build.
    $Index = Invoke-RestMethod `
        -Uri "https://api.nuget.org/v3-flatcontainer/python/index.json" `
        -UserAgent $UserAgent

    $Version = Select-NewestVersion @(
        $Index.versions | Where-Object { $_ -match '^\d+\.\d+\.\d+$' }
    )

    $FileName = "python.$Version.nupkg"
    $Package = Get-Download `
        -Url "https://api.nuget.org/v3-flatcontainer/python/$Version/$FileName" `
        -FileName $FileName

    $Extracted = Join-Path $WorkDir "python"
    New-CleanDirectory $Extracted
    Expand-With7Zip $Package $Extracted

    $Destination = Join-Path $ToolsDir "Python"
    Move-DirectoryContent (Join-Path $Extracted "tools") $Destination

    $PythonExe = Join-Path $Destination "python.exe"

    if (-not (Test-Path -LiteralPath $PythonExe)) {
        throw "python.exe was not found in $FileName."
    }

    # Add pip so packages can be installed later inside the sandbox.
    & $PythonExe -m ensurepip --default-pip | Out-Null

    if ($LASTEXITCODE -ne 0) {
        Write-Host "    Note: pip could not be added (exit code $LASTEXITCODE)." -ForegroundColor Yellow
    }

    $Version
}

# --- Visual Studio Code ------------------------------------------------------------------

Invoke-KitStep "Visual Studio Code" {
    $Zip = Get-Download `
        -Url "https://update.code.visualstudio.com/latest/win32-x64-archive/stable" `
        -FileName "VSCode-win32-x64.zip" `
        -AlwaysRefresh

    $Destination = Join-Path $ToolsDir "VSCode"
    New-CleanDirectory $Destination
    Expand-With7Zip $Zip $Destination

    # A "data" folder next to Code.exe turns on portable mode: settings and
    # extensions live inside the VS Code folder.
    $SettingsDir = Join-Path $Destination "data\user-data\User"
    New-Item -ItemType Directory -Path $SettingsDir -Force | Out-Null

    $Settings = [ordered]@{
        "python.defaultInterpreterPath" = $SandboxPythonExe
        "update.mode"                   = "none"
        "extensions.autoUpdate"         = $false
        "extensions.autoCheckUpdates"   = $false
        "telemetry.telemetryLevel"      = "off"
        "workbench.startupEditor"       = "none"
    }

    [IO.File]::WriteAllText(
        (Join-Path $SettingsDir "settings.json"),
        ($Settings | ConvertTo-Json),
        [Text.UTF8Encoding]::new($false)
    )

    $CodeCli = Join-Path $Destination "bin\code.cmd"

    foreach ($Extension in $VSCodeExtensions) {
        Write-Host "    Installing extension $Extension"

        & $CodeCli --install-extension $Extension --force | Out-Null

        if ($LASTEXITCODE -ne 0) {
            throw "Extension $Extension failed to install (exit code $LASTEXITCODE)."
        }
    }

    # Read the version from Code.exe. Newer builds keep resources\app inside a
    # version-named subfolder, so a fixed path to package.json breaks.
    $CodeExe = Join-Path $Destination "Code.exe"

    if (-not (Test-Path -LiteralPath $CodeExe)) {
        throw "Code.exe was not found in the VS Code zip."
    }

    $Version = [string](Get-Item -LiteralPath $CodeExe).VersionInfo.ProductVersion

    if (-not $Version) {
        $PackageJson = Get-ChildItem -LiteralPath $Destination -Recurse -Filter "package.json" -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -like "*\resources\app\package.json" } |
            Select-Object -First 1

        $Version = if ($PackageJson) {
            [string](Get-Content -LiteralPath $PackageJson.FullName -Raw | ConvertFrom-Json).version
        }
        else {
            "unknown"
        }
    }

    $Version
}

# ---------------------------------------------------------------------------
# Sandbox configuration and summary
# ---------------------------------------------------------------------------

Write-Step "Writing sandbox configurations"

function Get-WsbContent {
    param(
        [ValidateSet("Enable", "Disable")][string]$Networking,
        [ValidateSet("Enable", "Disable")][string]$ProtectedClient = "Disable",
        [ValidateSet("Enable", "Disable")][string]$Clipboard = "Enable"
    )

    return @"
<Configuration>
  <Networking>$Networking</Networking>
  <ProtectedClient>$ProtectedClient</ProtectedClient>
  <ClipboardRedirection>$Clipboard</ClipboardRedirection>
  <PrinterRedirection>Disable</PrinterRedirection>
  <AudioInput>Disable</AudioInput>
  <VideoInput>Disable</VideoInput>
  <MappedFolders>
    <MappedFolder>
      <HostFolder>$([Security.SecurityElement]::Escape($KitRoot))</HostFolder>
      <SandboxFolder>$SandboxKitPath</SandboxFolder>
      <ReadOnly>true</ReadOnly>
    </MappedFolder>
  </MappedFolders>
  <LogonCommand>
    <Command>powershell.exe -NoProfile -ExecutionPolicy Bypass -File $SandboxKitPath\Start-SandboxKit.ps1</Command>
  </LogonCommand>
</Configuration>
"@
}

# Online: the sandbox can reach the internet (pip, browsing, updates).
# Offline: no network at all; for examining untrusted files. The kit itself
# needs no network, so every tool works in both.
# Protected: offline, plus Protected Client mode (AppContainer isolation) and
# no clipboard sharing with the host. Protected Client blocks the writes that
# Start-SandboxKit.ps1 makes, so expect no desktop shortcuts or copied tools;
# run programs straight from C:\Kit\Tools instead.
[IO.File]::WriteAllText($WsbOnline, (Get-WsbContent -Networking "Enable"), [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText($WsbOffline, (Get-WsbContent -Networking "Disable"), [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText(
    $WsbProtected,
    (Get-WsbContent -Networking "Disable" -ProtectedClient "Enable" -Clipboard "Disable"),
    [Text.UTF8Encoding]::new($false)
)
Write-Host "    $WsbOnline"
Write-Host "    $WsbOffline"
Write-Host "    $WsbProtected"

# Remove the single .wsb file that earlier versions of this script wrote.
$OldWsb = Join-Path $KitRoot "SecurityToolkit.wsb"

if (Test-Path -LiteralPath $OldWsb) {
    Remove-Item -LiteralPath $OldWsb -Force
}

$Summary |
    ConvertTo-Json |
    Set-Content -LiteralPath (Join-Path $ToolsDir "versions.json") -Encoding UTF8

Remove-Item -LiteralPath $WorkDir -Recurse -Force -ErrorAction SilentlyContinue

if (-not (Test-Path -LiteralPath $StartScript)) {
    Write-Host ""
    Write-Host "WARNING: Start-SandboxKit.ps1 is missing from $KitRoot. Copy it there before starting the sandbox." -ForegroundColor Yellow
}

Write-Host ""
$Summary | Format-Table Tool, Version, Status -AutoSize -Wrap | Out-Host

$FailedCount = @($Summary | Where-Object { $_.Status -ne "OK" }).Count

if ($FailedCount -gt 0) {
    Write-Host "$FailedCount tool(s) failed. The rest of the kit is usable; rerun to retry." -ForegroundColor Yellow
    exit 1
}

Write-Host "Kit ready. Double-click SecurityToolkit-Online.wsb, SecurityToolkit-Offline.wsb or SecurityToolkit-Protected.wsb to start a sandbox." -ForegroundColor Green
