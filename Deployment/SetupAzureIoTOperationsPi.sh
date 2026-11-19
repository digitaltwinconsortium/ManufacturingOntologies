#!/usr/bin/env bash
# SetupAzureIoTOperationsPi.sh - Raspberry Pi 5 / K3s variant of SetupAzureIoTOperations.sh.
#
# Turns a Raspberry Pi 5 (ARM64) running K3s into the edge device of the reference solution - the role
# the Azure VM plays in the default deployment - and installs the Azure IoT Operations 2610 PUBLIC
# PREVIEW runtime (v1.6.0-preview.60) on it:
#   - checks/prepares the Pi host (cgroup memory controller, 4K kernel page size, vxlan module, limits),
#   - installs the Azure CLI, jq and (only if not already present) a single-node K3s server,
#   - downloads the ManufacturingOntologies repo and starts the production line simulation,
#   - Arc-enables the K3s cluster, installs AIO with 'az iot ops create --use-preview' and then
#     configures the OPC UA connector, assets and data flows exactly like SetupAzureIoTOperations.sh,
#     connecting the simulation OPC UA servers (both production lines) to the same Event Hubs namespace.
#
# Unlike the VM variant (invoked unattended by Bootstrap.sh through the VM CustomScript extension), this
# script is run MANUALLY on the Pi after the cloud deployment (Deployment/arm.json) completed with
# edgeDeploymentTarget=RaspberryPi (the deployment's 'raspberryPiSetupCommand' output contains the exact
# command). A Pi has no Azure managed identity, so the Azure CLI is signed in with a service principal
# (recommended; create it with Deployment/CreateRaspberryPiServicePrincipal.sh in Azure Cloud Shell, which
# prints the complete Pi command) or with your own account via the device code flow - which many tenants
# block with Conditional Access (sign-in error 53003). Every deployment value (location, managed identity,
# Event Hubs, custom locations OID) is derived from the resource group. The AIO instance itself still
# uses the shared '<rg>-Identity' user-assigned managed identity (federated with the Arc cluster's OIDC
# issuer) for Event Hubs and Key Vault, so no Azure secret is needed by the running solution.
#
# Prerequisites:
#   - Raspberry Pi 5 with 16 GB RAM (8 GB minimum) and a 64-bit OS with a 64-bit (arm64) userland:
#       * Raspberry Pi OS (64-bit), Bookworm or Trixie - the native OS flashed by Raspberry Pi Imager. The
#         script switches it to the 4K-page kernel and enables the memory cgroup (one reboot + re-run),
#         stops NetworkManager from managing the K3s CNI interfaces, and - because Microsoft does not
#         publish an apt repository for Trixie - installs the Azure CLI from PyPI into /opt/azure-cli.
#       * Ubuntu Server 24.04 LTS (ARM64), the OS on Azure IoT Operations' validated environment list.
#     Raspberry Pi OS works with K3s and AIO but is not on AIO's validated list (fine for evaluation).
#     Prefer NVMe/SSD storage over an SD card, with at least 32 GB free.
#   - Outbound internet access (Azure Arc, Azure IoT Operations, container registries).
#   - A service principal or Azure account with Owner - or Contributor + User Access Administrator - on
#     the resource group. The subscription's resource providers for Azure IoT Operations must be
#     registered (CreateRaspberryPiServicePrincipal.sh does that; an account with subscription rights
#     can also let this script do it).
#
# Usage (on the Pi) - run it straight from GitHub:
#   curl -fsSL https://raw.githubusercontent.com/digitaltwinconsortium/ManufacturingOntologies/main/Deployment/SetupAzureIoTOperationsPi.sh | sudo bash -s -- <resource-group> [subscription-id]
# or download it first and run the local copy:
#   curl -fsSL -o SetupAzureIoTOperationsPi.sh https://raw.githubusercontent.com/digitaltwinconsortium/ManufacturingOntologies/main/Deployment/SetupAzureIoTOperationsPi.sh
#   sudo bash SetupAzureIoTOperationsPi.sh <resource-group> [subscription-id]
#
# Arguments:
#   $1  RESOURCE_GROUP   Resource group the cloud deployment (arm.json) was deployed to (required)
#   $2  SUBSCRIPTION_ID  Azure subscription ID (optional; defaults to the signed-in CLI's subscription)
#
# Optional environment overrides (pass them through sudo: '... | sudo VAR=value bash -s -- <resource-group>'):
#   AZURE_CLIENT_ID, AZURE_CLIENT_SECRET, AZURE_TENANT_ID  Sign in non-interactively with a service principal
#                          (omit AZURE_CLIENT_SECRET to be prompted for it instead)
#   CUSTOM_LOCATIONS_OID   Object ID of the 'custom-locations' Entra application (otherwise looked up in
#                          Microsoft Graph or read from the arm.json deployment's customLocationsOid)
#   PI_PUBLIC_IP           Public egress IPv4 of the Pi to allow through the Key Vault firewall (auto-detected
#                          otherwise; only needed if the connection uses several egress IPs)
#   AIO_CLI_VERSION        azure-iot-ops CLI extension version (default 2.11.2, which bundles the 2610 preview runtime)
#   AIO_EXPECTED_VERSION   Expected Azure IoT Operations runtime version (default 1.6.0-preview.60)
#   AIO_BROKER_MEM_PROFILE, AIO_BROKER_FRONTEND_REPLICAS, AIO_BROKER_FRONTEND_WORKERS,
#   AIO_BROKER_BACKEND_PARTITIONS, AIO_BROKER_BACKEND_WORKERS, AIO_BROKER_BACKEND_RF
#                          MQTT broker sizing (defaults are sized for a single Raspberry Pi node)
#   INSTALL_K3S_VERSION    K3s version to install when K3s is not installed yet (default: latest stable)
#   SKIP_SIMULATION=true   Do not (re)start the production line simulation
#   ALLOW_LOW_MEMORY=true  Continue on a Pi with less than 8 GB RAM (not recommended)
#
# Like the VM variant, the script is idempotent/best-effort: individual steps log warnings but do not
# abort the whole run, so a partially-provisioned Pi can simply be re-run. If a host change requires a
# reboot (cgroup memory controller, kernel page size, kernel modules), the script says so and exits with
# code 2; reboot the Pi and run it again with the same arguments.

SCRIPT_URL="https://raw.githubusercontent.com/digitaltwinconsortium/ManufacturingOntologies/main/Deployment/SetupAzureIoTOperationsPi.sh"

# The whole script runs inside main(), invoked on the last line. When it is piped into 'bash -s', bash
# therefore parses the complete script before running anything: commands that read stdin (apt-get, az,
# the K3s installer, ...) cannot swallow the rest of the script, and a truncated download never runs.
main() {

# Command that re-runs this script with the given arguments, in the form it was started with.
rerun_command() {
  case "$0" in
    *.sh) echo "sudo bash $0 $*" ;;
    *) echo "curl -fsSL ${SCRIPT_URL} | sudo bash -s -- $*" ;;
  esac
}

set -u
set -o pipefail

RESOURCE_GROUP="${1:-}"
SUBSCRIPTION_ID="${2:-}"
# arm.json names every resource after the resource group (variables('resourcesName') = resourceGroup().name).
RESOURCES_NAME="${RESOURCE_GROUP}"
# Resolved from the resource group after signing in (section 1b).
LOCATION=""
MANAGED_IDENTITY_CLIENT_ID=""
CUSTOM_LOCATIONS_OID="${CUSTOM_LOCATIONS_OID:-}"
EVENTHUBS_NAMESPACE="${RESOURCES_NAME}-EventHubs"
EVENTHUBS_HOST="${EVENTHUBS_NAMESPACE}.servicebus.windows.net"
# Well-known application ID of the 'custom-locations' Microsoft Entra application (same in every tenant).
CUSTOM_LOCATIONS_APP_ID="bc313c14-388c-4e7d-a58e-70017303ee3b"

# Azure IoT Operations 2610 public preview (v1.6.0-preview.60). The azure-iot-ops CLI extension 2.11.2
# bundles both the 2610 GA (1.5.45) and the 2610 preview (1.6.0-preview.60) runtimes; 'az iot ops create
# --use-preview' selects the preview one. Pinning the extension version pins the runtime version.
AIO_CLI_VERSION="${AIO_CLI_VERSION:-2.11.2}"
AIO_EXPECTED_VERSION="${AIO_EXPECTED_VERSION:-1.6.0-preview.60}"
# MQTT broker sizing for a single Raspberry Pi node (the defaults target multi-core servers). The backend
# redundancy factor must stay >= 2; a value of 1 is rejected at deployment.
AIO_BROKER_MEM_PROFILE="${AIO_BROKER_MEM_PROFILE:-Low}"
AIO_BROKER_FRONTEND_REPLICAS="${AIO_BROKER_FRONTEND_REPLICAS:-1}"
AIO_BROKER_FRONTEND_WORKERS="${AIO_BROKER_FRONTEND_WORKERS:-1}"
AIO_BROKER_BACKEND_PARTITIONS="${AIO_BROKER_BACKEND_PARTITIONS:-1}"
AIO_BROKER_BACKEND_WORKERS="${AIO_BROKER_BACKEND_WORKERS:-1}"
AIO_BROKER_BACKEND_RF="${AIO_BROKER_BACKEND_RF:-2}"

KUBECONFIG_PATH="/etc/rancher/k3s/k3s.yaml"
export KUBECONFIG="${KUBECONFIG_PATH}"

# Derived Azure resource names (must match Deployment/arm.json).
CLUSTER_NAME="${RESOURCES_NAME}-Arc"
# The AIO instance name must be lowercase (^[a-z0-9][a-z0-9-]*[a-z0-9]$).
AIO_INSTANCE_NAME="$(printf '%s-aio' "${RESOURCES_NAME}" | tr '[:upper:]' '[:lower:]')"
# Schema registry name must be lowercase (^[a-z0-9][a-z0-9-]*[a-z0-9]$), matching arm.json's
# toLower(concat(resourcesName, '-schemaregistry')).
SCHEMA_REGISTRY_NAME="$(printf '%s-schemaregistry' "${RESOURCES_NAME}" | tr '[:upper:]' '[:lower:]')"
# Azure IoT Operations requires a Device Registry namespace (one per instance) passed to
# 'az iot ops create --ns-resource-id'. Name must be lowercase.
AIO_NAMESPACE_NAME="$(printf '%s-aions' "${RESOURCES_NAME}" | tr '[:upper:]' '[:lower:]')"
# The ADX cluster name MUST match arm.json: toLower(take(concat(replace(resourcesName, '-', ''), 'adx'), 22)).
ADX_CLUSTER_NAME_DERIVED="$(echo "${RESOURCES_NAME}" | tr -d '-' | tr '[:upper:]' '[:lower:]')adx"
ADX_CLUSTER_NAME_DERIVED="${ADX_CLUSTER_NAME_DERIVED:0:22}"
# The AIO data flows write to the SAME event hubs that Azure Data Explorer, Microsoft Fabric
# and Azure Databricks already consume, so the existing OPC UA PubSub expansion policies
# (OPCUATelemetryExpand / OPCUAMetaDataExpand) parse the AIO output unchanged.
TELEMETRY_EVENTHUB_NAME="data"
METADATA_EVENTHUB_NAME="metadata"
DATAFLOW_ENDPOINT_NAME="eventhubs"
TELEMETRY_DATAFLOW_NAME="opcua-telemetry-to-eventhubs"
METADATA_DATAFLOW_NAME="opcua-metadata-to-eventhubs"
# Cloud-to-edge command path: UA-CloudAction runs ON THE EDGE (inside the K3s cluster; see
# Deployment/<Line>/ProductionLine.yaml) and publishes the OPC UA method call directly to the local AIO
# MQTT broker as an MQTT v5 RPC request. No Event Hubs command endpoint or command/response dataflow is
# created here. The commander's action topic is per-asset and MUST match the asset/management-group/action
# registered in section 12e (it is the topic UA-CloudAction publishes to). The pressure-relief command is
# enabled on the 'assembly' station of BOTH production lines; the object/method IDs are identical because
# both lines run the same Station.NodeSet2.xml.
COMMAND_ASSETS=("assembly-seattle-asset" "assembly-munich-asset")
COMMAND_MGMT_GROUP="managementGroup"
COMMAND_ACTION_NAME="OpenPressureReliefValve"
COMMAND_OBJECT_ID="ns=2;i=424"
COMMAND_METHOD_ID="ns=2;i=435"
# Build the per-asset commander action topic: azure-iot-operations/asset-operations/<asset>/<mg>/<action>
command_topic_for() { echo "azure-iot-operations/asset-operations/$1/${COMMAND_MGMT_GROUP}/${COMMAND_ACTION_NAME}"; }
# Working directory for the generated data flow / asset configuration files.
AIO_CONFIG_DIR="$(mktemp -d)"

# The persistency.json files are the source of truth for which OPC UA nodes
# are published. AIO reads the SAME files so it samples exactly the same node set. The repo is
# downloaded to /opt/ManufacturingOntologies-main by this script (section P3); the per-line publisher
# configuration lives under Tools/FactorySimulation/PublisherConfig/<line>/persistency.json.
REPO_DIR="${REPO_DIR:-/opt/ManufacturingOntologies-main}"
PUBLISHER_CONFIG_DIR="${REPO_DIR}/Tools/FactorySimulation/PublisherConfig"
# Production lines to onboard (one PublisherConfig/<line>/persistency.json each).
LINES=("Munich" "Seattle")
# Default OPC UA port for endpoints whose persistency.json EndpointUrl omits it.
OPC_UA_PORT="4840"
# Stations (first dotted label of the OPC UA host) that must NOT be onboarded as AIO OPC UA
# devices/assets: 'commander' is the UA Cloud Commander command/response server and 'mes' is the
# MES server - neither is a telemetry source for the connector for OPC UA.
EXCLUDED_STATIONS="commander mes"
# AIO's connector for OPC UA stores its application instance certificate (managed by
# cert-manager) in this Kubernetes secret after 'az iot ops create'.
AIO_OPCUA_CERT_SECRET="aio-opc-opcuabroker-default-application-cert"
AIO_NAMESPACE="azure-iot-operations"

# --------------------------
# Preconditions: run as root with a resource group
# --------------------------
if [ "$(id -u)" -ne 0 ]; then
  echo "!!! ERROR: run this script as root: $(rerun_command "$@")"
  exit 1
fi
if [ -z "${RESOURCE_GROUP}" ]; then
  echo "Usage: $(rerun_command '<resource-group> [subscription-id]')"
  echo "  <resource-group>  resource group the cloud deployment (arm.json, edgeDeploymentTarget=RaspberryPi) was deployed to"
  exit 1
fi

# Log everything (stdout+stderr) to file and console, like Bootstrap.sh does on the VM.
mkdir -p /var/log/bootstrap
LOG_FILE="/var/log/bootstrap/SetupAzureIoTOperationsPi.log"
exec > >(tee -a "${LOG_FILE}") 2>&1

echo "=== Azure IoT Operations ${AIO_EXPECTED_VERSION} (Raspberry Pi 5 / K3s) setup started: $(date -Is) ==="
echo "Log file: ${LOG_FILE}"

# RUN_LAST_RC holds the exit code of the most recent `run` invocation. run() always
# returns 0 (best-effort: warn but continue) so the script keeps going on failure;
# callers that must branch on the real outcome inspect RUN_LAST_RC instead.
RUN_LAST_RC=0
# Helper: log a command, run it, warn (but continue) on failure.
run() {
  echo
  echo ">>> $*"
  "$@"
  local rc=$?
  RUN_LAST_RC=${rc}
  if [ "${rc}" -ne 0 ]; then
	echo "!!! WARNING: command failed (rc=${rc}): $*"
  fi
  return 0
}

# Wait (up to ~5 minutes) until the K3s API server answers and every node reports Ready.
wait_for_k3s() {
  local _i
  for _i in $(seq 1 60); do
	if kubectl get nodes >/dev/null 2>&1 \
	  && kubectl wait --for=condition=Ready node --all --timeout=10s >/dev/null 2>&1; then
	  return 0
	fi
	sleep 5
  done
  return 1
}

# --------------------------
# P1. Base packages
# --------------------------
echo
echo "=== Installing base packages ==="
export DEBIAN_FRONTEND=noninteractive
run apt-get update
run apt-get install -y ca-certificates curl gnupg unzip jq openssl

# --------------------------
# P2. Check and prepare the Raspberry Pi host
# --------------------------
echo
echo "=== Checking the Raspberry Pi host ==="
REBOOT_REQUIRED=false

ARCH="$(uname -m)"
if [ "${ARCH}" != "aarch64" ]; then
  echo "!!! ERROR: this script targets a Raspberry Pi 5 running a 64-bit (aarch64) OS; detected '${ARCH}'."
  echo "    Flash a 64-bit OS image, or use edgeDeploymentTarget=AzureVM for the cloud VM instead."
  exit 1
fi

# A 64-bit kernel can run a 32-bit (armhf) Raspberry Pi OS userland; AIO's CLI/tooling needs arm64.
DPKG_ARCH="$(dpkg --print-architecture 2>/dev/null || echo unknown)"
if [ "${DPKG_ARCH}" != "arm64" ]; then
  echo "!!! ERROR: the OS userland is '${DPKG_ARCH}', not arm64. Flash 'Raspberry Pi OS (64-bit)' or Ubuntu"
  echo "    Server 24.04 (ARM64) with Raspberry Pi Imager."
  exit 1
fi

PI_MODEL="$(tr -d '\0' </proc/device-tree/model 2>/dev/null || echo unknown)"
echo "Model: ${PI_MODEL}"
case "${PI_MODEL}" in
  *"Raspberry Pi 5"*) ;;
  *) echo "!!! WARNING: this host does not report itself as a Raspberry Pi 5; continuing anyway." ;;
esac

OS_ID="unknown"
OS_VERSION_ID="unknown"
OS_CODENAME=""
if [ -f /etc/os-release ]; then
  OS_ID="$(. /etc/os-release && echo "${ID:-unknown}")"
  OS_VERSION_ID="$(. /etc/os-release && echo "${VERSION_ID:-unknown}")"
  OS_CODENAME="$(. /etc/os-release && echo "${VERSION_CODENAME:-}")"
  echo "OS: $(. /etc/os-release && echo "${PRETTY_NAME:-unknown}")"
fi
# Raspberry Pi OS reports ID=debian; recognise it by its image stamp or the Raspberry Pi apt archive.
IS_RPI_OS=false
if [ -f /etc/rpi-issue ] || grep -qs 'archive.raspberrypi' /etc/apt/sources.list /etc/apt/sources.list.d/*; then
  IS_RPI_OS=true
fi
if [ "${OS_ID}" = "ubuntu" ] && [ "${OS_VERSION_ID}" = "24.04" ]; then
  echo "Ubuntu 24.04 LTS: on Azure IoT Operations' validated environment list for ARM64 K3s."
elif [ "${IS_RPI_OS}" = "true" ]; then
  echo "Raspberry Pi OS (Debian ${OS_VERSION_ID}${OS_CODENAME:+ '${OS_CODENAME}'}) detected: supported by this script and K3s."
  echo "NOTE: Azure IoT Operations validates ARM64 K3s on Ubuntu 24.04 only; Raspberry Pi OS is fine for this"
  echo "      preview/evaluation deployment but is not on AIO's validated environment list."
  if [ "${OS_VERSION_ID}" != "unknown" ] && [ "${OS_VERSION_ID}" -lt 12 ] 2>/dev/null; then
    echo "!!! WARNING: Raspberry Pi OS older than Bookworm (Debian 12) is not supported; please upgrade."
  fi
else
  echo "!!! WARNING: '${OS_ID} ${OS_VERSION_ID}' is neither Raspberry Pi OS (64-bit) nor Ubuntu 24.04 LTS;"
  echo "    the deployment may work but is untested."
fi
echo "Kernel: $(uname -r)"

MEM_KB="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)"
echo "Memory: $((MEM_KB / 1024)) MiB"
# Pi 5 8 GB reports ~8,000,000 kB and the 16 GB model ~16,000,000 kB.
if [ "${MEM_KB}" -lt 7500000 ]; then
  echo "!!! ERROR: Azure IoT Operations plus the two simulated production lines need at least 8 GB RAM"
  echo "    (16 GB recommended). Set ALLOW_LOW_MEMORY=true to continue anyway."
  if [ "${ALLOW_LOW_MEMORY:-false}" != "true" ]; then
	exit 1
  fi
elif [ "${MEM_KB}" -lt 15000000 ]; then
  echo "!!! WARNING: less than 16 GB RAM detected. Azure IoT Operations and both simulated production"
  echo "    lines will run close to the memory limit; a 16 GB Raspberry Pi 5 is recommended."
fi

mkdir -p /var/lib/rancher
FREE_KB="$(df -Pk /var/lib/rancher | awk 'NR==2 {print $4}')"
echo "Free disk space under /var/lib/rancher: $((FREE_KB / 1024 / 1024)) GiB"
if [ "${FREE_KB}" -lt 33554432 ]; then
  echo "!!! WARNING: less than 32 GiB free under /var/lib/rancher; container images and AIO broker"
  echo "    persistence may run out of space."
fi
if df -P /var/lib/rancher | awk 'NR==2 {print $1}' | grep -q mmcblk; then
  echo "!!! WARNING: K3s data is on the SD card. Use NVMe/SSD storage for acceptable AIO performance."
fi

# Raspberry Pi firmware files: /boot/firmware on current Ubuntu/Raspberry Pi OS, /boot on older images.
BOOT_DIR="/boot/firmware"
[ -f "${BOOT_DIR}/cmdline.txt" ] || BOOT_DIR="/boot"

# Raspberry Pi OS boots the Pi 5 with a 16K-page kernel (kernel_2712.img). Many container images
# (e.g. those using jemalloc) only work with 4K pages, so switch to the 4K-page kernel8.img, which
# Raspberry Pi OS (64-bit) ships in the linux-image-rpi-v8 package. Ubuntu's Pi kernel already uses 4K pages.
PAGE_SIZE="$(getconf PAGESIZE)"
echo "Kernel page size: ${PAGE_SIZE}"
if [ "${PAGE_SIZE}" != "4096" ]; then
  if [ "${IS_RPI_OS}" = "true" ] && [ -f "${BOOT_DIR}/config.txt" ]; then
	if [ ! -f "${BOOT_DIR}/kernel8.img" ]; then
	  run apt-get install -y linux-image-rpi-v8
	fi
	# Never point config.txt at a kernel image that does not exist - the Pi would not boot.
	if [ -f "${BOOT_DIR}/kernel8.img" ]; then
	  if ! grep -q '^kernel=kernel8.img' "${BOOT_DIR}/config.txt"; then
		echo ">>> Selecting the 4K-page kernel (kernel=kernel8.img) in ${BOOT_DIR}/config.txt"
		printf '\n[all]\nkernel=kernel8.img\n' >> "${BOOT_DIR}/config.txt"
	  fi
	  REBOOT_REQUIRED=true
	else
	  echo "!!! WARNING: ${BOOT_DIR}/kernel8.img is missing and linux-image-rpi-v8 could not provide it; staying"
	  echo "    on the ${PAGE_SIZE}-byte page kernel. Some Azure IoT Operations containers may crash."
	fi
  else
	echo "!!! WARNING: ${PAGE_SIZE}-byte kernel pages detected. Boot a 4K-page kernel; some Azure IoT"
	echo "    Operations containers may crash otherwise."
  fi
fi

# K3s needs the memory cgroup controller, which Raspberry Pi OS disables by default (its firmware adds
# cgroup_disable=memory); cgroup_enable=memory on the kernel command line re-enables it.
memory_cgroup_enabled() {
  grep -qw memory /sys/fs/cgroup/cgroup.controllers 2>/dev/null \
	|| [ "$(awk '$1 == "memory" {print $4}' /proc/cgroups 2>/dev/null)" = "1" ]
}
if memory_cgroup_enabled; then
  echo "Memory cgroup controller: enabled"
elif [ -f "${BOOT_DIR}/cmdline.txt" ]; then
  if ! grep -q 'cgroup_enable=memory' "${BOOT_DIR}/cmdline.txt"; then
	echo ">>> Enabling the memory cgroup controller in ${BOOT_DIR}/cmdline.txt"
	sed -i '1 s/$/ cgroup_memory=1 cgroup_enable=memory/' "${BOOT_DIR}/cmdline.txt"
  fi
  REBOOT_REQUIRED=true
else
  echo "!!! WARNING: the memory cgroup controller is disabled and ${BOOT_DIR}/cmdline.txt was not found."
  echo "    Add 'cgroup_enable=memory' to the kernel command line; K3s will not start without it."
fi

# Flannel (K3s' default CNI) needs the vxlan module. Raspberry Pi OS ships it with the kernel; Ubuntu ships
# it for the Pi in linux-modules-extra-raspi.
if ! modprobe vxlan 2>/dev/null; then
  if [ "${OS_ID}" = "ubuntu" ]; then
	run apt-get install -y linux-modules-extra-raspi
	modprobe vxlan 2>/dev/null || REBOOT_REQUIRED=true
  elif [ ! -d "/lib/modules/$(uname -r)" ]; then
	# Typical on Raspberry Pi OS after a kernel upgrade without a reboot: the running kernel's modules are gone.
	echo "!!! The modules of the running kernel $(uname -r) are not installed (kernel upgraded without a reboot)."
	REBOOT_REQUIRED=true
  else
	echo "!!! WARNING: the vxlan kernel module is not available; K3s pod networking (flannel) may fail."
  fi
fi

# Raspberry Pi OS (Bookworm and later) manages networking with NetworkManager, which interferes with the
# routes of the CNI's cni0/flannel/veth interfaces. Tell it to leave them alone (K3s' documented guidance).
if systemctl is-active --quiet NetworkManager 2>/dev/null; then
  NM_K3S_CONF="/etc/NetworkManager/conf.d/90-k3s-unmanaged-cni.conf"
  NM_K3S_CONTENT="$(printf '[keyfile]\nunmanaged-devices=interface-name:cni0;interface-name:flannel*;interface-name:veth*')"
  if [ "$(cat "${NM_K3S_CONF}" 2>/dev/null)" != "${NM_K3S_CONTENT}" ]; then
	echo ">>> Configuring NetworkManager to ignore the K3s CNI interfaces (${NM_K3S_CONF})"
	printf '%s\n' "${NM_K3S_CONTENT}" > "${NM_K3S_CONF}"
	run systemctl reload NetworkManager
  fi
fi

if [ "${REBOOT_REQUIRED}" = "true" ]; then
  echo
  echo "=== A reboot is required to apply the Raspberry Pi boot/kernel changes above. ==="
  echo "Reboot the Pi ('sudo reboot') and run this script again with the same arguments:"
  echo "  $(rerun_command "${RESOURCE_GROUP}" "${SUBSCRIPTION_ID}")"
  exit 2
fi

# --------------------------
# P3. Install the Azure CLI and download the ManufacturingOntologies repo
# --------------------------
echo
echo "=== Installing the Azure CLI ==="
AZ_APT_REPO="https://packages.microsoft.com/repos/azure-cli/"
AZ_APT_LIST="/etc/apt/sources.list.d/azure-cli.list"
AZ_VENV_DIR="/opt/azure-cli"
if command -v az >/dev/null 2>&1; then
  echo "Azure CLI already installed."
else
  # Microsoft's apt repository publishes arm64 builds for Ubuntu and for Debian up to Bookworm (Raspberry
  # Pi OS Bookworm). It has no Trixie suite, and Trixie's apt rejects the repository key's SHA-1 binding
  # signature even when pinned to bookworm (Azure/azure-cli#32731), so only use it when it serves this
  # release and otherwise fall back to the official PyPI package.
  if [ -n "${OS_CODENAME}" ] && curl -fsS --max-time 20 -o /dev/null "${AZ_APT_REPO}dists/${OS_CODENAME}/Release" 2>/dev/null; then
	run mkdir -p /etc/apt/keyrings
	run bash -c "curl -sL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor --yes -o /etc/apt/keyrings/microsoft.gpg"
	run chmod go+r /etc/apt/keyrings/microsoft.gpg
	echo "deb [arch=${DPKG_ARCH} signed-by=/etc/apt/keyrings/microsoft.gpg] ${AZ_APT_REPO} ${OS_CODENAME} main" \
	  > "${AZ_APT_LIST}"
	run apt-get update
	run apt-get install -y azure-cli
	if ! command -v az >/dev/null 2>&1; then
	  # Remove the repository again so it cannot break later 'apt-get update' runs.
	  echo "!!! WARNING: installing the Azure CLI from ${AZ_APT_REPO} failed; falling back to PyPI."
	  rm -f "${AZ_APT_LIST}"
	  run apt-get update
	fi
  else
	echo "Microsoft's Azure CLI apt repository has no '${OS_CODENAME:-unknown}' suite; installing from PyPI."
  fi
  if ! command -v az >/dev/null 2>&1; then
	# Self-contained virtual environment (PEP 668-safe); 'az extension add' works the same as with the .deb.
	# Most dependencies ship aarch64 wheels; the build tools cover any that must be compiled.
	run apt-get install -y python3 python3-venv python3-dev build-essential libffi-dev libssl-dev
	rm -rf "${AZ_VENV_DIR}"
	run python3 -m venv "${AZ_VENV_DIR}"
	run "${AZ_VENV_DIR}/bin/pip" install --no-cache-dir --upgrade pip
	echo ">>> Installing azure-cli from PyPI into ${AZ_VENV_DIR} (this can take several minutes on a Pi)"
	run "${AZ_VENV_DIR}/bin/pip" install --no-cache-dir azure-cli
	if [ -x "${AZ_VENV_DIR}/bin/az" ]; then
	  ln -sf "${AZ_VENV_DIR}/bin/az" /usr/local/bin/az
	  hash -r
	fi
  fi
fi
if ! command -v az >/dev/null 2>&1; then
  echo "!!! ERROR: the Azure CLI could not be installed. Aborting."
  exit 1
fi
run az version

echo
echo "=== Downloading the ManufacturingOntologies repo to ${REPO_DIR} ==="
REPO_ZIP="/tmp/ManufacturingOntologies-main.zip"
rm -f "${REPO_ZIP}"
if curl -fsSL "https://github.com/digitaltwinconsortium/ManufacturingOntologies/archive/refs/heads/main.zip" -o "${REPO_ZIP}"; then
  rm -rf "${REPO_DIR}"
  run unzip -q "${REPO_ZIP}" -d "$(dirname "${REPO_DIR}")"
  rm -f "${REPO_ZIP}"
  # Scripts may be authored on Windows: ensure LF line endings and the executable bit.
  find "${REPO_DIR}/Tools/FactorySimulation" -maxdepth 1 -type f -name "*.sh" -exec sed -i 's/\r$//' {} \; -exec chmod +x {} \; 2>/dev/null
else
  echo "!!! WARNING: could not download the repo; reusing ${REPO_DIR} if it exists."
fi
if [ ! -d "${REPO_DIR}" ]; then
  echo "!!! ERROR: ${REPO_DIR} does not exist. Aborting."
  exit 1
fi

# --------------------------
# P4. K3s (reuse the Pi's existing single-node server, or install one)
# --------------------------
echo
echo "=== K3s ==="
if command -v k3s >/dev/null 2>&1 && [ -f /etc/systemd/system/k3s.service ]; then
  echo "K3s already installed: $(k3s --version 2>/dev/null | head -n 1)"
  run systemctl enable --now k3s
else
  echo ">>> Installing K3s (single-node server)${INSTALL_K3S_VERSION:+ version ${INSTALL_K3S_VERSION}}"
  # The installer treats an empty INSTALL_K3S_VERSION as "latest stable".
  run bash -c "curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION='${INSTALL_K3S_VERSION:-}' sh -"
fi
if [ ! -f "${KUBECONFIG_PATH}" ]; then
  echo "!!! ERROR: ${KUBECONFIG_PATH} not found. This script needs a K3s SERVER node on the Pi (not a"
  echo "    k3s-agent). Aborting."
  exit 1
fi
if wait_for_k3s; then
  run kubectl get nodes -o wide
else
  echo "!!! ERROR: the K3s node did not become Ready. Check 'journalctl -u k3s'. Aborting."
  exit 1
fi

# --------------------------
# 1. Authenticate to Azure (the Pi has no managed identity)
# --------------------------
SP_HELPER_URL="https://raw.githubusercontent.com/digitaltwinconsortium/ManufacturingOntologies/main/Deployment/CreateRaspberryPiServicePrincipal.sh"
echo
echo "=== Signing in to Azure ==="
if [ -n "${AZURE_CLIENT_ID:-}" ] && [ -n "${AZURE_TENANT_ID:-}" ]; then
  if [ -z "${AZURE_CLIENT_SECRET:-}" ]; then
	# Prompt on the terminal (stdin may be the piped script), keeping the secret out of the shell history.
	read -r -s -p "Client secret of service principal ${AZURE_CLIENT_ID}: " AZURE_CLIENT_SECRET </dev/tty 2>/dev/null || true
	echo
  fi
  echo ">>> az login --service-principal (client id ${AZURE_CLIENT_ID})"
  if ! az login --service-principal --username "${AZURE_CLIENT_ID}" --password "${AZURE_CLIENT_SECRET:-}" \
	--tenant "${AZURE_TENANT_ID}" --output none; then
	echo "!!! ERROR: service principal sign-in failed (wrong/expired secret?). Create a new secret by re-running"
	echo "    CreateRaspberryPiServicePrincipal.sh in Azure Cloud Shell. Aborting AIO setup."
	exit 1
  fi
elif az account show >/dev/null 2>&1; then
  echo "Reusing the existing Azure CLI session ($(az account show --query user.name -o tsv 2>/dev/null))."
else
  echo "No service principal given (AZURE_CLIENT_ID/AZURE_TENANT_ID/AZURE_CLIENT_SECRET); trying the device"
  echo "code flow. Follow the instructions below to sign in."
  if ! az login --use-device-code --output none; then
	echo
	echo "!!! ERROR: az login failed. If the browser showed error 53003 ('blocked by Conditional Access'), your"
	echo "    tenant does not allow the device code flow. Use a service principal instead - run this in Azure"
	echo "    Cloud Shell (https://shell.azure.com, Bash) and then run the command it prints on the Pi:"
	echo "      curl -fsSL ${SP_HELPER_URL} | bash -s -- ${RESOURCE_GROUP} ${SUBSCRIPTION_ID}"
	echo "    Aborting AIO setup."
	exit 1
  fi
fi
if [ -n "${SUBSCRIPTION_ID}" ]; then
  run az account set --subscription "${SUBSCRIPTION_ID}"
else
  SUBSCRIPTION_ID="$(az account show --query id -o tsv 2>/dev/null)"
fi
echo "Subscription: ${SUBSCRIPTION_ID}"
# Tenant ID is required by the Event Hubs (Kafka) dataflow endpoint's managed-identity auth.
TENANT_ID="$(az account show --query tenantId -o tsv 2>/dev/null)"
# Object ID and type of the signed-in principal (user or service principal), used for the Key Vault role in 9b.
# Read the 'oid' claim of the ARM access token so no Microsoft Graph permission is needed (a resource-group
# scoped service principal cannot read Graph); fall back to Graph if decoding fails.
access_token_claim() {
  local payload
  payload="$(az account get-access-token --query accessToken -o tsv 2>/dev/null | cut -d. -f2 | tr '_-' '/+')"
  while [ $(( ${#payload} % 4 )) -ne 0 ]; do payload="${payload}="; done
  printf '%s' "${payload}" | base64 -d 2>/dev/null | jq -r --arg c "$1" '.[$c] // empty' 2>/dev/null
}
SIGNED_IN_OID="$(access_token_claim oid)"
if [ "$(az account show --query user.type -o tsv 2>/dev/null)" = "servicePrincipal" ]; then
  SIGNED_IN_PRINCIPAL_TYPE="ServicePrincipal"
  [ -n "${SIGNED_IN_OID}" ] || SIGNED_IN_OID="$(az ad sp show --id "$(az account show --query user.name -o tsv)" --query id -o tsv 2>/dev/null)"
else
  SIGNED_IN_PRINCIPAL_TYPE="User"
  [ -n "${SIGNED_IN_OID}" ] || SIGNED_IN_OID="$(az ad signed-in-user show --query id -o tsv 2>/dev/null)"
fi
echo "Signed in as ${SIGNED_IN_PRINCIPAL_TYPE} ${SIGNED_IN_OID:-<object id unknown>}"

# --------------------------
# 1b. Derive the deployment context from the resource group
# --------------------------
echo
echo "=== Reading the cloud deployment in resource group '${RESOURCE_GROUP}' ==="
LOCATION="$(az group show --name "${RESOURCE_GROUP}" --query location -o tsv 2>/dev/null)"
MANAGED_IDENTITY_CLIENT_ID="$(az identity show --name "${RESOURCES_NAME}-Identity" \
  --resource-group "${RESOURCE_GROUP}" --query clientId -o tsv 2>/dev/null)"
if ! az eventhubs namespace show --name "${EVENTHUBS_NAMESPACE}" --resource-group "${RESOURCE_GROUP}" >/dev/null 2>&1; then
  EVENTHUBS_HOST=""
fi
if [ -z "${CUSTOM_LOCATIONS_OID}" ]; then
  CUSTOM_LOCATIONS_OID="$(az ad sp show --id "${CUSTOM_LOCATIONS_APP_ID}" --query id -o tsv 2>/dev/null)"
fi
if [ -z "${CUSTOM_LOCATIONS_OID}" ]; then
  # No Graph access (e.g. a resource-group scoped service principal): reuse the value the arm.json
  # deployment was given as its required 'customLocationsOid' parameter.
  CUSTOM_LOCATIONS_OID="$(az deployment group list --resource-group "${RESOURCE_GROUP}" \
    --query "[?properties.parameters.customLocationsOid].properties.parameters.customLocationsOid.value | [0]" \
    -o tsv 2>/dev/null)"
fi
echo "Location: ${LOCATION:-<not found>}"
echo "Managed identity client id: ${MANAGED_IDENTITY_CLIENT_ID:-<not found>}"
echo "Event Hubs host: ${EVENTHUBS_HOST:-<not found>}"
echo "Custom locations OID: ${CUSTOM_LOCATIONS_OID:-<not found>}"

# --------------------------
# Validate inputs
# --------------------------
missing=""
for pair in "RESOURCE_GROUP=${RESOURCE_GROUP}" "LOCATION=${LOCATION}" "RESOURCES_NAME=${RESOURCES_NAME}" \
			"MANAGED_IDENTITY_CLIENT_ID=${MANAGED_IDENTITY_CLIENT_ID}" "SUBSCRIPTION_ID=${SUBSCRIPTION_ID}" \
			"EVENTHUBS_HOST=${EVENTHUBS_HOST}"; do
  name="${pair%%=*}"
  val="${pair#*=}"
  if [ -z "${val}" ]; then
	missing="${missing} ${name}"
  fi
done
if [ -n "${missing}" ]; then
  echo "!!! ERROR: could not resolve:${missing}. Deploy Deployment/arm.json with"
  echo "    edgeDeploymentTarget=RaspberryPi to resource group '${RESOURCE_GROUP}' first, and make sure the"
  echo "    signed-in account can read it. Aborting AIO setup."
  exit 1
fi

if [ -z "${CUSTOM_LOCATIONS_OID}" ]; then
  echo "!!! ERROR: could not determine the object ID of the 'custom-locations' Microsoft Entra application"
  echo "    (neither from Microsoft Graph nor from the arm.json deployment's customLocationsOid parameter). Get"
  echo "    it with 'az ad sp show --id ${CUSTOM_LOCATIONS_APP_ID} --query id -o tsv' (e.g. in Azure Cloud Shell)"
  echo "    and pass it as CUSTOM_LOCATIONS_OID=<oid>. Aborting AIO setup."
  exit 1
fi

# --------------------------
# 1c. Start the production line simulation
# --------------------------
# On the VM, Bootstrap.sh starts the simulation; on the Pi this script does it. StartSimulation.sh
# injects the Event Hubs connection string into the publisher config and the K8s manifests and applies
# them. The ADX cluster and the workload-identity client id are passed explicitly so StartSimulation.sh
# does not have to guess them from the (possibly multi-cluster) subscription.
echo
echo "=== Starting the production line simulation ==="
if [ "${SKIP_SIMULATION:-false}" = "true" ]; then
  echo "SKIP_SIMULATION=true; not (re)starting the simulation."
else
  START_SIM="${REPO_DIR}/Tools/FactorySimulation/StartSimulation.sh"
  # Read the connection string without echoing it; it is passed straight to StartSimulation.sh.
  EVENTHUBS_CONNECTION_STRING="$(az eventhubs namespace authorization-rule keys list \
	--resource-group "${RESOURCE_GROUP}" \
	--namespace-name "${EVENTHUBS_NAMESPACE}" \
	--name RootManageSharedAccessKey \
	--query primaryConnectionString -o tsv 2>/dev/null)"
  if [ -z "${EVENTHUBS_CONNECTION_STRING}" ]; then
	echo "!!! WARNING: could not read the Event Hubs connection string; the simulation is not started."
  elif [ ! -f "${START_SIM}" ]; then
	echo "!!! WARNING: ${START_SIM} not found; the simulation is not started."
  else
	# StartSimulation.sh reuses this script's Azure CLI session; its "no managed identity client id"
	# warning is expected on the Pi.
	echo ">>> Starting simulation (connection string redacted)"
	if ADX_CLUSTER_NAME="${ADX_CLUSTER_NAME_DERIVED}" ADX_RESOURCE_GROUP="${RESOURCE_GROUP}" \
	  UA_CLOUD_ACTION_MI_CLIENT_ID="${MANAGED_IDENTITY_CLIENT_ID}" \
	  bash "${START_SIM}" "${EVENTHUBS_CONNECTION_STRING}"; then
	  echo "Simulation started."
	else
	  echo "!!! WARNING: StartSimulation.sh failed (rc=$?)."
	fi
  fi
  unset EVENTHUBS_CONNECTION_STRING
fi

# --------------------------
# 2. Install/refresh the required Azure CLI extensions (pinned to the 2610 preview build)
# --------------------------
echo
echo "=== Installing Azure CLI extensions (connectedk8s, azure-iot-ops ${AIO_CLI_VERSION}) ==="
run az extension add --upgrade --yes --name connectedk8s
run az extension add --upgrade --yes --name azure-iot-ops --version "${AIO_CLI_VERSION}" --allow-preview
AIO_CLI_INSTALLED="$(az extension show --name azure-iot-ops --query version -o tsv 2>/dev/null)"
echo "azure-iot-ops extension: ${AIO_CLI_INSTALLED:-<not installed>}"
# Keep the CLI from nagging about newer extension versions; the version is pinned on purpose.
run az config set iotops.check_latest=false
# Capture the help first: piping it straight into 'grep -q' makes az fail with a broken pipe once grep
# exits on the first match, which 'set -o pipefail' turns into a false negative.
AIO_CREATE_HELP="$(az iot ops create --help 2>&1)"
if ! grep -q -- '--use-preview' <<<"${AIO_CREATE_HELP}"; then
  echo "!!! ERROR: the installed azure-iot-ops extension (${AIO_CLI_INSTALLED:-not installed}, expected"
  echo "    ${AIO_CLI_VERSION}) does not support 'az iot ops create --use-preview', so the ${AIO_EXPECTED_VERSION}"
  echo "    preview runtime cannot be selected. Output of 'az iot ops create --help':"
  printf '%s\n' "${AIO_CREATE_HELP}" | tail -n 20 | sed 's/^/      /'
  echo "    Aborting AIO setup."
  exit 1
fi
unset AIO_CREATE_HELP

# --------------------------
# 3. Register the resource providers AIO/Arc need
# --------------------------
# On the VM, the deployment's managed identity lacks the subscription-scope right to register providers.
# On the Pi, CreateRaspberryPiServicePrincipal.sh normally registered them already; otherwise register any
# missing provider (needs subscription rights) and wait for it ('az iot ops init' fails until they are all
# registered).
echo
echo "=== Registering the required resource providers ==="
AIO_PROVIDERS="Microsoft.ExtendedLocation Microsoft.Kubernetes Microsoft.KubernetesConfiguration Microsoft.IoTOperations Microsoft.DeviceRegistry Microsoft.SecretSyncController"
for rp in ${AIO_PROVIDERS}; do
  state="$(az provider show -n "${rp}" --query registrationState -o tsv 2>/dev/null)"
  if [ "${state}" != "Registered" ]; then
	run az provider register --namespace "${rp}" --subscription "${SUBSCRIPTION_ID}"
  fi
done

# Verify registration state (up to ~10 minutes); collect any that are still not registered.
unregistered=""
for _i in $(seq 1 40); do
  unregistered=""
  for rp in ${AIO_PROVIDERS}; do
	state="$(az provider show -n "${rp}" --query registrationState -o tsv 2>/dev/null)"
	if [ "${state}" != "Registered" ]; then
	  unregistered="${unregistered} ${rp}"
	fi
  done
  [ -z "${unregistered}" ] && break
  sleep 15
done
if [ -n "${unregistered}" ]; then
  echo "!!! WARNING: the following resource providers are NOT registered on subscription ${SUBSCRIPTION_ID}:${unregistered}"
  echo "    'az iot ops init' will fail until they are registered. Re-run CreateRaspberryPiServicePrincipal.sh in"
  echo "    Azure Cloud Shell, or have a subscription Owner/Contributor run:"
  for rp in ${unregistered}; do
	echo "      az provider register --namespace ${rp} --subscription ${SUBSCRIPTION_ID}"
  done
fi

# --------------------------
# 4. Prepare the cluster host (watch/instance and file-descriptor limits)
# --------------------------
echo
echo "=== Preparing K3s host limits for AIO ==="
cat > /etc/sysctl.d/99-azure-iot-operations.conf <<EOF
fs.inotify.max_user_instances=8192
fs.inotify.max_user_watches=524288
fs.file-max=100000
EOF
run sysctl --system

# --------------------------
# 5. Arc-enable the K3s cluster (with OIDC issuer + workload identity for AIO)
# --------------------------
echo
echo "=== Connecting the cluster to Azure Arc ==="
if az connectedk8s show --name "${CLUSTER_NAME}" --resource-group "${RESOURCE_GROUP}" >/dev/null 2>&1; then
  echo "Cluster '${CLUSTER_NAME}' is already Arc-connected; skipping 'az connectedk8s connect'."
else
  run az connectedk8s connect \
	--name "${CLUSTER_NAME}" \
	--resource-group "${RESOURCE_GROUP}" \
	--location "${LOCATION}" \
	--enable-oidc-issuer \
	--enable-workload-identity \
	--disable-auto-upgrade
fi

# Configure K3s with the OIDC issuer URL that AIO's workload identity requires. The Pi may already run
# a customized K3s, so use a config.yaml.d drop-in (and append with '+') instead of overwriting
# /etc/rancher/k3s/config.yaml like the VM variant does. Only restart K3s when the drop-in changes.
ISSUER_URL="$(az connectedk8s show --name "${CLUSTER_NAME}" --resource-group "${RESOURCE_GROUP}" \
  --query oidcIssuerProfile.issuerUrl -o tsv 2>/dev/null)"
if [ -n "${ISSUER_URL}" ]; then
  echo "OIDC issuer URL: ${ISSUER_URL}"
  K3S_OIDC_DROPIN="/etc/rancher/k3s/config.yaml.d/90-azure-iot-operations-oidc.yaml"
  mkdir -p "$(dirname "${K3S_OIDC_DROPIN}")"
  K3S_OIDC_NEW="${AIO_CONFIG_DIR}/k3s-oidc.yaml"
  cat > "${K3S_OIDC_NEW}" <<EOF
# Written by SetupAzureIoTOperationsPi.sh: Azure Arc OIDC issuer for Azure IoT Operations workload identity.
kube-apiserver-arg+:
  - service-account-issuer=${ISSUER_URL}
  - service-account-max-token-expiration=24h
EOF
  if cmp -s "${K3S_OIDC_NEW}" "${K3S_OIDC_DROPIN}"; then
	echo "K3s OIDC issuer configuration is already up to date."
  else
	cp "${K3S_OIDC_NEW}" "${K3S_OIDC_DROPIN}"
	run systemctl restart k3s
	if wait_for_k3s; then
	  run kubectl get nodes
	else
	  echo "!!! WARNING: K3s did not become Ready after the restart; check 'journalctl -u k3s'."
	fi
  fi
else
  echo "!!! WARNING: could not read the OIDC issuer URL; workload identity may not function."
fi

# --------------------------
# 6. Enable the cluster-connect and custom-locations features
# --------------------------
echo
echo "=== Enabling Arc features (cluster-connect, custom-locations) ==="
run az connectedk8s enable-features \
  --name "${CLUSTER_NAME}" \
  --resource-group "${RESOURCE_GROUP}" \
  --custom-locations-oid "${CUSTOM_LOCATIONS_OID}" \
  --features cluster-connect custom-locations

# --------------------------
# 7. Install Azure IoT Operations
# --------------------------
echo
echo "=== Initializing Azure IoT Operations foundation ==="
# 'az iot ops init' and 'az iot ops create' hard-fail unless the Arc-connected cluster
# reports connectivityStatus='Connected'. The k3s restart above (to apply the OIDC issuer
# config) bounces the Arc agent pods and resets that heartbeat, so 'az connectedk8s connect'
# returning is not enough - wait for connectivity to re-establish before installing AIO.
arc_connected=false
arc_wait_seconds=0
while [ "${arc_wait_seconds}" -lt 600 ]; do
  arc_status="$(az connectedk8s show --name "${CLUSTER_NAME}" --resource-group "${RESOURCE_GROUP}" --query connectivityStatus -o tsv 2>/dev/null)"
  if [ "${arc_status}" = "Connected" ]; then
    arc_connected=true
    echo ">>> Arc cluster '${CLUSTER_NAME}' is Connected after ${arc_wait_seconds}s"
    break
  fi
  echo ">>> Waiting for Arc connectivity (status='${arc_status:-unknown}', ${arc_wait_seconds}s elapsed)..."
  sleep 15
  arc_wait_seconds=$((arc_wait_seconds + 15))
done
if [ "${arc_connected}" != "true" ]; then
  echo "!!! WARNING: Arc cluster '${CLUSTER_NAME}' did not reach 'Connected' within 600s; 'az iot ops init' may fail."
fi
run az iot ops init \
  --resource-group "${RESOURCE_GROUP}" \
  --cluster "${CLUSTER_NAME}"

SCHEMA_REGISTRY_ID="$(az iot ops schema registry show \
  --name "${SCHEMA_REGISTRY_NAME}" \
  --resource-group "${RESOURCE_GROUP}" \
  --query id -o tsv 2>/dev/null)"
if [ -z "${SCHEMA_REGISTRY_ID}" ]; then
  # Fall back to the generic resource lookup if the iot ops sub-command is unavailable.
  SCHEMA_REGISTRY_ID="$(az resource show \
	--resource-group "${RESOURCE_GROUP}" \
	--name "${SCHEMA_REGISTRY_NAME}" \
	--resource-type Microsoft.DeviceRegistry/schemaRegistries \
	--query id -o tsv 2>/dev/null)"
fi

# 'az iot ops create' requires a Device Registry namespace (--ns-resource-id). Create it
# (idempotent: reuse if it already exists) and capture its resource id.
echo
echo "=== Creating the Device Registry namespace for Azure IoT Operations ==="
run az iot ops ns create \
  --name "${AIO_NAMESPACE_NAME}" \
  --resource-group "${RESOURCE_GROUP}"
NAMESPACE_ID="$(az iot ops ns show \
  --name "${AIO_NAMESPACE_NAME}" \
  --resource-group "${RESOURCE_GROUP}" \
  --query id -o tsv 2>/dev/null)"
if [ -z "${NAMESPACE_ID}" ]; then
  NAMESPACE_ID="$(az resource show \
	--resource-group "${RESOURCE_GROUP}" \
	--name "${AIO_NAMESPACE_NAME}" \
	--resource-type Microsoft.DeviceRegistry/namespaces \
	--query id -o tsv 2>/dev/null)"
fi

echo
echo "=== Creating the Azure IoT Operations instance (${AIO_EXPECTED_VERSION} preview runtime) ==="
# --use-preview selects the 2610 public preview runtime (v1.6.0-preview.60) bundled with the pinned CLI
# extension; using it constitutes acceptance of the Supplemental Terms of Use for Microsoft Azure Previews.
# --sku Standard is explicit because the Essentials SKU (single node) disables the OPC UA connector,
# which this solution depends on. The broker flags size the MQTT broker for a single Raspberry Pi node.
run az iot ops create \
  --resource-group "${RESOURCE_GROUP}" \
  --cluster "${CLUSTER_NAME}" \
  --name "${AIO_INSTANCE_NAME}" \
  --sr-resource-id "${SCHEMA_REGISTRY_ID}" \
  --ns-resource-id "${NAMESPACE_ID}" \
  --sku Standard \
  --use-preview \
  --broker-mem-profile "${AIO_BROKER_MEM_PROFILE}" \
  --broker-frontend-replicas "${AIO_BROKER_FRONTEND_REPLICAS}" \
  --broker-frontend-workers "${AIO_BROKER_FRONTEND_WORKERS}" \
  --broker-backend-part "${AIO_BROKER_BACKEND_PARTITIONS}" \
  --broker-backend-workers "${AIO_BROKER_BACKEND_WORKERS}" \
  --broker-backend-rf "${AIO_BROKER_BACKEND_RF}"
# NOTE: unlike the VM variant (whose managed identity lacks Microsoft.Authorization/roleAssignments/write),
# the account signed in on the Pi normally holds Owner/User Access Administrator, so 'az iot ops create'
# can grant the IoT Operations Arc extension the 'Azure Device Registry Administrator' role on the schema
# registry itself. If it warns that it could not, an Owner should grant that role on the schema registry.

AIO_INSTALLED_VERSION="$(az iot ops show --name "${AIO_INSTANCE_NAME}" --resource-group "${RESOURCE_GROUP}" \
  --query properties.version -o tsv 2>/dev/null)"
if [ "${AIO_INSTALLED_VERSION}" = "${AIO_EXPECTED_VERSION}" ]; then
  echo ">>> Azure IoT Operations instance '${AIO_INSTANCE_NAME}' runs version ${AIO_INSTALLED_VERSION}."
else
  echo "!!! WARNING: instance '${AIO_INSTANCE_NAME}' reports version '${AIO_INSTALLED_VERSION:-unknown}', expected"
  echo "    ${AIO_EXPECTED_VERSION}. An existing GA instance cannot be upgraded to a preview version; delete it"
  echo "    ('az iot ops delete --name ${AIO_INSTANCE_NAME} -g ${RESOURCE_GROUP} --include-deps') and re-run."
fi

# --------------------------
# 7b. Create an Azure Arc site (site manager) scoped to the resource group
# --------------------------
# A site groups Arc resources for OT users. Sites have a 1:1 relationship with a resource group, so
# scoping the site to this resource group automatically collects the AIO instance (no explicit
# assignment needed). The site is named after the resource group, as requested. The site name must
# match ^[a-zA-Z0-9][a-zA-Z0-9-_]{2,22}[a-zA-Z0-9]$.
echo
echo "=== Creating an Azure Arc site named '${RESOURCE_GROUP}' (scoped to the resource group) ==="
run az extension add --upgrade --yes --name site
run az site create \
  --name "${RESOURCE_GROUP}" \
  --resource-group "${RESOURCE_GROUP}" \
  --subscription "${SUBSCRIPTION_ID}" \
  --display-name "${RESOURCE_GROUP}"

# --------------------------
# 8. Enable managed-identity secret/identity access for the AIO instance
# --------------------------
echo
echo "=== Assigning the user-assigned managed identity to the AIO instance (for cloud auth) ==="
MANAGED_IDENTITY_RESOURCE_ID="$(az identity show \
  --name "${RESOURCES_NAME}-Identity" \
  --resource-group "${RESOURCE_GROUP}" \
  --query id -o tsv 2>/dev/null)"
if [ -n "${MANAGED_IDENTITY_RESOURCE_ID}" ]; then
  run az iot ops identity assign \
	--resource-group "${RESOURCE_GROUP}" \
	--name "${AIO_INSTANCE_NAME}" \
	--mi-user-assigned "${MANAGED_IDENTITY_RESOURCE_ID}"
else
  echo "!!! WARNING: could not resolve the managed identity resource ID; skipping identity assignment."
fi

# --------------------------
# 9. Create the Event Hubs (Kafka) data flow endpoint
# --------------------------
# The endpoint is created from a config file so it can set cloudEventAttributes=Propagate,
# which keeps the OPC UA connector's CloudEvent attributes (subject, time) available to the
# data flow map as message metadata. Authentication uses the shared user-assigned managed identity
# (granted 'Azure Event Hubs Data Sender' by the ARM template and federated with the Pi's Arc cluster by
# 'az iot ops identity assign' in section 8), so no secret is used or stored on the Pi.
echo
echo "=== Creating the Event Hubs Kafka data flow endpoint ==="
ENDPOINT_CONFIG="${AIO_CONFIG_DIR}/endpoint-eventhubs.json"
cat > "${ENDPOINT_CONFIG}" <<EOF
{
  "endpointType": "Kafka",
  "kafkaSettings": {
	"host": "${EVENTHUBS_HOST}:9093",
	"tls": {
	  "mode": "Enabled"
	},
	"authentication": {
	  "method": "UserAssignedManagedIdentity",
	  "userAssignedManagedIdentitySettings": {
		"clientId": "${MANAGED_IDENTITY_CLIENT_ID}",
		"tenantId": "${TENANT_ID}",
		"scope": "https://${EVENTHUBS_HOST}/.default"
	  }
	},
	"cloudEventAttributes": "Propagate",
	"copyMqttProperties": "Enabled"
  }
}
EOF
run az iot ops dataflow endpoint apply \
  --resource-group "${RESOURCE_GROUP}" \
  --instance "${AIO_INSTANCE_NAME}" \
  --name "${DATAFLOW_ENDPOINT_NAME}" \
  --config-file "${ENDPOINT_CONFIG}"

# The built-in local MQTT broker endpoint ('default') must also propagate CloudEvent
# attributes so 'subject'/'time' reach the map transform. Patch it via a config file too.
echo
echo "=== Ensuring the local MQTT broker endpoint propagates CloudEvent attributes ==="
MQTT_ENDPOINT_CONFIG="${AIO_CONFIG_DIR}/endpoint-mqtt.json"
cat > "${MQTT_ENDPOINT_CONFIG}" <<EOF
{
  "endpointType": "Mqtt",
  "mqttSettings": {
	"host": "aio-broker:18883",
	"tls": {
	  "mode": "Enabled"
	},
	"authentication": {
	  "method": "ServiceAccountToken",
	  "serviceAccountTokenSettings": {
		"audience": "aio-internal"
	  }
	},
	"cloudEventAttributes": "Propagate"
  }
}
EOF
run az iot ops dataflow endpoint apply \
  --resource-group "${RESOURCE_GROUP}" \
  --instance "${AIO_INSTANCE_NAME}" \
  --name "default" \
  --config-file "${MQTT_ENDPOINT_CONFIG}"

# --------------------------
# 9b. Pre-establish AIO -> station trust BEFORE onboarding devices/assets
# --------------------------
# AIO does NOT auto-accept untrusted OPC UA server certificates: it validates each station's server
# certificate against the connector's trust list (Kubernetes secret 'aio-opc-ua-broker-trust-list',
# populated here via Key Vault secret sync). We deliberately populate that trust list BEFORE section 10
# creates the devices/assets, because the Supervisor only spawns the OPC UA connector (and commander)
# pods once assets exist. A pod picks up the CURRENT contents of a mounted secret at startup with no
# delay; only UPDATES to an already-mounted secret incur the kubelet refresh lag (~60-90s). By trusting
# the stations first (and waiting for the synced secret to populate below), the connector pods mount a
# fully-populated trust list at startup and connect to the stations immediately - no pod restart needed.
#
# The connector/commander do NOT cache the trust list in memory: they back their trusted store with the
# mounted folder and re-read it from disk on each new session. The historical "restart to reload" step
# was only working around trust being added AFTER the pods had already started (an update-after-mount
# race), which this reordering removes.
echo
# The Key Vault name MUST match the name computed by the ARM template (Deployment/arm.json):
#   keyVaultName = toLower(take(concat(replace(resourcesName, '-', ''), 'kv'), 24))
# i.e. strip hyphens from the resource group name, append 'kv', lowercase, and truncate to 24
# characters (the Key Vault name length limit). Reproduce that here so both resolve the same vault;
# a divergent name silently breaks AIO secret sync, so the OPC UA trust list never populates and all
# station connections fail while health checks still report green.
KEY_VAULT_NAME="$(echo "${RESOURCES_NAME}" | tr -d '-' | tr '[:upper:]' '[:lower:]')kv"
KEY_VAULT_NAME="${KEY_VAULT_NAME:0:24}"
echo "=== Enabling AIO secret sync (reusing Key Vault ${KEY_VAULT_NAME}) ==="
KEY_VAULT_ID="$(az keyvault show --name "${KEY_VAULT_NAME}" --resource-group "${RESOURCE_GROUP}" --query id -o tsv 2>/dev/null)"

# The Key Vault firewall (defaultAction=Deny) only admits the Azure VNets of the deployment, but the Pi is
# outside Azure: both this CLI ('trust add' writes Key Vault secrets) and the cluster's secret sync
# controller reach the vault from the Pi's public egress IP, so detect that IP and allow it here - no manual
# step is needed. Re-deploying arm.json resets the firewall's IP rules, and a home/mobile connection may
# change its IP; re-running this script re-adds the rule in both cases. The ARM template grants Key Vault
# data roles only to the managed identity, so also grant the signed-in account 'Key Vault Secrets Officer'.
detect_public_ipv4() {
  local url ip
  # IPv4 only: Key Vault IP rules accept IPv4 addresses/ranges only.
  for url in https://api.ipify.org https://ipv4.icanhazip.com https://ifconfig.me/ip https://checkip.amazonaws.com; do
    ip="$(curl -4 -fsS --max-time 10 "${url}" 2>/dev/null | tr -d '[:space:]')"
    if [[ "${ip}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
      echo "${ip}"
      return 0
    fi
  done
  return 1
}
if [ -n "${KEY_VAULT_ID}" ]; then
  PI_PUBLIC_IP="${PI_PUBLIC_IP:-$(detect_public_ipv4)}"
  if [ -n "${PI_PUBLIC_IP}" ]; then
    echo ">>> Allowing the Pi's public IP ${PI_PUBLIC_IP} through the Key Vault firewall"
    run az keyvault network-rule add \
      --name "${KEY_VAULT_NAME}" \
      --resource-group "${RESOURCE_GROUP}" \
      --ip-address "${PI_PUBLIC_IP}/32" \
      --output none
  else
    echo "!!! WARNING: could not detect the Pi's public IP (set PI_PUBLIC_IP=<ip>); the Key Vault firewall"
    echo "    may block secret sync and the OPC UA trust list."
  fi
  if [ -n "${SIGNED_IN_OID}" ]; then
    existing_ra="$(az role assignment list --scope "${KEY_VAULT_ID}" --role "Key Vault Secrets Officer" \
      --fill-principal-name false --query "[?principalId=='${SIGNED_IN_OID}'].id | [0]" -o tsv 2>/dev/null)"
    if [ -z "${existing_ra}" ]; then
      run az role assignment create \
        --assignee-object-id "${SIGNED_IN_OID}" \
        --assignee-principal-type "${SIGNED_IN_PRINCIPAL_TYPE}" \
        --role "Key Vault Secrets Officer" \
        --scope "${KEY_VAULT_ID}" \
        --output none
    fi
  else
    echo "!!! WARNING: could not resolve the signed-in principal; grant it 'Key Vault Secrets Officer' on"
    echo "    ${KEY_VAULT_NAME} if adding the OPC UA trust list below fails."
  fi
  # Firewall and RBAC changes take a minute or two to propagate; wait until the data plane answers.
  kv_ready=false
  for _i in $(seq 1 30); do
    if az keyvault secret list --vault-name "${KEY_VAULT_NAME}" --maxresults 1 --output none 2>/dev/null; then
      kv_ready=true
      break
    fi
    sleep 10
  done
  if [ "${kv_ready}" = "true" ]; then
    echo ">>> Key Vault ${KEY_VAULT_NAME} is reachable from the Pi."
  else
    echo "!!! WARNING: Key Vault ${KEY_VAULT_NAME} is still not reachable from the Pi (firewall/RBAC); the"
    echo "    OPC UA trust list may not be populated."
  fi
fi

# Whether secret sync is enabled gates the OPC UA trust-list step below. Key off the
# result of 'secretsync enable' (RUN_LAST_RC) rather than probing 'connector opcua trust
# show': on a freshly enabled instance no trust list secret exists yet, so 'trust show'
# returns non-zero and would wrongly report secret sync as disabled, skipping the trust add.
secret_sync_enabled=false
if [ -n "${KEY_VAULT_ID}" ] && [ -n "${MANAGED_IDENTITY_RESOURCE_ID}" ]; then
  run az iot ops secretsync enable \
    --instance "${AIO_INSTANCE_NAME}" \
    --resource-group "${RESOURCE_GROUP}" \
    --mi-user-assigned "${MANAGED_IDENTITY_RESOURCE_ID}" \
    --kv-resource-id "${KEY_VAULT_ID}" \
    --skip-ra
  if [ "${RUN_LAST_RC}" -eq 0 ]; then
    secret_sync_enabled=true
  fi
else
  echo "!!! WARNING: could not resolve ${KEY_VAULT_NAME} or the managed identity; secret sync not enabled."
  echo "    The OPC UA trust list (below) requires secret sync and will be skipped."
fi

echo
echo "=== Adding the stations' OPC UA certificates to AIO's trust list (before onboarding) ==="
AIO_TRUST_LIST_SECRET="aio-opc-ua-broker-trust-list"
trust_added_count=0
if [ "${secret_sync_enabled}" != "true" ]; then
  echo "!!! NOTE: AIO secret sync is not enabled, so the OPC UA trust list cannot be updated."
  echo "    After enabling it, add each station cert (from /mnt/c/K3s/<Station>/<Line>/PKI/own/certs) with:"
  echo "      az iot ops connector opcua trust add --instance ${AIO_INSTANCE_NAME} \\"
  echo "        --resource-group ${RESOURCE_GROUP} --certificate-file <station>.der"
else
  for line in "${LINES[@]}"; do
    for station in Assembly Test Packaging; do
      # The station's public certs live under its host-mounted PKI own store. pki/own/certs holds
      # the RSA application instance cert plus alternate ECC curve variants; AIO connects with
      # Basic256Sha256 (RSA), so add only the RSA cert and skip the curve-tagged variants.
      cert_dir="/mnt/c/K3s/${station}/${line}/PKI/own/certs"
      [ -d "${cert_dir}" ] || continue
      for cert_file in "${cert_dir}"/*.der; do
        [ -f "${cert_file}" ] || continue
        case "${cert_file}" in
          *NistP256*|*NistP384*|*BrainpoolP256r1*|*BrainpoolP384r1*) continue ;;
        esac
        echo ">>> Trusting ${station}/${line}: ${cert_file}"
        # 'az iot ops connector opcua trust add' derives two names from the certificate file: the
        # Key Vault secret name (must match ^[0-9A-Za-z-]+$) and the secretSync targetKey (must match
        # ^[A-Za-z0-9.]([-A-Za-z0-9]+([-._a-zA-Z0-9]?[A-Za-z0-9])*)?...$). The station cert file names
        # contain dots, spaces and '[thumbprint]', which fail both. Copy the cert to a sanitized
        # <stem>.der file (valid targetKey) and pass a hyphen-only --secret-name from the same stem.
        cert_stem="$(basename "${cert_file}" | sed 's/\.[^.]*$//; s/[^0-9A-Za-z]/-/g; s/--*/-/g; s/^-//; s/-$//')"
        safe_cert_file="${AIO_CONFIG_DIR}/${cert_stem}.der"
        cp "${cert_file}" "${safe_cert_file}"
        run az iot ops connector opcua trust add \
          --instance "${AIO_INSTANCE_NAME}" \
          --resource-group "${RESOURCE_GROUP}" \
          --certificate-file "${safe_cert_file}" \
          --secret-name "${cert_stem}"
        if [ "${RUN_LAST_RC}" -eq 0 ]; then
          trust_added_count=$((trust_added_count + 1))
        fi
      done
    done
  done
  if [ "${trust_added_count}" -eq 0 ]; then
    echo "!!! NOTE: no station OPC UA certificate was found on disk yet. If AIO fails to connect to"
    echo "    a station, export that station's server certificate and run:"
    echo "      az iot ops connector opcua trust add --instance ${AIO_INSTANCE_NAME} \\"
    echo "        --resource-group ${RESOURCE_GROUP} --certificate-file <station>.der"
  else
    # Wait until the certs actually land in the synced trust-list secret BEFORE we onboard assets
    # (which is what makes the Supervisor spawn the connector/commander pods). This turns the former
    # "add then restart" race into a deterministic "trust list is ready before the pods start".
    # Key Vault -> secret sync has its own reconcile interval, so poll for up to ~5 minutes.
    echo ">>> Waiting for ${trust_added_count} station cert(s) to sync into '${AIO_TRUST_LIST_SECRET}'..."
    synced=0
    for _i in $(seq 1 60); do
      synced="$(kubectl -n "${AIO_NAMESPACE}" get secret "${AIO_TRUST_LIST_SECRET}" \
        -o jsonpath='{.data}' 2>/dev/null | jq 'length' 2>/dev/null || echo 0)"
      [ "${synced:-0}" -ge "${trust_added_count}" ] && break
      sleep 5
    done
    if [ "${synced:-0}" -ge "${trust_added_count}" ]; then
      echo ">>> Trust list ready: ${synced} certificate(s) present in '${AIO_TRUST_LIST_SECRET}'."
    else
      echo "!!! WARNING: only ${synced:-0}/${trust_added_count} station cert(s) visible in '${AIO_TRUST_LIST_SECRET}' after waiting."
      echo "    The connector may reject stations with 'BadCertificateUntrusted' until secret sync catches up"
      echo "    (it recovers on its own once the secret populates; no restart is required)."
    fi
  fi
fi

# --------------------------
# 9c/9d. Establish the reverse trust (stations trust AIO / Commander / MES) BEFORE onboarding
# --------------------------
# Complements 9b (AIO -> station trust) with the other direction, so trust is fully mutual before the
# Supervisor spawns the connector/commander pods at onboarding (section 10). AIO's connector presents a
# cert-manager-managed, self-signed application instance certificate (secret
# aio-opc-opcuabroker-default-application-cert) when it connects to a station; each station accepts a
# peer certificate only if it is in pki/trusted/certs or signed by an issuer in pki/issuer/certs (see
# Station/Program.cs CertificateValidationCallback). Doing this before onboarding means AIO's very first
# connection to each station succeeds instead of being rejected until the certs are distributed. The
# station-side stores are host-mounted directories that the OPC UA .NET validator re-reads on each
# validation, so no station restart is required.
echo
echo "=== Establishing OPC UA mutual trust between AIO and the stations ==="

AIO_CERT_CRT="${AIO_CONFIG_DIR}/opcuabroker.crt"
AIO_CERT_DER="${AIO_CONFIG_DIR}/opcuabroker.der"

# 9c. Retrieve AIO's connector application instance certificate (public key) and copy it into each
# telemetry station's host-mounted trusted store so the stations trust AIO's client certificate.
# cert-manager provisions this secret at AIO install time (after 'az iot ops create', independent of
# the connector pods), but it may lag a few seconds, so wait briefly for it before reading.
for _i in $(seq 1 36); do
  kubectl -n "${AIO_NAMESPACE}" get secret "${AIO_OPCUA_CERT_SECRET}" >/dev/null 2>&1 && break
  sleep 5
done
if kubectl -n "${AIO_NAMESPACE}" get secret "${AIO_OPCUA_CERT_SECRET}" >/dev/null 2>&1; then
  kubectl -n "${AIO_NAMESPACE}" get secret "${AIO_OPCUA_CERT_SECRET}" \
    -o jsonpath='{.data.tls\.crt}' | base64 -d > "${AIO_CERT_CRT}" 2>/dev/null

  if [ -s "${AIO_CERT_CRT}" ]; then
    # The stations (OPC UA .NET stack) expect DER-encoded certs in the PKI folders.
    if command -v openssl >/dev/null 2>&1; then
      run openssl x509 -outform der -in "${AIO_CERT_CRT}" -out "${AIO_CERT_DER}"
    fi
    aio_cert_to_copy="${AIO_CERT_DER}"
    [ -s "${AIO_CERT_DER}" ] || aio_cert_to_copy="${AIO_CERT_CRT}"

    # Copy AIO's certificate into each telemetry station's host-mounted trusted store. Each station's
    # /app/pki is host-mounted at /mnt/c/K3s/<Station>/<Line>/PKI (see Deployment/<Line>/
    # ProductionLine.yaml), so writing on the host persists across pod restarts. Only Assembly/Test/
    # Packaging are onboarded to AIO.
    cert_basename="aio-opcuabroker.${aio_cert_to_copy##*.}"
    for line in "${LINES[@]}"; do
      for station in Assembly Test Packaging; do
        dest_dir="/mnt/c/K3s/${station}/${line}/PKI/trusted/certs"
        run mkdir -p "${dest_dir}"
        run cp "${aio_cert_to_copy}" "${dest_dir}/${cert_basename}"
        echo ">>> ${station}/${line}: AIO certificate installed into ${dest_dir}"
      done
    done
  else
    echo "!!! WARNING: AIO connector certificate was empty; stations will not trust AIO."
  fi
else
  echo "!!! WARNING: secret ${AIO_OPCUA_CERT_SECRET} not found in ${AIO_NAMESPACE};"
  echo "    cannot distribute AIO's certificate to the stations. AIO connections may be refused."
fi

# 9d. Make the stations trust the OPC UA clients that connect to them: the UA Cloud Commander (issues
# commands) and the MES (drives the assembly line). With GDS Server Push disabled their certificates are
# not distributed automatically, so copy each client's own cert (host-mounted at
# /mnt/c/K3s/<Component>/<Line>/PKI/own/certs) into each station's trusted/certs. pki/own/certs holds the
# RSA application instance cert plus alternate ECC curve variants; the stations negotiate Basic256Sha256
# (RSA), so copy only the RSA cert and skip the curve-tagged variants.
echo
echo "=== Establishing trust for the OPC UA clients (Commander, MES) at the stations ==="
# Each entry maps a host PKI component directory to the filename prefix used in trusted/certs.
CLIENT_COMPONENTS="Commander:commander MES:mes"
for client in ${CLIENT_COMPONENTS}; do
  component="${client%%:*}"
  prefix="${client##*:}"
  client_cert_found=false
  for line in "${LINES[@]}"; do
    client_cert_dir="/mnt/c/K3s/${component}/${line}/PKI/own/certs"
    [ -d "${client_cert_dir}" ] || continue
    for cert_file in "${client_cert_dir}"/*.der; do
      [ -f "${cert_file}" ] || continue
      case "${cert_file}" in
        *NistP256*|*NistP384*|*BrainpoolP256r1*|*BrainpoolP384r1*) continue ;;
      esac
      client_cert_found=true
      cert_basename="${prefix}.$(basename "${cert_file}")"
      for station in Assembly Test Packaging; do
        dest_dir="/mnt/c/K3s/${station}/${line}/PKI/trusted/certs"
        run mkdir -p "${dest_dir}"
        run cp "${cert_file}" "${dest_dir}/${cert_basename}"
        echo ">>> ${station}/${line}: ${component} certificate installed into ${dest_dir}"
      done
    done
  done
  if [ "${client_cert_found}" != "true" ]; then
    echo "!!! NOTE: no ${component} OPC UA certificate was found under"
    echo "    /mnt/c/K3s/${component}/<Line>/PKI/own/certs yet. If the stations reject ${component},"
    echo "    copy its own cert into each station's PKI/trusted/certs and retry."
  fi
done

# --------------------------
# 10. Register the simulation OPC UA servers as AIO devices/assets (both lines)
# --------------------------
# The set of published OPC UA nodes is taken directly from persistency.json
# files, so AIO samples exactly the same nodes. persistency.json is an array of
# { EndpointUrl, OpcNodes[{ Id, OpcSamplingInterval, OpcPublishingInterval, ... }], ... }.
# For each EndpointUrl we create an AIO device + OPC UA inbound endpoint, then an asset whose
# data points map one-to-one to OpcNodes (dataSource = the OPC UA NodeId, samplingInterval =
# OpcSamplingInterval). This is the AIO equivalent of persistency.json's OpcNodes.
echo
echo "=== Registering OPC UA devices/assets from persistency.json (both production lines) ==="

# Build a NodeId-identifier -> OPC UA browse name map from the station information model
# (Station.NodeSet2.xml) so telemetry data points can be named by their real browse name
# (e.g. EnergyConsumption) instead of a generic node-<index>. The browse name becomes the
# telemetry Payload key and therefore opcua_telemetry.Name in ADX/Fabric/Databricks, which the
# dashboards and OEE functions filter on. Each UAVariable line looks like:
#   <UAVariable NodeId="ns=1;i=406" BrowseName="1:EnergyConsumption" ...>
# Extract "<identifier> <BrowseName>" pairs (dropping the "<namespaceIndex>:" browse-name prefix)
# and fold them into a JSON object with jq. If the NodeSet is missing, the map stays empty and the
# import falls back to node-<index>.
STATION_NODESET="${REPO_DIR}/Tools/FactorySimulation/Station/Station.NodeSet2.xml"
NODE_NAME_MAP="{}"
if [ -f "${STATION_NODESET}" ]; then
  NODE_NAME_MAP="$(grep -oE '<UAVariable [^>]*>' "${STATION_NODESET}" \
    | sed -nE 's/.*NodeId="[^"]*;i=([0-9]+)"[^>]*BrowseName="([^"]*:)?([^"]+)".*/\1 \3/p' \
    | jq -Rn 'reduce (inputs | split(" ")) as $p ({}; .[$p[0]] = $p[1])')"
  [ -n "${NODE_NAME_MAP}" ] || NODE_NAME_MAP="{}"
fi

for line in "${LINES[@]}"; do
  persistency="${PUBLISHER_CONFIG_DIR}/${line}/persistency.json"
  if [ ! -f "${persistency}" ]; then
	echo "!!! WARNING: ${persistency} not found; skipping line ${line}."
	continue
  fi
  echo
  echo "=== Line ${line} (${persistency}) ==="

  # Number of endpoint entries in this persistency.json.
  endpoint_count="$(jq 'length' "${persistency}" 2>/dev/null)"
  if [ -z "${endpoint_count}" ] || [ "${endpoint_count}" = "0" ]; then
	echo "!!! WARNING: no endpoints found in ${persistency}; skipping."
	continue
  fi

  idx=0
  while [ "${idx}" -lt "${endpoint_count}" ]; do
	endpoint_url="$(jq -r ".[${idx}].EndpointUrl" "${persistency}")"
	# Host portion of opc.tcp://<host>[:port]/  ->  <host>
	host="$(printf '%s' "${endpoint_url}" | sed -E 's#^opc\.tcp://##; s#/.*$##; s#:[0-9]+$##')"
	# Station is the first dotted label of the host (e.g. 'commander.munich' -> 'commander').
	station="$(printf '%s' "${host}" | cut -d. -f1 | tr '[:upper:]' '[:lower:]')"
	# Skip non-telemetry servers: 'commander' is the UA Cloud Commander command/response server
	# and 'mes' is the MES server; neither is onboarded as an AIO OPC UA device/asset.
	case " ${EXCLUDED_STATIONS} " in
	  *" ${station} "*)
		echo
		echo "--- skipping ${host} (station '${station}' excluded) ---"
		idx=$((idx + 1))
		continue
		;;
	esac
	# Ensure the endpoint address carries an explicit port for the AIO connector.
	if printf '%s' "${endpoint_url}" | grep -Eq '://[^/:]+:[0-9]+'; then
	  endpoint_address="${endpoint_url%/}"
	else
	  endpoint_address="opc.tcp://${host}:${OPC_UA_PORT}"
	fi
	# Names must be DNS-friendly: <host> like 'assembly.munich' -> 'assembly-munich'.
	safe_name="$(printf '%s' "${host}" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-' | sed -E 's/-+/-/g; s/^-//; s/-$//')"
	auth_mode="$(jq -r ".[${idx}].OpcAuthenticationMode // \"Anonymous\"" "${persistency}")"

	echo
	echo "--- ${safe_name} (${endpoint_address}, auth=${auth_mode}) ---"

	# Device + OPC UA inbound endpoint pointing at the OPC UA server. The simulation servers
	# accept anonymous sessions (OpcAuthenticationMode=Anonymous in persistency.json).
	run az iot ops ns device create \
	  --resource-group "${RESOURCE_GROUP}" \
	  --instance "${AIO_INSTANCE_NAME}" \
	  --name "${safe_name}"

	# AIO does NOT auto-accept untrusted server certificates. Instead, AIO is made to trust each
	# station's own OPC UA server certificate explicitly by adding it to AIO's connector trust list
	# (via Key Vault secret sync). That trust was established earlier, in section 9b above, BEFORE these
	# devices/assets are onboarded, so the connector pods start with a fully-populated trust list.
	run az iot ops ns device endpoint inbound add opcua \
	  --resource-group "${RESOURCE_GROUP}" \
	  --instance "${AIO_INSTANCE_NAME}" \
	  --device "${safe_name}" \
	  --name "${safe_name}-ep" \
	  --endpoint-address "${endpoint_address}"

	# Create the asset, then add a dataset (destination = the local MQTT topic that the
	# telemetry data flow subscribes to) and import all OpcNodes as data points in one batch. The
	# current CLI uses 'ns asset opcua create' + 'dataset add' + 'datapoint import --input-file'.
	# The NodeId is passed verbatim as the data point dataSource; sampling interval comes from
	# OpcSamplingInterval in persistency.json.
	node_count="$(jq -r ".[${idx}].OpcNodes | length" "${persistency}")"
	echo ">>> ${safe_name}: ${node_count} data point(s) from persistency.json"

	run az iot ops ns asset opcua create \
	  --resource-group "${RESOURCE_GROUP}" \
	  --instance "${AIO_INSTANCE_NAME}" \
	  --device "${safe_name}" \
	  --endpoint "${safe_name}-ep" \
	  --name "${safe_name}-asset"

	# Dataset whose destination is the MQTT topic consumed by the telemetry data flow.
	run az iot ops ns asset opcua dataset add \
	  --resource-group "${RESOURCE_GROUP}" \
	  --instance "${AIO_INSTANCE_NAME}" \
	  --asset "${safe_name}-asset" \
	  --name "telemetry" \
	  --dest topic="azure-iot-operations/data/${safe_name}" qos=Qos1 retain=Never ttl=3600

	# Add ALL OPC UA nodes in a single batch import instead of one slow ARM call per node
	# (per-node 'datapoint add' made the run exceed the CustomScript extension timeout). The
	# import file is a JSON array of { name, dataSource=NodeId, dataPointConfiguration }.
	datapoints_file="${AIO_CONFIG_DIR}/datapoints-${line}-${safe_name}.json"
	# Name each data point by its real OPC UA browse name (e.g. EnergyConsumption) rather than a
	# generic 'node-<index>', using the NodeId-identifier -> browse name map derived from
	# Station.NodeSet2.xml above. The name becomes the telemetry Payload key and therefore
	# opcua_telemetry.Name in ADX/Fabric/Databricks, which the dashboards and OEE functions filter on
	# (e.g. Name == "EnergyConsumption"). Fall back to node-<index> for any id not in the map.
	jq --argjson idx "${idx}" --argjson names "${NODE_NAME_MAP}" '
	  ( .[$idx].OpcNodes // [] )
	  | to_entries
	  | map({
		  name: ( ($names[ (.value.Id | capture(";i=(?<n>[0-9]+)$").n) ]) // ("node-" + (.key|tostring)) ),
		  dataSource: .value.Id,
		  dataPointConfiguration: ( { samplingInterval: (.value.OpcSamplingInterval // 1000) } | tojson )
		})
	' "${persistency}" > "${datapoints_file}"

	run az iot ops ns asset opcua datapoint import \
	  --resource-group "${RESOURCE_GROUP}" \
	  --instance "${AIO_INSTANCE_NAME}" \
	  --asset "${safe_name}-asset" \
	  --dataset "telemetry" \
	  --input-file "${datapoints_file}" \
	  --replace true

	idx=$((idx + 1))
  done
done

# --------------------------
# 11. Create the data flows: OPC UA (MQTT) -> Event Hubs (Kafka), reshaped to OPC UA PubSub
# --------------------------
# The reference solution's ADX/Fabric/Databricks expansion policies (OPCUATelemetryExpand /
# OPCUAMetaDataExpand) read the dataset identity and timestamp FROM THE MESSAGE BODY and
# expect an OPC UA PubSub DataSet message: { DataSetWriterId, Timestamp, Payload|MetaData }.
# Azure IoT Operations instead carries the identity in CloudEvent attributes (subject, time).
# A BuiltInTransformation map wraps the values under Payload/MetaData and copies the
# CloudEvent subject/time into DataSetWriterId/Timestamp so the existing policies work
# unchanged. See the "Azure IoT Operations configuration for OPC UA PubSub" section of the
# repository README. Two flows are created: telemetry -> 'data' hub, metadata -> 'metadata' hub.
echo
echo "=== Creating the OPC UA PubSub data flows (telemetry + metadata) ==="

# Telemetry flow: wrap fields under Payload, map identity/timestamp, send to the 'data' hub.
TELEMETRY_DATAFLOW_CONFIG="${AIO_CONFIG_DIR}/dataflow-telemetry.json"
cat > "${TELEMETRY_DATAFLOW_CONFIG}" <<EOF
{
  "mode": "Enabled",
  "operations": [
	{
	  "operationType": "Source",
	  "sourceSettings": {
		"endpointRef": "default",
		"dataSources": ["azure-iot-operations/data/#"]
	  }
	},
	{
	  "operationType": "BuiltInTransformation",
	  "builtInTransformationSettings": {
		"map": [
		  {
			"inputs": ["*"],
			"output": "Payload.*",
			"description": "Wrap all dataset value fields under Payload"
		  },
		  {
			"inputs": ["\$metadata.user_property.subject"],
			"output": "DataSetWriterId",
			"description": "CloudEvent subject -> dataset identity"
		  },
		  {
			"inputs": ["\$metadata.user_property.time"],
			"output": "Timestamp",
			"description": "CloudEvent time -> Timestamp"
		  }
		]
	  }
	},
	{
	  "operationType": "Destination",
	  "destinationSettings": {
		"endpointRef": "${DATAFLOW_ENDPOINT_NAME}",
		"dataDestination": "${TELEMETRY_EVENTHUB_NAME}"
	  }
	}
  ]
}
EOF
run az iot ops dataflow apply \
  --resource-group "${RESOURCE_GROUP}" \
  --instance "${AIO_INSTANCE_NAME}" \
  --profile default \
  --name "${TELEMETRY_DATAFLOW_NAME}" \
  --config-file "${TELEMETRY_DATAFLOW_CONFIG}"

# Metadata flow: wrap fields under MetaData, map identity/timestamp, send to the 'metadata' hub.
METADATA_DATAFLOW_CONFIG="${AIO_CONFIG_DIR}/dataflow-metadata.json"
cat > "${METADATA_DATAFLOW_CONFIG}" <<EOF
{
  "mode": "Enabled",
  "operations": [
	{
	  "operationType": "Source",
	  "sourceSettings": {
		"endpointRef": "default",
		"dataSources": ["azure-iot-operations/metadata/#"]
	  }
	},
	{
	  "operationType": "BuiltInTransformation",
	  "builtInTransformationSettings": {
		"map": [
		  {
			"inputs": ["*"],
			"output": "MetaData.*",
			"description": "Wrap all metadata fields under MetaData"
		  },
		  {
			"inputs": ["\$metadata.user_property.subject"],
			"output": "DataSetWriterId",
			"description": "CloudEvent subject -> dataset identity"
		  },
		  {
			"inputs": ["\$metadata.user_property.time"],
			"output": "Timestamp",
			"description": "CloudEvent time -> Timestamp"
		  }
		]
	  }
	},
	{
	  "operationType": "Destination",
	  "destinationSettings": {
		"endpointRef": "${DATAFLOW_ENDPOINT_NAME}",
		"dataDestination": "${METADATA_EVENTHUB_NAME}"
	  }
	}
  ]
}
EOF
run az iot ops dataflow apply \
  --resource-group "${RESOURCE_GROUP}" \
  --instance "${AIO_INSTANCE_NAME}" \
  --profile default \
  --name "${METADATA_DATAFLOW_NAME}" \
  --config-file "${METADATA_DATAFLOW_CONFIG}"

# --------------------------
# 11b. Cloud-to-edge command path (runs on the edge, not via a dataflow)
# --------------------------
# UA-CloudAction runs INSIDE the K3s cluster (see Deployment/<Line>/ProductionLine.yaml, the
# 'ua-cloud-action' Deployment) with MESSAGING_PLATFORM=MQTT. It publishes the OPC UA method call
# directly to the local AIO MQTT broker as a spec-valid MQTT v5 RPC request (Payload Format Indicator,
# Message Expiry, Correlation Data and Response Topic), which the built-in OPC UA connector commander
# executes (action registered in section 12e). Because the request is issued in-cluster, no Event Hubs
# command source endpoint and no command/response dataflows are needed here.

# --------------------------
# 12. AIO OPC UA commander action + edge command path (post-onboarding)
# --------------------------
# OPC UA mutual trust (stations <-> AIO, and stations <-> UA Cloud Commander / MES) is established
# earlier, in sections 9b-9d, BEFORE the devices/assets are onboarded - so the connector pods start
# already trusting the stations and the stations trust AIO. The steps below intentionally run AFTER
# onboarding because they operate on the onboarded assets and the edge command path, not on trust:
#  - 12e: register the commander management-group 'Call' action on each onboarded asset (needs the asset).
#  - 12f: copy the AIO broker CA trust bundle into the production-line namespaces.
#  - 12g: federate the UA-CloudAction service accounts with the shared managed identity.

# 12e. Register an OPC UA command (management-group action) so the AIO OPC UA connector's built-in
# commander can execute a command on the station directly - the AIO-native alternative to UA Cloud
# Commander. The reference command is "open the pressure relief valve" on the assembly station of BOTH
# production lines (the same command UA-CloudAction triggers). It is modeled as a management-group action
# of type "Call" on each station's telemetry asset: the management group's dataSource is the OPC UA
# objectId and the action's targetUri is the methodId (see Station.NodeSet2.xml), and the action's
# MQTT topic is the per-asset command topic so the commander subscribes to it. UA-CloudAction
# (MESSAGING_PLATFORM=MQTT) invokes it by publishing to that topic.
#
# This is registered via the GENERIC ARM resource API ('az resource update' / 'az rest' PATCH) rather
# than the preview 'az iot ops ns asset opcua management-group' verb. That verb is not available in
# every environment (and the whole 'ns' group is missing on older azure-iot-ops builds), so a
# preview-CLI-only approach silently skips the registration and the command path never works. The
# asset is an ARM resource of type 'Microsoft.DeviceRegistry/namespaces/assets', so PATCHing
# 'properties.managementGroups' works with plain 'az' and no extension dependency, fully automated.
# This is additive: UA Cloud Commander stays deployed as a backup.
echo
echo "=== Registering the AIO OPC UA commander action (assembly pressure relief valve, both lines) ==="
for COMMAND_ASSET in "${COMMAND_ASSETS[@]}"; do
    command_topic="$(command_topic_for "${COMMAND_ASSET}")"
    echo ">>> Asset '${COMMAND_ASSET}' -> topic '${command_topic}'"
    # Resolve the asset's full ARM resource id (name is namespace-prefixed in 'az resource list', so match
    # on the id rather than reconstructing a path).
    COMMAND_ASSET_ID="$(az resource list \
        --resource-group "${RESOURCE_GROUP}" \
        --resource-type "Microsoft.DeviceRegistry/namespaces/assets" \
        ${SUBSCRIPTION_ID:+--subscription "${SUBSCRIPTION_ID}"} \
        --query "[?ends_with(name, '/${COMMAND_ASSET}') || name=='${COMMAND_ASSET}'].id | [0]" -o tsv 2>/dev/null || true)"
    if [ -z "${COMMAND_ASSET_ID}" ]; then
        echo "!!! NOTE: could not resolve asset '${COMMAND_ASSET}' in '${RESOURCE_GROUP}'; skipping the AIO"
        echo "    commander action registration for it. Ensure the asset exists, then re-run this section."
        continue
    fi
    # Build the managementGroups payload (one management group with one Call action). The action topic
    # MUST equal the per-asset command topic so the commander subscribes to the same topic UA-CloudAction
    # publishes to. Write to a file to avoid shell/JMESPath quoting pitfalls.
    COMMAND_MG_FILE="${AIO_CONFIG_DIR}/management-groups-${COMMAND_ASSET}.json"
    cat > "${COMMAND_MG_FILE}" <<EOF
[
  {
    "name": "${COMMAND_MGMT_GROUP}",
    "dataSource": "${COMMAND_OBJECT_ID}",
    "defaultTopic": "${command_topic}",
    "actions": [
      {
        "name": "${COMMAND_ACTION_NAME}",
        "actionType": "Call",
        "targetUri": "${COMMAND_METHOD_ID}",
        "topic": "${command_topic}"
      }
    ]
  }
]
EOF
    # Primary path: generic ARM PATCH via 'az resource update' (errors shown, best-effort).
    if az resource update --ids "${COMMAND_ASSET_ID}" \
        --set properties.managementGroups=@"${COMMAND_MG_FILE}" \
        --output none; then
        echo ">>> Registered management group '${COMMAND_MGMT_GROUP}' with Call action '${COMMAND_ACTION_NAME}' on '${COMMAND_ASSET}'."
    else
        # Fallback: REST PATCH to the asset id (still extension-independent). Try a couple of API versions.
        echo "  'az resource update' did not apply; trying a REST PATCH fallback..."
        COMMAND_PATCH_FILE="${AIO_CONFIG_DIR}/asset-patch-${COMMAND_ASSET}.json"
        printf '{"properties":{"managementGroups":%s}}' "$(cat "${COMMAND_MG_FILE}")" > "${COMMAND_PATCH_FILE}"
        _patched=""
        for _apiver in 2025-10-01 2024-11-01 2026-04-01; do
            if az rest --method patch \
                --url "https://management.azure.com${COMMAND_ASSET_ID}?api-version=${_apiver}" \
                --headers "Content-Type=application/json" \
                --body @"${COMMAND_PATCH_FILE}" \
                --output none 2>/dev/null; then
                _patched="${_apiver}"; break
            fi
        done
        if [ -n "${_patched}" ]; then
            echo ">>> Registered management group '${COMMAND_MGMT_GROUP}' with Call action '${COMMAND_ACTION_NAME}' on '${COMMAND_ASSET}' (REST api-version ${_patched})."
        else
            echo "!!! NOTE: could not register the commander action automatically on '${COMMAND_ASSET}'. The"
            echo "    command path will not execute until the management group '${COMMAND_MGMT_GROUP}' (dataSource"
            echo "    ${COMMAND_OBJECT_ID}) and Call action '${COMMAND_ACTION_NAME}' (targetUri ${COMMAND_METHOD_ID},"
            echo "    topic ${command_topic}) are added to asset '${COMMAND_ASSET}', or keep using UA Cloud Commander."
        fi
    fi
    echo ">>> UA-CloudAction (MESSAGING_PLATFORM=MQTT) can invoke the command by publishing to:"
    echo "    ${command_topic}"
done

# --------------------------
# 12f. Copy the AIO broker CA trust bundle into the production-line namespaces
# --------------------------
# UA-CloudAction runs on the edge in the per-line namespaces (seattle/munich) and mounts the AIO MQTT
# broker's CA trust bundle to validate the broker's TLS server certificate. That configMap
# ('azure-iot-operations-aio-ca-trust-bundle') is created by AIO in the '${AIO_NAMESPACE}' namespace and is
# namespace-scoped, so it must be copied into each line namespace or the UA-CloudAction pod stays stuck in
# ContainerCreating (MountVolume.SetUp failed ... configmap not found). The volume is marked optional in the
# manifest, but copying the bundle here is what makes TLS trust actually work.
echo
echo "=== Copying the AIO broker CA trust bundle into the production-line namespaces ==="
CA_TRUST_BUNDLE="azure-iot-operations-aio-ca-trust-bundle"
for line in "${LINES[@]}"; do
    line_ns="$(echo "${line}" | tr '[:upper:]' '[:lower:]')"
    # Ensure the namespace exists (StartSimulation.sh normally creates it via ProductionLine.yaml).
    kubectl create namespace "${line_ns}" 2>/dev/null || true
    if kubectl get configmap "${CA_TRUST_BUNDLE}" -n "${AIO_NAMESPACE}" >/dev/null 2>&1; then
        # Rebuild the configMap with only apiVersion/kind/name/data so server-managed metadata
        # (namespace, uid, resourceVersion, creationTimestamp AND ownerReferences) is dropped - an empty
        # ownerReferences.uid otherwise makes 'kubectl apply' reject it in the target namespace.
        kubectl get configmap "${CA_TRUST_BUNDLE}" -n "${AIO_NAMESPACE}" -o json \
            | jq '{apiVersion, kind, metadata: {name: .metadata.name}, data}' \
            | kubectl apply -n "${line_ns}" -f - \
            && echo "  copied ${CA_TRUST_BUNDLE} into namespace '${line_ns}'." \
            || echo "  warning: could not copy CA trust bundle into '${line_ns}' (copy it manually or set MQTT_TLS_INSECURE=true)."
    else
        echo "  warning: configmap ${CA_TRUST_BUNDLE} not found in ${AIO_NAMESPACE}; skipping copy for '${line_ns}'."
    fi
done

# --------------------------
# 12g. Federate the production-line UA-CloudAction service accounts with the shared managed identity
# --------------------------
# UA-CloudAction (edge) queries Azure Data Explorer using Microsoft Entra Workload Identity: its Kubernetes
# service account token is exchanged for an Entra token for the shared '${RESOURCES_NAME}-Identity' managed
# identity (which already has ADX access), so no service principal or secret is needed. The cluster's OIDC
# issuer and workload identity were enabled during Arc connect (section 5). Here we create one federated
# identity credential per line namespace, trusting the 'ua-cloud-action' service account.
echo
echo "=== Federating UA-CloudAction service accounts with '${RESOURCES_NAME}-Identity' (workload identity) ==="
if [ -n "${ISSUER_URL}" ]; then
    for line in "${LINES[@]}"; do
        line_ns="$(echo "${line}" | tr '[:upper:]' '[:lower:]')"
        run az identity federated-credential create \
            --name "ua-cloud-action-${line_ns}" \
            --identity-name "${RESOURCES_NAME}-Identity" \
            --resource-group "${RESOURCE_GROUP}" \
            --issuer "${ISSUER_URL}" \
            --subject "system:serviceaccount:${line_ns}:ua-cloud-action" \
            --audience "api://AzureADTokenExchange" \
            && echo "  federated ua-cloud-action in '${line_ns}' with ${RESOURCES_NAME}-Identity." \
            || echo "  warning: could not create the federated credential for '${line_ns}' (create it manually)."
    done
else
    echo "  warning: OIDC issuer URL is unknown; skipping workload identity federation."
    echo "           UA-CloudAction will fall back to APPLICATION_ID/KEY/AAD_TENANT_ID if those are set."
fi

# Restart the UA-CloudAction pods in each line namespace so they pick up the changes made after they were
# first deployed by StartSimulation.sh: the CA trust bundle copied in 12f, and (via the workload-identity
# admission webhook) the projected federated token now that the federated credential exists. Without this
# the pods keep running with the missing configMap / no federated token until the next manual restart.
for line in "${LINES[@]}"; do
    line_ns="$(echo "${line}" | tr '[:upper:]' '[:lower:]')"
    kubectl rollout restart deployment/ua-cloud-action -n "${line_ns}" 2>/dev/null \
        && echo "  restarted ua-cloud-action in '${line_ns}'." \
        || echo "  note: ua-cloud-action deployment not found in '${line_ns}' yet (it will pick up the changes on next start)."
done

# Clean up the generated config files (they contain no secrets).
rm -rf "${AIO_CONFIG_DIR}"

echo
echo "=== Azure IoT Operations (Raspberry Pi 5 / K3s) setup finished: $(date -Is) ==="
echo "AIO ${AIO_INSTALLED_VERSION:-<unknown version>} now reads the simulation OPC UA servers and forwards OPC UA"
echo "PubSub DataSet messages to the '${TELEMETRY_EVENTHUB_NAME}' and '${METADATA_EVENTHUB_NAME}' event hubs,"
echo "so the existing ADX/Fabric/Databricks expansion policies apply."
echo
echo "Notes for the Raspberry Pi:"
echo "  - Check the deployment with: KUBECONFIG=${KUBECONFIG_PATH} az iot ops check"
echo "  - The Key Vault firewall admits the Pi's public IP ${PI_PUBLIC_IP:-<unknown>}. If that IP changes, or after"
echo "    re-deploying arm.json (which resets the firewall's IP rules), re-run this script to restore access."
echo "  - Full log: ${LOG_FILE}"

}

main "$@"
