#!/usr/bin/env bash
set -Eeuo pipefail

#
# LocalKubernetesLabForWindows
#
# Common provisioning script for a freshly imported Ubuntu 24.04 WSL2 node.
#
# IMPORTANT:
# This script is intended to run BEFORE kubeadm init/join.
# It deliberately refuses to touch an already initialized Kubernetes node.
#

log() {
    echo "[k8slab] $*"
}

die() {
    echo "[k8slab] ERROR: $*" >&2
    exit 1
}

require_env() {
    local name="$1"

    if [[ -z "${!name:-}" ]]; then
        die "required environment variable '$name' is not set"
    fi
}


#
# Required node identity.
#
require_env ROLE
require_env NODE_HOSTNAME
require_env NODE_FQDN
require_env REPO_ROOT

#
# Lab-wide node identities.
#
require_env CONTROLLER_HOSTNAME
require_env CONTROLLER_FQDN
require_env CONTROLLER_IP

require_env NODE01_HOSTNAME
require_env NODE01_FQDN
require_env NODE01_IP

require_env NODE02_HOSTNAME
require_env NODE02_FQDN
require_env NODE02_IP

#
# Software versions supplied by config/software.psd1.
#
require_env CONTAINERD_VERSION
require_env RUNC_VERSION

require_env KUBEADM_PACKAGE_VERSION
require_env KUBELET_PACKAGE_VERSION

require_env K8S_REPOS
require_env K8S_APT_KEY_SHA256

require_env CRICTL_VERSION
require_env CRICTL_SHA256


INSTALL_KUBECTL="${INSTALL_KUBECTL:-0}"
INSTALL_CILIUM_CLI="${INSTALL_CILIUM_CLI:-0}"

if [[ "${INSTALL_KUBECTL}" == "1" ]]; then
    require_env KUBECTL_PACKAGE_VERSION
fi

if [[ "${INSTALL_CILIUM_CLI}" == "1" ]]; then
    require_env CILIUM_CLI_VERSION
    require_env CILIUM_CLI_SHA256
fi


case "${ROLE}" in
    controller|node01|node02)
        ;;
    *)
        die "ROLE must be controller, node01 or node02"
        ;;
esac


#
# Architecture guard.
#
ARCH="$(uname -m)"

if [[ "${ARCH}" != "x86_64" ]]; then
    die "this BOM currently supports x86_64 only; detected ${ARCH}"
fi


#
# Strong safety gate.
#
# Never accidentally run this provisioning process over a real cluster.
#
if [[ -f /etc/kubernetes/admin.conf ]] || \
   [[ -f /etc/kubernetes/kubelet.conf ]]; then

    die "Kubernetes is already initialized on this node; refusing to provision"
fi


#
# Validate repository source files before changing the OS.
#
[[ -d "${REPO_ROOT}" ]] ||
    die "repository path not found: ${REPO_ROOT}"

[[ -f "${REPO_ROOT}/linux/common/k8s-modules.conf" ]] ||
    die "missing k8s-modules.conf"

[[ -f "${REPO_ROOT}/linux/common/99-kubernetes-cri.conf" ]] ||
    die "missing 99-kubernetes-cri.conf"

[[ -f "${REPO_ROOT}/linux/common/crictl.yaml" ]] ||
    die "missing crictl.yaml"

[[ -f "${REPO_ROOT}/kubernetes/nodes/${ROLE}/containerd-config.toml" ]] ||
    die "missing containerd config for ${ROLE}"

[[ -f "${REPO_ROOT}/kubernetes/nodes/${ROLE}/kubelet-default" ]] ||
    die "missing kubelet-default for ${ROLE}"


TMPDIR_K8SLAB="$(mktemp -d)"

cleanup() {
    rm -rf "${TMPDIR_K8SLAB}"
}

trap cleanup EXIT


log "provisioning ${ROLE}"
log "hostname: ${NODE_HOSTNAME}"
log "fqdn:     ${NODE_FQDN}"


#
# --------------------------------------------------------------------
# WSL identity
# --------------------------------------------------------------------
#

id ubuntu >/dev/null 2>&1 ||
    die "expected source user 'ubuntu' does not exist"

cat > /etc/wsl.conf <<EOF
[boot]
systemd=true

[user]
default=ubuntu

[network]
hostname=${NODE_HOSTNAME}
generateHosts=false
EOF

printf '%s\n' "${NODE_HOSTNAME}" > /etc/hostname

hostnamectl set-hostname "${NODE_HOSTNAME}"


#
# Controlled hosts file.
#
cat > /etc/hosts <<EOF
127.0.0.1 localhost
${CONTROLLER_IP} ${CONTROLLER_FQDN} ${CONTROLLER_HOSTNAME}
${NODE01_IP} ${NODE01_FQDN} ${NODE01_HOSTNAME}
${NODE02_IP} ${NODE02_FQDN} ${NODE02_HOSTNAME}
::1 localhost ip6-localhost ip6-loopback
fe00::0 ip6-localnet
ff00::0 ip6-mcastprefix
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
EOF


#
# --------------------------------------------------------------------
# Kubernetes kernel prerequisites
# --------------------------------------------------------------------
#

install -D -m 0644 \
    "${REPO_ROOT}/linux/common/k8s-modules.conf" \
    /etc/modules-load.d/k8s.conf

install -D -m 0644 \
    "${REPO_ROOT}/linux/common/99-kubernetes-cri.conf" \
    /etc/sysctl.d/99-kubernetes-cri.conf

modprobe overlay
modprobe br_netfilter

swapoff -a || true

sysctl --system >/dev/null


#
# --------------------------------------------------------------------
# Base packages
# --------------------------------------------------------------------
#

export DEBIAN_FRONTEND=noninteractive

log "updating Ubuntu package metadata"

apt-get update


log "installing base prerequisites"

apt-get install -y \
    ca-certificates \
    curl \
    gnupg \
    apt-transport-https \
    iproute2 \
    iptables \
    kmod \
    conntrack \
    socat \
    ethtool \
    ebtables \
    ipset


#
# --------------------------------------------------------------------
# Exact container runtime
# --------------------------------------------------------------------
#

log "installing containerd ${CONTAINERD_VERSION}"
log "installing runc ${RUNC_VERSION}"

apt-get install -y \
    --allow-downgrades \
    "containerd=${CONTAINERD_VERSION}" \
    "runc=${RUNC_VERSION}"


#
# Use the exact containerd config captured from the validated node.
#
install -D -m 0644 \
    "${REPO_ROOT}/kubernetes/nodes/${ROLE}/containerd-config.toml" \
    /etc/containerd/config.toml

grep -Eq 'SystemdCgroup[[:space:]]*=[[:space:]]*true' \
    /etc/containerd/config.toml ||
    die "captured containerd config does not enable SystemdCgroup"


#
# --------------------------------------------------------------------
# Kubernetes signing key and repositories
# --------------------------------------------------------------------
#

install -d -m 0755 /etc/apt/keyrings

FIRST_REPO="$(printf '%s\n' "${K8S_REPOS}" | awk '{print $1}')"

[[ -n "${FIRST_REPO}" ]] ||
    die "K8S_REPOS is empty"

KEY_URL="https://pkgs.k8s.io/core:/stable:/${FIRST_REPO}/deb/Release.key"
KEY_TMP="${TMPDIR_K8SLAB}/kubernetes-apt-keyring.gpg"

log "downloading Kubernetes signing key"

curl -fsSL "${KEY_URL}" |
    gpg --dearmor --yes --output "${KEY_TMP}"

ACTUAL_KEY_SHA="$(
    sha256sum "${KEY_TMP}" |
    awk '{print $1}'
)"

if [[ "${ACTUAL_KEY_SHA}" != "${K8S_APT_KEY_SHA256}" ]]; then
    die "Kubernetes APT key SHA256 mismatch: expected ${K8S_APT_KEY_SHA256}, got ${ACTUAL_KEY_SHA}"
fi

install -m 0644 \
    "${KEY_TMP}" \
    /etc/apt/keyrings/kubernetes-apt-keyring.gpg


#
# Remove only Kubernetes repository definitions managed by this project.
#
rm -f \
    /etc/apt/sources.list.d/kubernetes-v1.34.list \
    /etc/apt/sources.list.d/kubernetes-v1.35.list


for REPO_VERSION in ${K8S_REPOS}; do

    case "${REPO_VERSION}" in
        v1.34|v1.35)
            ;;
        *)
            die "unsupported Kubernetes repo version: ${REPO_VERSION}"
            ;;
    esac

    cat > "/etc/apt/sources.list.d/kubernetes-${REPO_VERSION}.list" <<EOF
deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${REPO_VERSION}/deb/ /
EOF

done


apt-get update


#
# --------------------------------------------------------------------
# Exact Kubernetes packages
# --------------------------------------------------------------------
#

#
# Make reruns before kubeadm initialization predictable.
#
apt-mark unhold kubeadm kubelet kubectl >/dev/null 2>&1 || true


log "installing kubeadm ${KUBEADM_PACKAGE_VERSION}"
log "installing kubelet ${KUBELET_PACKAGE_VERSION}"

apt-get install -y \
    --allow-downgrades \
    "kubeadm=${KUBEADM_PACKAGE_VERSION}" \
    "kubelet=${KUBELET_PACKAGE_VERSION}"


if [[ "${INSTALL_KUBECTL}" == "1" ]]; then

    log "installing kubectl ${KUBECTL_PACKAGE_VERSION}"

    apt-get install -y \
        --allow-downgrades \
        "kubectl=${KUBECTL_PACKAGE_VERSION}"

fi


apt-mark hold kubeadm kubelet >/dev/null

if [[ "${INSTALL_KUBECTL}" == "1" ]]; then
    apt-mark hold kubectl >/dev/null
fi


#
# Exact kubelet node-IP configuration captured from validated lab.
#
install -D -m 0644 \
    "${REPO_ROOT}/kubernetes/nodes/${ROLE}/kubelet-default" \
    /etc/default/kubelet


#
# --------------------------------------------------------------------
# crictl standalone binary
# --------------------------------------------------------------------
#

CRICTL_ARCHIVE="${TMPDIR_K8SLAB}/crictl.tar.gz"
CRICTL_DIR="${TMPDIR_K8SLAB}/crictl"

mkdir -p "${CRICTL_DIR}"

CRICTL_URL="https://github.com/kubernetes-sigs/cri-tools/releases/download/v${CRICTL_VERSION}/crictl-v${CRICTL_VERSION}-linux-amd64.tar.gz"

log "installing crictl v${CRICTL_VERSION}"

curl -fL \
    "${CRICTL_URL}" \
    -o "${CRICTL_ARCHIVE}"

tar -xzf \
    "${CRICTL_ARCHIVE}" \
    -C "${CRICTL_DIR}"

[[ -f "${CRICTL_DIR}/crictl" ]] ||
    die "crictl binary missing from release archive"

ACTUAL_CRICTL_SHA="$(
    sha256sum "${CRICTL_DIR}/crictl" |
    awk '{print $1}'
)"

if [[ "${ACTUAL_CRICTL_SHA}" != "${CRICTL_SHA256}" ]]; then
    die "crictl SHA256 mismatch: expected ${CRICTL_SHA256}, got ${ACTUAL_CRICTL_SHA}"
fi

install -m 0755 \
    "${CRICTL_DIR}/crictl" \
    /usr/local/bin/crictl

install -D -m 0644 \
    "${REPO_ROOT}/linux/common/crictl.yaml" \
    /etc/crictl.yaml


#
# --------------------------------------------------------------------
# Optional Cilium CLI — controller only
# --------------------------------------------------------------------
#

if [[ "${INSTALL_CILIUM_CLI}" == "1" ]]; then

    if [[ "${ROLE}" != "controller" ]]; then
        die "Cilium CLI installation is only expected on controller"
    fi

    CILIUM_ARCHIVE="${TMPDIR_K8SLAB}/cilium.tar.gz"
    CILIUM_DIR="${TMPDIR_K8SLAB}/cilium"

    mkdir -p "${CILIUM_DIR}"

    CILIUM_URL="https://github.com/cilium/cilium-cli/releases/download/v${CILIUM_CLI_VERSION}/cilium-linux-amd64.tar.gz"

    log "installing Cilium CLI v${CILIUM_CLI_VERSION}"

    curl -fL \
        "${CILIUM_URL}" \
        -o "${CILIUM_ARCHIVE}"

    tar -xzf \
        "${CILIUM_ARCHIVE}" \
        -C "${CILIUM_DIR}"

    [[ -f "${CILIUM_DIR}/cilium" ]] ||
        die "Cilium binary missing from release archive"

    ACTUAL_CILIUM_SHA="$(
        sha256sum "${CILIUM_DIR}/cilium" |
        awk '{print $1}'
    )"

    if [[ "${ACTUAL_CILIUM_SHA}" != "${CILIUM_CLI_SHA256}" ]]; then
        die "Cilium CLI SHA256 mismatch: expected ${CILIUM_CLI_SHA256}, got ${ACTUAL_CILIUM_SHA}"
    fi

    install -m 0755 \
        "${CILIUM_DIR}/cilium" \
        /usr/local/bin/cilium
fi


#
# --------------------------------------------------------------------
# Proven WSL persistence configuration
# --------------------------------------------------------------------
#

if [[ "${ROLE}" == "controller" ]]; then

    install -m 0755 \
        "${REPO_ROOT}/linux/controller/k8slab-controller-network.sh" \
        /usr/local/sbin/k8slab-controller-network.sh

    install -D -m 0644 \
        "${REPO_ROOT}/linux/controller/k8slab-controller-network.service" \
        /etc/systemd/system/k8slab-controller-network.service

    install -D -m 0644 \
        "${REPO_ROOT}/linux/controller/30-k8slab-network.conf" \
        /etc/systemd/system/kubelet.service.d/30-k8slab-network.conf

    install -D -m 0644 \
        "${REPO_ROOT}/linux/controller/99-k8slab-inotify.conf" \
        /etc/sysctl.d/99-k8slab-inotify.conf

else

    WORKER_REPO="${REPO_ROOT}/linux/workers/${ROLE}"

    install -m 0755 \
        "${WORKER_REPO}/k8slab-worker-network.sh" \
        /usr/local/sbin/k8slab-worker-network.sh

    install -D -m 0644 \
        "${WORKER_REPO}/k8slab-netns.service" \
        /etc/systemd/system/k8slab-netns.service

    install -D -m 0644 \
        "${WORKER_REPO}/10-netns.conf" \
        /etc/systemd/system/containerd.service.d/10-netns.conf

    install -D -m 0644 \
        "${WORKER_REPO}/20-wsl-netns.conf" \
        /etc/systemd/system/kubelet.service.d/20-wsl-netns.conf

    install -D -m 0644 \
        "${WORKER_REPO}/99-k8slab-inotify.conf" \
        /etc/sysctl.d/99-k8slab-inotify.conf

fi


#
# Apply the shared WSL kernel limit immediately.
#
sysctl --system >/dev/null


#
# systemd integration.
#
systemctl daemon-reload

systemctl enable containerd.service
systemctl enable kubelet.service

if [[ "${ROLE}" == "controller" ]]; then

    systemctl enable \
        k8slab-controller-network.service

else

    systemctl enable \
        k8slab-netns.service

fi


#
# Package installation may have auto-started these services.
# Stop them deliberately.
#
# The Windows launcher/bootstrap workflow will start them later in the
# correct controller -> worker order, after all three nodes are provisioned.
#
systemctl stop kubelet.service >/dev/null 2>&1 || true
systemctl stop containerd.service >/dev/null 2>&1 || true

systemctl reset-failed kubelet.service >/dev/null 2>&1 || true
systemctl reset-failed containerd.service >/dev/null 2>&1 || true


#
# --------------------------------------------------------------------
# Final verification
# --------------------------------------------------------------------
#

log "verifying installed versions"

kubeadm version -o short
kubelet --version
containerd --version
runc --version | head -1
crictl --version

if [[ "${INSTALL_KUBECTL}" == "1" ]]; then
    kubectl version --client=true
fi

if [[ "${INSTALL_CILIUM_CLI}" == "1" ]]; then
    cilium version --client
fi

grep -n \
    'SystemdCgroup' \
    /etc/containerd/config.toml

echo
log "${ROLE} provisioning completed successfully"
echo
log "A WSL restart is required before relying on the new hostname/wsl.conf."