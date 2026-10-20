#!/usr/bin/env bash
set -euo pipefail

TOKEN_FILE=/vagrant/k3s_token

# Do not let a worker consume a token left over from an earlier `vagrant up`.
rm -f "$TOKEN_FILE"

echo "Installing K3s Server in Controller Mode"
curl -sfL https://get.k3s.io | sh -s - --write-kubeconfig-mode 644

until [ -s /var/lib/rancher/k3s/server/node-token ]; do sleep 1; done

# Publish only a complete token.  The rename prevents the worker from reading a
# partially-written shared file.
install -m 600 /var/lib/rancher/k3s/server/node-token "${TOKEN_FILE}.tmp"
mv -f "${TOKEN_FILE}.tmp" "$TOKEN_FILE"
echo "Token successfully saved to shared folder."
