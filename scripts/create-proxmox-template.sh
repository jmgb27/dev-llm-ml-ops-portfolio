#!/usr/bin/env bash
# One-time golden image for Terraform VM clones.
# Run as root on a Proxmox node (e.g. ssh root@pve).
#
# Creates Ubuntu 24.04 LTS cloud-init template — recommended for K3s + Ansible.
# Documentation: scripts/README.md
set -euo pipefail

VMID="${VMID:-9000}"
VM_NAME="${VM_NAME:-ubuntu-2404-cloudinit}"
STORAGE="${STORAGE:-rpool}"
BRIDGE="${BRIDGE:-vmbr0}"
IMAGE_URL="${IMAGE_URL:-https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img}"
WORKDIR="${WORKDIR:-/var/lib/vz/template/iso}"
IMAGE_FILE="${WORKDIR}/noble-server-cloudimg-amd64.img"
SNIPPET="/var/lib/vz/snippets/vendor-${VMID}.yaml"

echo "==> Creating Proxmox template ${VMID} (${VM_NAME})"
echo "    storage=${STORAGE}  bridge=${BRIDGE}"

if qm status "${VMID}" &>/dev/null; then
  echo "ERROR: VM ID ${VMID} already exists. Pick another VMID or remove it first." >&2
  exit 1
fi

mkdir -p "${WORKDIR}" /var/lib/vz/snippets

if [[ ! -f "${IMAGE_FILE}" ]]; then
  echo "==> Downloading Ubuntu 24.04 cloud image..."
  wget -q --show-progress -O "${IMAGE_FILE}" "${IMAGE_URL}"
else
  echo "==> Using existing image: ${IMAGE_FILE}"
fi

# Install qemu-guest-agent on first boot (required by Terraform BPG provider)
cat > "${SNIPPET}" <<'EOF'
#cloud-config
package_update: true
packages:
  - qemu-guest-agent
runcmd:
  - systemctl enable --now qemu-guest-agent
EOF

echo "==> Creating VM ${VMID}..."
qm create "${VMID}" \
  --name "${VM_NAME}" \
  --memory 2048 \
  --cores 2 \
  --net0 "virtio,bridge=${BRIDGE}"

echo "==> Importing disk to ${STORAGE}..."
qm importdisk "${VMID}" "${IMAGE_FILE}" "${STORAGE}"

qm set "${VMID}" --scsihw virtio-scsi-pci --scsi0 "${STORAGE}:vm-${VMID}-disk-0"
qm set "${VMID}" --ide2 "${STORAGE}:cloudinit"
qm set "${VMID}" --boot order=scsi0
qm set "${VMID}" --serial0 socket --vga serial0
qm set "${VMID}" --agent enabled=1
qm set "${VMID}" --cicustom "vendor=local:snippets/vendor-${VMID}.yaml"

echo "==> First boot (installs qemu-guest-agent)..."
qm start "${VMID}"

echo "    Waiting for guest agent (up to 3 min)..."
for i in $(seq 1 36); do
  if qm agent "${VMID}" ping &>/dev/null; then
    echo "    Guest agent is up."
    break
  fi
  sleep 5
  if [[ "${i}" -eq 36 ]]; then
    echo "WARN: Guest agent did not respond. Check 'qm terminal ${VMID}' then re-run from shutdown step." >&2
  fi
done

echo "==> Shutting down and converting to template..."
qm shutdown "${VMID}" --wait 180 || qm stop "${VMID}"

# Vendor snippet is node-local; drop it so cross-node clones (pve2/pve4) do not inherit it.
# qemu-guest-agent is already baked into the disk from first boot above.
echo "==> Removing node-local cicustom reference (required for multi-node clones)..."
qm set "${VMID}" --delete cicustom

qm template "${VMID}"

echo ""
echo "Done. Template ready:"
qm list | awk -v id="${VMID}" '$1 == id {print}'
echo ""
echo "Set in terraform/terraform.tfvars:"
echo "  template_vm_id  = ${VMID}"
echo "  cloud_init_user = \"ubuntu\""
