#!/usr/bin/env bash
# K3s server + three web applications routed by Host header through Traefik.
set -euo pipefail

: "${NODE_IP:?NODE_IP must be provided by the Vagrantfile}"
: "${CONFS_DIR:?CONFS_DIR must be provided by the Vagrantfile}"
KUBECTL=/usr/local/bin/kubectl

IFACE=$(ip -o -4 addr show | awk -v ip="$NODE_IP" '$4 ~ "^"ip"/" {print $2; exit}')
if [ -z "$IFACE" ]; then
  echo "No interface carries $NODE_IP" >&2
  exit 1
fi

if systemctl is-active --quiet firewalld; then
  systemctl disable --now firewalld
fi

echo "Installing K3s server on $(hostname) ($NODE_IP via $IFACE)..."
curl -sfL https://get.k3s.io | sh -s - server \
  --node-ip "$NODE_IP" \
  --advertise-address "$NODE_IP" \
  --flannel-iface "$IFACE" \
  --write-kubeconfig-mode 644

until $KUBECTL get node "$(hostname)" >/dev/null 2>&1; do sleep 2; done
$KUBECTL wait --for=condition=Ready node/"$(hostname)" --timeout=180s

echo "Deploying the three applications and the Ingress..."
$KUBECTL apply -f "$CONFS_DIR"
$KUBECTL rollout status deployment/app-one   --timeout=300s
$KUBECTL rollout status deployment/app-two   --timeout=300s
$KUBECTL rollout status deployment/app-three --timeout=300s

# Traefik is installed asynchronously by K3s' bundled Helm controller.
echo "Waiting for the Traefik ingress controller..."
until $KUBECTL -n kube-system get deployment traefik >/dev/null 2>&1; do sleep 3; done
$KUBECTL -n kube-system rollout status deployment/traefik --timeout=300s

echo "alias k=kubectl" > /etc/profile.d/kubectl-alias.sh

echo "Smoke test:"
for host in app1.com app2.com other.com; do
  for _ in $(seq 1 30); do
    if out=$(curl -sf --max-time 3 -H "Host: $host" "http://$NODE_IP/"); then
      echo "  $host -> $(echo "$out" | grep -o 'Hello from [^.]*')"
      break
    fi
    sleep 2
  done
done
