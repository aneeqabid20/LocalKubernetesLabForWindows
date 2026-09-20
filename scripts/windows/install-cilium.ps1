[CmdletBinding()]
param(
    [switch]$PlanOnly,
    [int]$NodeReadyTimeoutSeconds = 180
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

$Controller    = $Config.WSL.Controller
$CiliumVersion = $Config.Cilium.Version

$ExpectedNodes = @(
    $Config.Nodes.Controller.FQDN,
    $Config.Nodes.Node01.Hostname,
    $Config.Nodes.Node02.Hostname
)


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


Write-Host ""
Write-Host "========================================"
Write-Host " Local Kubernetes Lab - Install Cilium"
Write-Host "========================================"
Write-Host ""

Write-Host "Repository     : $Repo"
Write-Host "Controller     : $Controller"
Write-Host "Cilium version : v$CiliumVersion"
Write-Host ""

$ValuesWindows = Join-Path $Repo "kubernetes\cilium-values.yaml"

if (-not (Test-Path -LiteralPath $ValuesWindows)) {
    throw "Missing Cilium values file: $ValuesWindows"
}

$ValuesLinux = Convert-ToWslPath `
    -WindowsPath $ValuesWindows

Write-Host "Values file    : $ValuesLinux"
Write-Host ""


if ($PlanOnly) {

    Write-Host "Planned sequence:"
    Write-Host ""
    Write-Host "  1. Verify controller is running"
    Write-Host "  2. Verify Kubernetes control plane is initialized"
    Write-Host "  3. Verify exactly three Kubernetes nodes are registered"
    Write-Host "  4. Verify Cilium is not already installed"
    Write-Host "  5. Install Cilium v$CiliumVersion"
    Write-Host "  6. Apply kubernetes/cilium-values.yaml"
    Write-Host "  7. Wait for Cilium and Hubble health"
    Write-Host "  8. Wait for all three Kubernetes nodes to become Ready"
    Write-Host ""

    Write-Host "========================================"
    Write-Host " PLAN ONLY - NO CHANGES MADE"
    Write-Host "========================================"
    Write-Host ""

    exit 0
}


#
# Controller must already be running.
#
$Running = @(
    & wsl.exe --list --running --quiet 2>$null |
        ForEach-Object {
            ($_ -replace "`0", "").Trim()
        } |
        Where-Object {
            -not [string]::IsNullOrWhiteSpace($_)
        }
)

if ($Running -notcontains $Controller) {
    throw "Controller '$Controller' is not running. Run start.ps1 first."
}


#
# Kubernetes must already be initialized.
#
if (-not (
    Test-LinuxFile `
        -Distro $Controller `
        -Path "/etc/kubernetes/admin.conf"
)) {
    throw "Kubernetes is not initialized on $Controller."
}


#
# Cilium CLI must exist.
#
& wsl.exe `
    -d $Controller `
    -- `
    test -x /usr/local/bin/cilium

if ($LASTEXITCODE -ne 0) {
    throw "Cilium CLI is not installed on $Controller."
}


#
# Verify Kubernetes API access.
#
& wsl.exe `
    -d $Controller `
    -u root `
    -- `
    env KUBECONFIG=/etc/kubernetes/admin.conf `
    kubectl get nodes `
    -o name

if ($LASTEXITCODE -ne 0) {
    throw "Unable to access the Kubernetes API."
}


#
# Verify the expected three nodes are registered.
#
$RegisteredNodes = @(
    & wsl.exe `
        -d $Controller `
        -u root `
        -- `
        env KUBECONFIG=/etc/kubernetes/admin.conf `
        kubectl get nodes `
        -o custom-columns=NAME:.metadata.name `
        --no-headers
) |
    ForEach-Object {
        $_.Trim()
    } |
    Where-Object {
        -not [string]::IsNullOrWhiteSpace($_)
    }

if ($RegisteredNodes.Count -ne 3) {
    throw "Expected 3 Kubernetes nodes but found $($RegisteredNodes.Count)."
}

foreach ($ExpectedNode in $ExpectedNodes) {

    if ($RegisteredNodes -notcontains $ExpectedNode) {
        throw "Expected Kubernetes node '$ExpectedNode' is not registered."
    }
}

Write-Host "[PASS] all three Kubernetes nodes are registered"


#
# Refuse to overwrite an existing Cilium installation.
#
$ExistingCilium = @(
    & wsl.exe `
        -d $Controller `
        -u root `
        -- `
        env KUBECONFIG=/etc/kubernetes/admin.conf `
        kubectl -n kube-system `
        get daemonset cilium `
        --ignore-not-found `
        -o name
)

if ($LASTEXITCODE -ne 0) {
    throw "Unable to check for an existing Cilium installation."
}

$ExistingCilium = @(
    $ExistingCilium |
        ForEach-Object {
            $_.Trim()
        } |
        Where-Object {
            -not [string]::IsNullOrWhiteSpace($_)
        }
)

if ($ExistingCilium.Count -gt 0) {
    throw "Cilium already appears to be installed. Refusing duplicate installation."
}

Write-Host "[PASS] Cilium is not currently installed"


#
# Install Cilium.
#
Write-Host ""
Write-Host "========================================"
Write-Host " Installing Cilium v$CiliumVersion"
Write-Host "========================================"
Write-Host ""

& wsl.exe `
    -d $Controller `
    -u root `
    -- `
    cilium install `
    --version "v$CiliumVersion" `
    --values $ValuesLinux `
    --kubeconfig /etc/kubernetes/admin.conf `
    --wait `
    --wait-duration 5m0s

if ($LASTEXITCODE -ne 0) {
    throw "Cilium installation failed."
}


#
# Wait for Cilium/Hubble health.
#
Write-Host ""
Write-Host "[k8slab] waiting for Cilium and Hubble..."

& wsl.exe `
    -d $Controller `
    -u root `
    -- `
    cilium status `
    --kubeconfig /etc/kubernetes/admin.conf `
    --wait

if ($LASTEXITCODE -ne 0) {
    throw "Cilium did not become healthy."
}


#
# Wait for all Kubernetes nodes.
#
Write-Host ""
Write-Host "[k8slab] waiting for all Kubernetes nodes to become Ready..."

& wsl.exe `
    -d $Controller `
    -u root `
    -- `
    env KUBECONFIG=/etc/kubernetes/admin.conf `
    kubectl wait `
    --for=condition=Ready `
    nodes `
    --all `
    "--timeout=${NodeReadyTimeoutSeconds}s"

if ($LASTEXITCODE -ne 0) {
    throw "Not all Kubernetes nodes became Ready."
}


#
# Final state.
#
Write-Host ""
Write-Host "========================================"
Write-Host " Kubernetes nodes"
Write-Host "========================================"
Write-Host ""

& wsl.exe `
    -d $Controller `
    -u root `
    -- `
    env KUBECONFIG=/etc/kubernetes/admin.conf `
    kubectl get nodes -o wide

if ($LASTEXITCODE -ne 0) {
    throw "Unable to display Kubernetes nodes."
}


Write-Host ""
Write-Host "========================================"
Write-Host " Cilium status"
Write-Host "========================================"
Write-Host ""

& wsl.exe `
    -d $Controller `
    -u root `
    -- `
    cilium status `
    --kubeconfig /etc/kubernetes/admin.conf

if ($LASTEXITCODE -ne 0) {
    throw "Unable to retrieve final Cilium status."
}

Write-Host ""
Write-Host "[PASS] Cilium v$CiliumVersion installed and healthy"
Write-Host "[PASS] all three Kubernetes nodes are Ready"
Write-Host ""
Write-Host "========================================"
Write-Host " Cilium installation completed"
Write-Host "========================================"
Write-Host ""