#!/usr/bin/env bash
# Prepare a node for kubeadm: swap, SELinux, kernel modules, sysctl, /etc/hosts.
# Safe to re-run (idempotent). Does NOT touch the firewall, install containerd,
# or install kubeadm; follow docs/01-os-preparation.md for those steps.
#
# Usage: sudo ./scripts/prepare-node.sh [path/to/hosts-file]
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run as root (use sudo)." >&2
  exit 1
fi

HOSTS_FILE="${1:-$(dirname "$0")/../configs/hosts.example}"

# shellcheck disable=SC1091
. /etc/os-release
echo ">> Detected OS: ${PRETTY_NAME:-unknown}"

echo ">> Disabling swap"
swapoff -a
sed -i '/\sswap\s/ s/^\([^#]\)/#\1/' /etc/fstab

if command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce)" != "Disabled" ]]; then
  echo ">> Setting SELinux to permissive (lab setting)"
  setenforce 0 || true
  sed -i 's/^SELINUX=enforcing$/SELINUX=permissive/' /etc/selinux/config
fi

echo ">> Loading kernel modules"
modprobe overlay
modprobe br_netfilter
cat > /etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF

echo ">> Applying sysctl settings"
cat > /etc/sysctl.d/k8s.conf <<'EOF'
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables  = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system >/dev/null

if [[ -f "$HOSTS_FILE" ]]; then
  if ! grep -q '# k8s-ha-cluster' /etc/hosts; then
    echo ">> Adding cluster hosts to /etc/hosts"
    { echo '# k8s-ha-cluster'; grep -v '^#' "$HOSTS_FILE"; } >> /etc/hosts
  else
    echo ">> /etc/hosts already contains the cluster entries, skipping"
  fi
else
  echo "!! Hosts file not found: $HOSTS_FILE (skipping /etc/hosts update)" >&2
fi

echo
echo "Done. Remember to:"
echo "  - set a unique lowercase hostname:  hostnamectl set-hostname <name>"
echo "  - configure the firewall, install containerd and kubeadm (docs/01-os-preparation.md)"
