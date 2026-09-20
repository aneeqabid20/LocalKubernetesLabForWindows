[CmdletBinding(
    SupportsShouldProcess = $true,
    ConfirmImpact = "High"
)]
param(
    [string]$RuntimeRoot = (
        Join-Path $HOME "WSL\LocalKubernetesLabForWindows"
    ),

    [string]$SourceDistro = "Ubuntu-24.04"
)

$ErrorActionPreference = "Stop"

$Repo = (
    Resolve-Path (
        Join-Path $PSScriptRoot "..\.."
    )
).Path

$ConfigPath = Join-Path $Repo "config\lab.psd1"
$RuntimeStateDir = Join-Path $Repo "artifacts\runtime"

$Config = Import-PowerShellDataFile $ConfigPath

$Controller = $Config.WSL.Controller
$Node01 = $Config.WSL.Node01
$Node02 = $Config.WSL.Node02


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


function Invoke-WslCommand {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    & wsl.exe @Arguments

    if ($LASTEXITCODE -ne 0) {
        throw "wsl.exe failed: $($Arguments -join ' ')"
    }
}


$TargetNames = @(
    $Controller,
    $Node01,
    $Node02
)

#
# Safety validation
#

if (
    $TargetNames |
        Where-Object {
            [string]::IsNullOrWhiteSpace($_)
        }
) {
    throw "One or more configured WSL distro names are empty."
}


if (
    (@($TargetNames | Select-Object -Unique)).Count -ne
    $TargetNames.Count
) {
    throw "Configured WSL distro names must be unique."
}


if ($TargetNames -contains $SourceDistro) {
    throw "SAFETY STOP: source distro '$SourceDistro' is configured as a lab target."
}


$RuntimeFull = (
    [System.IO.Path]::GetFullPath($RuntimeRoot)
).TrimEnd('\')

$HomeFull = (
    [System.IO.Path]::GetFullPath($HOME)
).TrimEnd('\')

$WslParentFull = (
    [System.IO.Path]::GetFullPath(
        (Join-Path $HOME "WSL")
    )
).TrimEnd('\')

$RepoFull = (
    [System.IO.Path]::GetFullPath($Repo)
).TrimEnd('\')

$DriveRoot = (
    [System.IO.Path]::GetPathRoot($RuntimeFull)
).TrimEnd('\')


if (
    $RuntimeFull -eq $HomeFull -or
    $RuntimeFull -eq $WslParentFull -or
    $RuntimeFull -eq $RepoFull -or
    $RuntimeFull -eq $DriveRoot
) {
    throw "SAFETY STOP: unsafe RuntimeRoot '$RuntimeFull'."
}


$Targets = @(
    @{
        Name = $Node02
        Path = Join-Path $RuntimeFull $Node02
    },
    @{
        Name = $Node01
        Path = Join-Path $RuntimeFull $Node01
    },
    @{
        Name = $Controller
        Path = Join-Path $RuntimeFull $Controller
    }
)


Write-Host ""
Write-Host "========================================"
Write-Host " Local Kubernetes Lab - Destroy"
Write-Host "========================================"
Write-Host ""

Write-Host "Runtime root : $RuntimeFull"
Write-Host "Source distro: $SourceDistro"
Write-Host ""

Write-Host "Lab distros:"
foreach ($Target in $Targets) {
    Write-Host "  $($Target.Name)"
}

Write-Host ""


foreach ($Target in $Targets) {

    $Installed = @(Get-WslNames)

    if ($Installed -contains $Target.Name) {

        if (
            $PSCmdlet.ShouldProcess(
                $Target.Name,
                "Permanently unregister WSL distro"
            )
        ) {

            $Running = @(Get-RunningWslNames)

            if ($Running -contains $Target.Name) {

                Write-Host "[k8slab] stopping $($Target.Name)"

                Invoke-WslCommand `
                    -Arguments @(
                        "--terminate",
                        $Target.Name
                    )
            }


            Write-Host "[k8slab] unregistering $($Target.Name)"

            Invoke-WslCommand `
                -Arguments @(
                    "--unregister",
                    $Target.Name
                )
        }
    }
    else {
        Write-Host "[k8slab] distro not installed: $($Target.Name)"
    }


    if (Test-Path -LiteralPath $Target.Path) {

        $TargetFull = (
            [System.IO.Path]::GetFullPath($Target.Path)
        ).TrimEnd('\')

        $TargetParent = (
            [System.IO.Directory]::GetParent($TargetFull)
        ).FullName.TrimEnd('\')

        if ($TargetParent -ne $RuntimeFull) {
            throw "SAFETY STOP: runtime target escaped RuntimeRoot: $TargetFull"
        }


        if (
            $PSCmdlet.ShouldProcess(
                $TargetFull,
                "Delete lab runtime directory"
            )
        ) {

            Write-Host "[k8slab] removing runtime: $TargetFull"

            Remove-Item `
                -LiteralPath $TargetFull `
                -Recurse `
                -Force
        }
    }


    $PidFile = Join-Path `
        $RuntimeStateDir `
        "$($Target.Name).pid"

    if (
        (Test-Path -LiteralPath $PidFile) -and
        $PSCmdlet.ShouldProcess(
            $PidFile,
            "Delete stale keepalive PID file"
        )
    ) {

        Remove-Item `
            -LiteralPath $PidFile `
            -Force
    }
}


#
# Remove RuntimeRoot only when nothing remains inside it.
#

if (Test-Path -LiteralPath $RuntimeFull) {

    $Remaining = @(
        Get-ChildItem `
            -LiteralPath $RuntimeFull `
            -Force `
            -ErrorAction SilentlyContinue
    )

    $Unrelated = @(
        $Remaining |
            Where-Object {
                $TargetNames -notcontains $_.Name
            }
    )

    if ($Unrelated.Count -gt 0) {

        Write-Host ""
        Write-Host "[k8slab] RuntimeRoot contains unrelated items:"

        foreach ($Item in $Unrelated) {
            Write-Host "  $($Item.Name)"
        }

        Write-Host "[k8slab] Leaving RuntimeRoot in place: $RuntimeFull"
    }
    elseif ($Remaining.Count -eq 0) {

        if (
            $PSCmdlet.ShouldProcess(
                $RuntimeFull,
                "Delete empty lab runtime root"
            )
        ) {

            Remove-Item `
                -LiteralPath $RuntimeFull `
                -Force

            Write-Host "[k8slab] removed empty runtime root"
        }
    }
    elseif ($WhatIfPreference) {

        Write-Host ""
        Write-Host "[k8slab] dry run: expected lab runtime directories remain."
        Write-Host "[k8slab] RuntimeRoot would become empty after the planned deletions."
    }
    else {

        Write-Host ""
        Write-Host "[k8slab] one or more lab runtime directories were retained."
        Write-Host "[k8slab] Leaving RuntimeRoot in place: $RuntimeFull"
    }
}

Write-Host ""
Write-Host "===== WSL STATUS ====="
& wsl.exe --list --verbose

Write-Host ""
Write-Host "========================================"
Write-Host " K8sLab destroy completed"
Write-Host "========================================"
Write-Host ""
