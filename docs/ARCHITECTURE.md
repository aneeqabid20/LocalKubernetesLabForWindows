# Architecture

The lab consists of three WSL2 distributions:

- `k8slab-controller`
- `k8slab-node01`
- `k8slab-node02`

The controller owns the private lab bridge. Each worker uses a dedicated Linux network namespace.

```text
                      WSL2
                       |
                 shared eth0
                       |
              k8slab-controller
                       |
                 k8slab-br0
                192.168.250.1
                  /         \
                 /           \
       veth-n01-host     veth-n02-host
              |               |
      node01 network      node02 network
        namespace           namespace
      192.168.250.2       192.168.250.3
```

Worker namespaces:

- `k8slab-node01-ns`
- `k8slab-node02-ns`

## Worker process placement

Worker containerd, kubelet, and OpenSSH services are ordered after the persistent worker network namespace. Containerd and kubelet use:

```text
NetworkNamespacePath=/run/netns/<worker-namespace>
PrivateMounts=no
```

This puts node networking in the worker namespace while preserving mount visibility required by Kubernetes.

OpenSSH uses a dedicated systemd drop-in with:

```text
NetworkNamespacePath=/run/netns/<worker-namespace>
```

Ubuntu SSH socket activation is disabled and `ssh.service` is used directly. The controller owns a lab-local ed25519 key, installs its public key in both workers, and maintains `known_hosts` for `192.168.250.2` and `192.168.250.3`. The worker `ubuntu` user has passwordless sudo because this is a disposable certification-training environment.

This provides the stable Linux-side interface required by node-level practice labs:

```bash
ssh ubuntu@192.168.250.2 ...
ssh ubuntu@192.168.250.3 ...
```

## kubeadm join

Worker joins use:

```text
nsenter --net=/run/netns/<namespace> kubeadm join ...
```

rather than `ip netns exec`.

## Controller responsibilities

The controller provides the Kubernetes control plane, etcd, API server, private bridge, scoped worker NAT, kubectl, and the Cilium CLI. It is intentionally schedulable.

## Pod networking

Cluster Pod CIDR: `10.244.0.0/16`

Typical node PodCIDRs:

```text
controller : 10.244.0.0/24
node01     : 10.244.1.0/24
node02     : 10.244.2.0/24
```

Cilium native routing installs direct routes between PodCIDRs over the private `192.168.250.0/24` node network.

## Persistence

WSL bridges, veth devices, and Linux network namespaces disappear when the WSL VM shuts down.

Persistent systemd services recreate them automatically:

- controller: `k8slab-controller-network.service`
- workers: `k8slab-netns.service`

Worker `containerd.service`, `kubelet.service`, and `ssh.service` depend on the namespace service. Their systemd drop-ins use `PartOf=k8slab-netns.service`, so an explicit namespace-service restart also restarts those processes and reattaches them to the current namespace.

`start.ps1` starts the controller first, waits for the bridge, then starts the workers. It waits for worker SSH, refreshes the controller's worker host keys, and verifies passwordless controller-to-worker SSH before declaring WSL infrastructure ready. For an initialized cluster it then waits for the Kubernetes API, node readiness, and Cilium health.

## WSL kernel constraint

All WSL2 distributions share the Microsoft WSL kernel and shared cgroup hierarchy. The project provides separate root filesystems and worker network namespaces, not full VM-level kernel isolation.
