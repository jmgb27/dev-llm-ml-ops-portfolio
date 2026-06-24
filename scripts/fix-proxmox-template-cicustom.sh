#!/usr/bin/env bash
# Fix template 9000 (or VMID) after cross-node clone failures:
#   volume 'local:snippets/vendor-9000.yaml' does not exist
#
# Run as root on the node that hosts the template (default: pve).
# Documentation: scripts/README.md
set -euo pipefail

VMID="${VMID:-9000}"
NODE="${NODE:-pve}"

echo "==> Fixing template ${VMID} on ${NODE}"

if ! pvesh get "/nodes/${NODE}/qemu/${VMID}/config" &>/dev/null; then
  echo "ERROR: VM ${VMID} not found on node ${NODE}" >&2
  exit 1
fi

IS_TEMPLATE="$(pvesh get "/nodes/${NODE}/qemu/${VMID}/config" --output-format json | python3 -c "import json,sys; print(json.load(sys.stdin).get('template',0))")"

if [[ "${IS_TEMPLATE}" == "1" ]]; then
  echo "==> Converting template back to VM..."
  qm set "${VMID}" --template 0
fi

echo "==> Removing cicustom vendor snippet reference..."
qm set "${VMID}" --delete cicustom 2>/dev/null || true

# If fixing an existing template, ensure guest-agent is baked into the disk
# (clones inherit the disk image, not cicustom). Boot once and install if needed.
if [[ "${IS_TEMPLATE}" == "1" ]]; then
  echo "==> Booting VM to verify qemu-guest-agent in disk image..."
  qm start "${VMID}"
  echo "    Waiting up to 3 min for guest agent..."
  AGENT_OK=false
  for i in $(seq 1 36); do
    if qm agent "${VMID}" ping &>/dev/null; then
      AGENT_OK=true
      break
    fi
    sleep 5
  done
  if [[ "${AGENT_OK}" != "true" ]]; then
    echo "WARN: qemu-guest-agent not running. Install via console before templating:" >&2
    echo "  qm terminal ${VMID}" >&2
    echo "  sudo apt update && sudo apt install -y qemu-guest-agent && sudo systemctl start qemu-guest-agent" >&2
    qm stop "${VMID}" || true
    exit 1
  fi
  qm shutdown "${VMID}" --wait 180 || qm stop "${VMID}"
fi

echo "==> Re-converting to template..."
qm template "${VMID}"

echo ""
echo "Done. Re-run: cd terraform && terraform apply"
