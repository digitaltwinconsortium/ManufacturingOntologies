#!/usr/bin/env bash
# Bootstrap.sh - Ubuntu version of the Windows Bootstrap.ps1
# - Logs to /var/log/bootstrap/Bootstrap.log
# - Installs Azure CLI
# - Downloads and unzips DTC ManufacturingOntologies repo
# - Installs K3s (single-node server)

set -u
set -o pipefail

# --------------------------
# Logging (like Start-Transcript)
# --------------------------
sudo mkdir -p /var/log/bootstrap
LOG_FILE="/var/log/bootstrap/Bootstrap.log"

# Log everything (stdout+stderr) to file and console
exec > >(sudo tee -a "${LOG_FILE}") 2>&1

echo "=== Bootstrap started: $(date -Is) ==="
echo "Running as: $(id -un) (uid=$(id -u))"
echo "Kernel: $(uname -a)"

# PowerShell used SilentlyContinue: emulate "continue on error" behavior
# by using a helper that logs failures but does not exit.
try() {
  echo
  echo ">>> $*"
  "$@"
  local rc=$?
  if [ $rc -ne 0 ]; then
    echo "!!! WARNING: command failed (rc=$rc): $*"
  fi
  return 0
}

# --------------------------
# Packages needed for bootstrap
# --------------------------
try sudo apt-get update
try sudo apt-get install -y ca-certificates curl gnupg lsb-release unzip apt-transport-https

# --------------------------
# Install Azure CLI (Ubuntu)
# Recommended: install from Microsoft's APT repository
# --------------------------
# This follows the documented approach: add MS key, add repo, then apt install azure-cli. [1](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli-linux?view=azure-cli-latest)[2](https://documentation.ubuntu.com/azure/azure-how-to/instances/install-azure-cli/)
echo
echo "=== Installing Azure CLI ==="
try sudo mkdir -p /etc/apt/keyrings
try bash -c "curl -sL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor | sudo tee /etc/apt/keyrings/microsoft.gpg > /dev/null"
try sudo chmod go+r /etc/apt/keyrings/microsoft.gpg

# Add Azure CLI repo (uses your Ubuntu codename: noble for 24.04)
AZ_DIST="$(lsb_release -cs)"
try sudo tee /etc/apt/sources.list.d/azure-cli.list > /dev/null <<EOF
deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/azure-cli/ ${AZ_DIST} main
EOF

try sudo apt-get update
try sudo apt-get install -y azure-cli
try az version

# --------------------------
# Download and expand ManufacturingOntologies repo
# --------------------------
echo
echo "=== Downloading ManufacturingOntologies repo ==="
WORKDIR="/opt"
ZIP_PATH="/tmp/ManufacturingOntologies-main.zip"
DEST_DIR="${WORKDIR}/ManufacturingOntologies-main"

try sudo rm -f "${ZIP_PATH}"
try sudo rm -rf "${DEST_DIR}"

try curl -L "https://github.com/digitaltwinconsortium/ManufacturingOntologies/archive/refs/heads/main.zip" -o "${ZIP_PATH}"
try sudo unzip -q "${ZIP_PATH}" -d "${WORKDIR}"
try sudo rm -f "${ZIP_PATH}"

echo "Repo extracted to: ${DEST_DIR}"

# --------------------------
# Fix line endings + make simulation scripts executable
# --------------------------
echo
echo "=== Fixing FactorySimulation scripts (CRLF + executable bit) ==="

FACTORY_SIM_DIR="${DEST_DIR}/Tools/FactorySimulation"

if [ -d "${FACTORY_SIM_DIR}" ]; then
  # 1) Convert CRLF -> LF (common when repos are authored on Windows)
  # Use sed so we don't depend on dos2unix being installed.
  sudo find "${FACTORY_SIM_DIR}" -maxdepth 1 -type f -name "*.sh" -print0 \
    | sudo xargs -0 -r sed -i 's/\r$//'

  # 2) Make scripts executable
  sudo find "${FACTORY_SIM_DIR}" -maxdepth 1 -type f -name "*.sh" -exec chmod +x {} \;

  # Optional: show what we fixed
  sudo ls -l "${FACTORY_SIM_DIR}"/*.sh 2>/dev/null || true
else
  echo "FactorySimulation directory not found: ${FACTORY_SIM_DIR}"
fi

# --------------------------
# Install K3s (single-node server)
# --------------------------
echo
echo "=== Installing K3s ==="
# K3s quick install method: curl -sfL https://get.k3s.io | sh - [3](https://docs.k3s.io/quick-start)[4](https://github.com/k3s-io/k3s/blob/master/install.sh)
# This installs K3s as a systemd service and writes kubeconfig to /etc/rancher/k3s/k3s.yaml. [3](https://docs.k3s.io/quick-start)[5](https://docs.k3s.io/cluster-access)
try bash -c "curl -sfL https://get.k3s.io | sudo sh -"

# Wait briefly for K3s to come up
try sudo systemctl status k3s --no-pager
try sudo kubectl get nodes

echo
echo "K3s kubeconfig location (admin): /etc/rancher/k3s/k3s.yaml"  # [5](https://docs.k3s.io/cluster-access)
echo "To use kubectl as a non-root user, either export KUBECONFIG or copy kubeconfig." # [5](https://docs.k3s.io/cluster-access)
echo "Example:"
echo "  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml"
echo "  kubectl get nodes"

echo
echo "=== Bootstrap finished: $(date -Is) ==="