#!/usr/bin/env bash
# K3s in server (controller) mode on <login>S.
set -euo pipefail

: "${K3S_TOKEN:?K3S_TOKEN must be provided by the Vagrantfile}"
: "${NODE_IP:?NODE_IP must be provided by the Vagrantfile}"

# The first NIC is VirtualBox NAT (10.0.2.15 on every VM). K3s must advertise
# and route pod traffic over the dedicated private interface instead.
IFACE=$(ip -o -4 addr show | awk -v ip="$NODE_IP" '$4 ~ "^"ip"/" {print $2; exit}')
if [ -z "$IFACE" ]; then
  echo "No interface carries $NODE_IP" >&2
  exit 1
fi

# K3s recommends disabling firewalld; the cloud image may or may not ship it.
if systemctl is-active --quiet firewalld; then
  systemctl disable --now firewalld
fi

echo "Installing K3s server on $(hostname) ($NODE_IP via $IFACE)..."
curl -sfL https://get.k3s.io | K3S_TOKEN="$K3S_TOKEN" sh -s - server \
  --node-ip "$NODE_IP" \
  --advertise-address "$NODE_IP" \
  --flannel-iface "$IFACE" \
  --write-kubeconfig-mode 644 \
  --disable traefik \
  --disable metrics-server
# Part 1 serves no application: dropping the ingress controller and the
# metrics server keeps the control plane inside 1024 MB without swapping.

echo "Waiting for the node to be Ready..."
# Kubernetes stores node names in lowercase (izouineS -> izouines).
NODE_NAME=$(hostname | tr "[:upper:]" "[:lower:]")
until /usr/local/bin/kubectl get node "$NODE_NAME" >/dev/null 2>&1; do sleep 2; done
/usr/local/bin/kubectl wait --for=condition=Ready node/"$NODE_NAME" --timeout=300s

# Short alias used during the defense.
echo "alias k=kubectl" > /etc/profile.d/kubectl-alias.sh
echo "K3s server ready."
