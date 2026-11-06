#!/usr/bin/env bash

# Bonus - K3d + Argo CD + local GitLab CE (namespace "gitlab") + playground app.
#
# Same GitOps loop as Part 3, but Argo CD watches a repository hosted on the
# local GitLab instead of GitHub. Safe to re-run: existing pieces are reused.

set -euo pipefail

CLUSTER_NAME="iot"
ARGOCD_NS="argocd"
DEV_NS="dev"
GITLAB_NS="gitlab"
APP_NAME="playground"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFS_DIR="${SCRIPT_DIR}/../confs"
# GitLab rejects weak root passwords (common ones, or containing "gitlab",
# "root", "admin"...): the first boot would then not set it. Keep it strong.
GITLAB_ROOT_PASSWORD="${GITLAB_ROOT_PASSWORD:-Inc3ption-0f-Th1ngs-42}"
ARGOCD_VERSION="v3.5.6"
GITLAB_URL="http://localhost:8181"
REPO_URL_HOST="${GITLAB_URL}/root/${APP_NAME}.git"
REPO_URL_CLUSTER="http://gitlab.${GITLAB_NS}.svc.cluster.local:8181/root/${APP_NAME}.git"

echo "============================================="
echo " [BONUS] Setting up K3d + Argo CD + GitLab   "
echo "============================================="


# 0. Prerequisites (Docker, git, kubectl, k3d)

"${SCRIPT_DIR}/install-tools.sh"

# A user just added to the docker group only gets it in a new login session.
if ! docker info >/dev/null 2>&1; then
  if [ -z "${IOT_SG_REEXEC:-}" ] && getent group docker | grep -qw "$(id -un)"; then
    export IOT_SG_REEXEC=1
    exec sg docker -c "$(printf '%q ' bash "${BASH_SOURCE[0]}" "$@")"
  fi
  echo "[BONUS] Error: cannot reach the Docker daemon."
  exit 1
fi

# Part 3's cluster publishes port 8888 too: the bonus cluster replaces it.
if k3d cluster get iot-p3 >/dev/null 2>&1; then
  echo "[BONUS] Deleting the Part 3 cluster 'iot-p3' (port 8888 is needed here)..."
  k3d cluster delete iot-p3
fi


# 1. K3d cluster

if k3d cluster get "${CLUSTER_NAME}" >/dev/null 2>&1; then
  echo "[BONUS] K3d cluster '${CLUSTER_NAME}' already exists, reusing it."
  k3d kubeconfig merge "${CLUSTER_NAME}" --kubeconfig-switch-context >/dev/null
else
  echo "[BONUS] Creating K3d cluster '${CLUSTER_NAME}'..."
  # 8888 -> playground app, 8181 -> GitLab (UI + git over HTTP),
  # 8080 -> Traefik (Argo CD UI).
  k3d cluster create "${CLUSTER_NAME}" \
    -p "8888:8888@loadbalancer" \
    -p "8181:8181@loadbalancer" \
    -p "8080:80@loadbalancer" \
    --wait
fi
kubectl wait --for=condition=Ready node --all --timeout=180s


# 2. Namespaces

echo "[BONUS] Ensuring namespaces exist..."
for ns in "${ARGOCD_NS}" "${DEV_NS}" "${GITLAB_NS}"; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
done


# 3. GitLab CE (started first: its first boot is by far the longest step)

kubectl create secret generic gitlab-root-password -n "${GITLAB_NS}" \
  --from-literal=password="${GITLAB_ROOT_PASSWORD}" \
  --dry-run=client -o yaml | kubectl apply -f -
echo "[BONUS] Applying GitLab deployment..."
kubectl apply -f "${CONFS_DIR}/gitlab.yaml"


# 4. Argo CD (installed while GitLab boots)

if kubectl get deployment argocd-server -n "${ARGOCD_NS}" >/dev/null 2>&1; then
  echo "[BONUS] Argo CD is already installed."
else
  echo "[BONUS] Installing Argo CD ${ARGOCD_VERSION}..."
  kubectl apply -n "${ARGOCD_NS}" --server-side --force-conflicts \
    -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"

  # Not needed here; frees memory for GitLab.
  kubectl scale deployment -n "${ARGOCD_NS}" --replicas=0 \
    argocd-dex-server argocd-notifications-controller argocd-applicationset-controller

  # Poll Git every ~10s instead of every 2-3 min.
  kubectl patch configmap argocd-cm -n "${ARGOCD_NS}" --type merge \
    -p '{"data": {"timeout.reconciliation": "10s", "timeout.reconciliation.jitter": "0s"}}'
  # Serve plain HTTP behind Traefik (otherwise the UI loops on redirects).
  kubectl patch configmap argocd-cmd-params-cm -n "${ARGOCD_NS}" --type merge \
    -p '{"data": {"server.insecure": "true"}}'
  # Config maps are only read at startup: restart so both patches apply.
  kubectl rollout restart deployment/argocd-server deployment/argocd-repo-server -n "${ARGOCD_NS}"
  kubectl rollout restart statefulset/argocd-application-controller -n "${ARGOCD_NS}"
fi
kubectl apply -f "${CONFS_DIR}/ingress.yaml"

echo "[BONUS] Waiting for Argo CD..."
for res in deployment/argocd-server deployment/argocd-repo-server statefulset/argocd-application-controller; do
  kubectl rollout status "$res" -n "${ARGOCD_NS}" --timeout=600s
done

ARGOCD_PASSWORD=$(kubectl -n "${ARGOCD_NS}" get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d)


# 5. Wait for GitLab

echo "[BONUS] Waiting for GitLab (first boot: image pull + migrations, 10-20 min)..."
kubectl rollout status deployment/gitlab -n "${GITLAB_NS}" --timeout=1800s

gitlab_http_ok() {
  curl -s -o /dev/null -w "%{http_code}" --max-time 5 "${GITLAB_URL}/users/sign_in" | grep -q "^200$"
}
for i in $(seq 1 60); do
  gitlab_http_ok && break
  if [ "$i" -eq 60 ]; then
    echo "[BONUS] Error: GitLab is not answering on ${GITLAB_URL}."
    exit 1
  fi
  echo "  Waiting for GitLab HTTP... (${i}/60)"
  sleep 5
done
echo "[BONUS] GitLab is up on ${GITLAB_URL}."


# 6. GitLab repository root/playground, seeded with the v1 manifest
#    (GitLab creates the project on the first push to a new path).

# Authenticate git as root without writing the password in any URL or file.
GIT_AUTH=(-c "http.extraHeader=Authorization: Basic $(printf '%s' "root:${GITLAB_ROOT_PASSWORD}" | base64 -w0)")

if git "${GIT_AUTH[@]}" ls-remote --exit-code "${REPO_URL_HOST}" refs/heads/main >/dev/null 2>&1; then
  # Never overwrite a version changed during the defense.
  echo "[BONUS] GitLab repository root/${APP_NAME} already exists, keeping its content."
else
  echo "[BONUS] Creating GitLab repository root/${APP_NAME} (v1)..."
  SEED_DIR="$(mktemp -d)"
  trap 'rm -rf "${SEED_DIR}"' EXIT
  cp "${CONFS_DIR}/deployment.yaml" "${SEED_DIR}/deployment.yaml"
  git -C "${SEED_DIR}" init -q -b main
  git -C "${SEED_DIR}" add deployment.yaml
  git -C "${SEED_DIR}" -c user.name="Administrator" -c user.email="admin@example.com" \
    commit -q -m "Add playground deployment (v1)"
  for i in $(seq 1 10); do
    git -C "${SEED_DIR}" "${GIT_AUTH[@]}" push -q "${REPO_URL_HOST}" main && break
    if [ "$i" -eq 10 ]; then
      echo "[BONUS] Error: cannot push to ${REPO_URL_HOST} (wrong root password?)."
      exit 1
    fi
    echo "  Push failed, retrying in 10s... (${i}/10)"
    sleep 10
  done
  echo "[BONUS] Repository created and seeded."
fi


# 7. Argo CD: repository credentials + Application

echo "[BONUS] Configuring Argo CD repository credentials..."
kubectl apply -n "${ARGOCD_NS}" -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: gitlab-repo-creds
  namespace: ${ARGOCD_NS}
  labels:
    argocd.argoproj.io/secret-type: repository
type: Opaque
stringData:
  type: git
  url: ${REPO_URL_CLUSTER}
  username: root
  password: ${GITLAB_ROOT_PASSWORD}
EOF

echo "[BONUS] Applying Argo CD application manifest..."
kubectl apply -f "${CONFS_DIR}/argocd-app.yaml"
# Force a refresh so the repo-server picks up the credentials immediately.
kubectl annotate application "${APP_NAME}" -n "${ARGOCD_NS}" \
  argocd.argoproj.io/refresh=hard --overwrite

echo "[BONUS] Waiting for the application to sync..."
for i in $(seq 1 60); do
  SYNC=$(kubectl get application "${APP_NAME}" -n "${ARGOCD_NS}" \
    -o jsonpath='{.status.sync.status}' 2>/dev/null || true)
  HEALTH=$(kubectl get application "${APP_NAME}" -n "${ARGOCD_NS}" \
    -o jsonpath='{.status.health.status}' 2>/dev/null || true)
  if [ "${SYNC}" = "Synced" ] && [ "${HEALTH}" = "Healthy" ]; then
    echo "[BONUS] Application is Synced and Healthy."
    break
  fi
  echo "  Sync: ${SYNC:-Pending} | Health: ${HEALTH:-Pending} (${i}/60)"
  sleep 5
done


# Summary

echo ""
echo "============================================="
echo "         [BONUS] Setup Complete!             "
echo "============================================="
echo ""
echo "  GitLab UI:   ${GITLAB_URL}"
echo "    User:      root"
echo "    Password:  ${GITLAB_ROOT_PASSWORD}"
echo "    (set on GitLab's first boot only; if the gitlab-data volume already"
echo "     existed, the password chosen at that time still applies)"
echo ""
echo "  Argo CD UI:  http://localhost:8080"
echo "    User:      admin"
echo "    Password:  ${ARGOCD_PASSWORD}"
echo ""
echo "  App:         http://localhost:8888"
echo ""

echo " Namespaces"
kubectl get ns
echo ""
echo " GitLab Pods"
kubectl get pods -n "${GITLAB_NS}"
echo ""
echo " Argo CD Pods"
kubectl get pods -n "${ARGOCD_NS}"
echo ""
echo " App Pods"
kubectl get pods -n "${DEV_NS}"
echo ""

echo "[BONUS] Testing app on http://localhost:8888..."
if curl -s --max-time 5 http://localhost:8888/; then
  echo ""
else
  echo "[BONUS] App not responding yet, give it a few seconds to start."
fi
echo ""
echo "To test the GitOps loop (v1 -> v2):"
echo "  git clone ${REPO_URL_HOST} && cd ${APP_NAME}      # user: root / password above"
echo "  sed -i 's/playground:v1/playground:v2/' deployment.yaml"
echo "  git commit -am v2 && git push"
echo "  # wait ~10-20s for Argo CD to sync, then:"
echo "  curl http://localhost:8888"
