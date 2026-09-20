[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = "High")]
param(
    [string]$SourceDistro = "Ubuntu-24.04",

    [string]$RuntimeRoot = (
        Join-Path $HOME "WSL\LocalKubernetesLabForWindows"
    ),

    [switch]$ReplaceExisting
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


$Targets = @(
    @{
        Name = $Controller
        Path = Join-Path $RuntimeRoot $Controller
    },
    @{
        Name = $Node01
        Path = Join-Path $RuntimeRoot $Node01
    },
    @{
        Name = $Node02
        Path = Join-Path $RuntimeRoot $Node02
    }
)


Write-Host ""
Write-Host "========================================"
Write-Host " Local Kubernetes Lab - Create Distros"
Write-Host "========================================"
Write-Host ""

Write-Host "Source distro : $SourceDistro"
Write-Host "Runtime root  : $RuntimeRoot"
Write-Host ""


#
# Safety validation
#
$Installed = @(Get-WslNames)

if ($Installed -notcontains $SourceDistro) {
    throw "Source distro '$SourceDistro' is not installed."
}


$ExistingTargets = @(
    $Targets |
        Where-Object {
            $Installed -contains $_.Name
        }
)


if (
    $ExistingTargets.Count -gt 0 -and
    -not $ReplaceExisting
) {

    Write-Host "Existing lab distros detected:"
    Write-Host ""

    foreach ($Target in $ExistingTargets) {
        Write-Host "  $($Target.Name)"
    }

    Write-Host ""
    Write-Host "SAFETY STOP:"
    Write-Host "No distro has been modified."
    Write-Host ""
    Write-Host "Use -ReplaceExisting only when you intentionally"
    Write-Host "want to destroy and rebuild the existing lab."
    Write-Host ""

    throw "Refusing to overwrite existing lab distros."
}


#
# Check runtime paths independently from WSL registrations.
#
foreach ($Target in $Targets) {

    if (Test-Path $Target.Path) {

        $Items = @(
            Get-ChildItem `
                -LiteralPath $Target.Path `
                -Force `
                -ErrorAction SilentlyContinue
        )

        if (
            $Items.Count -gt 0 -and
            -not $ReplaceExisting
        ) {
            throw "Runtime path '$($Target.Path)' is not empty."
        }
    }
}


$Archive = Join-Path `
    ([System.IO.Path]::GetTempPath()) `
    "k8slab-base-$([guid]::NewGuid().ToString('N')).tar"

$CreatedDistros = @()


try {

    #
    # If replacement was explicitly requested,
    # unregister only our named lab distros.
    #
    if ($ReplaceExisting) {

        foreach ($Target in $Targets) {

            $InstalledNow = @(Get-WslNames)

            if ($InstalledNow -contains $Target.Name) {

                if (
                    $PSCmdlet.ShouldProcess(
                        $Target.Name,
                        "Unregister existing WSL distro"
                    )
                ) {

                    Write-Host "[k8slab] unregistering $($Target.Name)"

                    Invoke-WslCommand `
                        -Arguments @(
                            "--unregister",
                            $Target.Name
                        )
                }
            }


            if (Test-Path $Target.Path) {

                $Items = @(
                    Get-ChildItem `
                        -LiteralPath $Target.Path `
                        -Force `
                        -ErrorAction SilentlyContinue
                )

                if ($Items.Count -gt 0) {

                    if (
                        $PSCmdlet.ShouldProcess(
                            $Target.Path,
                            "Delete old runtime directory"
                        )
                    ) {

                        Write-Host "[k8slab] removing $($Target.Path)"

                        Remove-Item `
                            -LiteralPath $Target.Path `
                            -Recurse `
                            -Force
                    }
                }
            }
        }
    }


    #
    # Stop source distro before export to obtain a consistent snapshot.
    #
    $Running = @(Get-RunningWslNames)

    if ($Running -contains $SourceDistro) {

        if (
            $PSCmdlet.ShouldProcess(
                $SourceDistro,
                "Terminate source distro before export"
            )
        ) {

            Write-Host "[k8slab] stopping source distro $SourceDistro"

            Invoke-WslCommand `
                -Arguments @(
                    "--terminate",
                    $SourceDistro
                )
        }
    }


    #
    # Create runtime root.
    #
    if (
        $PSCmdlet.ShouldProcess(
            $RuntimeRoot,
            "Create runtime root"
        )
    ) {

        New-Item `
            -ItemType Directory `
            -Force `
            -Path $RuntimeRoot |
            Out-Null
    }


    #
    # Export source distro once.
    #
    if (
        $PSCmdlet.ShouldProcess(
            $SourceDistro,
            "Export temporary WSL base archive"
        )
    ) {

        Write-Host "[k8slab] exporting $SourceDistro"
        Write-Host "[k8slab] temporary archive: $Archive"

        Invoke-WslCommand `
            -Arguments @(
                "--export",
                $SourceDistro,
                $Archive
            )
    }


    #
    # Import all three nodes from the same temporary snapshot.
    #
    foreach ($Target in $Targets) {

        if (
            $PSCmdlet.ShouldProcess(
                $Target.Name,
                "Import WSL2 distro into $($Target.Path)"
            )
        ) {

            Write-Host ""
            Write-Host "[k8slab] creating $($Target.Name)"
            Write-Host "[k8slab] location: $($Target.Path)"

            New-Item `
                -ItemType Directory `
                -Force `
                -Path $Target.Path |
                Out-Null

            Invoke-WslCommand `
                -Arguments @(
                    "--import",
                    $Target.Name,
                    $Target.Path,
                    $Archive,
                    "--version",
                    "2"
                )

            $CreatedDistros += $Target.Name
        }
    }


    Write-Host ""
    Write-Host "===== CREATED DISTROS ====="

    & wsl.exe --list --verbose

    Write-Host ""
    Write-Host "========================================"
    Write-Host " WSL lab distros created successfully"
    Write-Host "========================================"
    Write-Host ""
}
catch {

    Write-Host ""
    Write-Host "========================================"
    Write-Host " Distro creation FAILED"
    Write-Host "========================================"
    Write-Host ""

    #
    # Roll back only distros created by THIS execution.
    #
    foreach ($Created in $CreatedDistros) {

        Write-Host "[k8slab] rolling back $Created"

        & wsl.exe --unregister $Created 2>$null
    }

    throw
}
finally {

    if (Test-Path $Archive) {

        Write-Host "[k8slab] deleting temporary archive"

        Remove-Item `
            -LiteralPath $Archive `
            -Force `
            -ErrorAction SilentlyContinue
    }
}