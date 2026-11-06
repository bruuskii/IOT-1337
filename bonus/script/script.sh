#!/bin/bash

# Bonus - Setup K3d + Lightweight Argo CD + GitLab Omnibus + Playground App
#
# Idempotent & Resumable:
#   - Reuses existing cluster if already created
#   - Detects existing images in cluster cache
#   - Direct-streams large images via ctr (avoids k3d deadlock)
#   - Skips already-healthy components (ArgoCD, GitLab, Repo, App)
#   - Resumes seamlessly from the point of failure


set -euo pipefail 

CLUSTER_NAME="iot"
ARGOCD_NS="argocd"
DEV_NS="dev"
GITLAB_NS="gitlab"
APP_NAME="playground"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFS_DIR="${SCRIPT_DIR}/../config"
GITLAB_ROOT_PASSWORD="${GITLAB_ROOT_PASSWORD:-password}"
ARGOCD_VERSION="v2.14.11"

echo "============================================="
echo " [BONUS] Setting up K3d + Argo CD + GitLab   "
echo "============================================="


# 1. Ensure K3d cluster exists

if k3d cluster list 2>/dev/null | grep -qw "${CLUSTER_NAME}"; then
  echo "[BONUS] K3d cluster '${CLUSTER_NAME}' already exists — reusing."
else
  echo "[BONUS] Creating K3d cluster '${CLUSTER_NAME}'..."
  # Port 8888 -> Application (wil42/playground uses port 8888)
  # Port 8181 -> GitLab Web UI & HTTP Git
  # Port 8080 -> Argo CD Web UI
  k3d cluster create "${CLUSTER_NAME}" \
    -p "8888:8888@loadbalancer" \
    -p "8181:8181@loadbalancer" \
    -p "8080:80@loadbalancer" \
    --wait
fi

echo "[BONUS] Verifying cluster node readiness..."
kubectl wait --for=condition=ready node --all --timeout=60s


# 2. Resumable Image Loading into K3d

echo "[BONUS] Checking container images inside cluster..."
NODE_CONTAINER="k3d-${CLUSTER_NAME}-server-0"

# Function to check if image exists in cluster
image_in_cluster() {
  local img_name="$1"
  docker exec -i "${NODE_CONTAINER}" sh -c 'crictl images 2>/dev/null || ctr -n k8s.io images list 2>/dev/null' | grep -q "${img_name}"
}

if image_in_cluster "gitlab/gitlab-ce"; then
  echo "[BONUS] GitLab image already present inside cluster."
else
  echo "[BONUS] GitLab image missing from cluster. Preparing import..."
  if ! docker image inspect "gitlab/gitlab-ce:latest" &>/dev/null; then
    echo "[BONUS] Pulling gitlab/gitlab-ce:latest to host first..."
    docker pull gitlab/gitlab-ce:latest
  fi
  echo "[BONUS] Direct-streaming gitlab/gitlab-ce into cluster..."
  docker save gitlab/gitlab-ce:latest | docker exec -i "${NODE_CONTAINER}" ctr -n k8s.io images import -
  echo "[BONUS] GitLab image successfully loaded into cluster!"

  if kubectl get pod -n "${GITLAB_NS}" -l app=gitlab 2>/dev/null | grep -q "ContainerCreating"; then
    echo "[BONUS] Restarting stuck GitLab pod..."
    kubectl delete pod -n "${GITLAB_NS}" -l app=gitlab --grace-period=0 --force 2>/dev/null || true
  fi
fi

# Check and import smaller images (ArgoCD, Redis, Playground)
MISSING_IMAGES=()
for img in "quay.io/argoproj/argocd:${ARGOCD_VERSION}" "redis:7.0.15-alpine" "wil42/playground:v1"; do
  IMG_NAME=$(echo "$img" | cut -d: -f1)
  if ! image_in_cluster "${IMG_NAME}"; then
    MISSING_IMAGES+=("$img")
  fi
done

if [ ${#MISSING_IMAGES[@]} -gt 0 ]; then
  echo "[BONUS] Importing missing helper images into K3d: ${MISSING_IMAGES[*]}"
  for img in "${MISSING_IMAGES[@]}"; do
    if ! docker image inspect "$img" &>/dev/null; then
      docker pull "$img" || true
    fi
  done
  k3d image import "${MISSING_IMAGES[@]}" -c "${CLUSTER_NAME}" || true
else
  echo "[BONUS] All helper images are already loaded in cluster."
fi


# 3. Create Namespaces

echo "[BONUS] Ensuring namespaces exist..."
for ns in "${ARGOCD_NS}" "${DEV_NS}" "${GITLAB_NS}"; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
done


# 4. Install / Verify Argo CD

ARGOCD_READY=false
if kubectl get deployment argocd-server -n "${ARGOCD_NS}" &>/dev/null; then
  READY_REPLICAS=$(kubectl get deployment argocd-server -n "${ARGOCD_NS}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  if [ "${READY_REPLICAS:-0}" -ge 1 ]; then
    ARGOCD_READY=true
  fi
fi

if [ "${ARGOCD_READY}" = "true" ]; then
  echo "[BONUS] Argo CD is already installed and ready."
  kubectl apply -f "${CONFS_DIR}/ingress.yaml" 2>/dev/null || true
else
  echo "[BONUS] Installing Lightweight Argo CD..."
  kubectl apply -n "${ARGOCD_NS}" --server-side=true \
    -f https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml

  echo "[BONUS] Scaling down unneeded Argo CD components..."
  kubectl scale deployment -n "${ARGOCD_NS}" argocd-dex-server --replicas=0 2>/dev/null || true
  kubectl scale deployment -n "${ARGOCD_NS}" argocd-notifications-controller --replicas=0 2>/dev/null || true
  kubectl scale deployment -n "${ARGOCD_NS}" argocd-applicationset-controller --replicas=0 2>/dev/null || true

  kubectl patch configmap argocd-cm -n "${ARGOCD_NS}" \
    --type merge -p '{"data": {"timeout.reconciliation": "10s"}}' 2>/dev/null || true
  kubectl patch configmap argocd-cmd-params-cm -n "${ARGOCD_NS}" \
    --type merge -p '{"data": {"server.insecure": "true"}}' 2>/dev/null || true

  echo "[BONUS] Exposing Argo CD UI via Traefik Ingress..."
  kubectl apply -f "${CONFS_DIR}/ingress.yaml"

  echo "[BONUS] Waiting for Argo CD server to be ready..."
  kubectl rollout status deployment/argocd-server -n "${ARGOCD_NS}" --timeout=300s
fi

ARGOCD_PASSWORD=$(kubectl -n "${ARGOCD_NS}" get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" 2>/dev/null | base64 -d || echo "admin")


# 5. Deploy / Verify GitLab CE Omnibus

GITLAB_READY=false
if kubectl get deployment gitlab -n "${GITLAB_NS}" &>/dev/null; then
  GITLAB_REPLICAS=$(kubectl get deployment gitlab -n "${GITLAB_NS}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  if [ "${GITLAB_REPLICAS:-0}" -ge 1 ]; then
    if curl -s -L -o /dev/null -w "%{http_code}" --max-time 5 "http://localhost:8181/users/sign_in" | grep -qE "200|302"; then
      GITLAB_READY=true
    fi
  fi
fi

if [ "${GITLAB_READY}" = "true" ]; then
  echo "[BONUS] GitLab CE is already running and responsive on port 8181."
else
  echo "[BONUS] Applying GitLab deployment..."
  kubectl apply -f "${CONFS_DIR}/gitlab.yaml"

  echo "[BONUS] Waiting for GitLab to become ready..."
  kubectl rollout status deployment/gitlab -n "${GITLAB_NS}" --timeout=900s

  echo "[BONUS] Verifying GitLab HTTP service..."
  for i in $(seq 1 40); do
    if curl -s -L -o /dev/null -w "%{http_code}" --max-time 5 "http://localhost:8181/users/sign_in" | grep -qE "200|302"; then
      echo "[BONUS] GitLab Web UI is up!"
      break
    fi
    echo "  Waiting for GitLab HTTP response... (${i}/40)"
    sleep 1
  done
fi


# 6. Ensure GitLab Token + Project + Manifests

echo "[BONUS] Ensuring GitLab API access token..."
RAW_TOKEN_OUTPUT=$(kubectl exec -n "${GITLAB_NS}" deploy/gitlab -- \
  gitlab-rails runner "
    user = User.find_by_username('root')
    user.personal_access_tokens.where(name: 'iot-automation').destroy_all
    token = user.personal_access_tokens.create!(
      name: 'iot-automation',
      scopes: [:api, :read_repository, :write_repository],
      expires_at: 365.days.from_now
    )
    puts \"TOKEN_DELIM_START:#{token.token}:TOKEN_DELIM_END\"
  " 2>/dev/null || echo "")

GITLAB_TOKEN=$(echo "${RAW_TOKEN_OUTPUT}" | sed -n 's/.*TOKEN_DELIM_START:\(.*\):TOKEN_DELIM_END.*/\1/p' | tr -d '\r\n[:space:]')

if [ -z "${GITLAB_TOKEN}" ]; then
  GITLAB_TOKEN=$(echo "${RAW_TOKEN_OUTPUT}" | grep -o 'glpat-[A-Za-z0-9_\-]*' | head -n1 || echo "")
fi

if [ -z "${GITLAB_TOKEN}" ]; then
  echo "[BONUS] Retrying token creation in 5s..."
  sleep 5
  RAW_TOKEN_OUTPUT=$(kubectl exec -n "${GITLAB_NS}" deploy/gitlab -- \
    gitlab-rails runner "
      user = User.find_by_username('root')
      user.personal_access_tokens.where(name: 'iot-automation').destroy_all
      token = user.personal_access_tokens.create!(
        name: 'iot-automation',
        scopes: [:api, :read_repository, :write_repository],
        expires_at: 365.days.from_now
      )
      puts \"TOKEN_DELIM_START:#{token.token}:TOKEN_DELIM_END\"
    " 2>/dev/null || echo "")
  GITLAB_TOKEN=$(echo "${RAW_TOKEN_OUTPUT}" | sed -n 's/.*TOKEN_DELIM_START:\(.*\):TOKEN_DELIM_END.*/\1/p' | tr -d '\r\n[:space:]')
  if [ -z "${GITLAB_TOKEN}" ]; then
    GITLAB_TOKEN=$(echo "${RAW_TOKEN_OUTPUT}" | grep -o 'glpat-[A-Za-z0-9_\-]*' | head -n1 || echo "")
  fi
fi

if [ -z "${GITLAB_TOKEN}" ]; then
  echo "[BONUS] Error: Failed to generate GitLab personal access token."
  exit 1
fi
echo "[BONUS] GitLab API access token verified."

# Check if project 'playground' already exists in GitLab
PROJECT_RESP=$(curl -s --max-time 10 "http://127.0.0.1:8181/api/v4/projects/root%2Fplayground" \
  -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" 2>/dev/null || echo "")
PROJECT_ID=$(echo "${PROJECT_RESP}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")

if [ -z "${PROJECT_ID}" ]; then
  echo "[BONUS] Creating GitLab project 'playground'..."
  for attempt in 1 2 3; do
    CREATE_RESP=$(curl -s --max-time 15 -X POST "http://127.0.0.1:8181/api/v4/projects" \
      -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
      -H "Content-Type: application/json" \
      -d '{
        "name": "playground",
        "visibility": "public",
        "initialize_with_readme": true
      }' 2>/dev/null || echo "")
    PROJECT_ID=$(echo "${CREATE_RESP}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")
    if [ -n "${PROJECT_ID}" ]; then
      break
    fi
    echo "  Retrying project creation in 5s... (${attempt}/3)"
    sleep 5
  done
  
  if [ -z "${PROJECT_ID}" ]; then
    # Final fallback check if created despite response error
    PROJECT_RESP=$(curl -s --max-time 10 "http://127.0.0.1:8181/api/v4/projects/root%2Fplayground" \
      -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" 2>/dev/null || echo "")
    PROJECT_ID=$(echo "${PROJECT_RESP}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "1")
  fi
  echo "[BONUS] Created GitLab project 'playground' (ID: ${PROJECT_ID})."
else
  echo "[BONUS] GitLab project 'playground' already exists (ID: ${PROJECT_ID})."
fi

# Check if deployment.yaml already exists in project repository
echo "[BONUS] Synchronizing deployment.yaml in GitLab repository..."
FILE_EXISTS_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
  "http://127.0.0.1:8181/api/v4/projects/${PROJECT_ID}/repository/files/deployment.yaml?ref=main" \
  -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" 2>/dev/null || echo "404")

FILE_PAYLOAD=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    content = f.read()
payload = {
    'branch': 'main',
    'content': content,
    'commit_message': 'Synchronize playground deployment manifests'
}
print(json.dumps(payload))
" "${CONFS_DIR}/deployment.yaml")

if [ "${FILE_EXISTS_CODE}" = "200" ]; then
  curl -s --max-time 10 -X PUT \
    "http://127.0.0.1:8181/api/v4/projects/${PROJECT_ID}/repository/files/deployment.yaml" \
    -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "${FILE_PAYLOAD}" >/dev/null 2>&1 || true
  echo "[BONUS] deployment.yaml updated in GitLab repository."
else
  curl -s --max-time 10 -X POST \
    "http://127.0.0.1:8181/api/v4/projects/${PROJECT_ID}/repository/files/deployment.yaml" \
    -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "${FILE_PAYLOAD}" >/dev/null 2>&1 || true
  echo "[BONUS] deployment.yaml pushed to GitLab repository."
fi


# 7. Configure Argo CD Repo Credentials & Application

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
  url: http://gitlab.gitlab.svc.cluster.local:8181/root/playground.git
  username: root
  password: ${GITLAB_TOKEN}
EOF

# Force refresh so repo-server picks up the credentials immediately
kubectl patch application "${APP_NAME}" -n "${ARGOCD_NS}" \
  --type merge -p '{"metadata": {"annotations": {"argocd.argoproj.io/refresh": "hard"}}}' 2>/dev/null || true

SYNC=$(kubectl get application "${APP_NAME}" -n "${ARGOCD_NS}" \
  -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "")
HEALTH=$(kubectl get application "${APP_NAME}" -n "${ARGOCD_NS}" \
  -o jsonpath='{.status.health.status}' 2>/dev/null || echo "")

if [ "${SYNC}" = "Synced" ] && [ "${HEALTH}" = "Healthy" ]; then
  echo "[BONUS] Argo CD application '${APP_NAME}' is already Synced and Healthy!"
else
  echo "[BONUS] Applying Argo CD application manifest..."
  kubectl apply -f "${CONFS_DIR}/argocd-app.yaml"

  echo "[BONUS] Waiting for application to sync..."
  for i in $(seq 1 60); do
    SYNC=$(kubectl get application "${APP_NAME}" -n "${ARGOCD_NS}" \
      -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "")
    HEALTH=$(kubectl get application "${APP_NAME}" -n "${ARGOCD_NS}" \
      -o jsonpath='{.status.health.status}' 2>/dev/null || echo "")
    if [ "${SYNC}" = "Synced" ] && [ "${HEALTH}" = "Healthy" ]; then
      echo "[BONUS] Application is Synced and Healthy!"
      break
    fi
    echo "  Sync: ${SYNC:-Pending} | Health: ${HEALTH:-Pending} (${i}/60)"
    sleep 5
  done
fi


# Summary

echo ""
echo "============================================="
echo "         [BONUS] Setup Complete!             "
echo "============================================="
echo ""
echo "  GitLab UI:   http://localhost:8181"
echo "    User:      root"
echo "    Password:  ${GITLAB_ROOT_PASSWORD}"
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
echo " GitLab Pods "
kubectl get pods -n "${GITLAB_NS}"
echo ""
echo " Argo CD Pods "
kubectl get pods -n "${ARGOCD_NS}"
echo ""
echo " App Pods "
kubectl get pods -n "${DEV_NS}"
echo ""

echo "[BONUS] Testing app on http://localhost:8888..."
sleep 2
if curl -s --max-time 5 http://localhost:8888/ >/dev/null 2>&1; then
  echo "[BONUS] App is responding on http://localhost:8888!"
else
  echo "[BONUS] App not responding yet  give it a few seconds to start."
fi
echo ""
echo "To test the GitOps loop:"
echo "  1. Open GitLab: http://localhost:8181/root/playground"
echo "  2. Edit deployment.yaml (e.g. change image tag v1 to v2)"
echo "  3. Wait ~10s for Argo CD to auto-sync"
echo "  4. Run: curl http://localhost:8888"