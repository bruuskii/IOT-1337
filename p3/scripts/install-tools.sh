#!/usr/bin/env bash
# Installs everything Part 3 needs on an Ubuntu/Debian VM: Docker, kubectl, k3d.
# Safe to re-run: tools already present are left untouched.
set -euo pipefail

K3D_VERSION="${K3D_VERSION:-v5.9.0}"

SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  SUDO="sudo"
fi

case "$(uname -m)" in
  x86_64)        ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

if ! command -v docker >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1 \
   || ! command -v curl >/dev/null 2>&1; then
  echo "[tools] Installing Docker, git and curl from the distribution..."
  $SUDO apt-get update -y
  $SUDO apt-get install -y docker.io git curl ca-certificates
fi
$SUDO systemctl enable --now docker

# Let the invoking user talk to Docker without sudo (takes effect in new
# sessions; the calling scripts use `sg docker` meanwhile).
TARGET_USER="${SUDO_USER:-$(id -un)}"
if [ "$TARGET_USER" != "root" ] && ! id -nG "$TARGET_USER" | grep -qw docker; then
  echo "[tools] Adding $TARGET_USER to the docker group..."
  $SUDO usermod -aG docker "$TARGET_USER"
fi

if ! command -v kubectl >/dev/null 2>&1; then
  echo "[tools] Installing kubectl..."
  KUBECTL_VERSION="$(curl -fsSL https://dl.k8s.io/release/stable.txt)"
  tmp="$(mktemp -d)"
  curl -fsSLo "$tmp/kubectl" "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl"
  curl -fsSLo "$tmp/kubectl.sha256" "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl.sha256"
  echo "$(cat "$tmp/kubectl.sha256")  $tmp/kubectl" | sha256sum --check --quiet
  $SUDO install -m 0755 "$tmp/kubectl" /usr/local/bin/kubectl
  rm -rf "$tmp"
fi

if ! command -v k3d >/dev/null 2>&1; then
  echo "[tools] Installing k3d ${K3D_VERSION}..."
  curl -fsSL https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh \
    | TAG="$K3D_VERSION" USE_SUDO=true bash
fi

echo "[tools] docker:  $(docker --version 2>/dev/null || $SUDO docker --version)"
echo "[tools] kubectl: $(kubectl version --client 2>/dev/null | head -1)"
echo "[tools] k3d:     $(k3d version | head -1)"
