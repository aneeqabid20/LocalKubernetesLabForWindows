[CmdletBinding()]
param(
    [int]$TimeoutSeconds = 30
)

$ErrorActionPreference = "Stop"

$Repo = (
    Resolve-Path (
        Join-Path $PSScriptRoot "..\.."
    )
).Path

$ConfigPath = Join-Path $Repo "config\lab.psd1"
$RuntimeDir = Join-Path $Repo "artifacts\runtime"

$Config = Import-PowerShellDataFile $ConfigPath

$Controller = $Config.WSL.Controller
$Node01 = $Config.WSL.Node01
$Node02 = $Config.WSL.Node02


function Get-RunningWslDistros {
    $Names = @(
        & wsl.exe --list --running --quiet 2>$null |
            ForEach-Object {
                ($_ -replace "`0", "").Trim()
            } |
            Where-Object {
                -not [string]::IsNullOrWhiteSpace($_)
            }
    )

    return $Names
}


function Test-DistroRunning {
    param(
        [Parameter(Mandatory)]
        [string]$Distro
    )

    $Running = @(Get-RunningWslDistros)

    return ($Running -contains $Distro)
}


function Stop-LabDistro {
    param(
        [Parameter(Mandatory)]
        [string]$Distro
    )

    if (-not (Test-DistroRunning -Distro $Distro)) {
        Write-Host "[k8slab] $Distro is already stopped"
        return
    }

    Write-Host "[k8slab] stopping $Distro"

    & wsl.exe --terminate $Distro

    if ($LASTEXITCODE -ne 0) {
        throw "Failed to terminate WSL distro '$Distro'."
    }

    $Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    while ($Stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {

        if (-not (Test-DistroRunning -Distro $Distro)) {
            Write-Host "[k8slab] stopped: $Distro"
            return
        }

        Start-Sleep -Seconds 1
    }

    throw "Timeout waiting for '$Distro' to stop."
}


function Remove-KeepAlivePidFile {
    param(
        [Parameter(Mandatory)]
        [string]$Distro
    )

    $PidFile = Join-Path $RuntimeDir "$Distro.pid"

    if (Test-Path $PidFile) {
        Remove-Item $PidFile -Force
    }
}


try {
    Write-Host ""
    Write-Host "========================================"
    Write-Host " Local Kubernetes Lab - Stop"
    Write-Host "========================================"
    Write-Host ""

    #
    # Stop workers before the controller.
    #
    Stop-LabDistro -Distro $Node02
    Remove-KeepAlivePidFile -Distro $Node02

    Stop-LabDistro -Distro $Node01
    Remove-KeepAlivePidFile -Distro $Node01

    Stop-LabDistro -Distro $Controller
    Remove-KeepAlivePidFile -Distro $Controller

    Write-Host ""
    Write-Host "===== WSL STATUS ====="

    & wsl.exe --list --verbose

    Write-Host ""
    Write-Host "========================================"
    Write-Host " K8sLab stopped successfully"
    Write-Host "========================================"
    Write-Host ""
}
catch {
    Write-Host ""
    Write-Host "========================================"
    Write-Host " K8sLab stop FAILED"
    Write-Host "========================================"
    Write-Host ""

    Write-Error $_.Exception.Message
    exit 1
}