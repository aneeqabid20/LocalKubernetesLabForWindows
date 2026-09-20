[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Position = 0)]
    [ValidateSet(
        "preflight",
        "setup",
        "vms",
        "provision",
        "start",
        "stop",
        "status",
        "k8s",
        "cilium",
        "verify",
        "shell",
        "ssh",
        "destroy"
    )]
    [string]$Action = "status",

    [ValidateSet("controller","node01","node02")]
    [string]$Node = "controller",

    [switch]$Root,
    [switch]$ReplaceExisting,
    [switch]$PlanOnly,
    [switch]$SkipVerify
)

$ErrorActionPreference = "Stop"

$Repo = $PSScriptRoot
$Scripts = Join-Path $Repo "scripts\windows"

function Invoke-LabScript {
    param(
        [Parameter(Mandatory)][string]$Name,
        [hashtable]$Arguments = @{}
    )

    $Path = Join-Path $Scripts $Name

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Required script not found: $Path"
    }

    & $Path @Arguments
}

switch ($Action) {
    "preflight" {
        Invoke-LabScript -Name "preflight.ps1"
    }

    "setup" {
        Invoke-LabScript -Name "setup.ps1" -Arguments @{
            PlanOnly        = $PlanOnly
            ReplaceExisting = $ReplaceExisting
            SkipVerify      = $SkipVerify
        }
    }

    "vms" {
        Invoke-LabScript -Name "create-distros.ps1" -Arguments @{
            ReplaceExisting = $ReplaceExisting
        }
    }

    "provision" {
        Invoke-LabScript -Name "provision-nodes.ps1"
    }

    "start" {
        Invoke-LabScript -Name "start.ps1"
    }

    "stop" {
        Invoke-LabScript -Name "stop.ps1"
    }

    "status" {
        Invoke-LabScript -Name "status.ps1"
    }

    "k8s" {
        Invoke-LabScript -Name "bootstrap-kubernetes.ps1" -Arguments @{
            PlanOnly = $PlanOnly
        }
    }

    "cilium" {
        Invoke-LabScript -Name "install-cilium.ps1" -Arguments @{
            PlanOnly = $PlanOnly
        }
    }

    "verify" {
        Invoke-LabScript -Name "verify.ps1"
    }

    { $_ -in @("shell","ssh") } {
        Invoke-LabScript -Name "shell.ps1" -Arguments @{
            Node = $Node
            Root = $Root
        }
    }

    "destroy" {
        $Args = @{}
        if ($WhatIfPreference) {
            $Args.WhatIf = $true
        }
        Invoke-LabScript -Name "destroy.ps1" -Arguments $Args
    }
}
