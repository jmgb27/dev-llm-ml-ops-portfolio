# Proxmox template bootstrap

One-time script to build the **golden image** that Terraform clones when provisioning VMs.

## Why this exists

Terraform clones from an existing Proxmox template — it does not create the base image. This script automates that one-time setup:

1. Downloads the official **Ubuntu 24.04 LTS** cloud image
2. Imports it into Proxmox with cloud-init and virtio
3. Installs **qemu-guest-agent** on first boot (required by the [BPG Terraform provider](https://registry.terraform.io/providers/bpg/proxmox/latest/docs))
4. Converts the VM to a **template** for `terraform apply`

```
Ubuntu cloud image  →  template (9000)  →  Terraform clones  →  Ansible configures
     (this script)         (once)            (repeatable)           (later)
```

## Requirements

- Proxmox VE node with `qm` CLI (run script **as root** on the hypervisor)
- Outbound internet (to download the cloud image)
- Free VM ID (default `9000`)
- Storage pool with `images` content (default `rpool`)
- Network bridge (default `vmbr0`)

## Quick start

From your workstation:

```bash
scp scripts/create-proxmox-template.sh root@<proxmox-host>:/root/
ssh root@<proxmox-host>
bash /root/create-proxmox-template.sh
```

Then in `terraform/terraform.tfvars`:

```hcl
template_vm_id  = 9000
cloud_init_user = "ubuntu"
```

Run `terraform apply`.

## Configuration

All settings are environment variables with sensible defaults:

| Variable | Default | Description |
|----------|---------|-------------|
| `VMID` | `9000` | Proxmox VM/template ID |
| `VM_NAME` | `ubuntu-2404-cloudinit` | Display name in Proxmox UI |
| `STORAGE` | `rpool` | Datastore for disks and cloud-init |
| `BRIDGE` | `vmbr0` | Network bridge attached to the template |
| `IMAGE_URL` | Ubuntu 24.04 noble amd64 cloud image | Override to pin a different release |
| `WORKDIR` | `/var/lib/vz/template/iso` | Where the `.img` file is cached |

Example — different VM ID and storage:

```bash
VMID=9001 STORAGE=local-lvm bash create-proxmox-template.sh
```

If the cloud image already exists in `WORKDIR`, the script skips the download.

## What the script does

| Step | Action |
|------|--------|
| 1 | Abort if VM ID already exists |
| 2 | Download `noble-server-cloudimg-amd64.img` (if missing) |
| 3 | Write a cloud-init vendor snippet to install `qemu-guest-agent` |
| 4 | Create VM, import disk, attach cloud-init drive |
| 5 | Enable QEMU guest agent, set virtio-scsi boot |
| 6 | First boot — guest agent installs via cloud-init |
| 7 | Shutdown, **remove cicustom** (node-local snippet), then `qm template` |

## Troubleshooting

### Cross-node clone: `local:snippets/vendor-9000.yaml` does not exist

The vendor snippet used during first boot only exists on the node where the template was built. If clones to `pve2`/`pve4` fail with this error, fix the existing template on `pve`:

```bash
scp scripts/fix-proxmox-template-cicustom.sh root@pve:/root/
ssh root@pve
bash /root/fix-proxmox-template-cicustom.sh
```

Then re-run `terraform apply`. New templates created with `create-proxmox-template.sh` already remove cicustom before templating.

### VM ID already exists

```bash
qm destroy 9000   # only if you intend to recreate the template
```

Or use a different ID: `VMID=9001 bash create-proxmox-template.sh`

### Guest agent timeout

The script waits up to 3 minutes. If it warns and continues:

```bash
qm terminal 9000
# inside the VM:
sudo apt update && sudo apt install -y qemu-guest-agent
sudo systemctl enable --now qemu-guest-agent
exit

qm shutdown 9000 --wait 120
qm template 9000
```

### Wrong storage or bridge

Check on the Proxmox host:

```bash
pvesm status          # storage pools
cat /etc/network/interfaces   # bridges (vmbr0, etc.)
```

Re-run with overrides: `STORAGE=local-lvm BRIDGE=vmbr1 bash create-proxmox-template.sh`

## Why Ubuntu 24.04?

Chosen for this project's K3s + Ansible stack:

- First-class K3s and cloud-init support
- `ubuntu` default user matches `cloud_init_user` in Terraform
- Modern kernel for containers, cgroup v2, and service mesh sidecars
- AVX2 inference capability comes from **physical host CPU**, not the template — same image works on all nodes

## Related files

- `terraform/` — clones this template and sets CPU, RAM, disk, static IP, SSH keys
- `terraform/terraform.tfvars.example` — copy to `terraform.tfvars` and set `template_vm_id`
