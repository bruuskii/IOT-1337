#!/usr/bin/env bash
set -euo pipefail

TOKEN_FILE=/vagrant/k3s_token

echo "Installing K3s Agent..."
echo "Waiting for a complete token in the shared folder..."
until [ -s "$TOKEN_FILE" ]; do sleep 2; done

export K3S_TOKEN
K3S_TOKEN=$(<"$TOKEN_FILE")
export K3S_URL=https://192.168.56.110:6443

echo "Token found. Installing K3s Agent with the token..."
curl -sfL https://get.k3s.io | sh -
