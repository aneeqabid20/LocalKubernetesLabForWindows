#!/usr/bin/env bash
set -euo pipefail

BRIDGE="k8slab-br0"
BRIDGE_IP="192.168.250.1/24"
WORKER_SUBNET="192.168.250.0/24"
WAN_IF="eth0"
NAT_COMMENT="k8slab-worker-netns-nat"

echo "[k8slab] configuring controller network"

# Kubernetes networking kernel modules.
modprobe overlay
modprobe br_netfilter

# Create bridge if it does not already exist.
if ! ip link show "${BRIDGE}" >/dev/null 2>&1; then
    echo "[k8slab] creating bridge ${BRIDGE}"
    ip link add "${BRIDGE}" type bridge
fi

# Idempotently ensure the controller lab IP exists.
ip addr replace "${BRIDGE_IP}" dev "${BRIDGE}"
ip link set "${BRIDGE}" up

# Kubernetes / routed-worker requirements.
sysctl -w net.ipv4.ip_forward=1 >/dev/null
sysctl -w net.bridge.bridge-nf-call-iptables=1 >/dev/null
sysctl -w net.bridge.bridge-nf-call-ip6tables=1 >/dev/null

# Add only the lab-specific NAT rule and never duplicate it.
if ! iptables -t nat -C POSTROUTING \
    -s "${WORKER_SUBNET}" \
    -o "${WAN_IF}" \
    -m comment --comment "${NAT_COMMENT}" \
    -j MASQUERADE 2>/dev/null; then

    echo "[k8slab] adding worker NAT rule"

    iptables -t nat -A POSTROUTING \
        -s "${WORKER_SUBNET}" \
        -o "${WAN_IF}" \
        -m comment --comment "${NAT_COMMENT}" \
        -j MASQUERADE
fi

echo "[k8slab] controller network ready"

# Diagnostic output must never determine service success/failure.
ip -br -4 addr show "${BRIDGE}" || true

exit 0
