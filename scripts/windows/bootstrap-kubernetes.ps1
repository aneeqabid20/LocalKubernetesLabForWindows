[CmdletBinding()]
param(
    [switch]$PlanOnly
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

$Controller = $Config.WSL.Controller
$Node01     = $Config.WSL.Node01
$Node02     = $Config.WSL.Node02

$ControllerHostname = $Config.Nodes.Controller.Hostname
$ControllerFqdn     = $Config.Nodes.Controller.FQDN

$Node01Hostname = $Config.Nodes.Node01.Hostname
$Node02Hostname = $Config.Nodes.Node02.Hostname

#
# The persistent worker namespace name follows the node hostname.
#
$Node01Namespace = "$Node01Hostname-ns"
$Node02Namespace = "$Node02Hostname-ns"


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


function Get-RunningWslNames {

    return @(
        & wsl.exe --list --running --quiet 2>$null |
            ForEach-Object {
                ($_ -replace "`0", "").Trim()
            } |
            Where-Object {
                -not [string]::IsNullOrWhiteSpace($_)
            }
    )
}


function Convert-ToWslPath {
    param(
        [Parameter(Mandatory)]
        [string]$WindowsPath
    )

    $FullPath = [System.IO.Path]::GetFullPath($WindowsPath)

    if ($FullPath -match '^([A-Za-z]):\\(.*)$') {

        $Drive = $Matches[1].ToLowerInvariant()
        $Rest  = $Matches[2] -replace '\\', '/'

        return "/mnt/$Drive/$Rest"
    }

    throw "Unsupported Windows path format: '$WindowsPath'."
}


function Test-LinuxFile {
    param(
        [Parameter(Mandatory)]
        [string]$Distro,

        [Parameter(Mandatory)]
        [string]$Path
    )

    & wsl.exe `
        -d $Distro `
        -u root `
        -- `
        test -f $Path `
        2>$null

    return ($LASTEXITCODE -eq 0)
}


function Assert-ServiceActive {
    param(
        [Parameter(Mandatory)]
        [string]$Distro,

        [Parameter(Mandatory)]
        [string]$Service
    )

    & wsl.exe `
        -d $Distro `
        -u root `
        -- `
        systemctl is-active --quiet $Service

    if ($LASTEXITCODE -ne 0) {
        throw "$Distro / $Service is not active."
    }
}


function Assert-NetworkNamespace {
    param(
        [Parameter(Mandatory)]
        [string]$Distro,

        [Parameter(Mandatory)]
        [string]$Namespace
    )

    & wsl.exe `
        -d $Distro `
        -u root `
        -- `
        test -e "/run/netns/$Namespace"

    if ($LASTEXITCODE -ne 0) {
        throw "$Distro network namespace '$Namespace' does not exist."
    }
}


function Join-Worker {
    param(
        [Parameter(Mandatory)]
        [string]$Distro,

        [Parameter(Mandatory)]
        [string]$Namespace,

        [Parameter(Mandatory)]
        [string]$Hostname,

        [Parameter(Mandatory)]
        [string[]]$JoinArguments
    )

    Write-Host ""
    Write-Host "========================================"
    Write-Host " Joining $Hostname"
    Write-Host "========================================"
    Write-Host ""

    #
    # IMPORTANT:
    #
    # kubeadm join itself must execute inside the worker's dedicated
    # Linux network namespace.
    #
    & wsl.exe `
        -d $Distro `
        -u root `
        -- `
        nsenter "--net=/run/netns/$Namespace" `
        kubeadm join @JoinArguments

    if ($LASTEXITCODE -ne 0) {
        throw "kubeadm join failed for $Hostname."
    }

    if (-not (Test-LinuxFile -Distro $Distro -Path "/etc/kubernetes/kubelet.conf")) {
        throw "$Hostname joined but /etc/kubernetes/kubelet.conf was not created."
    }

    Assert-ServiceActive `
        -Distro $Distro `
        -Service "kubelet.service"

    Write-Host "[PASS] $Hostname joined successfully"
}


Write-Host ""
Write-Host "========================================"
Write-Host " Local Kubernetes Lab - Bootstrap"
Write-Host "========================================"
Write-Host ""

Write-Host "Repository        : $Repo"
Write-Host "Controller distro : $Controller"
Write-Host "Controller node   : $ControllerFqdn"
Write-Host "Node01 distro     : $Node01"
Write-Host "Node01 node       : $Node01Hostname"
Write-Host "Node01 namespace  : $Node01Namespace"
Write-Host "Node02 distro     : $Node02"
Write-Host "Node02 node       : $Node02Hostname"
Write-Host "Node02 namespace  : $Node02Namespace"
Write-Host ""

if ($PlanOnly) {

    Write-Host "Planned sequence:"
    Write-Host ""
    Write-Host "  1. Validate all three WSL nodes are running"
    Write-Host "  2. Validate networking and containerd"
    Write-Host "  3. kubeadm init on $ControllerFqdn"
    Write-Host "  4. Create /home/ubuntu/.kube/config"
    Write-Host "  5. Generate worker join token"
    Write-Host "  6. nsenter kubeadm join -> $Node01Hostname"
    Write-Host "  7. nsenter kubeadm join -> $Node02Hostname"
    Write-Host "  8. Verify three Kubernetes node registrations"
    Write-Host ""
    Write-Host "Cilium is intentionally NOT installed by this script."
    Write-Host ""

    Write-Host "========================================"
    Write-Host " PLAN ONLY - NO CHANGES MADE"
    Write-Host "========================================"
    Write-Host ""

    exit 0
}


#
# WSL runtime preflight.
#
$Installed = Get-WslNames
$Running   = Get-RunningWslNames

foreach ($Distro in @(
    $Controller,
    $Node01,
    $Node02
)) {

    if ($Installed -notcontains $Distro) {
        throw "Required WSL distro '$Distro' is not installed."
    }

    if ($Running -notcontains $Distro) {
        throw "Required WSL distro '$Distro' is not running. Run start.ps1 first."
    }
}


#
# Infrastructure preflight.
#
Assert-ServiceActive `
    -Distro $Controller `
    -Service "k8slab-controller-network.service"

Assert-ServiceActive `
    -Distro $Controller `
    -Service "containerd.service"

Assert-ServiceActive `
    -Distro $Node01 `
    -Service "k8slab-netns.service"

Assert-ServiceActive `
    -Distro $Node01 `
    -Service "containerd.service"

Assert-ServiceActive `
    -Distro $Node02 `
    -Service "k8slab-netns.service"

Assert-ServiceActive `
    -Distro $Node02 `
    -Service "containerd.service"

Assert-NetworkNamespace `
    -Distro $Node01 `
    -Namespace $Node01Namespace

Assert-NetworkNamespace `
    -Distro $Node02 `
    -Namespace $Node02Namespace


#
# Refuse an already initialized or partially initialized cluster.
#
if (Test-LinuxFile -Distro $Controller -Path "/etc/kubernetes/admin.conf") {
    throw "Controller is already initialized. Refusing to run kubeadm init again."
}

foreach ($Worker in @(
    @{
        Distro   = $Node01
        Hostname = $Node01Hostname
    },
    @{
        Distro   = $Node02
        Hostname = $Node02Hostname
    }
)) {

    if (Test-LinuxFile -Distro $Worker.Distro -Path "/etc/kubernetes/kubelet.conf") {
        throw "$($Worker.Hostname) already contains kubelet.conf. Refusing a duplicate join."
    }
}


#
# Locate the kubeadm configuration.
#
$KubeadmConfigWindows = Join-Path $Repo "kubernetes\kubeadm-init.yaml"

if (-not (Test-Path -LiteralPath $KubeadmConfigWindows)) {
    throw "Missing kubeadm configuration: $KubeadmConfigWindows"
}

$KubeadmConfigLinux = Convert-ToWslPath `
    -WindowsPath $KubeadmConfigWindows

Write-Host "[k8slab] kubeadm config: $KubeadmConfigLinux"


#
# Initialize controller.
#
Write-Host ""
Write-Host "========================================"
Write-Host " Initializing controller"
Write-Host "========================================"
Write-Host ""

& wsl.exe `
    -d $Controller `
    -u root `
    -- `
    kubeadm init `
    --config $KubeadmConfigLinux

if ($LASTEXITCODE -ne 0) {
    throw "kubeadm init failed."
}

if (-not (Test-LinuxFile -Distro $Controller -Path "/etc/kubernetes/admin.conf")) {
    throw "kubeadm init completed but admin.conf was not created."
}

Assert-ServiceActive `
    -Distro $Controller `
    -Service "kubelet.service"

Write-Host "[PASS] controller initialized"


#
# Configure kubectl for the default ubuntu user.
#
& wsl.exe `
    -d $Controller `
    -u root `
    -- `
    mkdir -p /home/ubuntu/.kube

if ($LASTEXITCODE -ne 0) {
    throw "Unable to create /home/ubuntu/.kube."
}

& wsl.exe `
    -d $Controller `
    -u root `
    -- `
    cp /etc/kubernetes/admin.conf /home/ubuntu/.kube/config

if ($LASTEXITCODE -ne 0) {
    throw "Unable to copy admin.conf."
}

& wsl.exe `
    -d $Controller `
    -u root `
    -- `
    chown -R ubuntu:ubuntu /home/ubuntu/.kube

if ($LASTEXITCODE -ne 0) {
    throw "Unable to set ownership on /home/ubuntu/.kube."
}


#
# Generate one join command.
#
$JoinOutput = @(
    & wsl.exe `
        -d $Controller `
        -u root `
        -- `
        kubeadm token create --print-join-command
)

if ($LASTEXITCODE -ne 0) {
    throw "Unable to generate kubeadm worker join command."
}

$JoinCommand = ($JoinOutput -join " ").Trim()

if ($JoinCommand -notmatch '^kubeadm\s+join\s+') {
    throw "Unexpected kubeadm join command format."
}

$JoinArgumentText = (
    $JoinCommand -replace '^kubeadm\s+join\s+', ''
).Trim()

$JoinArguments = @(
    $JoinArgumentText -split '\s+'
)

if ($JoinArguments.Count -lt 5) {
    throw "Parsed kubeadm join argument list is unexpectedly short."
}


#
# Join workers.
#
Join-Worker `
    -Distro $Node01 `
    -Namespace $Node01Namespace `
    -Hostname $Node01Hostname `
    -JoinArguments $JoinArguments

Join-Worker `
    -Distro $Node02 `
    -Namespace $Node02Namespace `
    -Hostname $Node02Hostname `
    -JoinArguments $JoinArguments


#
# Registration verification.
#
Write-Host ""
Write-Host "========================================"
Write-Host " Kubernetes nodes"
Write-Host "========================================"
Write-Host ""

& wsl.exe `
    -d $Controller `
    -- `
    kubectl get nodes -o wide

if ($LASTEXITCODE -ne 0) {
    throw "kubectl get nodes failed."
}

$NodeCount = (
    & wsl.exe `
        -d $Controller `
        -- `
        kubectl get nodes `
        --no-headers `
        -o name
).Count

if ($LASTEXITCODE -ne 0) {
    throw "Unable to count Kubernetes nodes."
}

if ($NodeCount -ne 3) {
    throw "Expected 3 Kubernetes nodes but found $NodeCount."
}

Write-Host ""
Write-Host "[PASS] all three Kubernetes nodes are registered"
Write-Host ""
Write-Host "Nodes may remain NotReady until Cilium is installed."
Write-Host ""
Write-Host "========================================"
Write-Host " Kubernetes bootstrap completed"
Write-Host "========================================"
Write-Host ""