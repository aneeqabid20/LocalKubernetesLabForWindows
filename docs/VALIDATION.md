# Validation

The automation was validated against a disposable three-node environment before final use on the long-lived lab.

## Disposable build

A fresh disposable environment successfully completed WSL distro creation, node provisioning, private networking, containerd startup, kubeadm initialization, both worker joins, Cilium 1.20.1 installation, Hubble deployment, and workload verification.

## Functional verification

The verification suite passed:

- all three WSL distros running
- controller and worker systemd services active
- controller bridge `192.168.250.1/24`
- node01 namespace IP `192.168.250.2`
- node02 namespace IP `192.168.250.3`
- distinct controller/node01/node02 network namespaces
- exactly one scoped worker NAT rule
- `fs.inotify.max_user_instances=1024`
- all Kubernetes nodes Ready
- expected Kubernetes InternalIPs
- Cilium healthy
- cross-node ICMP
- cross-node HTTP
- CoreDNS resolution
- ClusterIP routing

## Cold recovery

The completed disposable cluster was stopped and restarted. Networking, runtimes, Kubernetes API, nodes, Cilium, Hubble, DNS, Pod networking, and Service routing all recovered successfully.

## Original lab recovery

The long-lived lab was also subjected to `wsl --shutdown` and recovered with the final `start.ps1`. Post-recovery verification passed again.

Validated node versions:

```text
k8slab-controller.k8slab.local  v1.35.8
k8slab-node01                   v1.35.8
k8slab-node02                   v1.34.11
```
