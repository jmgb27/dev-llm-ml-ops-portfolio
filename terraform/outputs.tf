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

output "litellm_r2_bucket_name" {
  description = "R2 bucket for LiteLLM audit logs (empty when R2 logging is disabled)"
  value       = var.enable_litellm_r2_logs ? cloudflare_r2_bucket.litellm_audit_logs[0].name : null
}

output "litellm_r2_s3_endpoint_url" {
  description = "S3-compatible endpoint for LiteLLM s3_v2 audit callback"
  value       = var.enable_litellm_r2_logs ? "https://${var.cloudflare_account_id}.r2.cloudflarestorage.com" : null
}

output "litellm_r2_access_key_id" {
  description = "S3 access key ID for LiteLLM (R2 API token id)"
  value       = var.enable_litellm_r2_logs ? cloudflare_api_token.litellm_audit_logs[0].id : null
  sensitive   = true
}

output "litellm_r2_secret_access_key" {
  description = "S3 secret access key for LiteLLM (sha256 of R2 API token value)"
  value       = var.enable_litellm_r2_logs ? sha256(cloudflare_api_token.litellm_audit_logs[0].value) : null
  sensitive   = true
}

output "litellm_r2_s3_path" {
  description = "Object prefix for audit logs inside the bucket"
  value       = var.enable_litellm_r2_logs ? var.litellm_r2_s3_path : null
}
