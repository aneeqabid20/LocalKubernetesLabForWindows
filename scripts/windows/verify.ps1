[CmdletBinding()]
param(
    [int]$TimeoutSeconds = 180,
    [switch]$KeepResources
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

$ControllerName = $Config.Nodes.Controller.FQDN
$Node01Name = $Config.Nodes.Node01.Hostname
$Node02Name = $Config.Nodes.Node02.Hostname

$ControllerIP = $Config.Nodes.Controller.IP
$Node01IP = $Config.Nodes.Node01.IP
$Node02IP = $Config.Nodes.Node02.IP

$Node01NS = $Config.Nodes.Node01.Namespace
$Node02NS = $Config.Nodes.Node02.Namespace

$Bridge = $Config.Network.Bridge
$WorkerSubnet = $Config.Network.Subnet

$VerifyNamespace = "k8slab-verify"

$Failures = @()


function Pass {
    param([string]$Message)

    Write-Host "[PASS] $Message"
}


function Fail {
    param([string]$Message)

    Write-Host "[FAIL] $Message"
    $script:Failures += $Message
}


function Get-RunningWslDistros {
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


function Invoke-Wsl {
    param(
        [Parameter(Mandatory)]
        [string]$Distro,

        [Parameter(Mandatory)]
        [string[]]$Command
    )

    $Output = & wsl.exe `
        -d $Distro `
        -u root `
        -- `
        @Command `
        2>&1

    $ExitCode = $LASTEXITCODE

    return @{
        Output   = $Output
        ExitCode = $ExitCode
    }
}


function Invoke-Kubectl {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    $Command = @(
        "env",
        "KUBECONFIG=/etc/kubernetes/admin.conf",
        "kubectl"
    ) + $Arguments

    return Invoke-Wsl `
        -Distro $Controller `
        -Command $Command
}


function Test-Service {
    param(
        [string]$Distro,
        [string]$Service
    )

    $Result = Invoke-Wsl `
        -Distro $Distro `
        -Command @(
            "systemctl",
            "is-active",
            "--quiet",
            $Service
        )

    if ($Result.ExitCode -eq 0) {
        Pass "$Distro / $Service active"
    }
    else {
        Fail "$Distro / $Service not active"
    }
}


try {

    Write-Host ""
    Write-Host "========================================"
    Write-Host " Local Kubernetes Lab - Verification"
    Write-Host "========================================"
    Write-Host ""


    #
    # 1. WSL runtime
    #
    Write-Host "===== 1. WSL RUNTIME ====="

    $Running = @(Get-RunningWslDistros)

    foreach ($Distro in @($Controller, $Node01, $Node02)) {
        if ($Running -contains $Distro) {
            Pass "$Distro running"
        }
        else {
            Fail "$Distro stopped"
        }
    }

    if ($Failures.Count -gt 0) {
        throw "Required WSL lab distros are not running."
    }


    #
    # 2. systemd services
    #
    Write-Host ""
    Write-Host "===== 2. SYSTEM SERVICES ====="

    Test-Service `
        -Distro $Controller `
        -Service "k8slab-controller-network.service"

    Test-Service `
        -Distro $Controller `
        -Service "containerd.service"

    Test-Service `
        -Distro $Controller `
        -Service "kubelet.service"

    foreach ($Worker in @($Node01, $Node02)) {

        Test-Service `
            -Distro $Worker `
            -Service "k8slab-netns.service"

        Test-Service `
            -Distro $Worker `
            -Service "containerd.service"

        Test-Service `
            -Distro $Worker `
            -Service "kubelet.service"
    }


    #
    # 3. Controller bridge
    #
    Write-Host ""
    Write-Host "===== 3. CONTROLLER NETWORK ====="

    $BridgeResult = Invoke-Wsl `
        -Distro $Controller `
        -Command @(
            "ip",
            "-br",
            "-4",
            "addr",
            "show",
            $Bridge
        )

    $BridgeText = ($BridgeResult.Output -join " ")

    if (
        $BridgeResult.ExitCode -eq 0 -and
        $BridgeText -match [regex]::Escape("$ControllerIP/24")
    ) {
        Pass "$Bridge has $ControllerIP/24"
    }
    else {
        Fail "$Bridge missing expected controller address"
    }


    #
    # 4. Worker namespaces and IPs
    #
    Write-Host ""
    Write-Host "===== 4. WORKER NETWORK NAMESPACES ====="

    $Node01Addr = Invoke-Wsl `
        -Distro $Node01 `
        -Command @(
            "ip",
            "-n",
            $Node01NS,
            "-br",
            "-4",
            "addr",
            "show",
            "eth0"
        )

    if (
        $Node01Addr.ExitCode -eq 0 -and
        (($Node01Addr.Output -join " ") -match [regex]::Escape("$Node01IP/24"))
    ) {
        Pass "node01 namespace IP = $Node01IP"
    }
    else {
        Fail "node01 namespace IP incorrect"
    }


    $Node02Addr = Invoke-Wsl `
        -Distro $Node02 `
        -Command @(
            "ip",
            "-n",
            $Node02NS,
            "-br",
            "-4",
            "addr",
            "show",
            "eth0"
        )

    if (
        $Node02Addr.ExitCode -eq 0 -and
        (($Node02Addr.Output -join " ") -match [regex]::Escape("$Node02IP/24"))
    ) {
        Pass "node02 namespace IP = $Node02IP"
    }
    else {
        Fail "node02 namespace IP incorrect"
    }


    #
    # Verify that controller, node01 and node02 really use
    # distinct Linux network namespaces.
    #
    $ControllerNetNS = (
        Invoke-Wsl `
            -Distro $Controller `
            -Command @(
                "readlink",
                "/proc/self/ns/net"
            )
    ).Output -join ""

    $Node01NetNS = (
        Invoke-Wsl `
            -Distro $Node01 `
            -Command @(
                "nsenter",
                "--net=/run/netns/$Node01NS",
                "readlink",
                "/proc/self/ns/net"
            )
    ).Output -join ""

    $Node02NetNS = (
        Invoke-Wsl `
            -Distro $Node02 `
            -Command @(
                "nsenter",
                "--net=/run/netns/$Node02NS",
                "readlink",
                "/proc/self/ns/net"
            )
    ).Output -join ""

    if (
        $ControllerNetNS -ne $Node01NetNS -and
        $ControllerNetNS -ne $Node02NetNS -and
        $Node01NetNS -ne $Node02NetNS
    ) {
        Pass "controller/node01/node02 network namespaces are distinct"
    }
    else {
        Fail "network namespace isolation check failed"
    }


    #
    # 5. NAT
    #
    Write-Host ""
    Write-Host "===== 5. WORKER NAT ====="

    $NatResult = Invoke-Wsl `
        -Distro $Controller `
        -Command @(
            "iptables",
            "-t",
            "nat",
            "-S",
            "POSTROUTING"
        )

    $NatMatches = @(
        $NatResult.Output |
            Select-String "k8slab-worker-netns-nat"
    )

    if ($NatMatches.Count -eq 1) {
        Pass "exactly one lab worker NAT rule exists"
    }
    else {
        Fail "expected one lab NAT rule; found $($NatMatches.Count)"
    }


    #
    # 6. Inotify
    #
    Write-Host ""
    Write-Host "===== 6. WSL KERNEL LIMIT ====="

    $Inotify = Invoke-Wsl `
        -Distro $Controller `
        -Command @(
            "sysctl",
            "-n",
            "fs.inotify.max_user_instances"
        )

    $InotifyValue = ($Inotify.Output -join "").Trim()

    if (
        $Inotify.ExitCode -eq 0 -and
        $InotifyValue -eq "$($Config.WSLKernel.InotifyMaxUserInstances)"
    ) {
        Pass "fs.inotify.max_user_instances = $InotifyValue"
    }
    else {
        Fail "unexpected inotify limit: $InotifyValue"
    }


    #
    # 7. Kubernetes nodes
    #
    Write-Host ""
    Write-Host "===== 7. KUBERNETES NODES ====="

    $NodeCheck = Invoke-Kubectl `
        -Arguments @(
            "wait",
            "--for=condition=Ready",
            "nodes",
            "--all",
            "--timeout=$($TimeoutSeconds)s"
        )

    $NodeCheck.Output | ForEach-Object {
        Write-Host $_
    }

    if ($NodeCheck.ExitCode -eq 0) {
        Pass "all Kubernetes nodes Ready"
    }
    else {
        Fail "one or more Kubernetes nodes not Ready"
    }


    #
    # Verify Kubernetes node IPs.
    #
    $ExpectedNodes = @(
        @{
            Name = $ControllerName
            IP   = $ControllerIP
        },
        @{
            Name = $Node01Name
            IP   = $Node01IP
        },
        @{
            Name = $Node02Name
            IP   = $Node02IP
        }
    )

    foreach ($Node in $ExpectedNodes) {

        $IPResult = Invoke-Kubectl `
            -Arguments @(
                "get",
                "node",
                $Node.Name,
                "-o",
                "json"
            )

        $ActualIP = ""

        if ($IPResult.ExitCode -eq 0) {

            try {
                $NodeJson = (
                    $IPResult.Output -join "`n"
                ) | ConvertFrom-Json

                $InternalAddress = $NodeJson.status.addresses |
                    Where-Object {
                        $_.type -eq "InternalIP"
                    } |
                    Select-Object -First 1

                if ($null -ne $InternalAddress) {
                    $ActualIP = $InternalAddress.address
                }
            }
            catch {
                $ActualIP = ""
            }
        }

        if (
            $IPResult.ExitCode -eq 0 -and
            $ActualIP -eq $Node.IP
        ) {
            Pass "$($Node.Name) InternalIP = $ActualIP"
        }
        else {
            Fail "$($Node.Name) InternalIP expected $($Node.IP), got $ActualIP"
        }
    }


    #
    # 8. Cilium
    #
    Write-Host ""
    Write-Host "===== 8. CILIUM ====="

    $Cilium = Invoke-Wsl `
        -Distro $Controller `
        -Command @(
            "env",
            "KUBECONFIG=/etc/kubernetes/admin.conf",
            "cilium",
            "status",
            "--wait"
        )

    $Cilium.Output | ForEach-Object {
        Write-Host $_
    }

    if ($Cilium.ExitCode -eq 0) {
        Pass "Cilium healthy"
    }
    else {
        Fail "Cilium health check failed"
    }


    #
    # 9. Temporary verification workloads
    #
    Write-Host ""
    Write-Host "===== 9. TEST WORKLOADS ====="

    Invoke-Kubectl `
        -Arguments @(
            "delete",
            "namespace",
            $VerifyNamespace,
            "--ignore-not-found=true",
            "--wait=true"
        ) | Out-Null

    $Manifest = @"
apiVersion: v1
kind: Namespace
metadata:
  name: $VerifyNamespace
---
apiVersion: v1
kind: Pod
metadata:
  name: verify-controller
  namespace: $VerifyNamespace
  labels:
    app: verify-controller
spec:
  nodeName: $ControllerName
  containers:
  - name: busybox
    image: busybox:1.36.1
    command:
    - sh
    - -c
    - |
      mkdir -p /www
      echo controller-ok > /www/index.html
      exec httpd -f -p 8080 -h /www
---
apiVersion: v1
kind: Pod
metadata:
  name: verify-node01
  namespace: $VerifyNamespace
  labels:
    app: verify-node01
spec:
  nodeName: $Node01Name
  containers:
  - name: busybox
    image: busybox:1.36.1
    command:
    - sh
    - -c
    - |
      mkdir -p /www
      echo node01-ok > /www/index.html
      exec httpd -f -p 8080 -h /www
---
apiVersion: v1
kind: Pod
metadata:
  name: verify-node02
  namespace: $VerifyNamespace
  labels:
    app: verify-node02
spec:
  nodeName: $Node02Name
  containers:
  - name: busybox
    image: busybox:1.36.1
    command:
    - sh
    - -c
    - |
      mkdir -p /www
      echo node02-ok > /www/index.html
      exec httpd -f -p 8080 -h /www
---
apiVersion: v1
kind: Service
metadata:
  name: verify-controller
  namespace: $VerifyNamespace
spec:
  selector:
    app: verify-controller
  ports:
  - port: 8080
    targetPort: 8080
"@

    $ApplyOutput = $Manifest |
        & wsl.exe `
            -d $Controller `
            -u root `
            -- `
            env KUBECONFIG=/etc/kubernetes/admin.conf `
            kubectl apply -f - `
            2>&1

    $ApplyExitCode = $LASTEXITCODE

    $ApplyOutput | ForEach-Object {
        Write-Host $_
    }

    if ($ApplyExitCode -ne 0) {
        throw "Failed to create verification workloads."
    }


    $PodWait = Invoke-Kubectl `
        -Arguments @(
            "wait",
            "--namespace",
            $VerifyNamespace,
            "--for=condition=Ready",
            "pod/verify-controller",
            "pod/verify-node01",
            "pod/verify-node02",
            "--timeout=$($TimeoutSeconds)s"
        )

    $PodWait.Output | ForEach-Object {
        Write-Host $_
    }

    if ($PodWait.ExitCode -eq 0) {
        Pass "verification pods Ready"
    }
    else {
        Fail "verification pods did not become Ready"
        throw "Cannot continue data-plane tests."
    }


    #
    # Capture Pod addresses.
    #
    function Get-PodIP {
        param([string]$Pod)

        $Result = Invoke-Kubectl `
            -Arguments @(
                "get",
                "pod",
                $Pod,
                "--namespace",
                $VerifyNamespace,
                "-o",
                "jsonpath={.status.podIP}"
            )

        return (($Result.Output -join "").Trim())
    }


    $ControllerPodIP = Get-PodIP "verify-controller"
    $Node01PodIP = Get-PodIP "verify-node01"
    $Node02PodIP = Get-PodIP "verify-node02"

    Write-Host ""
    Write-Host "Controller Pod : $ControllerPodIP"
    Write-Host "Node01 Pod     : $Node01PodIP"
    Write-Host "Node02 Pod     : $Node02PodIP"


    #
    # 10. Pod-to-Pod connectivity
    #
    Write-Host ""
    Write-Host "===== 10. POD NETWORK ====="

    $ConnectivityTests = @(
        @{
            Source = "verify-node01"
            Target = $Node02PodIP
            Name   = "node01 -> node02"
        },
        @{
            Source = "verify-node02"
            Target = $Node01PodIP
            Name   = "node02 -> node01"
        },
        @{
            Source = "verify-controller"
            Target = $Node02PodIP
            Name   = "controller -> node02"
        },
        @{
            Source = "verify-node02"
            Target = $ControllerPodIP
            Name   = "node02 -> controller"
        }
    )

    foreach ($Test in $ConnectivityTests) {

        $Result = Invoke-Kubectl `
            -Arguments @(
                "exec",
                "--namespace",
                $VerifyNamespace,
                $Test.Source,
                "--",
                "ping",
                "-c",
                "2",
                $Test.Target
            )

        if ($Result.ExitCode -eq 0) {
            Pass "$($Test.Name) ICMP"
        }
        else {
            Fail "$($Test.Name) ICMP"
        }
    }


    #
    # HTTP across worker nodes.
    #
    $HTTP = Invoke-Kubectl `
        -Arguments @(
            "exec",
            "--namespace",
            $VerifyNamespace,
            "verify-node01",
            "--",
            "wget",
            "-qO-",
            "http://${Node02PodIP}:8080"
        )

    $HTTPText = ($HTTP.Output -join "").Trim()

    if (
        $HTTP.ExitCode -eq 0 -and
        $HTTPText -eq "node02-ok"
    ) {
        Pass "node01 -> node02 HTTP"
    }
    else {
        Fail "node01 -> node02 HTTP"
    }


    #
    # 11. DNS
    #
    Write-Host ""
    Write-Host "===== 11. CLUSTER DNS ====="

    $DNS = Invoke-Kubectl `
        -Arguments @(
            "exec",
            "--namespace",
            $VerifyNamespace,
            "verify-node02",
            "--",
            "nslookup",
            "verify-controller.$VerifyNamespace.svc.cluster.local"
        )

    if (
        $DNS.ExitCode -eq 0 -and
        (($DNS.Output -join "`n") -match "Address")
    ) {
        Pass "CoreDNS service resolution"
    }
    else {
        Fail "CoreDNS service resolution"
    }


    #
    # 12. ClusterIP
    #
    Write-Host ""
    Write-Host "===== 12. CLUSTERIP SERVICE ====="

    $ServiceHTTP = Invoke-Kubectl `
        -Arguments @(
            "exec",
            "--namespace",
            $VerifyNamespace,
            "verify-node02",
            "--",
            "wget",
            "-qO-",
            "http://verify-controller:8080"
        )

    $ServiceText = ($ServiceHTTP.Output -join "").Trim()

    if (
        $ServiceHTTP.ExitCode -eq 0 -and
        $ServiceText -eq "controller-ok"
    ) {
        Pass "ClusterIP service routing"
    }
    else {
        Fail "ClusterIP service routing"
    }


    #
    # Result
    #
    Write-Host ""
    Write-Host "========================================"

    if ($Failures.Count -eq 0) {
        Write-Host " K8sLab verification PASSED"
    }
    else {
        Write-Host " K8sLab verification FAILED"
    }

    Write-Host "========================================"
    Write-Host ""

}
finally {

    if (-not $KeepResources) {

        $RunningNow = @(Get-RunningWslDistros)

        if ($RunningNow -contains $Controller) {

            Write-Host "[k8slab] cleaning verification resources..."

            Invoke-Kubectl `
                -Arguments @(
                    "delete",
                    "namespace",
                    $VerifyNamespace,
                    "--ignore-not-found=true",
                    "--wait=false"
                ) | Out-Null
        }
        else {
            Write-Host "[k8slab] cleanup skipped because controller is stopped."
        }
    }


}


if ($Failures.Count -gt 0) {

    Write-Host ""
    Write-Host "Failed checks:"

    foreach ($Failure in $Failures) {
        Write-Host " - $Failure"
    }

    exit 1
}

exit 0