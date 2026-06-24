resource "proxmox_virtual_environment_vm" "k3s" {
  for_each = var.vms

  name        = each.key
  description = "Managed by Terraform — configure with Ansible"
  node_name   = each.value.node_name
  tags        = concat(["terraform", "k3s"], each.value.tags)

  timeout_clone  = 1800
  timeout_create = 1800

  clone {
    vm_id     = var.template_vm_id
    node_name = var.template_node_name
    full      = true
    retries   = 5
  }

  # Expose the virtio guest-agent channel; Ansible installs and starts the service.
  # wait_for_ip is off so Terraform does not block on agent ping (we use static IPs).
  agent {
    enabled = true
    wait_for_ip {
      disabled = true
    }
  }

  cpu {
    cores = each.value.cores
    type  = "host"
  }

  memory {
    dedicated = each.value.memory_mb
  }

  disk {
    datastore_id = var.datastore_id
    interface    = "scsi0"
    size         = each.value.disk_gb
    file_format  = "raw"
    ssd          = true
    discard      = "on"
  }

  network_device {
    bridge = var.network_bridge
    model  = "virtio"
  }

  initialization {
    datastore_id = var.datastore_id

    user_account {
      username = var.cloud_init_user
      keys     = var.ssh_public_keys
    }

    dns {
      servers = var.network_dns_servers
    }

    ip_config {
      ipv4 {
        address = "${each.value.ip_address}/${var.network_cidr_prefix}"
        gateway = var.network_gateway
      }
    }
  }

  operating_system {
    type = "l26"
  }

  started = true
  on_boot = true

  lifecycle {
    ignore_changes = [
      initialization[0].user_account,
    ]
  }
}
