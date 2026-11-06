#!/usr/bin/env bash
# K3s in agent mode on <login>SW, joining the server at $SERVER_IP.
set -euo pipefail

: "${K3S_TOKEN:?K3S_TOKEN must be provided by the Vagrantfile}"
: "${SERVER_IP:?SERVER_IP must be provided by the Vagrantfile}"
: "${NODE_IP:?NODE_IP must be provided by the Vagrantfile}"

IFACE=$(ip -o -4 addr show | awk -v ip="$NODE_IP" '$4 ~ "^"ip"/" {print $2; exit}')
if [ -z "$IFACE" ]; then
  echo "No interface carries $NODE_IP" >&2
  exit 1
fi

if systemctl is-active --quiet firewalld; then
  systemctl disable --now firewalld
fi

echo "Waiting for the K3s server at https://${SERVER_IP}:6443..."
until curl -ksf --max-time 3 "https://${SERVER_IP}:6443/ping" >/dev/null; do sleep 3; done

echo "Installing K3s agent on $(hostname) ($NODE_IP via $IFACE)..."
curl -sfL https://get.k3s.io | \
  K3S_URL="https://${SERVER_IP}:6443" K3S_TOKEN="$K3S_TOKEN" sh -s - agent \
  --node-ip "$NODE_IP" \
  --flannel-iface "$IFACE"

echo "alias k=kubectl" > /etc/profile.d/kubectl-alias.sh
echo "K3s agent installed and joined ${SERVER_IP}."
