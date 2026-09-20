[CmdletBinding()]
param(
    [ValidateSet(
        "controller",
        "node01",
        "node02"
    )]
    [string]$Node = "controller",

    [switch]$Root
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


switch ($Node) {

    "controller" {
        $Distro = $Config.WSL.Controller
        $Namespace = $null
    }

    "node01" {
        $Distro = $Config.WSL.Node01
        $Namespace = $Config.Nodes.Node01.Namespace
    }

    "node02" {
        $Distro = $Config.WSL.Node02
        $Namespace = $Config.Nodes.Node02.Namespace
    }
}


$Installed = @(
    & wsl.exe --list --quiet 2>$null |
        ForEach-Object {
            ($_ -replace "`0", "").Trim()
        } |
        Where-Object {
            -not [string]::IsNullOrWhiteSpace($_)
        }
)

if ($Installed -notcontains $Distro) {
    throw "WSL distro '$Distro' is not installed."
}


$Running = @(
    & wsl.exe --list --running --quiet 2>$null |
        ForEach-Object {
            ($_ -replace "`0", "").Trim()
        } |
        Where-Object {
            -not [string]::IsNullOrWhiteSpace($_)
        }
)

if ($Running -notcontains $Distro) {
    throw "WSL distro '$Distro' is not running. Run start.ps1 first."
}


Write-Host ""
Write-Host "========================================"
Write-Host " Local Kubernetes Lab - Node Shell"
Write-Host "========================================"
Write-Host ""

Write-Host "Node   : $Node"
Write-Host "Distro : $Distro"

if ($Namespace) {
    Write-Host "NetNS  : $Namespace"
}
else {
    Write-Host "NetNS  : default/controller"
}

Write-Host ""


if ($null -eq $Namespace) {

    if ($Root) {
        & wsl.exe -d $Distro -u root
    }
    else {
        & wsl.exe -d $Distro
    }

    exit $LASTEXITCODE
}


#
# Worker nodes use a dedicated Linux network namespace.
# Enter that namespace before launching the interactive shell.
#

& wsl.exe `
    -d $Distro `
    -u root `
    -- `
    test -e "/run/netns/$Namespace"

if ($LASTEXITCODE -ne 0) {
    throw "Worker network namespace '$Namespace' does not exist. Run start.ps1 first."
}


if ($Root) {

    & wsl.exe `
        -d $Distro `
        -u root `
        -- `
        nsenter `
        "--net=/run/netns/$Namespace" `
        bash -l
}
else {

    & wsl.exe `
        -d $Distro `
        -u root `
        -- `
        nsenter `
        "--net=/run/netns/$Namespace" `
        sudo -u ubuntu `
        -- `
        bash -l
}

exit $LASTEXITCODE