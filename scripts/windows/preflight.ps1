[CmdletBinding()]
param(
    [string]$SourceDistro = "Ubuntu-24.04"
)

$ErrorActionPreference = "Stop"

$Repo = (
    Resolve-Path (
        Join-Path $PSScriptRoot "..\.."
    )
).Path

$Config = Import-PowerShellDataFile (
    Join-Path $Repo "config\lab.psd1"
)

$Failures = @()
$Warnings = @()


function Pass {
    param([string]$Message)

    Write-Host "[PASS] $Message"
}


function Fail {
    param([string]$Message)

    Write-Host "[FAIL] $Message"
    $script:Failures += $Message
}


function Warn {
    param([string]$Message)

    Write-Host "[WARN] $Message"
    $script:Warnings += $Message
}


function Get-WslNames {

    return @(
        & wsl.exe --list --quiet 2>$null |
            ForEach-Object {
                ($_ -replace "`0", "").Trim()
            } |
            Where-Object {
                -not [string]::IsNullOrWhiteSpace($_)
            }
    )
}


Write-Host ""
Write-Host "========================================"
Write-Host " Local Kubernetes Lab - Preflight"
Write-Host "========================================"
Write-Host ""


#
# 1. Windows
#
Write-Host "===== 1. WINDOWS ====="

if ($env:OS -eq "Windows_NT") {
    Pass "Running on Windows"
}
else {
    Fail "This lab requires Windows"
}


$WindowsInfo = Get-CimInstance Win32_OperatingSystem

Write-Host "Windows      : $($WindowsInfo.Caption)"
Write-Host "Version      : $($WindowsInfo.Version)"
Write-Host "Build        : $($WindowsInfo.BuildNumber)"
Write-Host "RAM          : $([math]::Round($WindowsInfo.TotalVisibleMemorySize / 1MB, 1)) GB"


#
# 2. WSL command
#
Write-Host ""
Write-Host "===== 2. WSL ====="

$WslCommand = Get-Command wsl.exe -ErrorAction SilentlyContinue

if ($null -eq $WslCommand) {
    Fail "wsl.exe not found"
}
else {
    Pass "wsl.exe available"

    Write-Host ""
    & wsl.exe --version
}


#
# 3. Source Ubuntu distro
#
Write-Host ""
Write-Host "===== 3. SOURCE DISTRO ====="

$InstalledDistros = @(Get-WslNames)

if ($InstalledDistros -contains $SourceDistro) {

    Pass "source distro '$SourceDistro' installed"

    $UbuntuRelease = @(
        & wsl.exe `
            -d $SourceDistro `
            -- `
            sh -c 'grep "^PRETTY_NAME=" /etc/os-release | cut -d= -f2-' `
            2>$null
    )

    if ($LASTEXITCODE -eq 0) {

        $UbuntuReleaseText = (
            $UbuntuRelease -join ""
        ).Trim().Trim('"')

        Write-Host "Source OS    : $UbuntuReleaseText"

        if ($UbuntuReleaseText -match "Ubuntu 24\.04") {
            Pass "source distro is Ubuntu 24.04"
        }
        else {
            Fail "expected Ubuntu 24.04 source distro"
        }
    }
    else {
        Fail "unable to inspect source Ubuntu distro"
    }
}
else {
    Fail "source distro '$SourceDistro' is not installed"
}


#
# 4. systemd support
#
Write-Host ""
Write-Host "===== 4. SYSTEMD SUPPORT ====="

if ($InstalledDistros -contains $SourceDistro) {

    $Pid1 = @(
        & wsl.exe `
            -d $SourceDistro `
            -- `
            ps -p 1 -o comm= `
            2>$null
    )

    $Pid1Text = ($Pid1 -join "").Trim()

    Write-Host "PID 1        : $Pid1Text"

    if ($Pid1Text -eq "systemd") {
        Pass "systemd enabled in source distro"
    }
    else {
        Fail "systemd is not PID 1 in source distro"
    }
}


#
# 5. CPU / RAM
#
Write-Host ""
Write-Host "===== 5. HOST RESOURCES ====="

$Cpu = Get-CimInstance Win32_ComputerSystem

$LogicalCpu = $Cpu.NumberOfLogicalProcessors
$TotalRamGB = [math]::Round(
    $Cpu.TotalPhysicalMemory / 1GB,
    1
)

Write-Host "Logical CPUs : $LogicalCpu"
Write-Host "Physical RAM : $TotalRamGB GB"

if ($LogicalCpu -ge 4) {
    Pass "at least 4 logical CPUs available"
}
else {
    Fail "less than 4 logical CPUs available"
}

if ($TotalRamGB -ge 8) {
    Pass "at least 8 GB RAM available"
}
else {
    Fail "less than 8 GB RAM available"
}

if ($TotalRamGB -lt 12) {
    Warn "12+ GB RAM recommended for the 3-node lab"
}


#
# 6. .wslconfig
#
Write-Host ""
Write-Host "===== 6. WSL RESOURCE CONFIG ====="

$WslConfigPath = Join-Path $HOME ".wslconfig"

if (Test-Path $WslConfigPath) {

    Pass ".wslconfig exists"

    Get-Content $WslConfigPath |
        ForEach-Object {
            Write-Host "  $_"
        }
}
else {
    Warn ".wslconfig does not exist"
}


#
# 7. Runtime storage path
#
Write-Host ""
Write-Host "===== 7. RUNTIME STORAGE ====="

$RuntimeRoot = Join-Path `
    $HOME `
    "WSL\LocalKubernetesLabForWindows"

Write-Host "Runtime root : $RuntimeRoot"

if (Test-Path $RuntimeRoot) {
    Pass "runtime root exists"
}
else {
    Write-Host "[INFO] runtime root will be created during setup"
}


#
# 8. Target distro collision
#
Write-Host ""
Write-Host "===== 8. TARGET DISTROS ====="

$Targets = @(
    $Config.WSL.Controller,
    $Config.WSL.Node01,
    $Config.WSL.Node02
)

foreach ($Target in $Targets) {

    if ($InstalledDistros -contains $Target) {
        Warn "target '$Target' already exists"
    }
    else {
        Pass "target '$Target' is available for creation"
    }
}


#
# 9. Required Windows commands
#
Write-Host ""
Write-Host "===== 9. REQUIRED COMMANDS ====="

foreach ($Command in @(
    "wsl.exe",
    "tar.exe",
    "curl.exe"
)) {

    $Resolved = Get-Command `
        $Command `
        -ErrorAction SilentlyContinue

    if ($null -ne $Resolved) {
        Pass "$Command available"
    }
    else {
        Fail "$Command not found"
    }
}


#
# Result
#
Write-Host ""
Write-Host "========================================"

if ($Failures.Count -eq 0) {

    Write-Host " Preflight PASSED"

    if ($Warnings.Count -gt 0) {
        Write-Host " $($Warnings.Count) warning(s)"
    }
}
else {

    Write-Host " Preflight FAILED"
    Write-Host " $($Failures.Count) failure(s)"
}

Write-Host "========================================"
Write-Host ""


if ($Warnings.Count -gt 0) {

    Write-Host "Warnings:"

    foreach ($Warning in $Warnings) {
        Write-Host " - $Warning"
    }

    Write-Host ""
}


if ($Failures.Count -gt 0) {

    Write-Host "Failures:"

    foreach ($Failure in $Failures) {
        Write-Host " - $Failure"
    }

    exit 1
}

exit 0