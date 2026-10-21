#Requires -Version 5.1

<#
.SYNOPSIS
    Prepares a Windows Sandbox session from the mapped toolkit folder.

.DESCRIPTION
    Runs automatically at sandbox logon (see the SecurityToolkit-*.wsb
    files). The kit is
    mapped read-only at C:\Kit, so nothing in the sandbox can change it.

    Python and VS Code need to write to their own folders, so they are copied
    to C:\Tools. Everything else runs straight from C:\Kit\Tools.

    Build the kit on the host with Build-SandboxKit.ps1 first.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$KitRoot    = $PSScriptRoot
$KitTools   = Join-Path $KitRoot "Tools"
$Installers = Join-Path $KitRoot "Installers"
$LocalTools = "C:\Tools"
$LogFile    = Join-Path $LocalTools "SandboxKit.log"
$Desktop    = [Environment]::GetFolderPath("Desktop")

$Timer = [Diagnostics.Stopwatch]::StartNew()
$script:Failures = 0

New-Item -ItemType Directory -Path $LocalTools -Force | Out-Null
Start-Transcript -Path $LogFile -Force | Out-Null

function Get-Stamp {
    # Wall-clock time plus seconds since the script started.
    "[{0:HH:mm:ss.fff} +{1,6:0.0}s]" -f (Get-Date), $Timer.Elapsed.TotalSeconds
}

function Write-KitLog {
    param(
        [string]$Message,
        [ConsoleColor]$Color = [ConsoleColor]::Gray
    )

    Write-Host "$(Get-Stamp) $Message" -ForegroundColor $Color
}

function Measure-Item {
    <#
        Runs one sub-task and logs how long it took. The parameter names are
        deliberately unusual: the script block can see this function's
        variables, so a common name like $Name would hide the caller's.
    #>
    param(
        [string]$MeasureLabel,
        [scriptblock]$MeasureAction
    )

    $MeasureTimer = [Diagnostics.Stopwatch]::StartNew()
    Write-KitLog "    $MeasureLabel..."

    try {
        & $MeasureAction
    }
    finally {
        Write-KitLog ("    {0} took {1:0.0}s" -f $MeasureLabel, $MeasureTimer.Elapsed.TotalSeconds)
    }
}

function Invoke-Step {
    param(
        [string]$Name,
        [scriptblock]$Action
    )

    $StepTimer = [Diagnostics.Stopwatch]::StartNew()
    Write-KitLog "==> $Name" Cyan

    try {
        & $Action
        Write-KitLog ("    Step finished in {0:0.0}s" -f $StepTimer.Elapsed.TotalSeconds) DarkGray
    }
    catch {
        $script:Failures++
        Write-KitLog ("    FAILED after {0:0.0}s: {1}" -f $StepTimer.Elapsed.TotalSeconds, $_.Exception.Message) Red
    }
}

Write-KitLog "Start-SandboxKit.ps1 started on $env:COMPUTERNAME as $env:USERNAME"
Write-KitLog ("PowerShell process launched at {0:HH:mm:ss.fff}" -f (Get-Process -Id $PID).StartTime)
$MemoryGB = 0
$System = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue

if ($System) {
    $MemoryGB = $System.TotalPhysicalMemory / 1GB
}

Write-KitLog ("PowerShell {0}; {1} logical processors; {2:0.0} GB memory" -f $PSVersionTable.PSVersion, [Environment]::ProcessorCount, $MemoryGB)

if (-not (Test-Path -LiteralPath $KitTools)) {
    Write-Host "No Tools folder in $KitRoot. Run Build-SandboxKit.ps1 on the host first." -ForegroundColor Red
    Stop-Transcript | Out-Null
    Start-Sleep -Seconds 15
    exit 1
}

# ---------------------------------------------------------------------------
# Copy the tools that need a writable folder
# ---------------------------------------------------------------------------

Invoke-Step "Copying Python and VS Code to $LocalTools" {
    foreach ($Name in @("Python", "VSCode")) {
        $Source = Join-Path $KitTools $Name

        if (-not (Test-Path -LiteralPath $Source)) {
            Write-Host "    $Name is not in the kit; skipped."
            continue
        }

        $Destination = Join-Path $LocalTools $Name

        Measure-Item "Copying $Name" {
            robocopy $Source $Destination /E /MT:16 /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null

            # Robocopy exit codes below 8 mean success.
            if ($LASTEXITCODE -ge 8) {
                throw "Copying $Name failed (robocopy exit code $LASTEXITCODE)."
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Visual C++ runtimes (needed by Nmap and Wireshark)
# ---------------------------------------------------------------------------

# The runtime installers run in a hidden background process so setup carries
# on. Nmap and Wireshark need them; everything else works right away.
#
# On some computers each Windows Installer package spends 2 minutes verifying
# its signature, about 8 minutes in all. It happens with networking off too,
# so it is not a network timeout; the cause is still being investigated.
#
# Progress goes to C:\Tools\VCRuntimes.log, and each installer writes its own
# detailed log (C:\Tools\vc_redist.<arch>*.log).

$RuntimeInstallScript = @'
param(
    [string]$LogFile,
    [string]$LogDir,
    [Parameter(ValueFromRemainingArguments)]
    [string[]]$Installer
)

function Write-RuntimeLog {
    param([string]$Message)
    Add-Content -LiteralPath $LogFile ("{0:HH:mm:ss.fff} {1}" -f (Get-Date), $Message)
}

try {
    foreach ($Path in $Installer) {
        $Name = [IO.Path]::GetFileNameWithoutExtension($Path)
        $Timer = [Diagnostics.Stopwatch]::StartNew()
        Write-RuntimeLog "$Name started"

        $Process = Start-Process `
            -FilePath $Path `
            -ArgumentList "/install", "/quiet", "/norestart", "/log", (Join-Path $LogDir "$Name.log") `
            -Wait `
            -PassThru

        # 0 = success, 3010 = success with reboot suggested,
        # 1638 = a newer version is already present.
        $Result = if (@(0, 3010, 1638) -contains $Process.ExitCode) { "OK" } else { "FAILED" }

        Write-RuntimeLog ("{0} {1}, exit code {2}, took {3:0.0}s" -f $Name, $Result, $Process.ExitCode, $Timer.Elapsed.TotalSeconds)
    }
}
catch {
    Write-RuntimeLog "ERROR: $($_.Exception.Message)"
}
'@

Invoke-Step "Starting Visual C++ runtime installs in the background" {
    $Runtimes = @(
        @{
            Arch = "x64"
            Key  = "HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64"
        }
        @{
            Arch = "x86"
            Key  = "HKLM:\SOFTWARE\WOW6432Node\Microsoft\VisualStudio\14.0\VC\Runtimes\x86"
        }
    )

    $Pending = @()

    foreach ($Runtime in $Runtimes) {
        $Property = Get-ItemProperty -Path $Runtime.Key -ErrorAction SilentlyContinue

        if ($Property -and $Property.PSObject.Properties["Installed"] -and $Property.Installed -eq 1) {
            Write-KitLog "    $($Runtime.Arch) already present."
            continue
        }

        $Installer = Join-Path $Installers "vc_redist.$($Runtime.Arch).exe"

        if (-not (Test-Path -LiteralPath $Installer)) {
            Write-KitLog "    vc_redist.$($Runtime.Arch).exe is not in the kit; skipped."
            continue
        }

        $Pending += $Installer
    }

    if ($Pending.Count -eq 0) {
        return
    }

    $RuntimeLog = Join-Path $LocalTools "VCRuntimes.log"
    $ScriptPath = Join-Path $LocalTools "Install-VCRuntimes.ps1"
    Set-Content -LiteralPath $ScriptPath -Value $RuntimeInstallScript -Encoding UTF8

    Start-Process `
        -FilePath "powershell.exe" `
        -ArgumentList (@("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $ScriptPath, "-LogFile", $RuntimeLog, "-LogDir", $LocalTools) + $Pending) `
        -WindowStyle Hidden

    Write-KitLog "    Installing in the background; Nmap and Wireshark need these to finish. Progress: $RuntimeLog"
}

# ---------------------------------------------------------------------------
# Sysinternals EULA
# ---------------------------------------------------------------------------

Invoke-Step "Accepting the Sysinternals EULA for this session" {
    # Without this, every Sysinternals tool shows a EULA dialog on first run.
    $Key = "HKCU:\Software\Sysinternals"
    New-Item -Path $Key -Force | Out-Null
    New-ItemProperty -Path $Key -Name "EulaAccepted" -Value 1 -PropertyType DWord -Force | Out-Null
}

# ---------------------------------------------------------------------------
# PATH
# ---------------------------------------------------------------------------

Invoke-Step "Adding tools to PATH" {
    $Candidates = @(
        "$LocalTools\Python"
        "$LocalTools\Python\Scripts"
        "$LocalTools\VSCode\bin"
        "$KitTools\PowerShell"
        "$KitTools\Git\cmd"
        "$KitTools\7-Zip"
        "$KitTools\Sysinternals"
        "$KitTools\Nmap"
        "$KitTools\Wireshark"
    )

    $NewEntries = @(
        $Candidates | Where-Object { Test-Path -LiteralPath (Split-Path $_ -Parent) }
    )

    $UserPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $Existing = @(([string]$UserPath) -split ";" | Where-Object { $_ })

    $Merged = @($NewEntries + $Existing | Select-Object -Unique) -join ";"

    # Setting the user PATH notifies Explorer, so windows opened from the
    # desktop or Start menu pick up the new PATH.
    # This call broadcasts a settings change to every open window and can
    # stall for a while if one of them is slow to answer, so it is timed.
    Measure-Item "Saving the user PATH" {
        [Environment]::SetEnvironmentVariable("Path", $Merged, "User")
    }
    $env:Path = "$env:Path;$($NewEntries -join ';')"
}

# ---------------------------------------------------------------------------
# Desktop shortcuts
# ---------------------------------------------------------------------------

Invoke-Step "Creating desktop shortcuts" {
    $Shell = New-Object -ComObject WScript.Shell

    function New-Shortcut {
        # Internal helper; -WhatIf support would add nothing.
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
            "PSUseShouldProcessForStateChangingFunctions", "",
            Justification = "Internal helper, not called by users.")]
        param(
            [string]$Name,
            $Target,
            [string]$Arguments = ""
        )

        if (-not $Target -or -not (Test-Path -LiteralPath $Target)) {
            Write-Host "    $Name is not in the kit; skipped."
            return
        }

        $Shortcut = $Shell.CreateShortcut((Join-Path $Desktop "$Name.lnk"))
        $Shortcut.TargetPath = $Target
        $Shortcut.Arguments = $Arguments
        $Shortcut.WorkingDirectory = $env:USERPROFILE
        $Shortcut.IconLocation = "$Target,0"
        $Shortcut.Save()
    }

    $HxD = Get-ChildItem -LiteralPath (Join-Path $KitTools "HxD") -Recurse -Include "HxD64.exe", "HxD.exe" -ErrorAction SilentlyContinue |
        Sort-Object { $_.Name -ne "HxD64.exe" } |
        Select-Object -First 1

    $Npcap = Get-ChildItem -LiteralPath $Installers -Filter "npcap-*.exe" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

    New-Shortcut "Visual Studio Code" "$LocalTools\VSCode\Code.exe"
    New-Shortcut "PowerShell 7" "$KitTools\PowerShell\pwsh.exe"
    New-Shortcut "Git Bash" "$KitTools\Git\git-bash.exe" "--cd-to-home"
    New-Shortcut "Wireshark" "$KitTools\Wireshark\Wireshark.exe"
    New-Shortcut "HxD" $(if ($HxD) { $HxD.FullName })
    New-Shortcut "7-Zip" "$KitTools\7-Zip\7zFM.exe"
    New-Shortcut "Process Explorer" "$KitTools\Sysinternals\procexp64.exe"
    New-Shortcut "Process Monitor" "$KitTools\Sysinternals\Procmon64.exe"
    New-Shortcut "Autoruns" "$KitTools\Sysinternals\Autoruns64.exe"
    New-Shortcut "TCPView" "$KitTools\Sysinternals\tcpview64.exe"
    New-Shortcut "Install Npcap (live capture)" $(if ($Npcap) { $Npcap.FullName })

    # A shortcut to Tools\Other, where you keep your own portable programs.
    $OtherDir = Join-Path $KitTools "Other"

    if (Test-Path -LiteralPath $OtherDir) {
        $Shortcut = $Shell.CreateShortcut((Join-Path $Desktop "Other Tools.lnk"))
        $Shortcut.TargetPath = $OtherDir
        $Shortcut.IconLocation = "$env:SystemRoot\System32\shell32.dll,3"
        $Shortcut.Save()
    }
    else {
        Write-Host "    No Tools\Other folder in the kit; skipped."
    }
}

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

$Seconds = [math]::Round($Timer.Elapsed.TotalSeconds)

Write-Host ""

if ($script:Failures -eq 0) {
    Write-KitLog "Sandbox ready in $Seconds seconds." Green
}
else {
    Write-KitLog "Sandbox ready in $Seconds seconds with $($script:Failures) failed step(s). See $LogFile." Yellow
}

Stop-Transcript | Out-Null
Start-Sleep -Seconds 5
