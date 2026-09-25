# Validation

The automation was validated against a disposable three-node environment before final use on the long-lived lab.

## Disposable build

A fresh disposable environment successfully completed WSL distro creation, node provisioning, private networking, containerd startup, kubeadm initialization, both worker joins, Cilium 1.20.1 installation, Hubble deployment, and workload verification.

## Functional verification

The verification suite passed:

- all three WSL distros running
- controller and worker systemd services active
- worker `ssh.service` active inside each dedicated worker network namespace
- Ubuntu `ssh.socket` masked on both workers
- controller -> node01/node02 SSH works in `BatchMode` with no password prompt
- worker `ubuntu` user accepts `sudo -n` over SSH
- remote kubelet status is `active` over SSH
- port 22 is listening inside each worker network namespace
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

The completed disposable cluster was stopped and restarted. Networking, runtimes, Kubernetes API, nodes, Cilium, Hubble, DNS, Pod networking, Service routing, and passwordless controller-to-worker SSH must all recover successfully.

Worker namespace-service recovery should also be tested explicitly by restarting `k8slab-netns.service` on each worker and confirming that containerd, kubelet, and SSH are active afterwards and that SSH still reports the configured `NetworkNamespacePath`.

## Worker SSH acceptance procedure

Use this procedure after a completely fresh build to prove that worker SSH requires no manual setup.

From the controller as the normal `ubuntu` user:

```bash
ssh -o BatchMode=yes -o ConnectTimeout=5 ubuntu@192.168.250.2 hostname
ssh -o BatchMode=yes -o ConnectTimeout=5 ubuntu@192.168.250.3 hostname

ssh -o BatchMode=yes -o ConnectTimeout=5 ubuntu@192.168.250.2 "sudo -n true"
ssh -o BatchMode=yes -o ConnectTimeout=5 ubuntu@192.168.250.3 "sudo -n true"

ssh -o BatchMode=yes -o ConnectTimeout=5 ubuntu@192.168.250.2 "sudo -n systemctl is-active kubelet"
ssh -o BatchMode=yes -o ConnectTimeout=5 ubuntu@192.168.250.3 "sudo -n systemctl is-active kubelet"
```

Expected hostnames are `k8slab-node01` and `k8slab-node02`; both kubelet checks must return `active`. No command should prompt for a password or host-key confirmation.

From Windows PowerShell, validate service placement:

```powershell
wsl -d k8slab-node01 -u root -- systemctl show ssh.service -p NetworkNamespacePath
wsl -d k8slab-node02 -u root -- systemctl show ssh.service -p NetworkNamespacePath

wsl -d k8slab-node01 -u root -- ip netns exec k8slab-node01-ns ss -lntp
wsl -d k8slab-node02 -u root -- ip netns exec k8slab-node02-ns ss -lntp
```

Expected namespace properties:

```text
NetworkNamespacePath=/run/netns/k8slab-node01-ns
NetworkNamespacePath=/run/netns/k8slab-node02-ns
```

Each namespace must contain an `sshd` listener on port 22.

Then run `wsl --shutdown`, start the lab again, and repeat the controller SSH checks. Finally restart `k8slab-netns.service` on each worker one at a time and confirm `ssh.service`, `containerd.service`, and `kubelet.service` return to `active` before repeating the SSH tests.

## Original lab recovery

The long-lived lab was also subjected to `wsl --shutdown` and recovered with the final `start.ps1`. Post-recovery verification passed again.

Validated node versions:

```text
k8slab-controller.k8slab.local  v1.35.8
k8slab-node01                   v1.35.8
k8slab-node02                   v1.34.11
```
