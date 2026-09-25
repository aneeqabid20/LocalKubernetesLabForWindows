[CmdletBinding()]
param(
    [switch]$PlanOnly,
    [switch]$PreflightOnly
)

$ErrorActionPreference = "Stop"

$Repo = (
    Resolve-Path (
        Join-Path $PSScriptRoot "..\.."
    )
).Path

$Lab = Import-PowerShellDataFile (
    Join-Path $Repo "config\lab.psd1"
)

$Software = Import-PowerShellDataFile (
    Join-Path $Repo "config\software.psd1"
)


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


function Convert-ToWslPath {
    param(
        [Parameter(Mandatory)]
        [string]$Distro,

        [Parameter(Mandatory)]
        [string]$WindowsPath
    )

    #
    # Convert standard Windows drive paths directly in PowerShell.
    #
    # Avoid passing C:\... through wsl.exe/wslpath because native
    # argument processing can strip backslashes.
    #
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
        test -f $Path

    return ($LASTEXITCODE -eq 0)
}


function Get-LinuxPid1 {
    param(
        [Parameter(Mandatory)]
        [string]$Distro
    )

    $Result = @(
        & wsl.exe `
            -d $Distro `
            -u root `
            -- `
            ps -p 1 -o comm=
    )

    if ($LASTEXITCODE -ne 0) {
        return ""
    }

    return ($Result -join "").Trim()
}


function Invoke-NodeProvision {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Node,

        [Parameter(Mandatory)]
        [string]$RepoLinux,

        [string]$ControllerPublicKeyB64 = ""
    )

    Write-Host ""
    Write-Host "========================================"
    Write-Host " Provisioning $($Node.Role)"
    Write-Host "========================================"
    Write-Host ""

    $Environment = @(
        "ROLE=$($Node.Role)",
        "NODE_HOSTNAME=$($Node.Hostname)",
        "NODE_FQDN=$($Node.FQDN)",
        "REPO_ROOT=$RepoLinux",

        "CONTROLLER_HOSTNAME=$($Lab.Nodes.Controller.Hostname)",
        "CONTROLLER_FQDN=$($Lab.Nodes.Controller.FQDN)",
        "CONTROLLER_IP=$($Lab.Nodes.Controller.IP)",

        "NODE01_HOSTNAME=$($Lab.Nodes.Node01.Hostname)",
        "NODE01_FQDN=$($Lab.Nodes.Node01.FQDN)",
        "NODE01_IP=$($Lab.Nodes.Node01.IP)",

        "NODE02_HOSTNAME=$($Lab.Nodes.Node02.Hostname)",
        "NODE02_FQDN=$($Lab.Nodes.Node02.FQDN)",
        "NODE02_IP=$($Lab.Nodes.Node02.IP)",

        "CONTAINERD_VERSION=$($Software.ContainerRuntime.ContainerdVersion)",
        "RUNC_VERSION=$($Software.ContainerRuntime.RuncVersion)",

        "KUBEADM_PACKAGE_VERSION=$($Node.KubeadmPackage)",
        "KUBELET_PACKAGE_VERSION=$($Node.KubeletPackage)",

        "K8S_REPOS=$($Node.Repositories)",
        "K8S_APT_KEY_SHA256=$($Software.Kubernetes.AptKeySha256)",

        "CRICTL_VERSION=$($Node.CrictlVersion)",
        "CRICTL_SHA256=$($Node.CrictlSha256)",

        "INSTALL_KUBECTL=$($Node.InstallKubectl)",
        "INSTALL_CILIUM_CLI=$($Node.InstallCiliumCLI)"
    )

    if ($Node.InstallKubectl -eq 1) {
        $Environment += `
            "KUBECTL_PACKAGE_VERSION=$($Software.Kubernetes.PackageVersion35)"
    }

    if ($Node.InstallCiliumCLI -eq 1) {

        $Environment += `
            "CILIUM_CLI_VERSION=$($Software.CiliumCLI.Version)"

        $Environment += `
            "CILIUM_CLI_SHA256=$($Software.CiliumCLI.Sha256)"
    }

    if ($Node.Role -ne "controller") {

        if ([string]::IsNullOrWhiteSpace($ControllerPublicKeyB64)) {
            throw "Controller SSH public key was not supplied for $($Node.Role)."
        }

        $Environment += `
            "CONTROLLER_PUBLIC_KEY_B64=$ControllerPublicKeyB64"
    }


    $Arguments = @(
        "-d",
        $Node.Distro,
        "-u",
        "root",
        "--",
        "env"
    )

    $Arguments += $Environment

    $Arguments += @(
        "/bin/bash",
        "$RepoLinux/scripts/linux/provision-node.sh"
    )


    & wsl.exe @Arguments

    if ($LASTEXITCODE -ne 0) {
        throw "Provisioning failed for $($Node.Distro)."
    }

    Write-Host ""
    Write-Host "[PASS] $($Node.Distro) provisioned"
}


#
# --------------------------------------------------------------------
# Derive repository tracks from software.psd1.
#
# Example:
#
# https://pkgs.k8s.io/core:/stable:/v1.35/deb/
#                            ^^^^^
#
# --------------------------------------------------------------------
#

$Repo35Match = [regex]::Match(
    $Software.Kubernetes.Repo35,
    'v\d+\.\d+'
)

$Repo34Match = [regex]::Match(
    $Software.Kubernetes.Repo34,
    'v\d+\.\d+'
)

if (-not $Repo35Match.Success) {
    throw "Unable to derive Kubernetes repository track from Repo35."
}

if (-not $Repo34Match.Success) {
    throw "Unable to derive Kubernetes repository track from Repo34."
}

$RepoTrack35 = $Repo35Match.Value
$RepoTrack34 = $Repo34Match.Value


#
# --------------------------------------------------------------------
# Node plan
# --------------------------------------------------------------------
#

$Nodes = @(

    @{
        Role             = "controller"
        Distro           = $Lab.WSL.Controller
        Hostname         = $Lab.Nodes.Controller.Hostname
        FQDN             = $Lab.Nodes.Controller.FQDN

        KubeadmPackage   = $Software.Kubernetes.PackageVersion35
        KubeletPackage   = $Software.Kubernetes.PackageVersion35

        Repositories     = $RepoTrack35

        CrictlVersion    = $Software.Crictl.Controller.Version
        CrictlSha256     = $Software.Crictl.Controller.Sha256

        InstallKubectl   = 1
        InstallCiliumCLI = 1
    },

    @{
        Role             = "node01"
        Distro           = $Lab.WSL.Node01
        Hostname         = $Lab.Nodes.Node01.Hostname
        FQDN             = $Lab.Nodes.Node01.FQDN

        KubeadmPackage   = $Software.Kubernetes.PackageVersion35
        KubeletPackage   = $Software.Kubernetes.PackageVersion35

        Repositories     = $RepoTrack35

        CrictlVersion    = $Software.Crictl.Node01.Version
        CrictlSha256     = $Software.Crictl.Node01.Sha256

        InstallKubectl   = 0
        InstallCiliumCLI = 0
    },

    @{
        Role             = "node02"
        Distro           = $Lab.WSL.Node02
        Hostname         = $Lab.Nodes.Node02.Hostname
        FQDN             = $Lab.Nodes.Node02.FQDN

        KubeadmPackage   = $Software.Kubernetes.PackageVersion35
        KubeletPackage   = $Software.Kubernetes.PackageVersion34

        Repositories     = "$RepoTrack34 $RepoTrack35"

        CrictlVersion    = $Software.Crictl.Node02.Version
        CrictlSha256     = $Software.Crictl.Node02.Sha256

        InstallKubectl   = 0
        InstallCiliumCLI = 0
    }
)


#
# --------------------------------------------------------------------
# Display plan
# --------------------------------------------------------------------
#

Write-Host ""
Write-Host "========================================"
Write-Host " Local Kubernetes Lab - Provision Nodes"
Write-Host "========================================"
Write-Host ""

Write-Host "Repository : $Repo"
Write-Host ""

foreach ($Node in $Nodes) {

    Write-Host "$($Node.Role):"
    Write-Host "  distro       = $($Node.Distro)"
    Write-Host "  hostname     = $($Node.Hostname)"
    Write-Host "  fqdn         = $($Node.FQDN)"
    Write-Host "  kubeadm      = $($Node.KubeadmPackage)"
    Write-Host "  kubelet      = $($Node.KubeletPackage)"
    Write-Host "  repositories = $($Node.Repositories)"
    Write-Host "  crictl       = $($Node.CrictlVersion)"
    Write-Host "  kubectl      = $($Node.InstallKubectl)"
    Write-Host "  cilium-cli   = $($Node.InstallCiliumCLI)"
    Write-Host ""
}


if ($PlanOnly) {

    Write-Host "========================================"
    Write-Host " PLAN ONLY - NO CHANGES MADE"
    Write-Host "========================================"
    Write-Host ""

    exit 0
}


#
# --------------------------------------------------------------------
# Preflight all nodes BEFORE modifying any node.
# --------------------------------------------------------------------
#

$InstalledDistros = @(Get-WslNames)
$PreflightFailures = @()


foreach ($Node in $Nodes) {

    Write-Host "[preflight] checking $($Node.Distro)"

    if ($InstalledDistros -notcontains $Node.Distro) {

        $PreflightFailures += `
            "WSL distro '$($Node.Distro)' is not installed."

        continue
    }


    $Pid1 = Get-LinuxPid1 `
        -Distro $Node.Distro

    if ($Pid1 -ne "systemd") {

        $PreflightFailures += `
            "$($Node.Distro): systemd is not PID 1."

        continue
    }


    $OsRelease = @(
        & wsl.exe `
            -d $Node.Distro `
            -u root `
            -- `
            cat /etc/os-release
    )

    $VersionLine = @(
        $OsRelease |
            Where-Object {
                $_ -match '^VERSION_ID='
            }
    )

    $VersionText = (
        $VersionLine -join ""
    ).Replace('"', '').Trim()

    if ($VersionText -ne "VERSION_ID=24.04") {

        $PreflightFailures += `
            "$($Node.Distro): expected Ubuntu VERSION_ID=24.04."

        continue
    }


    & wsl.exe `
        -d $Node.Distro `
        -u root `
        -- `
        id ubuntu `
        1>$null `
        2>$null

    if ($LASTEXITCODE -ne 0) {

        $PreflightFailures += `
            "$($Node.Distro): required user 'ubuntu' is missing."

        continue
    }


    if (
        Test-LinuxFile `
            -Distro $Node.Distro `
            -Path "/etc/kubernetes/admin.conf"
    ) {

        $PreflightFailures += `
            "$($Node.Distro): Kubernetes admin.conf already exists."

        continue
    }


    if (
        Test-LinuxFile `
            -Distro $Node.Distro `
            -Path "/etc/kubernetes/kubelet.conf"
    ) {

        $PreflightFailures += `
            "$($Node.Distro): Kubernetes kubelet.conf already exists."

        continue
    }
}


if ($PreflightFailures.Count -gt 0) {

    Write-Host ""
    Write-Host "========================================"
    Write-Host " PROVISIONING SAFETY STOP"
    Write-Host "========================================"
    Write-Host ""

    foreach ($Failure in $PreflightFailures) {
        Write-Host "[FAIL] $Failure"
    }

    Write-Host ""
    Write-Host "No node provisioning was started."
    Write-Host ""

    throw "Node provisioning preflight failed."
}


Write-Host ""
Write-Host "[PASS] all nodes passed provisioning preflight"


if ($PreflightOnly) {

    Write-Host ""
    Write-Host "========================================"
    Write-Host " PREFLIGHT ONLY - NO CHANGES MADE"
    Write-Host "========================================"
    Write-Host ""

    exit 0
}


#
# Convert repository path using the controller WSL environment.
#
$RepoLinux = Convert-ToWslPath `
    -Distro $Lab.WSL.Controller `
    -WindowsPath $Repo

Write-Host "[k8slab] repository inside WSL: $RepoLinux"


#
# --------------------------------------------------------------------
# Provision sequentially.
# --------------------------------------------------------------------
#

$ControllerNode = @(
    $Nodes |
        Where-Object {
            $_.Role -eq "controller"
        }
)[0]

Invoke-NodeProvision `
    -Node $ControllerNode `
    -RepoLinux $RepoLinux

$ControllerPublicKeyOutput = @(
    & wsl.exe `
        -d $Lab.WSL.Controller `
        -u root `
        -- `
        cat /home/ubuntu/.ssh/id_ed25519.pub
)

if ($LASTEXITCODE -ne 0) {
    throw "Unable to read controller SSH public key after provisioning."
}

$ControllerPublicKey = (
    $ControllerPublicKeyOutput -join ""
).Trim()

if ($ControllerPublicKey -notmatch '^ssh-ed25519\s+') {
    throw "Controller SSH public key is not a valid ed25519 public key."
}

$ControllerPublicKeyB64 = [Convert]::ToBase64String(
    [System.Text.Encoding]::UTF8.GetBytes($ControllerPublicKey)
)

Write-Host "[PASS] controller lab SSH key ready"

foreach ($Node in @(
    $Nodes |
        Where-Object {
            $_.Role -ne "controller"
        }
)) {

    Invoke-NodeProvision `
        -Node $Node `
        -RepoLinux $RepoLinux `
        -ControllerPublicKeyB64 $ControllerPublicKeyB64
}


#
# --------------------------------------------------------------------
# Restart boundary.
#
# /etc/wsl.conf hostname changes are guaranteed only after distro restart.
# Terminate only the three lab distros.
# --------------------------------------------------------------------
#

Write-Host ""
Write-Host "[k8slab] applying WSL restart boundary"

$StopNodes = @($Nodes)
[array]::Reverse($StopNodes)

foreach ($Node in $StopNodes) {

    Write-Host "[k8slab] terminating $($Node.Distro)"

    & wsl.exe `
        --terminate `
        $Node.Distro `
        2>$null

    if ($LASTEXITCODE -ne 0) {
        throw "Failed to terminate $($Node.Distro)."
    }
}


Write-Host ""
Write-Host "========================================"
Write-Host " Node provisioning completed"
Write-Host "========================================"
Write-Host ""
Write-Host "The three lab distros are now provisioned and stopped."
Write-Host "Use start.ps1 for ordered startup."
Write-Host ""

exit 0