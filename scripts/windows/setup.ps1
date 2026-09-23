[CmdletBinding()]
param(
    [string]$SourceDistro = "Ubuntu-24.04",

    [string]$RuntimeRoot = (
        Join-Path $HOME "WSL\LocalKubernetesLabForWindows"
    ),

    [switch]$ReplaceExisting,
    [switch]$SkipVerify,
    [switch]$SkipKubernetes,
    [switch]$PlanOnly
)

$ErrorActionPreference = "Stop"

$Repo = (
    Resolve-Path (
        Join-Path $PSScriptRoot "..\.."
    )
).Path

$ScriptsDir = Join-Path $Repo "scripts\windows"

$PreflightScript = Join-Path $ScriptsDir "preflight.ps1"
$CreateScript    = Join-Path $ScriptsDir "create-distros.ps1"
$ProvisionScript = Join-Path $ScriptsDir "provision-nodes.ps1"
$StartScript     = Join-Path $ScriptsDir "start.ps1"
$BootstrapScript = Join-Path $ScriptsDir "bootstrap-kubernetes.ps1"
$CiliumScript    = Join-Path $ScriptsDir "install-cilium.ps1"
$VerifyScript    = Join-Path $ScriptsDir "verify.ps1"

function Write-Step {
    param(
        [Parameter(Mandatory)][int]$Number,
        [Parameter(Mandatory)][string]$Title
    )

    Write-Host ""
    Write-Host "========================================"
    Write-Host " Step $Number - $Title"
    Write-Host "========================================"
    Write-Host ""
}

$RequiredScripts = @(
    $PreflightScript,
    $CreateScript,
    $ProvisionScript,
    $StartScript,
    $BootstrapScript,
    $CiliumScript,
    $VerifyScript
)

foreach ($Script in $RequiredScripts) {
    if (-not (Test-Path -LiteralPath $Script)) {
        throw "Required script not found: $Script"
    }
}

Write-Host ""
Write-Host "========================================"
Write-Host " Local Kubernetes Lab - Setup"
Write-Host "========================================"
Write-Host ""

Write-Host "Repository    : $Repo"
Write-Host "Source distro : $SourceDistro"
Write-Host "Runtime root  : $RuntimeRoot"
Write-Host "Replace       : $ReplaceExisting"
Write-Host "Verify        : $(-not $SkipVerify -and -not $SkipKubernetes)"
Write-Host "Kubernetes    : $(-not $SkipKubernetes)"
Write-Host ""

if ($PlanOnly) {

    Write-Host "===== SETUP PLAN ====="
    Write-Host ""

    Write-Host "1. Run host/source preflight checks"

    if ($ReplaceExisting) {
        Write-Host "2. Recreate the three configured WSL lab distros"
    }
    else {
        Write-Host "2. Create the three configured WSL lab distros"
    }

    Write-Host "3. Provision containerd, Kubernetes packages, node configuration and persistence"
    Write-Host "4. Start controller/worker WSL infrastructure"

    if ($SkipKubernetes) {
        Write-Host "5. Skip Kubernetes cluster bootstrap"
        Write-Host "6. Skip Cilium and Hubble"
        Write-Host "7. Skip Kubernetes functional verification"
    }
    else {
        Write-Host "5. Initialize Kubernetes and join both workers"
        Write-Host "6. Install Cilium and Hubble"

        if ($SkipVerify) {
            Write-Host "7. Skip functional verification"
        }
        else {
            Write-Host "7. Run full functional verification"
        }
    }

    Write-Host ""
    Write-Host "No changes were made."
    return
}

Write-Step -Number 1 -Title "Preflight"
& $PreflightScript -SourceDistro $SourceDistro

Write-Step -Number 2 -Title "Create WSL Distros"

$CreateArguments = @{
    SourceDistro = $SourceDistro
    RuntimeRoot  = $RuntimeRoot
}

if ($ReplaceExisting) {
    $CreateArguments.ReplaceExisting = $true
}

& $CreateScript @CreateArguments

Write-Step -Number 3 -Title "Provision Nodes"
& $ProvisionScript

Write-Step -Number 4 -Title "Start WSL Infrastructure"
& $StartScript -SkipKubernetesWait

if ($SkipKubernetes) {

    Write-Host ""
    Write-Host "========================================"
    Write-Host " Infrastructure setup completed"
    Write-Host " Kubernetes bootstrap was skipped"
    Write-Host "========================================"
    Write-Host ""
    return
}

Write-Step -Number 5 -Title "Bootstrap Kubernetes"
& $BootstrapScript

Write-Step -Number 6 -Title "Install Cilium"
& $CiliumScript

if (-not $SkipVerify) {

    Write-Step -Number 7 -Title "Verify Cluster"
    & $VerifyScript
}
else {

    Write-Step -Number 7 -Title "Verification Skipped"
    Write-Host "[k8slab] verification skipped by request"
}

Write-Host ""
Write-Host "========================================"
Write-Host " K8sLab setup completed successfully"
Write-Host "========================================"
Write-Host ""