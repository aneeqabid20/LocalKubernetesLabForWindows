# Local Kubernetes Lab for Windows

A real **kubeadm-based, three-node Kubernetes lab on Windows 11 using WSL2**.

It is intended for Kubernetes certification practice and hands-on work with kubeadm, containerd, CNI, cluster upgrades, etcd, troubleshooting, node networking, and cluster recovery without cloud cost.

## Prerequisites

Before cloning or building the lab, complete the [Windows and WSL prerequisites](docs/PREREQUISITES.md).

## Lab topology

| Node | Role | Kubernetes | Lab IP |
|---|---|---:|---:|
| `k8slab-controller.k8slab.local` | Control plane + schedulable worker | v1.35.8 | `192.168.250.1` |
| `k8slab-node01` | Worker | v1.35.8 | `192.168.250.2` |
| `k8slab-node02` | Worker | v1.34.11 | `192.168.250.3` |

Core software:

- containerd 2.2.1
- runc 1.3.4
- kubeadm / kubelet / kubectl
- Cilium 1.20.1
- Hubble Relay and Hubble UI
- Pod CIDR `10.244.0.0/16`
- Service CIDR `10.96.0.0/12`
- DNS domain `cluster.local`

## Why special networking is required

WSL2 distributions share the WSL kernel and normally share the default WSL network environment. That is not sufficient for a realistic multi-node kubeadm cluster.

This project creates:

- controller bridge `k8slab-br0`
- worker-specific Linux network namespaces
- dedicated veth pairs
- private node IPs on `192.168.250.0/24`
- scoped worker NAT
- containerd and kubelet running in the worker network namespaces

The result is three independently addressed Kubernetes nodes using real kubeadm, kubelet, containerd, systemd, and Cilium.

## WSL2 limitation

The nodes have separate root filesystems and worker network namespaces, but they still share the WSL2 kernel and cgroup hierarchy. This is therefore not identical to three independent VMs, although it is substantially closer to a kubeadm node workflow than kind, k3d, or minikube.

## Prerequisites

Recommended host:

- Windows 11
- WSL2
- Ubuntu 24.04 source distribution named `Ubuntu-24.04`
- systemd enabled in WSL
- Internet access
- approximately 10 GB RAM for WSL
- approximately 6 processors for WSL

Example `%USERPROFILE%\.wslconfig`:

```ini
[wsl2]
processors=6
memory=10GB
swap=0
```

The source Ubuntu distribution is exported temporarily when creating the three lab distributions. No Ubuntu tarball or VHDX is stored in this repository.

## Quick start

Open PowerShell:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
cd "$HOME\LocalKubernetesLabForWindows"
.\lab.ps1 setup
```

The setup flow runs:

1. host/source preflight
2. creation of three WSL2 distributions
3. node provisioning
4. persistent WSL/network startup
5. kubeadm initialization and worker joins
6. Cilium and Hubble installation
7. functional verification

## Common commands

```powershell
.\lab.ps1 status
.\lab.ps1 start
.\lab.ps1 stop
.\lab.ps1 verify
```

Controller shell:

```powershell
.\lab.ps1 shell -Node controller
```

Worker shell inside the worker's Kubernetes network namespace:

```powershell
.\lab.ps1 shell -Node node01
.\lab.ps1 shell -Node node02
```

Root shell:

```powershell
.\lab.ps1 shell -Node node01 -Root
```

`ssh` is also available as a command alias:

```powershell
.\lab.ps1 ssh -Node node01
```

This command opens the selected WSL node console. Worker SSH is configured separately for controller-to-worker access.

## Infrastructure-only setup

For manual kubeadm practice, prepare the three WSL nodes, containerd, Kubernetes packages, networking, and persistence without creating the Kubernetes cluster:

```powershell
.\lab.ps1 setup -SkipKubernetes
```

This mode still performs:

1. preflight checks
2. WSL distro creation
3. node provisioning
4. containerd and kubelet preparation
5. worker network namespace and persistent networking setup
6. node startup

It intentionally skips:

- `kubeadm init`
- worker `kubeadm join`
- Cilium and Hubble installation
- Kubernetes functional verification

The prepared nodes can then be used for manual kubeadm and CNI practice.

## Rebuild

Preview:

```powershell
.\lab.ps1 setup -PlanOnly -ReplaceExisting
```

Then intentionally rebuild:

```powershell
.\lab.ps1 setup -ReplaceExisting
```

## Destroy

Preview first:

```powershell
.\lab.ps1 destroy -WhatIf
```

Then:

```powershell
.\lab.ps1 destroy
```

Destroy targets only the three WSL distro names in `config/lab.psd1`. The source `Ubuntu-24.04` distro is not a lab target.

## Cilium

Cilium is configured for:

- native routing
- Kubernetes IPAM
- `10.244.0.0/16` native routing CIDR
- automatic direct node routes
- kube-proxy replacement disabled
- one operator replica
- Hubble Relay enabled
- Hubble UI enabled

## Mixed-version upgrade practice

The lab intentionally keeps node02 one minor version behind:

- controller: v1.35.8
- node01: v1.35.8
- node02: v1.34.11

This provides a useful kubeadm version-skew and upgrade practice scenario.

## Verification

`verify.ps1` validates:

- WSL runtime state
- systemd services
- controller bridge
- worker network namespaces
- worker IP addresses
- NAT
- WSL inotify setting
- Kubernetes node readiness
- expected InternalIPs
- Cilium health
- cross-node ICMP
- cross-node HTTP
- CoreDNS
- ClusterIP routing

Verification workloads are cleaned automatically.

## Repository layout

```text
.
|-- config/
|-- docs/
|-- kubernetes/
|-- linux/
|-- scripts/
|   |-- linux/
|   `-- windows/
|-- .gitattributes
|-- .gitignore
|-- lab.ps1
|-- Makefile
`-- README.md
```

## Runtime data

WSL distro runtime data is stored outside the repository:

```text
%USERPROFILE%\WSL\LocalKubernetesLabForWindows
```

Transient PID files are stored under `artifacts/runtime/` and are ignored by Git.

VHDX files, tar archives, kubeconfig credentials, logs, and other runtime state are also excluded.

## Documentation

- `docs/ARCHITECTURE.md`
- `docs/TROUBLESHOOTING.md`
- `docs/VALIDATION.md`
