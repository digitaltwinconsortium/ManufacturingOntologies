#!/usr/bin/env bash
# Bootstrap.sh - Ubuntu version of the Windows Bootstrap.ps1
# - Logs to /var/log/bootstrap/Bootstrap.log
# - Installs Azure CLI
# - Downloads and unzips DTC ManufacturingOntologies repo
# - Installs K3s (single-node server)

set -u
set -o pipefail

# --------------------------
# Arguments
# --------------------------
# $1 (optional): the Event Hubs namespace RootManageSharedAccessKey connection string. When provided
# (the ARM deployment passes it automatically), the production line simulation is started at the end
# of this script. Captured before logging is enabled below so the secret is not written to the log.
#
# $2-$8: Azure IoT Operations onboarding context, passed by the ARM deployment. Azure Arc + Azure IoT
# Operations are always set up on the K3s cluster after the simulation starts.
EVENTHUBS_CONNECTION_STRING="${1:-}"
AIO_RESOURCE_GROUP="${2:-}"
AIO_LOCATION="${3:-}"
AIO_RESOURCES_NAME="${4:-}"
AIO_MANAGED_IDENTITY_CLIENT_ID="${5:-}"
AIO_SUBSCRIPTION_ID="${6:-}"
AIO_CUSTOM_LOCATIONS_OID="${7:-}"
AIO_EVENTHUBS_HOST="${8:-}"

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
DEST_DIR="${WORKDIR}/ManufacturingOntologies-crpogace-deployment-trust-fix"

try sudo rm -f "${ZIP_PATH}"
try sudo rm -rf "${DEST_DIR}"

try curl -L "https://github.com/cristipogacean/ManufacturingOntologies/archive/refs/heads/crpogace/deployment-trust-fix.zip" -o "${ZIP_PATH}"
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

# --------------------------
# Start the production line simulation
# --------------------------
# When the Event Hubs connection string was supplied as $1 (the ARM deployment passes it), start the
# Munich/Seattle production lines and UA-CloudPublisher (for GDS push) automatically so no manual step is required.
# StartSimulation.sh injects the connection string into the publisher config and the K8s manifests and
# applies them; it uses kubectl, so point KUBECONFIG at the K3s admin kubeconfig.
echo
echo "=== Starting production line simulation ==="
if [ -n "${EVENTHUBS_CONNECTION_STRING}" ]; then
  START_SIM="${FACTORY_SIM_DIR}/StartSimulation.sh"
  if [ -f "${START_SIM}" ]; then
    # StartSimulation.sh is authored on Windows; ensure LF line endings and the executable bit.
    try sudo sed -i 's/\r$//' "${START_SIM}"
    try sudo chmod +x "${START_SIM}"
    # Invoke StartSimulation.sh directly (not via the try helper) so the connection string, passed as
    # an argument, is never echoed to the bootstrap log. The managed identity client id ($2) lets
    # StartSimulation.sh authenticate the az CLI (it runs before SetupAzureIoTOperations.sh logs in).
    echo ">>> Starting simulation (connection string redacted)"
    if sudo env KUBECONFIG=/etc/rancher/k3s/k3s.yaml bash "${START_SIM}" "${EVENTHUBS_CONNECTION_STRING}" "${AIO_MANAGED_IDENTITY_CLIENT_ID}"; then
      echo "Simulation started."
    else
      echo "!!! WARNING: StartSimulation.sh failed (rc=$?)."
    fi
  else
    echo "!!! WARNING: ${START_SIM} not found; cannot start the simulation automatically."
  fi
else
  echo "No Event Hubs connection string was passed to Bootstrap.sh; skipping automatic simulation start."
  echo "To start it manually, run: ${FACTORY_SIM_DIR}/StartSimulation.sh '<eventhubs-connection-string>'"
fi

# --------------------------
# Deploy Azure Arc + Azure IoT Operations
# --------------------------
# Arc-enable the K3s cluster and install AIO so its OPC UA connector reads the simulation
# servers and forwards their data to the same Event Hubs namespace.
# AIO authenticates to Azure with the VM's managed identity, so no secret is passed here.
echo
echo "=== Azure IoT Operations ==="
# The CustomScript extension downloads SetupAzureIoTOperations.sh next to Bootstrap.sh; fall
# back to the copy in the downloaded repo if it is not present in the working directory.
AIO_SCRIPT="./SetupAzureIoTOperations.sh"
if [ ! -f "${AIO_SCRIPT}" ]; then
  AIO_SCRIPT="${DEST_DIR}/Deployment/SetupAzureIoTOperations.sh"
fi
if [ -f "${AIO_SCRIPT}" ]; then
  # Authored on Windows; ensure LF line endings and the executable bit.
  try sudo sed -i 's/\r$//' "${AIO_SCRIPT}"
  try sudo chmod +x "${AIO_SCRIPT}"
  try sudo env KUBECONFIG=/etc/rancher/k3s/k3s.yaml REPO_DIR="${DEST_DIR}" bash "${AIO_SCRIPT}" \
    "${AIO_RESOURCE_GROUP}" \
    "${AIO_LOCATION}" \
    "${AIO_RESOURCES_NAME}" \
    "${AIO_MANAGED_IDENTITY_CLIENT_ID}" \
    "${AIO_SUBSCRIPTION_ID}" \
    "${AIO_CUSTOM_LOCATIONS_OID}" \
    "${AIO_EVENTHUBS_HOST}"
else
  echo "!!! WARNING: SetupAzureIoTOperations.sh not found; cannot set up Azure IoT Operations."
fi

echo
echo "=== Bootstrap finished: $(date -Is) ==="