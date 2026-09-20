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

Worker containerd and kubelet systemd units use:

```text
NetworkNamespacePath=/run/netns/<worker-namespace>
PrivateMounts=no
```

This puts node networking in the worker namespace while preserving mount visibility required by Kubernetes.

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

`start.ps1` starts the controller first, waits for the bridge, then starts the workers. For an initialized cluster it waits for the Kubernetes API, node readiness, and Cilium health.

## WSL kernel constraint

All WSL2 distributions share the Microsoft WSL kernel and shared cgroup hierarchy. The project provides separate root filesystems and worker network namespaces, not full VM-level kernel isolation.
