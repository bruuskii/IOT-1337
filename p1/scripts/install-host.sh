#!/usr/bin/env bash
# Host prerequisites for p1 and p2 on the Ubuntu VM: Vagrant + VirtualBox.
# Safe to re-run.
set -euo pipefail

# This Ubuntu VM runs VirtualBox VMs itself: the physical host must expose
# VT-x/AMD-V to it. With the Ubuntu VM powered off, on the physical host:
#   VBoxManage modifyvm "<ubuntu-vm-name>" --nested-hw-virt on
if ! grep -qE 'vmx|svm' /proc/cpuinfo; then
  echo "No VT-x/AMD-V in this VM: enable nested virtualization on the host first:" >&2
  echo "  VBoxManage modifyvm \"<ubuntu-vm-name>\" --nested-hw-virt on" >&2
  exit 1
fi

if ! command -v vagrant >/dev/null 2>&1; then
  echo "[host] Installing Vagrant from the HashiCorp repository..."
  sudo apt-get update -y
  sudo apt-get install -y curl gpg lsb-release
  curl -fsSL https://apt.releases.hashicorp.com/gpg \
    | sudo gpg --dearmor --yes -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
  echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
    | sudo tee /etc/apt/sources.list.d/hashicorp.list >/dev/null
  sudo apt-get update -y
  sudo apt-get install -y vagrant
fi

if ! command -v VBoxManage >/dev/null 2>&1; then
  echo "[host] Installing VirtualBox..."
  sudo apt-get install -y virtualbox
fi

vagrant --version
VBoxManage --version
echo "[host] Ready. Run p1 and p2 one at a time (both use 192.168.56.110):"
echo "  cd p1 && vagrant up    ...    vagrant destroy -f"
