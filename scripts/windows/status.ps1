[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$Repo = (
    Resolve-Path (
        Join-Path $PSScriptRoot "..\.."
    )
).Path

$ConfigPath = Join-Path $Repo "config\lab.psd1"
$Config = Import-PowerShellDataFile $ConfigPath

$Controller = $Config.WSL.Controller
$Node01 = $Config.WSL.Node01
$Node02 = $Config.WSL.Node02


function Get-WslNames {
    param(
        [switch]$RunningOnly
    )

    if ($RunningOnly) {
        $Output = & wsl.exe --list --running --quiet 2>$null
    }
    else {
        $Output = & wsl.exe --list --quiet 2>$null
    }

    return @(
        $Output |
            ForEach-Object {
                ($_ -replace "`0", "").Trim()
            } |
            Where-Object {
                -not [string]::IsNullOrWhiteSpace($_)
            }
    )
}


function Test-DistroRunning {
    param(
        [Parameter(Mandatory)]
        [string]$Distro
    )

    $Running = @(Get-WslNames -RunningOnly)
    return ($Running -contains $Distro)
}


function Get-ServiceState {
    param(
        [Parameter(Mandatory)]
        [string]$Distro,

        [Parameter(Mandatory)]
        [string]$Service
    )

    if (-not (Test-DistroRunning -Distro $Distro)) {
        return "n/a"
    }

    $Result = & wsl.exe `
        -d $Distro `
        -u root `
        -- `
        systemctl is-active $Service `
        2>$null

    if ($null -eq $Result) {
        return "unknown"
    }

    return (($Result -join "").Trim())
}


function Show-DistroStatus {
    param(
        [Parameter(Mandatory)]
        [string]$Distro,

        [Parameter(Mandatory)]
        [string[]]$Services
    )

    $Running = Test-DistroRunning -Distro $Distro

    if ($Running) {
        Write-Host "$Distro : RUNNING"
    }
    else {
        Write-Host "$Distro : STOPPED"
        return
    }

    foreach ($Service in $Services) {
        $State = Get-ServiceState `
            -Distro $Distro `
            -Service $Service

        Write-Host "  $Service : $State"
    }
}


Write-Host ""
Write-Host "========================================"
Write-Host " Local Kubernetes Lab - Status"
Write-Host "========================================"
Write-Host ""

$Installed = @(Get-WslNames)

foreach ($Required in @($Controller, $Node01, $Node02)) {
    if ($Installed -notcontains $Required) {
        Write-Host "$Required : NOT INSTALLED"
    }
}

Write-Host "===== WSL NODES ====="

Show-DistroStatus `
    -Distro $Controller `
    -Services @(
        "k8slab-controller-network.service",
        "containerd.service",
        "kubelet.service"
    )

Show-DistroStatus `
    -Distro $Node01 `
    -Services @(
        "k8slab-netns.service",
        "containerd.service",
        "kubelet.service"
    )

Show-DistroStatus `
    -Distro $Node02 `
    -Services @(
        "k8slab-netns.service",
        "containerd.service",
        "kubelet.service"
    )


#
# Do not issue a WSL command against the controller unless
# it is already running. Otherwise status.ps1 would start it.
#
if (Test-DistroRunning -Distro $Controller) {

    Write-Host ""
    Write-Host "===== CONTROLLER NETWORK ====="

    & wsl.exe `
        -d $Controller `
        -u root `
        -- `
        ip -br -4 addr show $Config.Network.Bridge `
        2>$null

    Write-Host ""
    Write-Host "===== INOTIFY ====="

    & wsl.exe `
        -d $Controller `
        -u root `
        -- `
        sysctl fs.inotify.max_user_instances `
        2>$null


    & wsl.exe `
        -d $Controller `
        -u root `
        -- `
        test -f /etc/kubernetes/admin.conf `
        2>$null

    $ClusterInitialized = ($LASTEXITCODE -eq 0)

    if ($ClusterInitialized) {

        Write-Host ""
        Write-Host "===== KUBERNETES NODES ====="

        & wsl.exe `
            -d $Controller `
            -u root `
            -- `
            env KUBECONFIG=/etc/kubernetes/admin.conf `
            kubectl get nodes -o wide

        Write-Host ""
        Write-Host "===== CILIUM ====="

        & wsl.exe `
            -d $Controller `
            -u root `
            -- `
            env KUBECONFIG=/etc/kubernetes/admin.conf `
            cilium status
    }
    else {
        Write-Host ""
        Write-Host "Kubernetes cluster is not initialized."
    }
}
else {
    Write-Host ""
    Write-Host "Kubernetes status skipped because controller is stopped."
}

Write-Host ""
Write-Host "========================================"
Write-Host " Status check complete"
Write-Host "========================================"
Write-Host ""