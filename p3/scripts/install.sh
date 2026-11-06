#!/usr/bin/env bash
# Part 3: K3d cluster + Argo CD continuously deploying p3/confs/app from GitHub.
#   - namespace "argocd": Argo CD
#   - namespace "dev":    the wil42/playground application (port 8888)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFS_DIR="${SCRIPT_DIR}/../confs"
CLUSTER_NAME="iot-p3"
ARGOCD_VERSION="v3.5.6"
APP_NAME="playground"

# 1. Tools (Docker, kubectl, k3d).
"${SCRIPT_DIR}/install-tools.sh"

# A user just added to the docker group only gets it in a new login session:
# re-run this script under that group instead of asking for a re-login.
if ! docker info >/dev/null 2>&1; then
  if [ -z "${IOT_SG_REEXEC:-}" ] && getent group docker | grep -qw "$(id -un)"; then
    export IOT_SG_REEXEC=1
    exec sg docker -c "$(printf '%q ' bash "${BASH_SOURCE[0]}" "$@")"
  fi
  echo "Cannot reach the Docker daemon (is it running, are you in the docker group?)" >&2
  exit 1
fi

# 2. Cluster. The k3d load balancer publishes port 8888 on the VM, where the
#    playground LoadBalancer Service listens.
if k3d cluster get "$CLUSTER_NAME" >/dev/null 2>&1; then
  echo "K3d cluster '$CLUSTER_NAME' already exists, reusing it."
  k3d kubeconfig merge "$CLUSTER_NAME" --kubeconfig-switch-context >/dev/null
else
  echo "Creating K3d cluster '$CLUSTER_NAME'..."
  k3d cluster create "$CLUSTER_NAME" -p "8888:8888@loadbalancer" --wait
fi
kubectl wait --for=condition=Ready nodes --all --timeout=180s

# 3. Namespaces.
for ns in argocd dev; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
done

# 4. Argo CD (server-side apply: its CRDs exceed the client-side annotation limit).
echo "Installing Argo CD ${ARGOCD_VERSION}..."
kubectl apply -n argocd --server-side --force-conflicts \
  -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"
kubectl wait --for=condition=Available deployment --all -n argocd --timeout=600s
kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=300s

# 5. The Application: Argo CD watches the public GitHub repository.
kubectl apply -f "${CONFS_DIR}/argocd-application.yaml"

echo "Waiting for Argo CD to sync the application..."
for i in $(seq 1 60); do
  sync=$(kubectl -n argocd get application "$APP_NAME" -o jsonpath='{.status.sync.status}' 2>/dev/null || true)
  health=$(kubectl -n argocd get application "$APP_NAME" -o jsonpath='{.status.health.status}' 2>/dev/null || true)
  echo "  sync=${sync:-?} health=${health:-?} (${i}/60)"
  [ "$sync" = "Synced" ] && [ "$health" = "Healthy" ] && break
  sleep 5
done

ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d)

echo
kubectl get ns
kubectl get pods -n dev
echo
echo "App:        curl http://localhost:8888/"
curl -s --max-time 5 http://localhost:8888/ && echo || echo "(not answering yet, retry in a few seconds)"
echo
echo "Argo CD UI: kubectl port-forward svc/argocd-server -n argocd 8080:443"
echo "            then open https://localhost:8080  (user: admin  password: ${ARGOCD_PASSWORD})"
echo
echo "Switch version (from the repo root):"
echo "  sed -i 's/playground:v1/playground:v2/' p3/confs/app/deployment.yaml"
echo "  git commit -am 'v2' && git push"
echo "  # Argo CD polls every ~3 min; click REFRESH in the UI to sync immediately."
