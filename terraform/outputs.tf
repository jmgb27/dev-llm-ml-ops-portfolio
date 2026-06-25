output "vm_ids" {
  description = "Proxmox VM IDs keyed by name"
  value       = { for name, vm in proxmox_virtual_environment_vm.k3s : name => vm.vm_id }
}

output "vm_ips" {
  description = "Static IPv4 addresses keyed by VM name"
  value       = { for name, vm in var.vms : name => vm.ip_address }
}

output "ansible_inventory_ini" {
  description = "Render into ansible/inventory.ini after apply"
  value = join("\n", concat(
    ["[k3s_master]"],
    [
      for name, vm in var.vms : "${name} ansible_host=${vm.ip_address} ansible_user=${var.cloud_init_user}"
      if vm.role == "master"
    ],
    [""],
    ["[k3s_workers]"],
    [
      for name, vm in var.vms : "${name} ansible_host=${vm.ip_address} ansible_user=${var.cloud_init_user}"
      if vm.role == "worker"
    ],
    [""],
    ["[k3s_cluster:children]", "k3s_master", "k3s_workers"],
  ))
}

