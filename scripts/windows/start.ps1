[CmdletBinding()]
param(
    [int]$ControllerTimeoutSeconds = 60,
    [int]$WorkerTimeoutSeconds = 90,
    [int]$KubernetesTimeoutSeconds = 180,
    [switch]$SkipKubernetesWait
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

$Bridge = $Config.Network.Bridge
$ControllerIP = $Config.Nodes.Controller.IP
$PrefixLength = ($Config.Network.Subnet -split "/")[1]

New-Item -ItemType Directory -Force -Path $RuntimeDir | Out-Null


function Get-WslDistros {
    $Names = @(
        & wsl.exe --list --quiet 2>$null |
            ForEach-Object {
                ($_ -replace "`0", "").Trim()
            } |
            Where-Object {
                -not [string]::IsNullOrWhiteSpace($_)
            }
    )

    return $Names
}


function Assert-RequiredDistros {
    $Available = @(Get-WslDistros)

    foreach ($Distro in @($Controller, $Node01, $Node02)) {
        if ($Available -notcontains $Distro) {
            throw "Required WSL distro '$Distro' is not installed."
        }
    }
}


function Start-KeepAlive {
    param(
        [Parameter(Mandatory)]
        [string]$Distro
    )

    $PidFile = Join-Path $RuntimeDir "$Distro.pid"

    if (Test-Path $PidFile) {
        $SavedPidText = (Get-Content $PidFile -Raw).Trim()

        if ($SavedPidText -match '^\d+$') {
            $SavedPid = [int]$SavedPidText

            $Existing = Get-Process `
                -Id $SavedPid `
                -ErrorAction SilentlyContinue

            if (
                $null -ne $Existing -and
                $Existing.ProcessName -eq "wsl"
            ) {
                Write-Host "[k8slab] $Distro keepalive already running (PID $SavedPid)"
                return
            }
        }

        Remove-Item $PidFile -Force -ErrorAction SilentlyContinue
    }

    Write-Host "[k8slab] starting $Distro"

    $Process = Start-Process `
        -FilePath "wsl.exe" `
        -ArgumentList @(
            "-d", $Distro,
            "-u", "root",
            "--",
            "sleep", "infinity"
        ) `
        -WindowStyle Hidden `
        -PassThru

    Set-Content `
        -Path $PidFile `
        -Value $Process.Id `
        -Encoding ASCII `
        -NoNewline

    Write-Host "[k8slab] $Distro keepalive PID = $($Process.Id)"
}


function Test-ServiceActive {
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
        systemctl is-active --quiet $Service `
        2>$null

    return ($LASTEXITCODE -eq 0)
}


function Wait-Condition {
    param(
        [Parameter(Mandatory)]
        [scriptblock]$Condition,

        [Parameter(Mandatory)]
        [int]$TimeoutSeconds,

        [Parameter(Mandatory)]
        [string]$Description
    )

    $Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    while ($Stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        if (& $Condition) {
            Write-Host "[k8slab] ready: $Description"
            return
        }

        Start-Sleep -Seconds 1
    }

    throw "Timeout waiting for: $Description"
}


function Test-ControllerBridge {
    $Output = & wsl.exe `
        -d $Controller `
        -u root `
        -- `
        ip -4 -o addr show dev $Bridge `
        2>$null

    if ($LASTEXITCODE -ne 0) {
        return $false
    }

    $Expected = "$ControllerIP/$PrefixLength"

    return (($Output -join " ") -match [regex]::Escape($Expected))
}


function Wait-Service {
    param(
        [string]$Distro,
        [string]$Service,
        [int]$TimeoutSeconds
    )

    Wait-Condition `
        -TimeoutSeconds $TimeoutSeconds `
        -Description "$Distro / $Service" `
        -Condition {
            Test-ServiceActive `
                -Distro $Distro `
                -Service $Service
        }
}


function Test-KubeletConfigured {
    param(
        [Parameter(Mandatory)]
        [string]$Distro
    )

    & wsl.exe `
        -d $Distro `
        -u root `
        -- `
        test -f /var/lib/kubelet/config.yaml `
        2>$null

    if ($LASTEXITCODE -ne 0) {
        return $false
    }

    & wsl.exe `
        -d $Distro `
        -u root `
        -- `
        test -f /etc/kubernetes/kubelet.conf `
        2>$null

    return ($LASTEXITCODE -eq 0)
}


try {
    Write-Host ""
    Write-Host "========================================"
    Write-Host " Local Kubernetes Lab - Start"
    Write-Host "========================================"
    Write-Host ""

    Assert-RequiredDistros

    #
    # Controller first.
    #
    Start-KeepAlive -Distro $Controller

    Wait-Service `
        -Distro $Controller `
        -Service "k8slab-controller-network.service" `
        -TimeoutSeconds $ControllerTimeoutSeconds

    Wait-Service `
        -Distro $Controller `
        -Service "containerd.service" `
        -TimeoutSeconds $ControllerTimeoutSeconds

    if (Test-KubeletConfigured -Distro $Controller) {

        Wait-Service `
            -Distro $Controller `
            -Service "kubelet.service" `
            -TimeoutSeconds $ControllerTimeoutSeconds
    }
    else {

        Write-Host "[k8slab] $Controller kubelet is not configured by kubeadm yet; skipping kubelet wait."
    }

    Wait-Condition `
        -TimeoutSeconds $ControllerTimeoutSeconds `
        -Description "$Bridge with $ControllerIP/$PrefixLength" `
        -Condition {
            Test-ControllerBridge
        }

    #
    # Workers only start after the controller bridge exists.
    #
    Start-KeepAlive -Distro $Node01
    Start-KeepAlive -Distro $Node02

    foreach ($Worker in @($Node01, $Node02)) {
        Wait-Service `
            -Distro $Worker `
            -Service "k8slab-netns.service" `
            -TimeoutSeconds $WorkerTimeoutSeconds

        Wait-Service `
            -Distro $Worker `
            -Service "containerd.service" `
            -TimeoutSeconds $WorkerTimeoutSeconds

        if (Test-KubeletConfigured -Distro $Worker) {

            Wait-Service `
                -Distro $Worker `
                -Service "kubelet.service" `
                -TimeoutSeconds $WorkerTimeoutSeconds
        }
        else {

            Write-Host "[k8slab] $Worker kubelet is not configured by kubeadm yet; skipping kubelet wait."
        }
    }

    Write-Host ""
    Write-Host "[k8slab] WSL infrastructure is running."

    #
    # Kubernetes may not exist yet during an initial provisioning workflow.
    #
    & wsl.exe `
        -d $Controller `
        -u root `
        -- `
        test -f /etc/kubernetes/admin.conf `
        2>$null

    $ClusterInitialized = ($LASTEXITCODE -eq 0)

    if ($ClusterInitialized -and -not $SkipKubernetesWait) {

        Write-Host "[k8slab] waiting for Kubernetes API..."

        Wait-Condition `
            -TimeoutSeconds $KubernetesTimeoutSeconds `
            -Description "Kubernetes API /readyz" `
            -Condition {

                $ReadyOutput = @(
                    & wsl.exe `
                        -d $Controller `
                        -u root `
                        -- `
                        env KUBECONFIG=/etc/kubernetes/admin.conf `
                        kubectl get --raw=/readyz `
                        2>$null
                )

                if ($LASTEXITCODE -ne 0) {
                    return $false
                }

                return (
                    (($ReadyOutput -join "`n").Trim()) -eq "ok"
                )
            }

        Write-Host ""
        Write-Host "[k8slab] waiting for Kubernetes nodes..."

        & wsl.exe `
            -d $Controller `
            -u root `
            -- `
            env KUBECONFIG=/etc/kubernetes/admin.conf `
            kubectl wait `
            --for=condition=Ready `
            nodes `
            --all `
            "--timeout=$($KubernetesTimeoutSeconds)s"

        if ($LASTEXITCODE -ne 0) {
            throw "Kubernetes nodes did not become Ready."
        }

        Write-Host ""
        Write-Host "[k8slab] waiting for Cilium..."

        & wsl.exe `
            -d $Controller `
            -u root `
            -- `
            env KUBECONFIG=/etc/kubernetes/admin.conf `
            cilium status --wait

        if ($LASTEXITCODE -ne 0) {
            throw "Cilium did not become healthy."
        }

        Write-Host ""
        Write-Host "===== KUBERNETES NODES ====="

        & wsl.exe `
            -d $Controller `
            -u root `
            -- `
            env KUBECONFIG=/etc/kubernetes/admin.conf `
            kubectl get nodes -o wide
    }
    elseif (-not $ClusterInitialized) {
        Write-Host "[k8slab] Kubernetes is not initialized yet."
        Write-Host "[k8slab] WSL infrastructure startup completed."
    }
    else {
        Write-Host "[k8slab] Kubernetes readiness check skipped."
    }

    Write-Host ""
    Write-Host "========================================"
    Write-Host " K8sLab started successfully"
    Write-Host "========================================"
    Write-Host ""
}
catch {
    Write-Host ""
    Write-Host "========================================"
    Write-Host " K8sLab startup FAILED"
    Write-Host "========================================"
    Write-Host ""
    Write-Error $_.Exception.Message
    exit 1
}