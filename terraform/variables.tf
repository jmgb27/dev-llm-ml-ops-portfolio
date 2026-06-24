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
