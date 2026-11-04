#!/usr/bin/env bash
set -euo pipefail

# P3 is intentionally self-contained: the evaluator can run this script on a
# clean VM after installing Docker. It creates the K3d cluster and Argo CD.

CLUSTER_NAME="iot-cluster"
ARGOCD_VERSION="stable"

if ! command -v docker >/dev/null 2>&1; then
  echo "Docker is required. Install Docker first."
  exit 1
fi

if ! docker info >/dev/null 2>&1; then
  echo "Docker is installed but is not running. Start Docker and try again."
  exit 1
fi

if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl is required. Install kubectl first."
  exit 1
fi

if ! command -v k3d >/dev/null 2>&1; then
  echo "Installing k3d..."
  curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
fi

if ! k3d cluster get "$CLUSTER_NAME" >/dev/null 2>&1; then
  echo "Creating K3d cluster: $CLUSTER_NAME"
  k3d cluster create "$CLUSTER_NAME"
else
  echo "K3d cluster already exists: $CLUSTER_NAME"
fi

kubectl wait --for=condition=Ready nodes --all --timeout=120s

echo "Installing Argo CD..."
kubectl apply -n argocd -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"
kubectl wait --for=condition=Available deployment --all -n argocd --timeout=300s

echo "Creating the dev namespace."
kubectl apply -f "$(dirname "$0")/../manifests/namespace.yaml"

echo "Registering the GitHub application with Argo CD."
kubectl apply -f "$(dirname "$0")/../argocd-application.yaml"

echo
echo "P3 is installed. Check the result with:"
echo "  kubectl get pods -n argocd"
echo "  kubectl get pods -n dev"
echo "  kubectl get applications -n argocd"
