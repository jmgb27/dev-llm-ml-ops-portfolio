variable "proxmox_endpoint" {
  description = "Proxmox API URL, e.g. https://pve.example.com:8006/"
  type        = string
}

variable "proxmox_api_token" {
  description = "Proxmox API token in the form 'user@pam!tokenid=secret'"
  type        = string
  sensitive   = true
}

variable "proxmox_insecure_tls" {
  description = "Skip TLS verification for self-signed Proxmox certificates"
  type        = bool
  default     = true
}

variable "proxmox_ssh_username" {
  description = "SSH username used by the provider for file uploads (cloud-init snippets)"
  type        = string
  default     = "root"
}

variable "template_vm_id" {
  description = "VM ID of the cloud-init template to clone (Ubuntu/Debian)"
  type        = number
}

variable "template_node_name" {
  description = "Proxmox node where the template VM lives (for cross-node clones)"
  type        = string
}

variable "datastore_id" {
  description = "Proxmox datastore for VM disks and cloud-init"
  type        = string
}

variable "network_bridge" {
  description = "Linux bridge for VM networking"
  type        = string
  default     = "vmbr0"
}

variable "network_gateway" {
  description = "Default gateway for static VM IPs"
  type        = string
}

variable "network_cidr_prefix" {
  description = "CIDR prefix length for static VM IPs (e.g. 24 for /24)"
  type        = number
  default     = 24
}

variable "network_dns_servers" {
  description = "DNS servers passed to cloud-init"
  type        = list(string)
  default     = ["1.1.1.1", "8.8.8.8"]
}

variable "cloud_init_user" {
  description = "Default cloud-init user created by the template"
  type        = string
  default     = "ubuntu"
}

variable "ssh_public_keys" {
  description = "SSH public keys injected via cloud-init"
  type        = list(string)
}

variable "vms" {
  description = "K3s cluster VMs to provision on Proxmox"
  type = map(object({
    node_name  = string
    role       = string # master | worker
    cores      = number
    memory_mb  = number
    disk_gb    = number
    ip_address = string
    tags       = optional(list(string), [])
  }))

  validation {
    condition = alltrue([
      for _, vm in var.vms : contains(["master", "worker"], vm.role)
    ])
    error_message = "Each VM role must be either \"master\" or \"worker\"."
  }
}

variable "enable_litellm_r2_logs" {
  description = "Provision Cloudflare R2 bucket and S3 credentials for LiteLLM audit logs"
  type        = bool
  default     = false
}

variable "cloudflare_account_id" {
  description = "Cloudflare account ID (required when enable_litellm_r2_logs is true)"
  type        = string
  default     = ""
}

variable "cloudflare_api_token" {
  description = "Cloudflare API token with R2 bucket and Account API token permissions (required when enable_litellm_r2_logs is true)"
  type        = string
  sensitive   = true
  default     = null
}

variable "litellm_r2_bucket_name" {
  description = "R2 bucket name for LiteLLM audit logs"
  type        = string
  default     = "litellm-audit-logs"
}

variable "litellm_r2_location" {
  description = "R2 bucket location hint (apac, enam, eeur, weur, wnam, oc); omit for automatic placement"
  type        = string
  default     = "enam"
}

variable "litellm_r2_s3_path" {
  description = "Object key prefix inside the bucket for audit log objects"
  type        = string
  default     = "litellm-audit"
}

variable "litellm_r2_read_permission_group_id" {
  description = "Workers R2 Storage Bucket Item Read permission group id (global Cloudflare constant)"
  type        = string
  default     = "6a018a9f2fc74eb6b293b0c548f38b39"
}

variable "litellm_r2_write_permission_group_id" {
  description = "Workers R2 Storage Bucket Item Write permission group id (global Cloudflare constant)"
  type        = string
  default     = "2efd5506f9c8494dacb1fa10a3e7d5b6"
}

check "litellm_r2_cloudflare_credentials" {
  assert {
    condition = !var.enable_litellm_r2_logs || (
      var.cloudflare_account_id != "" && var.cloudflare_api_token != null && var.cloudflare_api_token != ""
    )
    error_message = "Set cloudflare_account_id and cloudflare_api_token when enable_litellm_r2_logs is true."
  }
}
