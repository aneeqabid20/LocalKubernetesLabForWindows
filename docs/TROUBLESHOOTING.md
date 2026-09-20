# Troubleshooting

## Kubernetes API connection refused during startup

The kubelet service can become active before the static kube-apiserver Pod is ready. The final `start.ps1` waits for Kubernetes `/readyz` before waiting for node readiness.

## Too many open files

The lab persists:

```text
fs.inotify.max_user_instances=1024
```

Check it with:

```bash
sysctl fs.inotify.max_user_instances
```

## Worker namespace missing

Example:

```powershell
wsl -d k8slab-node01 -u root -- ip netns list
```

Expected:

```text
k8slab-node01-ns
```

If needed:

```powershell
.\lab.ps1 stop
wsl --shutdown
.\lab.ps1 start
```

## Check worker IP

```powershell
wsl -d k8slab-node01 -u root -- nsenter --net=/run/netns/k8slab-node01-ns ip -4 addr
wsl -d k8slab-node02 -u root -- nsenter --net=/run/netns/k8slab-node02-ns ip -4 addr
```

Expected:

- node01: `192.168.250.2/24`
- node02: `192.168.250.3/24`

## Cilium health

```powershell
.\lab.ps1 verify
```

## Full WSL reset

```powershell
.\lab.ps1 stop
wsl --shutdown
.\lab.ps1 start
```

## kubeadm join

Do not replace the project's `nsenter --net=... kubeadm join` approach with `ip netns exec`; the latter caused kubeadm/cgroup validation problems during WSL2 testing.

## Source Ubuntu distribution

`Ubuntu-24.04` is the source distribution. It is not a Kubernetes node and normal lab lifecycle operations do not remove it.
