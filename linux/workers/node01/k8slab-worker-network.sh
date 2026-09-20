#!/usr/bin/env bash
set -euo pipefail

NS="k8slab-node01-ns"
BRIDGE="k8slab-br0"
HOST_VETH="veth-n01-host"
PEER_VETH="veth-n01-peer"
NODE_IP="192.168.250.2/24"
NODE_IP_ONLY="192.168.250.2"
GATEWAY="192.168.250.1"

echo "[k8slab] configuring node01 network"

mkdir -p /run/netns

# The controller creates the bridge. Wait for it during cold boot.
for attempt in $(seq 1 60); do
    if ip link show "${BRIDGE}" >/dev/null 2>&1; then
        break
    fi

    if [ "${attempt}" -eq 60 ]; then
        echo "[k8slab] ERROR: bridge ${BRIDGE} did not appear"
        exit 1
    fi

    sleep 1
done

# Create the dedicated worker network namespace if needed.
if ! ip netns list | awk '{print $1}' | grep -qx "${NS}"; then
    echo "[k8slab] creating namespace ${NS}"
    ip netns add "${NS}"
fi

# Rebuild the veth pair if eth0 is not present inside the namespace.
if ! ip -n "${NS}" link show eth0 >/dev/null 2>&1; then
    if ip link show "${HOST_VETH}" >/dev/null 2>&1; then
        ip link delete "${HOST_VETH}"
    fi

    echo "[k8slab] creating veth pair"
    ip link add "${HOST_VETH}" type veth peer name "${PEER_VETH}"
    ip link set "${PEER_VETH}" netns "${NS}"
    ip -n "${NS}" link set "${PEER_VETH}" name eth0
fi

# Attach host-side veth to the common bridge.
ip link set "${HOST_VETH}" master "${BRIDGE}"
ip link set "${HOST_VETH}" up

# Configure namespace interfaces.
ip -n "${NS}" link set lo up
ip -n "${NS}" link set eth0 up

if ! ip -n "${NS}" -4 addr show dev eth0 | grep -q "${NODE_IP_ONLY}/24"; then
    ip -n "${NS}" addr flush dev eth0
    ip -n "${NS}" addr add "${NODE_IP}" dev eth0
fi

ip -n "${NS}" route replace default via "${GATEWAY}" dev eth0

# Newly-created namespaces need this applied each boot.
nsenter --net="/run/netns/${NS}" \
    sysctl -w net.ipv4.ip_forward=1 >/dev/null

echo "[k8slab] node01 network ready"

ip -n "${NS}" -br -4 addr || true
ip -n "${NS}" route || true

exit 0
